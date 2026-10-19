extends Node
# Manages chunk creation, deletion, distance-based generation, the remesh queue,
# the spherical render mode and the block break particles.
# Baked lighting detail is controlled by Chunk's LOD settings; this script does not
# use Godot scene lighting.

const CHUNK_MIDPOINT = Vector3(0.5, 0.5, 0.5) * Chunk.CHUNK_SIZE
const CHUNK_END_SIZE = Chunk.CHUNK_SIZE - 1

# Chunks within this many chunks of the player keep their physics colliders switched
# on. Full lighting detail uses Chunk.FULL_LIGHTING_DISTANCE_CHUNKS.
const COLLISION_DISTANCE_CHUNKS = 4
# Generation and meshing run on worker threads, so several chunks can be started per frame.
const CHUNKS_PER_FRAME = 3
# Rebuilds (lighting changes, new neighbors, sphere updates) started per frame.
const REMESH_PER_FRAME = 4
# Finished meshes uploaded to the GPU per frame.
const MESH_APPLIES_PER_FRAME = 6
# The sphere is re-centered after the player moved this many blocks.
const SPHERE_UPDATE_STEP = 3.0
# MULTIPLAYER: key that opens/closes the current world to the LAN ("Open to LAN").
const LAN_TOGGLE_KEY = KEY_F9

var render_distance: int = 8:
	set(value):
		render_distance = maxi(1, value)
		_delete_distance = render_distance + 2

# SPHERE RENDER MODE: when true, only blocks within sphere_radius_blocks of the player
# are drawn instead of whole chunks. 0 radius = render_distance * chunk size.
# Toggle in the inspector, from code (voxel_world.sphere_render_mode = true), or with F4.
var _sphere_dirty := true
@export var sphere_render_mode := false:
	set(value):
		sphere_render_mode = value
		_sphere_dirty = true
@export var sphere_radius_blocks := 0.0:
	set(value):
		sphere_radius_blocks = value
		_sphere_dirty = true

var _delete_distance: int = 10
var effective_render_distance: int = 0
var _old_player_chunk := Vector3i(2147483647, 2147483647, 2147483647)
var _generating := true
var _deleting := false
var _chunks: Dictionary = {}

var _player_chunk := Vector3i.ZERO
var _detail_dirty := false
var _remesh_queue: Array = []
var _remesh_set: Dictionary = {}
var _particles: BlockParticles

# MULTIPLAYER: chunks that exist but still have to receive the recorded block edits
# (Net.edits) once their terrain has finished generating.
var _awaiting_edits: Dictionary = {}
var _remote_players: RemotePlayers
var _seed_synced := false

@onready var player = get_node_or_null("../Player")


func _ready() -> void:
	_particles = BlockParticles.new()
	_particles.world = self
	add_child(_particles)

	# MULTIPLAYER: other players' avatars + on-screen messages, and edit syncing.
	_remote_players = RemotePlayers.new()
	_remote_players.name = "RemotePlayers"
	_remote_players.local_player = player
	add_child(_remote_players)
	Net.block_edit_received.connect(_on_net_block_edit)
	_apply_initial_net_edits()


# MULTIPLAYER: leaving the world (back to the menu, quitting) ends the session.
func _exit_tree() -> void:
	Net.leave_session()


func _unhandled_key_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key != null and key.pressed and not key.echo and key.keycode == KEY_F4:
		sphere_render_mode = not sphere_render_mode
	if key != null and key.pressed and not key.echo and key.keycode == LAN_TOGGLE_KEY:
		_toggle_lan()
		get_viewport().set_input_as_handled()


func _process(_delta: float) -> void:
	# Apply finished generation and mesh jobs from the worker threads.
	Chunk.process_results(MESH_APPLIES_PER_FRAME)
	_apply_awaiting_edits()

	if player == null:
		return

	# MULTIPLAYER: must happen before the first chunk is created (see _sync_world_seed).
	if not _seed_synced:
		_seed_synced = true
		_sync_world_seed()

	render_distance = Settings.render_distance
	var player_chunk := Vector3i((player.global_position / float(Chunk.CHUNK_SIZE)).round())

	# Chunks read this when they are created (should_use_full_lighting and
	# should_keep_chunk_collision), so it has to be current before any are added.
	if player_chunk != _player_chunk:
		_player_chunk = player_chunk
		_detail_dirty = true
	if _detail_dirty:
		_detail_dirty = false
		_refresh_chunk_detail()

	var center: Vector3 = player.global_position
	if _sphere_dirty or (sphere_render_mode and center.distance_squared_to(Chunk.sphere_center) >= SPHERE_UPDATE_STEP * SPHERE_UPDATE_STEP):
		_update_sphere(center)

	_process_remesh_queue()

	if _deleting or player_chunk != _old_player_chunk:
		_delete_far_away_chunks(player_chunk)
		_generating = true

	if not _generating:
		return

	# Bias generation vertically in the direction of player movement.
	var generation_center := player_chunk
	if "velocity" in player:
		generation_center.y += int(round(clampf(player.velocity.y, -render_distance / 4.0, render_distance / 4.0)))

	if _create_chunks(player_chunk, generation_center):
		return

	if effective_render_distance < render_distance:
		effective_render_distance += 1
	else:
		_generating = false


# Creates up to CHUNKS_PER_FRAME chunks. Returns true if any were created.
func _create_chunks(player_chunk: Vector3i, generation_center: Vector3i) -> bool:
	var created := 0
	var reach := effective_render_distance
	var max_sq := render_distance * render_distance
	for x in range(generation_center.x - reach, generation_center.x + reach + 1):
		for y in range(generation_center.y - reach, generation_center.y + reach + 1):
			for z in range(generation_center.z - reach, generation_center.z + reach + 1):
				var chunk_position := Vector3i(x, y, z)
				if (player_chunk - chunk_position).length_squared() > max_sq:
					continue
				if _chunks.has(chunk_position):
					continue

				var chunk := Chunk.new()
				chunk.chunk_position = chunk_position
				_chunks[chunk_position] = chunk
				add_child(chunk)
				# MULTIPLAYER: re-apply recorded edits once this chunk has generated.
				if Net.edits.has(chunk_position):
					_awaiting_edits[chunk_position] = true
				created += 1
				if created >= CHUNKS_PER_FRAME:
					return true
	return created > 0


func get_chunk(chunk_position: Vector3i) -> Chunk:
	return _chunks.get(chunk_position)


func get_block_global_position(block_global_position: Vector3i) -> int:
	var chunk: Chunk = _chunks.get(Vector3i(
			block_global_position.x >> Chunk.CHUNK_SHIFT,
			block_global_position.y >> Chunk.CHUNK_SHIFT,
			block_global_position.z >> Chunk.CHUNK_SHIFT))
	if chunk == null:
		return 0
	return chunk.get_block(Vector3i(
			block_global_position.x & Chunk.CHUNK_MASK,
			block_global_position.y & Chunk.CHUNK_MASK,
			block_global_position.z & Chunk.CHUNK_MASK))


# True if a solid (non-air, non-plant) block occupies the given world position.
func is_solid_at(world_position: Vector3) -> bool:
	var id := get_block_global_position(Vector3i(world_position.floor()))
	return id != 0 and not Chunk.is_block_transparent(id)


# from_network is true for edits that arrive from another player (or the host's edit log);
# those must not be sent back out.
func set_block_global_position(block_global_position: Vector3i, block_id: int, from_network := false) -> void:
	var chunk_position := Vector3i(
			block_global_position.x >> Chunk.CHUNK_SHIFT,
			block_global_position.y >> Chunk.CHUNK_SHIFT,
			block_global_position.z >> Chunk.CHUNK_SHIFT)
	var chunk: Chunk = _chunks.get(chunk_position)
	if chunk == null or not chunk.is_generated():
		if from_network:
			# The chunk is not loaded/generated yet: remember the edit, it is applied
			# as soon as the chunk has finished generating.
			Net.record_edit(chunk_position, block_global_position, block_id)
			if chunk != null:
				_awaiting_edits[chunk_position] = true
		return
	var sub_position := Vector3i(
			block_global_position.x & Chunk.CHUNK_MASK,
			block_global_position.y & Chunk.CHUNK_MASK,
			block_global_position.z & Chunk.CHUNK_MASK)
	var old_id := chunk.get_block(sub_position)
	if old_id == block_id:
		return

	chunk.set_block(sub_position, block_id)
	# MULTIPLAYER: keep a log of every edit (so a regenerated chunk gets it back and
	# late joiners receive it) and tell the other players about local edits.
	Net.record_edit(chunk_position, block_global_position, block_id)
	if not from_network:
		Net.send_block_edit(block_global_position, block_id)
	# Rebuilds this chunk and only the neighbors the edit can reach (light, faces).
	chunk.regenerate(sub_position)

	# Minecraft-style break particles.
	if block_id == 0 and old_id != 0 and _particles != null:
		_particles.spawn_break(Vector3(block_global_position), old_id)


# ---------------------------------------------------------------- MULTIPLAYER

func _on_net_block_edit(block_pos: Vector3i, block_id: int) -> void:
	set_block_global_position(block_pos, block_id, true)


# Edits the host had already made when this client joined (flat x, y, z, id list).
func _apply_initial_net_edits() -> void:
	var flat := Net.take_initial_edits()
	for i in range(0, flat.size() - 3, 4):
		set_block_global_position(Vector3i(flat[i], flat[i + 1], flat[i + 2]), flat[i + 3], true)


# Applies the recorded edits to chunks that have just finished generating.
func _apply_awaiting_edits() -> void:
	if _awaiting_edits.is_empty():
		return
	for chunk_position in _awaiting_edits.keys():
		var chunk: Chunk = _chunks.get(chunk_position)
		if chunk == null or not is_instance_valid(chunk):
			# Chunk was deleted again; it is flagged anew if it gets recreated.
			_awaiting_edits.erase(chunk_position)
			continue
		if not chunk.is_generated():
			continue
		_awaiting_edits.erase(chunk_position)
		var chunk_edits: Dictionary = Net.edits.get(chunk_position, {})
		for block_position in chunk_edits:
			var block: Vector3i = block_position
			var sub_position := Vector3i(
					block.x & Chunk.CHUNK_MASK,
					block.y & Chunk.CHUNK_MASK,
					block.z & Chunk.CHUNK_MASK)
			chunk.set_block(sub_position, chunk_edits[block_position])
			chunk.regenerate(sub_position)


# Every player has to generate the SAME terrain, so the seed is shared:
#  - hosting or joined: use the host's seed (Net.world_seed).
#  - single player: keep whatever seed the game picked, and remember it so that opening
#    the world later (F9) shares the world you are actually standing in.
# Runs on the first frame, after every _ready() and before the first chunk is created,
# so it also wins over a seed picked earlier (e.g. activate_earth_world()).
func _sync_world_seed() -> void:
	if Net.is_online():
		TerrainGenerator.set_world_seed(Net.world_seed)
	else:
		Net.world_seed = TerrainGenerator.world_seed


# F9: open the running world to other players, or close it again (host only).
func _toggle_lan() -> void:
	if Net.is_client:
		return
	if Net.is_host:
		Net.leave_session()
		Net.status_changed.emit("World closed to multiplayer.")
		return
	Net.status_changed.emit("Opening world...")
	Net.open_world()


# Called by Chunk when it is created.
func should_use_full_lighting(chunk_position: Vector3i) -> bool:
	return _distance_sq_to_player(chunk_position) <= Chunk.FULL_LIGHTING_DISTANCE_CHUNKS * Chunk.FULL_LIGHTING_DISTANCE_CHUNKS


# Called by Chunk when it is created.
func should_keep_chunk_collision(chunk_position: Vector3i) -> bool:
	return _distance_sq_to_player(chunk_position) <= COLLISION_DISTANCE_CHUNKS * COLLISION_DISTANCE_CHUNKS


func _distance_sq_to_player(chunk_position: Vector3i) -> int:
	return (_player_chunk - chunk_position).length_squared()


# Rebuilds are throttled and de-duplicated: a chunk asked for by many neighbors is
# only rebuilt once per batch.
func queue_remesh(chunk_position: Vector3i) -> void:
	if _remesh_set.has(chunk_position):
		return
	_remesh_set[chunk_position] = true
	_remesh_queue.append(chunk_position)


func _process_remesh_queue() -> void:
	var budget := REMESH_PER_FRAME
	var head := 0
	var count := _remesh_queue.size()
	while budget > 0 and head < count:
		var chunk_position: Vector3i = _remesh_queue[head]
		head += 1
		_remesh_set.erase(chunk_position)
		var chunk: Chunk = _chunks.get(chunk_position)
		if chunk != null and is_instance_valid(chunk):
			chunk._request_mesh(false)
			budget -= 1
	if head > 0:
		_remesh_queue = _remesh_queue.slice(head)


# The player moved to another chunk: re-enable colliders for chunks that are now
# close, disable them for chunks that are now far, and queue lighting changes.
func _refresh_chunk_detail() -> void:
	for chunk_position in _chunks:
		var chunk: Chunk = _chunks[chunk_position]
		if not is_instance_valid(chunk):
			continue
		chunk.set_collision_enabled(should_keep_chunk_collision(chunk_position))
		if chunk.set_lighting_detail(should_use_full_lighting(chunk_position)):
			queue_remesh(chunk_position)


# Pushes the sphere settings into Chunk and queues every chunk whose mesh no longer
# matches (chunks crossing the sphere surface, or entering/leaving it).
func _update_sphere(center: Vector3) -> void:
	_sphere_dirty = false
	Chunk.sphere_mode = sphere_render_mode
	Chunk.sphere_radius = sphere_radius_blocks if sphere_radius_blocks > 0.0 else float(render_distance * Chunk.CHUNK_SIZE)
	Chunk.sphere_center = center
	for chunk_position in _chunks:
		var chunk: Chunk = _chunks[chunk_position]
		if is_instance_valid(chunk) and chunk.sphere_needs_refresh():
			queue_remesh(chunk_position)


func clean_up() -> void:
	# Worker tasks only post into a static queue, so chunks can be freed at any time.
	set_process(false)
	Chunk.clear_pending_results()
	for chunk in _chunks.values():
		if is_instance_valid(chunk):
			chunk.free()
	_chunks.clear()
	_remesh_queue.clear()
	_remesh_set.clear()
	_awaiting_edits.clear()


func _delete_far_away_chunks(player_chunk: Vector3i) -> void:
	_old_player_chunk = player_chunk
	effective_render_distance = maxi(1, effective_render_distance - 1)

	var deleted_this_frame := 0
	var max_deletions := int(clampi(2 * (render_distance - effective_render_distance), 2, 8))
	var delete_sq := _delete_distance * _delete_distance
	for chunk_position_key in _chunks.keys():
		if (player_chunk - chunk_position_key).length_squared() > delete_sq:
			var chunk = _chunks[chunk_position_key]
			_chunks.erase(chunk_position_key)
			if is_instance_valid(chunk):
				chunk.queue_free()
			deleted_this_frame += 1
			if deleted_this_frame >= max_deletions:
				_deleting = true
				return

	_deleting = false

class_name Chunk extends StaticBody3D

# Chunks are created by VoxelWorld. Everything expensive happens on the
# WorkerThreadPool and finished results are applied on the main thread:
#
#   1. _ready() starts a generation task (TerrainGenerator, packed byte array).
#   2. When blocks arrive, a mesh task builds the vertex arrays, the baked
#      lighting and ONE trimesh collider for the whole chunk.
#   3. Tasks never touch this node. They post a result into a static queue and
#      VoxelWorld calls Chunk.process_results() every frame, so freeing a chunk
#      while a task is still running is safe.
#
# Blocks are stored in a PackedByteArray of CHUNK_VOLUME ids, indexed
# (y * CHUNK_SIZE + z) * CHUNK_SIZE + x. An empty array means "all air".
# Use get_block() / set_block() instead of the old `data` dictionary.
#
# LIGHTING (modelled on Minecraft)
#   * Sky light: air with open sky above is level 15, then spreads sideways and
#     downward losing 1 level per block. Sealed rooms get no sky light.
#   * Block light: emitters (BLOCK_EMISSION) spread light the same way.
#   * Every vertex averages the light of the 4 blocks around it (smooth lighting),
#     then multiplies in ambient occlusion and the per-direction face shade.
#   * All of it is baked into vertex colors and multiplied with the texture.
# Chunks farther than FULL_LIGHTING_DISTANCE_CHUNKS skip the light flood and AO.
#
# SPHERE MODE
#   When Chunk.sphere_mode is on, only blocks whose centre lies within
#   Chunk.sphere_radius of Chunk.sphere_center are meshed. Faces are still culled
#   against the real world, so the cut-off never shows hollow insides.

const CHUNK_SIZE = 16 # Keep in sync with TerrainGenerator.
const CHUNK_SHIFT = 4 # CHUNK_SIZE == 1 << CHUNK_SHIFT
const CHUNK_MASK = CHUNK_SIZE - 1
const CHUNK_VOLUME = CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE
const TEXTURE_SHEET_WIDTH = 8
const CHUNK_LAST_INDEX = CHUNK_SIZE - 1
const TEXTURE_TILE_SIZE = 1.0 / TEXTURE_SHEET_WIDTH

# ------------------------------------------------------------------ tuning ---
# Brightness multiplier per AO level. Index 0 = boxed-in corner, 3 = open.
const AO_CURVE = [0.30, 0.50, 0.75, 1.0]

# Brightness of light level 0. Minecraft uses about 0.05 (almost black).
const MIN_BRIGHTNESS = 0.05

# Blocks that give off light: block id -> light level (0-15).
const BLOCK_EMISSION = { 5: 13 }

# true  = lighting comes only from the baked vertex colors (classic Minecraft look).
# false = baked lighting is multiplied with normal Godot lighting.
const UNSHADED = true

# true  = regenerate() rebuilds the mesh on a worker thread.
# false = regenerate() rebuilds it immediately on the calling thread.
const REGENERATE_ASYNC = true

# When this chunk loads or changes, rebuild the neighbors that can be affected.
const UPDATE_NEIGHBORS = true

# Chunks beyond this radius skip the padded light flood, smooth lighting and AO.
const FULL_LIGHTING_DISTANCE_CHUNKS = 3

# Minecraft's "sky light subtracted": 0 = full daylight, up to ~11 = night.
# It only affects meshes built after it is changed.
static var sky_light_reduction := 0

# Spherical render mode. VoxelWorld keeps these up to date.
static var sphere_mode := false
static var sphere_radius := 64.0
static var sphere_center := Vector3.ZERO

# ------------------------------------------------------------ light engine ---
const LIGHT_MAX = 15
const PAD_FULL = LIGHT_MAX # Padding of the region used for full lighting.
const PAD_FAST = 1         # Padding when only face culling is needed.

# x-, x+, z-, z+, y-, y+ (the first four are the horizontal ones).
const DIR_X = [-1, 1, 0, 0, 0, 0]
const DIR_Y = [0, 0, 0, 0, -1, 1]
const DIR_Z = [0, 0, -1, 1, 0, 0]

const UV_SIDE = 0
const UV_TOP = 1
const UV_BOTTOM = 2

const SPHERE_OUTSIDE = 0
const SPHERE_PARTIAL = 1
const SPHERE_INSIDE = 2

# One entry per cube face (same order as DIR_*):
#   normal - direction the face points (also the neighbor block to check)
#   verts  - indices into CORNERS, clockwise winding
#   shade  - Minecraft's per-direction face brightness
#   uv     - which texture variant the face uses
const FACES = [
	{ "normal": Vector3i.LEFT,    "verts": [3, 0, 4, 7], "shade": 0.6, "uv": UV_SIDE },
	{ "normal": Vector3i.RIGHT,   "verts": [1, 2, 6, 5], "shade": 0.6, "uv": UV_SIDE },
	{ "normal": Vector3i.FORWARD, "verts": [0, 1, 5, 4], "shade": 0.8, "uv": UV_SIDE },
	{ "normal": Vector3i.BACK,    "verts": [2, 3, 7, 6], "shade": 0.8, "uv": UV_SIDE },
	{ "normal": Vector3i.DOWN,    "verts": [2, 1, 0, 3], "shade": 0.5, "uv": UV_BOTTOM },
	{ "normal": Vector3i.UP,      "verts": [4, 5, 6, 7], "shade": 1.0, "uv": UV_TOP },
]

# Offset of each cube corner from the block origin.
const CORNERS = [
	Vector3i(0, 0, 0), Vector3i(1, 0, 0), Vector3i(1, 0, 1), Vector3i(0, 0, 1),
	Vector3i(0, 1, 0), Vector3i(1, 1, 0), Vector3i(1, 1, 1), Vector3i(0, 1, 1),
]

# The blocks around (and including) this chunk as flat byte arrays, so the light
# flood and the mesher never touch dictionaries or other nodes.
# Cell index = (y * size + z) * size + x in region coordinates (local + pad).
class Region extends RefCounted:
	var pad := 0
	var size := 0
	var area := 0
	var blocks := PackedByteArray()    # Block id per cell (0 = air).
	var solid := PackedByteArray()     # 1 where the block stops light / hides faces.
	var top := PackedInt32Array()      # Per column: highest solid y, or -1 (full lighting only).
	var sky := PackedByteArray()       # Sky light per cell (full lighting only).
	var blk := PackedByteArray()       # Block light per cell (full lighting only).
	var emitters := PackedInt32Array() # Cells that start a block light flood.

	func _init(p_pad: int, p_size: int, with_light: bool) -> void:
		pad = p_pad
		size = p_size
		area = p_size * p_size
		var volume := area * p_size
		blocks.resize(volume)
		solid.resize(volume)
		if with_light:
			sky.resize(volume)
			blk.resize(volume)
			top.resize(area)
			top.fill(-1)


# Growing vertex arrays of one chunk mesh.
class MeshBuf extends RefCounted:
	var positions := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	var with_normals := false

	func add_quad(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3,
			uv0: Vector2, uv1: Vector2, uv2: Vector2, uv3: Vector2,
			c0: Color, c1: Color, c2: Color, c3: Color, normal: Vector3, flip: bool) -> void:
		var base := positions.size()
		positions.push_back(p0)
		positions.push_back(p1)
		positions.push_back(p2)
		positions.push_back(p3)
		uvs.push_back(uv0)
		uvs.push_back(uv1)
		uvs.push_back(uv2)
		uvs.push_back(uv3)
		colors.push_back(c0)
		colors.push_back(c1)
		colors.push_back(c2)
		colors.push_back(c3)
		if with_normals:
			normals.push_back(normal)
			normals.push_back(normal)
			normals.push_back(normal)
			normals.push_back(normal)
		# Both splits keep the clockwise winding order.
		if flip:
			indices.push_back(base + 1)
			indices.push_back(base + 2)
			indices.push_back(base + 3)
			indices.push_back(base + 1)
			indices.push_back(base + 3)
			indices.push_back(base)
		else:
			indices.push_back(base)
			indices.push_back(base + 1)
			indices.push_back(base + 2)
			indices.push_back(base)
			indices.push_back(base + 2)
			indices.push_back(base + 3)


var blocks := PackedByteArray()
var chunk_position := Vector3i()

var _gen_done := false
var _remesh_pending := false
var _mesh_serial := 0       # Newest job (or synchronous rebuild) started.
var _running_serial := 0    # Serial of the job currently on a worker, 0 if none.
var _mesh_instance: MeshInstance3D
var _collision_shape: CollisionShape3D
var _full_lighting := true
var _collisions_enabled := true
var _collision_dirty := true # The collider must be rebuilt by the next job.
var _sphere_state := SPHERE_INSIDE

# Shared by every chunk. Built once on the main thread (see _ready).
static var _material: BaseMaterial3D

# Lookup tables, built once on the main thread before any task starts.
static var _tables_ready := false
static var _tile_side := PackedInt32Array()
static var _tile_top := PackedInt32Array()
static var _tile_bottom := PackedInt32Array()
static var _bright_lut := PackedFloat32Array() # index = 4 * light level (0-60)

# Results posted by worker tasks, applied by process_results().
static var _results: Array = []
static var _results_mutex := Mutex.new()

@onready var voxel_world = get_parent()


func _ready() -> void:
	_ensure_tables()
	_get_material()

	transform.origin = Vector3(chunk_position * CHUNK_SIZE)
	name = str(chunk_position)
	_full_lighting = voxel_world.should_use_full_lighting(chunk_position)
	_collisions_enabled = voxel_world.should_keep_chunk_collision(chunk_position)
	collision_layer = 0
	collision_mask = 0

	# Settings.world_type is set by the main menu: 0 = random blocks, 1 = flat grass, 2 = earth.
	WorkerThreadPool.add_task(_generate_task.bind(get_instance_id(), chunk_position, Settings.world_type), false, "chunk generation")


func _exit_tree() -> void:
	# Running tasks only touch their own copies of the data and post into the
	# static queue, so there is nothing to wait for. Stale results are dropped.
	_mesh_serial += 1


# ----------------------------------------------------------------- blocks ---

func is_generated() -> bool:
	return _gen_done


func get_block(local: Vector3i) -> int:
	if blocks.is_empty():
		return 0
	return blocks[(local.y * CHUNK_SIZE + local.z) * CHUNK_SIZE + local.x]


func set_block(local: Vector3i, block_id: int) -> void:
	if blocks.is_empty():
		if block_id == 0:
			return
		blocks.resize(CHUNK_VOLUME)
	blocks[(local.y * CHUNK_SIZE + local.z) * CHUNK_SIZE + local.x] = block_id


# Call after set_block(). Pass the edited block's local position so only the
# neighbors whose light or faces can actually change are rebuilt.
func regenerate(edit_local := Vector3i(-1000, -1000, -1000)) -> void:
	if REGENERATE_ASYNC:
		_request_mesh(true)
	else:
		_rebuild_mesh_now()
	if UPDATE_NEIGHBORS:
		_notify_edit(edit_local)


# Returns true only when the mesh format must change. VoxelWorld queues the rebuild.
func set_lighting_detail(enabled: bool) -> bool:
	if _full_lighting == enabled:
		return false
	_full_lighting = enabled
	return true


# Disable distant chunks in the physics broadphase. The collider is cached and
# switched back on before the player can get close.
func set_collision_enabled(enabled: bool) -> void:
	if _collisions_enabled == enabled:
		return
	_collisions_enabled = enabled
	if enabled and _collision_dirty:
		_request_mesh(false)
	else:
		_apply_collision_state()


# True when the last mesh no longer matches the sphere (VoxelWorld then queues it).
func sphere_needs_refresh() -> bool:
	if not _gen_done or blocks.is_empty():
		return false
	var state := _compute_sphere_state()
	return state != _sphere_state or state == SPHERE_PARTIAL


func _compute_sphere_state() -> int:
	if not sphere_mode:
		return SPHERE_INSIDE
	var low := Vector3(chunk_position * CHUNK_SIZE)
	var high := low + Vector3.ONE * CHUNK_SIZE
	var r2 := sphere_radius * sphere_radius
	var nearest := sphere_center.clamp(low, high)
	if nearest.distance_squared_to(sphere_center) > r2:
		return SPHERE_OUTSIDE
	var far := Vector3(
			maxf(absf(sphere_center.x - low.x), absf(sphere_center.x - high.x)),
			maxf(absf(sphere_center.y - low.y), absf(sphere_center.y - high.y)),
			maxf(absf(sphere_center.z - low.z), absf(sphere_center.z - high.z)))
	if far.length_squared() <= r2:
		return SPHERE_INSIDE
	return SPHERE_PARTIAL


# ------------------------------------------------------------------ tables ---

static func _ensure_tables() -> void:
	if _tables_ready:
		return
	_tile_side.resize(256)
	_tile_top.resize(256)
	_tile_bottom.resize(256)
	for i in 256:
		_tile_side[i] = i
		_tile_top[i] = i
		_tile_bottom[i] = i
	_tile_top[3] = 0     # Grass: top 0, bottom dirt.
	_tile_bottom[3] = 2
	_tile_top[5] = 31    # Furnace.
	_tile_bottom[5] = 31
	_tile_top[12] = 30   # Log.
	_tile_bottom[12] = 30
	_tile_top[19] = 4    # Bookshelf.
	_tile_bottom[19] = 4

	_bright_lut.resize(LIGHT_MAX * 4 + 1)
	for i in _bright_lut.size():
		_bright_lut[i] = _brightness(i * 0.25)
	_tables_ready = true


static func _get_material() -> BaseMaterial3D:
	if _material == null:
		var mat = (preload("res://world/textures/material.tres") as BaseMaterial3D).duplicate() as BaseMaterial3D

		# Vertex colors carry all the lighting information.
		mat.vertex_color_use_as_albedo = true
		# Treat the brightness values like sRGB so 0.5 really looks half as bright.
		mat.vertex_color_is_srgb = true

		# Crisp pixel art, and no bleeding between tiles on the texture sheet.
		mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST

		# Normal/height maps fight with baked lighting, so they are off.
		mat.normal_enabled = false
		mat.heightmap_enabled = false

		mat.roughness = 1.0
		mat.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
		if UNSHADED:
			mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		else:
			mat.diffuse_mode = BaseMaterial3D.DIFFUSE_LAMBERT

		_material = mat
	return _material


# The texture sheet, also used by the block break particles.
static func get_atlas_texture() -> Texture2D:
	return _get_material().albedo_texture


# --------------------------------------------------- worker tasks / results ---

static func _post_result(result: Dictionary) -> void:
	_results_mutex.lock()
	_results.append(result)
	_results_mutex.unlock()


static func clear_pending_results() -> void:
	_results_mutex.lock()
	_results.clear()
	_results_mutex.unlock()


# Applies finished worker results. Call once per frame from VoxelWorld.
# Generation results are cheap; only finished meshes count against the budget.
static func process_results(mesh_budget: int) -> void:
	_results_mutex.lock()
	if _results.is_empty():
		_results_mutex.unlock()
		return
	var pending := _results
	_results = []
	_results_mutex.unlock()

	var used := 0
	var i := 0
	var count := pending.size()
	while i < count and used < mesh_budget:
		var result: Dictionary = pending[i]
		i += 1
		var chunk := instance_from_id(result["id"]) as Chunk
		if chunk == null:
			continue # The chunk was deleted while the task ran.
		chunk._on_result(result)
		if result["kind"] == 1:
			used += 1
	if i < count:
		_results_mutex.lock()
		_results = pending.slice(i) + _results
		_results_mutex.unlock()


static func _generate_task(id: int, chunk_position: Vector3i, world_type: int) -> void:
	_post_result({ "id": id, "kind": 0, "blocks": TerrainGenerator.generate(chunk_position, world_type) })


static func _mesh_task(id: int, job: Dictionary, serial: int) -> void:
	_post_result(_build_job(id, job, serial))


func _on_result(result: Dictionary) -> void:
	if result["kind"] == 0:
		_on_generated(result["blocks"])
	else:
		_on_mesh_result(result)


func _on_generated(generated: PackedByteArray) -> void:
	blocks = generated
	_gen_done = true
	if not blocks.is_empty():
		_request_mesh(true)
	# Neighbors built before this chunk existed assumed it was empty, and neighbors
	# waiting for this chunk to generate can be meshed now (even if it is all air).
	_notify_loaded()


func _on_mesh_result(result: Dictionary) -> void:
	var serial: int = result["serial"]
	if serial == _running_serial:
		_running_serial = 0
	if serial == _mesh_serial:
		_apply_job_result(result)
	elif result["faces"] != null:
		_collision_dirty = true # A collider that was never applied.
	if _remesh_pending and _running_serial == 0:
		_remesh_pending = false
		_request_mesh(false)


func _apply_job_result(result: Dictionary) -> void:
	_apply_mesh(result["mesh"])
	if result["faces"] != null:
		_apply_collision_faces(result["faces"])


# ------------------------------------------------------------ mesh requests ---

func _neighbors_generated() -> bool:
	# Wait for neighbors that exist but have no blocks yet: they request a rebuild
	# of this chunk themselves as soon as they finish, so the border is meshed once.
	for face in FACES:
		var other: Chunk = voxel_world.get_chunk(chunk_position + face["normal"])
		if other != null and not other._gen_done:
			return false
	return true


func _request_mesh(collision: bool = true) -> void:
	if collision:
		_collision_dirty = true
	if not _gen_done or blocks.is_empty():
		return
	if _running_serial != 0:
		# One more rebuild afterwards covers any number of requests.
		_remesh_pending = true
		return
	if not _neighbors_generated():
		return
	_start_mesh_job()


func _make_job() -> Dictionary:
	var neighbors := {}
	for oy in range(-1, 2):
		for oz in range(-1, 2):
			for ox in range(-1, 2):
				if ox == 0 and oy == 0 and oz == 0:
					continue
				# Fast meshes only need the six face-adjacent chunks; full lighting
				# needs the whole 3x3x3 neighborhood.
				if not _full_lighting and absi(ox) + absi(oy) + absi(oz) != 1:
					continue
				var other: Chunk = voxel_world.get_chunk(chunk_position + Vector3i(ox, oy, oz))
				if other != null and not other.blocks.is_empty():
					neighbors[Vector3i(ox, oy, oz)] = other.blocks.duplicate()

	_sphere_state = _compute_sphere_state()
	var want_collision := _collision_dirty and _collisions_enabled
	if want_collision:
		_collision_dirty = false
	return {
		"blocks": blocks.duplicate(),
		"neighbors": neighbors,
		"full": _full_lighting,
		"collision": want_collision,
		"sphere_state": _sphere_state,
		"sphere_center": sphere_center,
		"sphere_r2": sphere_radius * sphere_radius,
		"origin": Vector3(chunk_position * CHUNK_SIZE),
	}


func _start_mesh_job() -> void:
	_remesh_pending = false
	var job := _make_job()
	if job["sphere_state"] == SPHERE_OUTSIDE and not job["collision"]:
		_apply_mesh(null) # Entirely outside the sphere, nothing to build.
		return
	_mesh_serial += 1
	_running_serial = _mesh_serial
	WorkerThreadPool.add_task(_mesh_task.bind(get_instance_id(), job, _mesh_serial), false, "chunk mesh")


func _rebuild_mesh_now() -> void:
	if not _gen_done or blocks.is_empty():
		return
	_remesh_pending = false
	_collision_dirty = true
	_mesh_serial += 1 # Any job still in flight is now stale.
	_apply_job_result(_build_job(get_instance_id(), _make_job(), _mesh_serial))


func _apply_mesh(mesh: ArrayMesh) -> void:
	if mesh == null:
		if _mesh_instance != null:
			_mesh_instance.mesh = null
		return
	if _mesh_instance == null:
		_mesh_instance = MeshInstance3D.new()
		_mesh_instance.material_override = _get_material()
		if UNSHADED:
			# Unshaded meshes never receive shadows, so don't pay to cast them either.
			_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(_mesh_instance)
	_mesh_instance.mesh = mesh


# ---------------------------------------------------------------- colliders ---

func _apply_collision_faces(faces: PackedVector3Array) -> void:
	if faces.is_empty():
		if _collision_shape != null:
			_collision_shape.queue_free()
			_collision_shape = null
	else:
		if _collision_shape == null:
			_collision_shape = CollisionShape3D.new()
			add_child(_collision_shape)
		var shape := ConcavePolygonShape3D.new()
		shape.backface_collision = true
		shape.set_faces(faces)
		_collision_shape.shape = shape
	_apply_collision_state()


func _apply_collision_state() -> void:
	var active := _collisions_enabled and _collision_shape != null
	collision_layer = 0xFFFFF if active else 0
	collision_mask = 0xFFFFF if active else 0


# ---------------------------------------------------------- neighbor updates ---

# This chunk just got its blocks: rebuild neighbors, spread over several frames.
func _notify_loaded() -> void:
	if not UPDATE_NEIGHBORS:
		return
	for oy in range(-1, 2):
		for oz in range(-1, 2):
			for ox in range(-1, 2):
				var manhattan := absi(ox) + absi(oy) + absi(oz)
				if manhattan == 0:
					continue
				if not _full_lighting and manhattan != 1:
					continue
				var offset := Vector3i(ox, oy, oz)
				var other: Chunk = voxel_world.get_chunk(chunk_position + offset)
				if other == null or other.blocks.is_empty() or not other._gen_done:
					continue
				if other._full_lighting or manhattan == 1:
					voxel_world.queue_remesh(chunk_position + offset)


# A block was edited: rebuild right away, but only neighbors the change can reach.
# Light travels at most LIGHT_MAX blocks, so the distance from the edited block to
# the neighbor decides. A negative local position means "unknown, rebuild all".
func _notify_edit(local: Vector3i) -> void:
	var known := local.x >= 0
	for oy in range(-1, 2):
		for oz in range(-1, 2):
			for ox in range(-1, 2):
				var manhattan := absi(ox) + absi(oy) + absi(oz)
				if manhattan == 0:
					continue
				var reach := 0
				if known:
					reach = _edge_distance(local.x, ox) + _edge_distance(local.y, oy) + _edge_distance(local.z, oz)
				var other: Chunk = voxel_world.get_chunk(chunk_position + Vector3i(ox, oy, oz))
				if other == null or other.blocks.is_empty():
					continue
				if other._full_lighting:
					if known and reach > LIGHT_MAX:
						continue
				else:
					if manhattan != 1 or (known and reach != 1):
						continue
				other._request_mesh(true)


# Distance along one axis from block coordinate c to the chunk at offset o.
static func _edge_distance(c: int, o: int) -> int:
	if o < 0:
		return c + 1
	if o > 0:
		return CHUNK_SIZE - c
	return 0


# ------------------------------------------------------------------- light ---

# Light level (0-15, can be fractional) -> brightness. This is Minecraft's
# classic light curve: it falls off quickly, then flattens out near the dark end.
static func _brightness(level: float) -> float:
	var f := 1.0 - clampf(level, 0.0, float(LIGHT_MAX)) / LIGHT_MAX
	var b := (1.0 - f) / (f * 3.0 + 1.0)
	return b * (1.0 - MIN_BRIGHTNESS) + MIN_BRIGHTNESS


# Copies one chunk's blocks into the region. offset is that chunk's position
# relative to the meshed chunk, (0, 0, 0) being the chunk itself.
static func _fill_region(region: Region, offset: Vector3i, src: PackedByteArray, with_light: bool) -> void:
	var size := region.size
	var area := region.area
	var bx := offset.x * CHUNK_SIZE + region.pad
	var by := offset.y * CHUNK_SIZE + region.pad
	var bz := offset.z * CHUNK_SIZE + region.pad
	# Only the part of the source chunk that falls inside the region.
	var x0 := maxi(0, -bx)
	var x1 := mini(CHUNK_SIZE - 1, size - 1 - bx)
	var y0 := maxi(0, -by)
	var y1 := mini(CHUNK_SIZE - 1, size - 1 - by)
	var z0 := maxi(0, -bz)
	var z1 := mini(CHUNK_SIZE - 1, size - 1 - bz)
	if x0 > x1 or y0 > y1 or z0 > z1:
		return

	var rblocks := region.blocks
	var rsolid := region.solid
	var rtop := region.top
	for y in range(y0, y1 + 1):
		var ry := y + by
		for z in range(z0, z1 + 1):
			var src_row := (y * CHUNK_SIZE + z) * CHUNK_SIZE
			var rz := z + bz
			var dst_row := ry * area + rz * size + bx
			for x in range(x0, x1 + 1):
				var id := src[src_row + x]
				if id == 0:
					continue
				var i := dst_row + x
				rblocks[i] = id
				if id != 27 and id != 28:
					rsolid[i] = 1
					if with_light:
						var col := rz * size + x + bx
						if ry > rtop[col]:
							rtop[col] = ry
				if with_light and BLOCK_EMISSION.has(id):
					region.blk[i] = BLOCK_EMISSION[id]
					region.emitters.append(i)


static func _build_region(job: Dictionary) -> Region:
	var full: bool = job["full"]
	var pad := PAD_FULL if full else PAD_FAST
	var region := Region.new(pad, CHUNK_SIZE + pad * 2, full)
	_fill_region(region, Vector3i.ZERO, job["blocks"], full)
	var neighbors: Dictionary = job["neighbors"]
	for offset in neighbors:
		_fill_region(region, offset, neighbors[offset], full)
	if full:
		_compute_light(region)
	return region


static func _compute_light(region: Region) -> void:
	var size := region.size
	var area := region.area
	var solid := region.solid
	var top := region.top
	var sky := region.sky

	# Sky light. Cells above the highest solid block of their column are open sky
	# (level 15) and are not stored. Light only has to be spread into the cells
	# below those roofs, so the flood starts where an open-sky cell sits next to a
	# column whose roof is higher: the air in that neighbor column, between our roof
	# and its roof, gets level 14.
	var queue := PackedInt32Array()
	for rz in size:
		for rx in size:
			var col := rz * size + rx
			var own_top := top[col]
			for d in 4:
				var nx: int = rx + DIR_X[d]
				var nz: int = rz + DIR_Z[d]
				if nx < 0 or nz < 0 or nx >= size or nz >= size:
					continue
				var ncol := nz * size + nx
				for ry in range(own_top + 1, top[ncol] + 1):
					var ni := ry * area + ncol
					if solid[ni] == 0 and sky[ni] < LIGHT_MAX - 1:
						sky[ni] = LIGHT_MAX - 1
						queue.append(ni)
	_flood(region, sky, queue, true)

	# Block light starts at the emitters and floods the same way.
	if not region.emitters.is_empty():
		_flood(region, region.blk, region.emitters, false)

	# Store level 15 for open-sky cells in the part the mesher samples
	# (this chunk plus one block of border).
	var lo := PAD_FULL - 1
	var hi := PAD_FULL + CHUNK_SIZE
	for ry in range(lo, hi + 1):
		for rz in range(lo, hi + 1):
			for rx in range(lo, hi + 1):
				var col := rz * size + rx
				if ry > top[col]:
					sky[ry * area + col] = LIGHT_MAX


# Breadth-first light spread: each step loses one level and light never enters
# solid blocks.
@warning_ignore("integer_division")
static func _flood(region: Region, light: PackedByteArray, queue: PackedInt32Array, is_sky: bool) -> void:
	var size := region.size
	var area := region.area
	var solid := region.solid
	var top := region.top
	var head := 0
	while head < queue.size():
		var i := queue[head]
		head += 1
		var level: int = light[i]
		if level <= 1:
			continue
		var ry := i / area
		var rem := i - ry * area
		var rz := rem / size
		var rx := rem - rz * size
		var next := level - 1
		for d in 6:
			var nx: int = rx + DIR_X[d]
			var ny: int = ry + DIR_Y[d]
			var nz: int = rz + DIR_Z[d]
			if nx < 0 or ny < 0 or nz < 0 or nx >= size or ny >= size or nz >= size:
				continue
			var ncol := nz * size + nx
			var j := ny * area + ncol
			if solid[j] != 0 or light[j] >= next:
				continue
			if is_sky and ny > top[ncol]:
				continue # Open sky is already at full level.
			light[j] = next
			queue.append(j)


# -------------------------------------------------------------------- mesh ---

# Runs on a worker thread. Builds the vertex arrays and, when asked, the collision
# triangles from one snapshot of the blocks.
static func _build_job(id: int, job: Dictionary, serial: int) -> Dictionary:
	var result := { "id": id, "kind": 1, "serial": serial, "mesh": null, "faces": null }
	var chunk_blocks: PackedByteArray = job["blocks"]
	var full: bool = job["full"]
	var want_collision: bool = job["collision"]
	var sphere_state: int = job["sphere_state"]
	var want_mesh := sphere_state != SPHERE_OUTSIDE
	if chunk_blocks.is_empty() or (not want_mesh and not want_collision):
		return result

	var region := _build_region(job)
	var size := region.size
	var area := region.area
	var pad := region.pad
	var rsolid := region.solid
	var rblocks := region.blocks
	var sky := region.sky
	var blk := region.blk

	# Cell offsets and corner geometry for each face, in the order of FACES.
	var steps := PackedInt32Array([-1, 1, -size, size, -area, area])
	var fvert := PackedVector3Array()
	var ao_u := PackedInt32Array()
	var ao_v := PackedInt32Array()
	fvert.resize(24)
	ao_u.resize(24)
	ao_v.resize(24)
	var shade := PackedFloat32Array()
	var uv_kind := PackedInt32Array()
	var normals := PackedVector3Array()
	for f in 6:
		var face: Dictionary = FACES[f]
		var normal: Vector3i = face["normal"]
		var verts: Array = face["verts"]
		shade.append(face["shade"])
		uv_kind.append(face["uv"])
		normals.append(Vector3(normal))
		for k in 4:
			var corner: Vector3i = CORNERS[verts[k]]
			fvert[f * 4 + k] = Vector3(corner)
			var c := corner * 2 - Vector3i.ONE # -1 or +1 on each axis
			var u: Vector3i
			var v: Vector3i
			if normal.x != 0:
				u = Vector3i(0, c.y, 0)
				v = Vector3i(0, 0, c.z)
			elif normal.y != 0:
				u = Vector3i(c.x, 0, 0)
				v = Vector3i(0, 0, c.z)
			else:
				u = Vector3i(c.x, 0, 0)
				v = Vector3i(0, c.y, 0)
			ao_u[f * 4 + k] = u.x + u.y * area + u.z * size
			ao_v[f * 4 + k] = v.x + v.y * area + v.z * size

	var buf := MeshBuf.new()
	buf.with_normals = not UNSHADED
	var collision_faces := PackedVector3Array()

	var tile_size := TEXTURE_TILE_SIZE
	var reduction4 := sky_light_reduction * 4
	var partial := sphere_state == SPHERE_PARTIAL
	var rel: Vector3 = job["sphere_center"] - job["origin"] - Vector3(0.5, 0.5, 0.5)
	var r2: float = job["sphere_r2"]

	for y in CHUNK_SIZE:
		for z in CHUNK_SIZE:
			var row := (y * CHUNK_SIZE + z) * CHUNK_SIZE
			for x in CHUNK_SIZE:
				var block_id: int = chunk_blocks[row + x]
				if block_id == 0:
					continue

				var draw_it := want_mesh
				if draw_it and partial:
					var dx := x - rel.x
					var dy := y - rel.y
					var dz := z - rel.z
					draw_it = dx * dx + dy * dy + dz * dz <= r2

				var cell := (y + pad) * area + (z + pad) * size + (x + pad)
				var origin := Vector3(x, y, z)

				# Bushes: two crossed quads lit by their own cell, no collision.
				if block_id == 27 or block_id == 28:
					if not draw_it:
						continue
					var level := 15.0
					if full:
						level = maxf(float(sky[cell]) - sky_light_reduction, float(blk[cell]))
					var pb := _brightness(level)
					var pc := Color(pb, pb, pb)
					var ptile := _tile_side[block_id]
					var px := (ptile % TEXTURE_SHEET_WIDTH) * tile_size
					var py := (ptile / TEXTURE_SHEET_WIDTH) * tile_size
					var puv0 := Vector2(px, py + tile_size)
					var puv1 := Vector2(px + tile_size, py + tile_size)
					var puv2 := Vector2(px + tile_size, py)
					var puv3 := Vector2(px, py)
					var cv := func(k: int) -> Vector3: return origin + Vector3(CORNERS[k])
					buf.add_quad(cv.call(2), cv.call(0), cv.call(7), cv.call(5), puv0, puv1, puv2, puv3, pc, pc, pc, pc, Vector3.UP, false)
					buf.add_quad(cv.call(7), cv.call(5), cv.call(2), cv.call(0), puv0, puv1, puv2, puv3, pc, pc, pc, pc, Vector3.UP, false)
					buf.add_quad(cv.call(3), cv.call(1), cv.call(6), cv.call(4), puv0, puv1, puv2, puv3, pc, pc, pc, pc, Vector3.UP, false)
					buf.add_quad(cv.call(6), cv.call(4), cv.call(3), cv.call(1), puv0, puv1, puv2, puv3, pc, pc, pc, pc, Vector3.UP, false)
					continue

				if not draw_it and not want_collision:
					continue

				for f in 6:
					# "front" is the cell the face looks into. Faces next to a solid
					# block can never be seen or touched.
					var front := cell + steps[f]
					if rsolid[front] != 0:
						continue

					var fi := f * 4
					var p0 := origin + fvert[fi]
					var p1 := origin + fvert[fi + 1]
					var p2 := origin + fvert[fi + 2]
					var p3 := origin + fvert[fi + 3]

					if want_collision:
						collision_faces.push_back(p0)
						collision_faces.push_back(p1)
						collision_faces.push_back(p2)
						collision_faces.push_back(p0)
						collision_faces.push_back(p2)
						collision_faces.push_back(p3)

					if not draw_it:
						continue

					var kind := uv_kind[f]
					var tile := _tile_side[block_id]
					if kind == UV_TOP:
						tile = _tile_top[block_id]
					elif kind == UV_BOTTOM:
						tile = _tile_bottom[block_id]
					var tx := (tile % TEXTURE_SHEET_WIDTH) * tile_size
					var ty := (tile / TEXTURE_SHEET_WIDTH) * tile_size

					var face_shade := shade[f]
					var c0: Color
					var c1: Color
					var c2: Color
					var c3: Color
					var flip := false
					if full:
						var sky_front: int = sky[front]
						var blk_front: int = blk[front]
						var cols: Array[Color] = [c0, c1, c2, c3]
						var ao := [0, 0, 0, 0]
						for k in 4:
							var step_u := ao_u[fi + k]
							var step_v := ao_v[fi + k]
							var i1 := front + step_u
							var i2 := front + step_v
							var ic := front + step_u + step_v
							var solid1 := rsolid[i1] != 0
							var solid2 := rsolid[i2] != 0
							var solid_corner := rsolid[ic] != 0

							# Smooth lighting: average the light of the front cell and the
							# three around the corner. Solid blocks borrow the front cell's
							# light. A sealed corner ignores the diagonal block.
							var sky1 := sky_front if solid1 else int(sky[i1])
							var blk1 := blk_front if solid1 else int(blk[i1])
							var sky2 := sky_front if solid2 else int(sky[i2])
							var blk2 := blk_front if solid2 else int(blk[i2])
							var sky3 := sky_front
							var blk3 := blk_front
							if not (solid1 and solid2) and not solid_corner:
								sky3 = sky[ic]
								blk3 = blk[ic]
							# Sums are 4x the light level, which is the LUT index.
							var light_index := clampi(maxi(sky_front + sky1 + sky2 + sky3 - reduction4, blk_front + blk1 + blk2 + blk3), 0, LIGHT_MAX * 4)

							# Ambient occlusion (0 = darkest, 3 = fully open).
							var ao_level := 0
							if not (solid1 and solid2):
								ao_level = 3 - (int(solid1) + int(solid2) + int(solid_corner))
							ao[k] = ao_level

							var b: float = _bright_lut[light_index] * face_shade * float(AO_CURVE[ao_level])
							cols[k] = Color(b, b, b)
						c0 = cols[0]
						c1 = cols[1]
						c2 = cols[2]
						c3 = cols[3]
						# Split the quad along the diagonal whose ends are brighter, so a
						# single dark corner stays a tidy corner shadow.
						flip = ao[0] + ao[2] < ao[1] + ao[3]
					else:
						c0 = Color(face_shade, face_shade, face_shade)
						c1 = c0
						c2 = c0
						c3 = c0

					buf.add_quad(p0, p1, p2, p3,
							Vector2(tx, ty + tile_size), Vector2(tx + tile_size, ty + tile_size),
							Vector2(tx + tile_size, ty), Vector2(tx, ty),
							c0, c1, c2, c3, normals[f], flip)

	if not buf.positions.is_empty():
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = buf.positions
		if buf.with_normals:
			arrays[Mesh.ARRAY_NORMAL] = buf.normals
		arrays[Mesh.ARRAY_COLOR] = buf.colors
		arrays[Mesh.ARRAY_TEX_UV] = buf.uvs
		arrays[Mesh.ARRAY_INDEX] = buf.indices
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		result["mesh"] = mesh
	if want_collision:
		result["faces"] = collision_faces
	return result


# Kept for other scripts (e.g. the Player's selected-block icon).
static func calculate_block_verts(pos: Vector3i) -> Array[Vector3]:
	return [
		Vector3(pos.x, pos.y, pos.z),
		Vector3(pos.x + 1, pos.y, pos.z),
		Vector3(pos.x + 1, pos.y, pos.z + 1),
		Vector3(pos.x, pos.y, pos.z + 1),
		Vector3(pos.x, pos.y + 1, pos.z),
		Vector3(pos.x + 1, pos.y + 1, pos.z),
		Vector3(pos.x + 1, pos.y + 1, pos.z + 1),
		Vector3(pos.x, pos.y + 1, pos.z + 1)
	]


static func calculate_block_uvs(block_id: int) -> Array[Vector2]:
	var row := int(block_id / TEXTURE_SHEET_WIDTH)
	var col := block_id % TEXTURE_SHEET_WIDTH
	var x := col * TEXTURE_TILE_SIZE
	var y := row * TEXTURE_TILE_SIZE
	return [
		Vector2(x, y + TEXTURE_TILE_SIZE),
		Vector2(x + TEXTURE_TILE_SIZE, y + TEXTURE_TILE_SIZE),
		Vector2(x + TEXTURE_TILE_SIZE, y),
		Vector2(x, y)
	]


static func is_block_transparent(block_id: int) -> bool:
	return block_id == 0 or block_id == 27 or block_id == 28

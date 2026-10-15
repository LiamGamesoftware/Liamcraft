class_name Chunk extends StaticBody3D

# These chunks are instanced and given data by VoxelWorld.
# After that, chunks finish setting themselves up in the _ready() function.
# If a chunk is changed, its "regenerate" method is called.
#
# LIGHTING (modelled on Minecraft)
#   * Sky light: every air block with open sky above it is level 15. Light then
#     spreads sideways and downward, losing 1 level per block, so caves, overhangs
#     and rooms with an opening fade out. A sealed room gets no sky light at all.
#   * Block light: emitters (BLOCK_EMISSION) spread light the same way.
#   * Every vertex averages the light of the 4 blocks around it (smooth lighting),
#     then multiplies in ambient occlusion and the per-direction face shade.
#   * All of it is baked into vertex colors and multiplied with the texture.
#
# To light a chunk correctly the script looks at a padded region around it (15
# blocks on every side, i.e. the 3x3x3 chunks around this one). That work, and the
# mesh building, runs on a worker thread.

const CHUNK_SIZE = 16 # Keep in sync with TerrainGenerator.
const TEXTURE_SHEET_WIDTH = 8
const CHUNK_LAST_INDEX = CHUNK_SIZE - 1
const TEXTURE_TILE_SIZE = 1.0 / TEXTURE_SHEET_WIDTH

# ------------------------------------------------------------------ tuning ---
# Brightness multiplier per AO level. Index 0 = boxed-in corner, 3 = open.
const AO_CURVE = [0.30, 0.50, 0.75, 1.0]

# Brightness of light level 0. Minecraft uses about 0.05 (almost black).
const MIN_BRIGHTNESS = 0.05

# Blocks that give off light: block id -> light level (0-15).
# 5 is the furnace. Add torches, lava, glowstone, etc. by id.
const BLOCK_EMISSION = { 5: 13 }

# true  = lighting comes only from the baked vertex colors (classic Minecraft look,
#         ignores DirectionalLight3D and shadows).
# false = baked lighting is multiplied with normal Godot lighting.
const UNSHADED = true

# true  = regenerate() rebuilds the mesh on the worker thread (no hitch, but the old
#         mesh stays visible for a moment).
# false = regenerate() rebuilds it immediately on the calling thread.
const REGENERATE_ASYNC = true

# When this chunk loads or changes, rebuild the neighboring chunks too, because
# light spills across chunk borders.
const UPDATE_NEIGHBORS = true

# Chunks beyond this radius keep their textured geometry but skip the padded
# light flood, smooth-lighting, and ambient-occlusion work. VoxelWorld upgrades
# them again before the player reaches them.
const FULL_LIGHTING_DISTANCE_CHUNKS = 3

# Minecraft's "sky light subtracted": 0 = full daylight, up to ~11 = night.
# It only affects meshes built after it is changed.
static var sky_light_reduction := 0

# ------------------------------------------------------------ light engine ---
const LIGHT_MAX = 15
const PAD = LIGHT_MAX
const REGION = CHUNK_SIZE + PAD * 2 # Side length of the padded region.
const REGION_AREA = REGION * REGION
const REGION_VOLUME = REGION_AREA * REGION

# x-, x+, z-, z+, y-, y+ (the first four are the horizontal ones).
const DIR_X = [-1, 1, 0, 0, 0, 0]
const DIR_Y = [0, 0, 0, 0, -1, 1]
const DIR_Z = [0, 0, -1, 1, 0, 0]

const UV_SIDE = 0
const UV_TOP = 1
const UV_BOTTOM = 2

# One entry per cube face:
#   normal - direction the face points (also the neighbor block to check)
#   verts  - indices into calculate_block_verts(), clockwise winding
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

# Offset of each cube corner from the block origin. Same order as calculate_block_verts().
const CORNERS = [
	Vector3i(0, 0, 0), Vector3i(1, 0, 0), Vector3i(1, 0, 1), Vector3i(0, 0, 1),
	Vector3i(0, 1, 0), Vector3i(1, 1, 0), Vector3i(1, 1, 1), Vector3i(0, 1, 1),
]

# The blocks around (and including) this chunk, stored as flat byte arrays so the
# light flood fill and the mesher never have to touch dictionaries or other nodes.
# Index of a cell = (y * REGION + z) * REGION + x, in region coordinates
# (chunk-local coordinates + PAD).
class Region extends RefCounted:
	var blocks := PackedByteArray()   # Block id per cell (0 = air). Ids must fit in a byte.
	var solid := PackedByteArray()    # 1 where the block stops light.
	var top := PackedInt32Array()     # Per column: highest solid y, or -1 if none.
	var sky := PackedByteArray()      # Sky light level per cell.
	var blk := PackedByteArray()      # Block light level per cell.
	var emitters := PackedInt32Array() # Cells that start a block light flood.
	var quads := 0

	func _init(volume: int, area: int):
		blocks.resize(volume)
		solid.resize(volume)
		sky.resize(volume)
		blk.resize(volume)
		top.resize(area)
		top.fill(-1)

var data = {}
var chunk_position = Vector3i()
var _thread
var _remesh_pending := false
var _mesh_serial := 0
var _mesh_instance: MeshInstance3D
var _full_lighting := true
var _collisions_enabled := true

# Shared by every chunk. Built once on the main thread (see _ready).
static var _material: BaseMaterial3D

@onready var voxel_world = get_parent()

func _ready():
	# 1. Position and name configuration
	transform.origin = Vector3(chunk_position * CHUNK_SIZE)
	name = str(chunk_position)
	_full_lighting = voxel_world.should_use_full_lighting(chunk_position)
	_collisions_enabled = voxel_world.should_keep_chunk_collision(chunk_position)

	# Settings.world_type is set by the main menu: 0 = random blocks, 1 = flat grass, 2 = earth.
	match Settings.world_type:
		0:
			data = TerrainGenerator.random_blocks(chunk_position)
		2:
			data = TerrainGenerator.world(chunk_position)
		_:
			data = TerrainGenerator.flat(chunk_position)

	# 2. Build the shared material on the main thread before any worker starts.
	_get_material()

	# 3. Collision, then the mesh on a worker thread.
	_generate_chunk_collider()
	_request_mesh()

	# 4. Neighbors that were built before this chunk existed assumed it was empty.
	if not data.is_empty():
		_notify_neighbors()

func _exit_tree():
	# Don't free the chunk while the mesh thread is still running.
	_mesh_serial += 1
	if _thread != null:
		_thread.wait_to_finish()
		_thread = null

func regenerate():
	# Colliders are rebuilt right away so physics matches the edit.
	_clear_colliders()
	_generate_chunk_collider()

	if REGENERATE_ASYNC:
		_request_mesh()
	else:
		_rebuild_mesh_now()

	# An edit can change the light up to 15 blocks away, across chunk borders.
	_notify_neighbors()


# Returns true only when the mesh format must change. VoxelWorld queues these
# refreshes, rather than launching a large batch of worker jobs in one frame.
func set_lighting_detail(enabled: bool) -> bool:
	if _full_lighting == enabled:
		return false
	_full_lighting = enabled
	return true


func refresh_mesh_for_lighting() -> void:
	_request_mesh()


# Disable distant chunks in the physics broadphase. Their collider shapes stay
# cached and are re-enabled before the player can get close to them.
func set_collision_enabled(enabled: bool) -> void:
	if _collisions_enabled == enabled:
		return
	_collisions_enabled = enabled
	_apply_collision_state()


static func _get_material() -> BaseMaterial3D:
	if _material == null:
		var mat = (preload("res://world/textures/material.tres") as BaseMaterial3D).duplicate() as BaseMaterial3D

		# Vertex colors carry all the lighting information.
		mat.vertex_color_use_as_albedo = true
		# Treat the brightness values like sRGB so 0.5 really looks half as bright,
		# which matches how Minecraft multiplies its lighting.
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

# ---------------------------------------------------------------- colliders ---

func _clear_colliders():
	for c in get_children():
		if c is CollisionShape3D:
			remove_child(c)
			c.queue_free()

func _generate_chunk_collider():
	if data.is_empty():
		collision_layer = 0
		collision_mask = 0
		return

	# For each block, generate a collider.
	# Blocks buried inside solid ground are skipped: nothing can ever touch them, and
	# dense terrain would otherwise create thousands of colliders per chunk.
	for block_position in data.keys():
		var block_id = data[block_position]
		if block_id != 27 and block_id != 28 and not _is_buried(block_position):
			_create_block_collider(block_position)
	_apply_collision_state()


func _apply_collision_state() -> void:
	if data.is_empty() or not _collisions_enabled:
		collision_layer = 0
		collision_mask = 0
		return
	collision_layer = 0xFFFFF
	collision_mask = 0xFFFFF

# True if all six neighbors are solid blocks of this same chunk. Blocks on the chunk's
# edge always count as exposed, because the neighboring chunk may not exist yet.
func _is_buried(p: Vector3i) -> bool:
	if p.x == 0 or p.y == 0 or p.z == 0:
		return false
	if p.x == CHUNK_LAST_INDEX or p.y == CHUNK_LAST_INDEX or p.z == CHUNK_LAST_INDEX:
		return false
	for face in FACES:
		if is_block_transparent(data.get(p + face["normal"], 0)):
			return false
	return true

# ---------------------------------------------------- mesh jobs (threading) ---
# Everything below until "light" runs on the main thread, except _thread_main.

func _get_neighbor_chunk(offset: Vector3i) -> Chunk:
	# Chunks are children of VoxelWorld, named after their chunk position.
	return voxel_world.get_node_or_null(str(chunk_position + offset)) as Chunk

func _notify_neighbors():
	if not UPDATE_NEIGHBORS:
		return
	for oy in range(-1, 2):
		for oz in range(-1, 2):
			for ox in range(-1, 2):
				if ox == 0 and oy == 0 and oz == 0:
					continue
				# Unlit meshes only need their six face-adjacent chunks. Detailed
				# lighting needs the full 3x3x3 neighborhood for light propagation.
				if not _full_lighting and absi(ox) + absi(oy) + absi(oz) != 1:
					continue
				var other = _get_neighbor_chunk(Vector3i(ox, oy, oz))
				# An empty chunk has no mesh, so there is nothing to relight.
				if other != null and not other.data.is_empty() and (other._full_lighting or absi(ox) + absi(oy) + absi(oz) == 1):
					other._request_mesh()

# Snapshot of everything the worker needs, so it never reads live chunk data.
func _make_job() -> Dictionary:
	var neighbors := {}
	for oy in range(-1, 2):
		for oz in range(-1, 2):
			for ox in range(-1, 2):
				if ox == 0 and oy == 0 and oz == 0:
					continue
				if not _full_lighting and absi(ox) + absi(oy) + absi(oz) != 1:
					continue
				var offset = Vector3i(ox, oy, oz)
				var other = _get_neighbor_chunk(offset)
				if other != null and not other.data.is_empty():
					neighbors[offset] = other.data.duplicate()
	return { "blocks": data.duplicate(), "neighbors": neighbors, "full_lighting": _full_lighting }

func _request_mesh():
	if _thread != null:
		# A job is running. One more rebuild afterwards covers any number of requests.
		_remesh_pending = true
		return
	_start_mesh_thread()

func _start_mesh_thread():
	_remesh_pending = false
	_mesh_serial += 1
	_thread = Thread.new()
	_thread.start(_thread_main.bind(_make_job(), _mesh_serial))

func _thread_main(job: Dictionary, serial: int):
	var mesh = _build_mesh(job)
	_on_mesh_built.call_deferred(mesh, serial)

func _on_mesh_built(mesh: ArrayMesh, serial: int):
	if serial != _mesh_serial:
		return # A newer (synchronous) rebuild replaced this job.
	if _thread != null:
		_thread.wait_to_finish()
		_thread = null
	_apply_mesh(mesh)
	if _remesh_pending:
		_start_mesh_thread()

func _rebuild_mesh_now():
	_remesh_pending = false
	_mesh_serial += 1 # Any job still in flight is now stale.
	if _thread != null:
		_thread.wait_to_finish()
		_thread = null
	_apply_mesh(_build_mesh(_make_job()))

func _apply_mesh(mesh: ArrayMesh):
	if _mesh_instance != null:
		remove_child(_mesh_instance)
		_mesh_instance.queue_free()
		_mesh_instance = null
	if mesh == null:
		return
	var mi = MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = _material
	if UNSHADED:
		# Unshaded meshes never receive shadows, so don't pay to cast them either.
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	_mesh_instance = mi

# ------------------------------------------------------------------- light ---

# Copies one chunk's blocks into the region. offset is that chunk's position
# relative to this one, (0, 0, 0) being this chunk.
func _fill_region(region: Region, offset: Vector3i, src: Dictionary):
	var bx = offset.x * CHUNK_SIZE + PAD
	var by = offset.y * CHUNK_SIZE + PAD
	var bz = offset.z * CHUNK_SIZE + PAD
	for key in src:
		var rx = key.x + bx
		var ry = key.y + by
		var rz = key.z + bz
		if rx < 0 or ry < 0 or rz < 0 or rx >= REGION or ry >= REGION or rz >= REGION:
			continue
		var id = mini(int(src[key]), 255)
		if id == 0:
			continue
		var i = ry * REGION_AREA + rz * REGION + rx
		region.blocks[i] = id
		if not is_block_transparent(id):
			region.solid[i] = 1
			var col = rz * REGION + rx
			if ry > region.top[col]:
				region.top[col] = ry
		if BLOCK_EMISSION.has(id):
			region.blk[i] = BLOCK_EMISSION[id]
			region.emitters.append(i)

func _build_region(job: Dictionary) -> Region:
	var region = Region.new(REGION_VOLUME, REGION_AREA)
	_fill_region(region, Vector3i.ZERO, job["blocks"])
	for offset in job["neighbors"]:
		_fill_region(region, offset, job["neighbors"][offset])
	_compute_light(region)
	return region

func _compute_light(region: Region):
	var solid = region.solid
	var top = region.top
	var sky = region.sky

	# Sky light. Cells above the highest solid block of their column are open sky
	# (level 15) and are not stored. Light only has to be spread into the cells
	# below those roofs, so the flood starts where an open-sky cell sits next to a
	# column whose roof is higher: the air in that neighbor column, between our roof
	# and its roof, gets level 14.
	var queue = PackedInt32Array()
	for rz in REGION:
		for rx in REGION:
			var col = rz * REGION + rx
			var own_top = top[col]
			for d in 4:
				var nx = rx + DIR_X[d]
				var nz = rz + DIR_Z[d]
				if nx < 0 or nz < 0 or nx >= REGION or nz >= REGION:
					continue
				var ncol = nz * REGION + nx
				for ry in range(own_top + 1, top[ncol] + 1):
					var ni = ry * REGION_AREA + ncol
					if solid[ni] == 0 and sky[ni] < LIGHT_MAX - 1:
						sky[ni] = LIGHT_MAX - 1
						queue.append(ni)
	_flood(region, sky, queue, true)

	# Block light starts at the emitters and floods the same way.
	_flood(region, region.blk, region.emitters, false)

	# Store level 15 for open-sky cells in the part the mesher samples
	# (this chunk plus one block of border).
	var lo = PAD - 1
	var hi = PAD + CHUNK_SIZE
	for ry in range(lo, hi + 1):
		for rz in range(lo, hi + 1):
			for rx in range(lo, hi + 1):
				var col = rz * REGION + rx
				if ry > top[col]:
					sky[ry * REGION_AREA + col] = LIGHT_MAX

# Breadth-first light spread: each step loses one level and light never enters
# solid blocks.
@warning_ignore("integer_division")
func _flood(region: Region, light: PackedByteArray, queue: PackedInt32Array, is_sky: bool):
	var solid = region.solid
	var top = region.top
	var head = 0
	while head < queue.size():
		var i = queue[head]
		head += 1
		var level: int = light[i]
		if level <= 1:
			continue
		var ry = i / REGION_AREA
		var rem = i - ry * REGION_AREA
		var rz = rem / REGION
		var rx = rem - rz * REGION
		var next = level - 1
		for d in 6:
			var nx = rx + DIR_X[d]
			var ny = ry + DIR_Y[d]
			var nz = rz + DIR_Z[d]
			if nx < 0 or ny < 0 or nz < 0 or nx >= REGION or ny >= REGION or nz >= REGION:
				continue
			var ncol = nz * REGION + nx
			var j = ny * REGION_AREA + ncol
			if solid[j] != 0 or light[j] >= next:
				continue
			if is_sky and ny > top[ncol]:
				continue # Open sky is already at full level.
			light[j] = next
			queue.append(j)

# Light level (0-15, can be fractional) -> brightness. This is Minecraft's
# classic light curve: it falls off quickly, then flattens out near the dark end.
static func _brightness(level: float) -> float:
	var f = 1.0 - clampf(level, 0.0, float(LIGHT_MAX)) / LIGHT_MAX
	var b = (1.0 - f) / (f * 3.0 + 1.0)
	return b * (1.0 - MIN_BRIGHTNESS) + MIN_BRIGHTNESS

# -------------------------------------------------------------------- mesh ---

func _build_mesh(job: Dictionary) -> ArrayMesh:
	var blocks: Dictionary = job["blocks"]
	if blocks.is_empty():
		return null

	var region = _build_region(job)

	var surface_tool = SurfaceTool.new()
	surface_tool.begin(Mesh.PRIMITIVE_TRIANGLES)

	# Normals and vertex colors are written per face, so there is no need for
	# generate_normals() or smooth groups.
	for block_position in blocks.keys():
		var p: Vector3i = block_position
		if p.x < 0 or p.y < 0 or p.z < 0 or p.x >= CHUNK_SIZE or p.y >= CHUNK_SIZE or p.z >= CHUNK_SIZE:
			continue
		var id = region.blocks[(p.y + PAD) * REGION_AREA + (p.z + PAD) * REGION + (p.x + PAD)]
		if id == 0:
			continue
		_draw_block_mesh(surface_tool, region, p, id)

	if region.quads == 0:
		return null # Fully buried chunk, nothing to draw.

	surface_tool.index()
	return surface_tool.commit()

func _draw_block_mesh(surface_tool: SurfaceTool, region: Region, pos: Vector3i, block_id: int):
	var verts = calculate_block_verts(pos)
	var uvs = calculate_block_uvs(block_id)
	var top_uvs = uvs
	var bottom_uvs = uvs
	var cell = (pos.y + PAD) * REGION_AREA + (pos.z + PAD) * REGION + (pos.x + PAD)

	# Bush blocks get drawn in their own special way: lit by the light in their own
	# block, no AO and no face shade.
	if block_id == 27 or block_id == 28:
		var level = maxf(float(region.sky[cell]) - sky_light_reduction, float(region.blk[cell]))
		var b = _brightness(level)
		var plant_color = Color(b, b, b)
		var plant_colors = [plant_color, plant_color, plant_color, plant_color]
		_draw_block_face(surface_tool, [verts[2], verts[0], verts[7], verts[5]], uvs, Vector3.UP, plant_colors, false)
		_draw_block_face(surface_tool, [verts[7], verts[5], verts[2], verts[0]], uvs, Vector3.UP, plant_colors, false)
		_draw_block_face(surface_tool, [verts[3], verts[1], verts[6], verts[4]], uvs, Vector3.UP, plant_colors, false)
		_draw_block_face(surface_tool, [verts[6], verts[4], verts[3], verts[1]], uvs, Vector3.UP, plant_colors, false)
		region.quads += 4
		return

	# Allow some blocks to have different top/bottom textures.
	if block_id == 3: # Grass.
		top_uvs = calculate_block_uvs(0)
		bottom_uvs = calculate_block_uvs(2)
	elif block_id == 5: # Furnace.
		top_uvs = calculate_block_uvs(31)
		bottom_uvs = top_uvs
	elif block_id == 12: # Log.
		top_uvs = calculate_block_uvs(30)
		bottom_uvs = top_uvs
	elif block_id == 19: # Bookshelf.
		top_uvs = calculate_block_uvs(4)
		bottom_uvs = top_uvs

	for face in FACES:
		var normal: Vector3i = face["normal"]

		# Only draw faces that border something see-through. "front" is the cell the
		# face looks into, and the light of that cell is what lights the face.
		var front = cell + normal.x + normal.y * REGION_AREA + normal.z * REGION
		if block_id == region.blocks[front] or region.solid[front] != 0:
			continue

		var face_uvs = uvs
		if face["uv"] == UV_TOP:
			face_uvs = top_uvs
		elif face["uv"] == UV_BOTTOM:
			face_uvs = bottom_uvs

		var sky_front: int = region.sky[front]
		var blk_front: int = region.blk[front]

		var face_verts = []
		var colors = []
		var ao = []
		for corner_index in face["verts"]:
			face_verts.append(verts[corner_index])

			# The two blocks touching this corner's edges (u and v) and the diagonal one,
			# all in the layer in front of the face.
			var c: Vector3i = CORNERS[corner_index] * 2 - Vector3i.ONE # -1 or +1 on each axis
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
			var step_u = u.x + u.y * REGION_AREA + u.z * REGION
			var step_v = v.x + v.y * REGION_AREA + v.z * REGION
			var i1 = front + step_u
			var i2 = front + step_v
			var ic = front + step_u + step_v
			var solid1 = region.solid[i1] != 0
			var solid2 = region.solid[i2] != 0
			var solid_corner = region.solid[ic] != 0

			# Smooth lighting: average the light of the front cell and the three
			# around the corner. Solid blocks have no light of their own, so they
			# borrow the front cell's. A sealed corner ignores the diagonal block.
			var sky1 = sky_front if solid1 else int(region.sky[i1])
			var blk1 = blk_front if solid1 else int(region.blk[i1])
			var sky2 = sky_front if solid2 else int(region.sky[i2])
			var blk2 = blk_front if solid2 else int(region.blk[i2])
			var sky3 = sky_front
			var blk3 = blk_front
			if not (solid1 and solid2) and not solid_corner:
				sky3 = region.sky[ic]
				blk3 = region.blk[ic]
			var sky_level = (sky_front + sky1 + sky2 + sky3) * 0.25
			var blk_level = (blk_front + blk1 + blk2 + blk3) * 0.25

			# Ambient occlusion (0 = darkest, 3 = fully open).
			var ao_level = 0
			if not (solid1 and solid2):
				ao_level = 3 - (int(solid1) + int(solid2) + int(solid_corner))
			ao.append(ao_level)

			# Final brightness = light * directional face shade * ambient occlusion.
			var light = _brightness(maxf(sky_level - sky_light_reduction, blk_level))
			var b = light * face["shade"] * AO_CURVE[ao_level]
			colors.append(Color(b, b, b))

		# Split the quad along the diagonal whose ends are brighter, so a single dark
		# corner stays a tidy corner shadow instead of smearing across the whole face.
		var flip = ao[0] + ao[2] < ao[1] + ao[3]

		_draw_block_face(surface_tool, face_verts, face_uvs, Vector3(normal), colors, flip)
		region.quads += 1

func _draw_block_face(surface_tool: SurfaceTool, face_verts: Array, face_uvs: Array, normal: Vector3, colors: Array, flip: bool):
	# Both splits keep the clockwise winding order for front-face rendering.
	var order = [0, 1, 2, 0, 2, 3]
	if flip:
		order = [1, 2, 3, 1, 3, 0]

	surface_tool.set_normal(normal)
	for i in order:
		surface_tool.set_color(colors[i])
		surface_tool.set_uv(face_uvs[i])
		surface_tool.add_vertex(face_verts[i])

func _create_block_collider(block_sub_position: Vector3i):
	var box = CollisionShape3D.new()
	var shape = BoxShape3D.new()
	shape.size = Vector3.ONE
	box.shape = shape
	box.transform.origin = Vector3(block_sub_position) + Vector3(0.5, 0.5, 0.5)
	add_child(box)

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
	var row = int(block_id / TEXTURE_SHEET_WIDTH)
	var col = block_id % TEXTURE_SHEET_WIDTH
	var x = col * TEXTURE_TILE_SIZE
	var y = row * TEXTURE_TILE_SIZE
	return [
		Vector2(x, y + TEXTURE_TILE_SIZE),
		Vector2(x + TEXTURE_TILE_SIZE, y + TEXTURE_TILE_SIZE),
		Vector2(x + TEXTURE_TILE_SIZE, y),
		Vector2(x, y)
	]

static func is_block_transparent(block_id: int) -> bool:
	return block_id == 0 or block_id == 27 or block_id == 28

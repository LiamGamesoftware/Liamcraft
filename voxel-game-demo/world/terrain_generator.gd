class_name TerrainGenerator
extends Resource

# Can't be "Chunk.CHUNK_SIZE" due to cyclic dependency issues.
# https://github.com/godotengine/godot/issues/21461
const CHUNK_SIZE = 16
const WORLD_BOTTOM = -64

const RANDOM_BLOCK_PROBABILITY = 0.015

# Block ids. Chunk.gd uses the id directly as the zero-based tile index on the
# texture sheet. These two values deliberately match the requested tile indices.
const BLOCK_STONE = 1
const BLOCK_DIRT = 2
const BLOCK_GRASS = 3
const BLOCK_BRICK = 8
const BLOCK_BARK = 12
const BLOCK_OBSIDIAN = 22
const BLOCK_LEAVES = 26
const BLOCK_TALL_GRASS = 28 # Rendered as a crossed, transparent plant by Chunk.

# Set this before any chunks are generated to get a different world. Prefer
# set_world_seed() when changing worlds at runtime so old cached noise is freed.
static var world_seed: int = 0

# FastNoiseLite allocation/configuration was a large fixed cost for every
# chunk. Each worker gets its own immutable set, so threaded chunk generation
# does not contend on a shared Resource.
static var _noise_cache: Dictionary = {}
static var _noise_cache_mutex: Mutex = Mutex.new()

# Add a biome by appending one dictionary. Entries are evaluated in max_value
# order. Every key has a safe default, so new biome definitions can stay small.
static var biomes: Array[Dictionary] = [
	{
		"name": "Plains",
		"max_value": -0.30,
		"base_height": -2.0,
		"plains_amplitude": 4.0,
		"hill_multiplier": 0.35,
		"mountain_multiplier": 0.0,
		"top_block": BLOCK_GRASS,
		"filler_block": BLOCK_DIRT,
		"filler_depth": 3,
		"tree_chance": 0.004,
		"surface_block": BLOCK_TALL_GRASS,
		"surface_chance": 0.10,
	},
	{
		"name": "Forest",
		"max_value": 0.35,
		"base_height": 2.0,
		"plains_amplitude": 6.0,
		"hill_multiplier": 0.70,
		"mountain_multiplier": 0.18,
		"top_block": BLOCK_GRASS,
		"filler_block": BLOCK_DIRT,
		"filler_depth": 4,
		"tree_chance": 0.035,
		"surface_block": BLOCK_TALL_GRASS,
		"surface_chance": 0.06,
	},
	{
		"name": "Highlands",
		"max_value": 1.0,
		"base_height": 9.0,
		"plains_amplitude": 6.0,
		"hill_multiplier": 1.0,
		"mountain_multiplier": 1.0,
		"top_block": BLOCK_GRASS,
		"filler_block": BLOCK_DIRT,
		"filler_depth": 3,
		"tree_chance": 0.006,
		"surface_block": BLOCK_TALL_GRASS,
		"surface_chance": 0.025,
	},
]

# Structures used only by world(), the earth terrain generator. Add, remove, or
# tune entries here without affecting random_blocks(), flat(), or origin_grass().
# `spacing` is the width of a deterministic spawn grid, and `chance` is the
# chance that a grid cell contains this structure.
static var earth_structures: Array[Dictionary] = [
	{
		"name": "Brick Pyramid",
		"enabled": true,
		"shape": "pyramid",
		"block": BLOCK_BRICK,
		"spacing": 512,
		"chance": 0.20,
		"base_size": 63,
		"height": 32,
		"radius": 31,
	},
	{
		"name": "Obsidian Monolith",
		"enabled": true,
		"shape": "monolith",
		"block": BLOCK_OBSIDIAN,
		"spacing": 384,
		"chance": 0.16,
		"width": 9,
		"height": 72,
		"radius": 4,
	},
]

# World shape, in blocks. Tweak these to taste.
const HILL_AMPLITUDE = 18.0
const MOUNTAIN_LIFT = 15.0
const MOUNTAIN_AMPLITUDE = 70.0
const MAX_TERRAIN_HEIGHT = 109.0

# Surface rules.
const STEEP_SLOPE = 3
const STONE_LINE = 60.0
const ROCK_JITTER = 10.0

# Caves carve connected tunnels below the upper soil layers.
const CAVE_MIN_Y = WORLD_BOTTOM + 2
const CAVE_MAX_Y = 82
const CAVE_SURFACE_DEPTH = 5
const CAVE_THRESHOLD = 0.67

# Trees.
const TREE_LEAF_RADIUS = 2
const TREE_SPACING = 2
const TREE_MAX_HEIGHT = 7
const PLAINS_TREE_CHANCE = 0.002
const FOREST_TREE_CHANCE = 0.03

# Heights are sampled for the chunk plus a border, so slopes at the chunk edge
# and trees rooted in neighbouring chunks come out the same on both sides.
const GRID_MARGIN = TREE_LEAF_RADIUS + 1
const GRID_SIZE = CHUNK_SIZE + 2 * GRID_MARGIN


static func set_world_seed(seed: int) -> void:
	world_seed = seed
	clear_noise_cache()


static func clear_noise_cache() -> void:
	_noise_cache_mutex.lock()
	_noise_cache.clear()
	_noise_cache_mutex.unlock()


static func empty():
	return {}


static func random_blocks(chunk_position: Vector3i):
	var random_data := {}
	var origin := chunk_position * CHUNK_SIZE
	for x in range(CHUNK_SIZE):
		for y in range(CHUNK_SIZE):
			for z in range(CHUNK_SIZE):
				var hash := _hash3(origin.x + x, origin.y + y, origin.z + z, 40)
				if float(hash & 0xFFFF) / 65536.0 < RANDOM_BLOCK_PROBABILITY:
					random_data[Vector3i(x, y, z)] = (hash >> 16) % 29 + 1
	return random_data


static func flat(chunk_position):
	var data = {}

	if chunk_position.y != -1:
		return data

	for x in range(CHUNK_SIZE):
		for z in range(CHUNK_SIZE):
			data[Vector3i(x, 0, z)] = 3

	return data


# Used to create the project icon.
static func origin_grass(chunk_position):
	if chunk_position == Vector3i.ZERO:
		return {Vector3i.ZERO: 3}

	return {}


# Minecraft-style earth terrain: plains, rolling hills, mountains, forests,
# trees, and structures. Every result is a pure function of position and seed,
# so adjacent chunks agree even when a structure crosses their border.
static func world(chunk_position):
	var origin := Vector3i(chunk_position) * CHUNK_SIZE

	# Nothing in the sky, except the headroom required by the tallest enabled
	# structure. This stays correct when the structure settings change.
	if origin.y > MAX_TERRAIN_HEIGHT + maxi(TREE_MAX_HEIGHT, _max_structure_height()):
		return {}
	if origin.y + CHUNK_SIZE - 1 < WORLD_BOTTOM:
		return {}

	var noise := _noise_for_current_thread()
	var continent_noise := noise["continent"] as FastNoiseLite
	var hill_noise := noise["hills"] as FastNoiseLite
	var mountain_noise := noise["mountains"] as FastNoiseLite
	var ridge_noise := noise["ridges"] as FastNoiseLite
	var rock_noise := noise["rock"] as FastNoiseLite
	var forest_noise := noise["forest"] as FastNoiseLite
	var biome_noise := noise["biomes"] as FastNoiseLite
	var cave_noise := noise["caves"] as FastNoiseLite

	var heights := PackedInt32Array()
	var biome_indices := PackedInt32Array()
	var rock := PackedFloat32Array()
	var stone_surface := PackedByteArray()
	heights.resize(GRID_SIZE * GRID_SIZE)
	biome_indices.resize(GRID_SIZE * GRID_SIZE)
	rock.resize(GRID_SIZE * GRID_SIZE)
	stone_surface.resize(GRID_SIZE * GRID_SIZE)

	for gz in range(GRID_SIZE):
		for gx in range(GRID_SIZE):
			var wx := origin.x + gx - GRID_MARGIN
			var wz := origin.z + gz - GRID_MARGIN
			var i := gx + gz * GRID_SIZE
			var biome_index := _biome_index_at(wx, wz, biome_noise)
			biome_indices[i] = biome_index
			heights[i] = _terrain_height(wx, wz, continent_noise, hill_noise, mountain_noise, ridge_noise, biomes[biome_index])
			rock[i] = rock_noise.get_noise_2d(wx, wz)

	# Calculate steep/rocky columns once. Tree placement previously recalculated
	# these exact slope checks after the ground pass.
	for gz in range(1, GRID_SIZE - 1):
		for gx in range(1, GRID_SIZE - 1):
			var i := gx + gz * GRID_SIZE
			if _is_stone_surface(heights, rock, i):
				stone_surface[i] = 1

	var data := {}

	# Ground: grass on top, a few layers of dirt, stone below.
	for z in range(CHUNK_SIZE):
		for x in range(CHUNK_SIZE):
			var i := (x + GRID_MARGIN) + (z + GRID_MARGIN) * GRID_SIZE
			var height := heights[i]
			var top := mini(height - origin.y, CHUNK_SIZE - 1)
			if top < 0:
				continue

			var biome: Dictionary = biomes[biome_indices[i]]
			var dirt_depth := int(biome.get("filler_depth", 3)) + _hash2(origin.x + x, origin.z + z, 2) % 2
			var bottom := maxi(WORLD_BOTTOM - origin.y, 0)
			for y in range(bottom, top + 1):
				var world_y := origin.y + y
				var depth := height - world_y
				if depth >= CAVE_SURFACE_DEPTH and _is_cave(origin.x + x, world_y, origin.z + z, cave_noise):
					continue
				var block := BLOCK_STONE
				if stone_surface[i] == 0:
					if depth == 0:
						block = int(biome.get("top_block", BLOCK_GRASS))
					elif depth <= dirt_depth:
						block = int(biome.get("filler_block", BLOCK_DIRT))
				data[Vector3i(x, y, z)] = block

	# Columns outside this chunk are included so hanging leaves agree at borders.
	for z in range(-TREE_LEAF_RADIUS, CHUNK_SIZE + TREE_LEAF_RADIUS):
		for x in range(-TREE_LEAF_RADIUS, CHUNK_SIZE + TREE_LEAF_RADIUS):
			var i := (x + GRID_MARGIN) + (z + GRID_MARGIN) * GRID_SIZE
			var ground := heights[i]
			if ground + TREE_MAX_HEIGHT < origin.y or ground + 1 >= origin.y + CHUNK_SIZE:
				continue

			var wx := origin.x + x
			var wz := origin.z + z
			if stone_surface[i] != 0 or not _tree_at(wx, wz, forest_noise, biome_noise):
				continue
			_place_tree(data, origin, wx, wz, ground)

	# Surface plants are generated from each biome definition. _put() preserves
	# tree trunks and leaves when a plant happens to share their position.
	for z in range(CHUNK_SIZE):
		for x in range(CHUNK_SIZE):
			var i := (x + GRID_MARGIN) + (z + GRID_MARGIN) * GRID_SIZE
			if stone_surface[i] == 0:
				_place_surface_decoration(data, origin, origin.x + x, heights[i], origin.z + z, biomes[biome_indices[i]])

	# Put structures last so they cleanly replace terrain, trees, and plants.
	_place_earth_structures(data, origin, continent_noise, hill_noise, mountain_noise, ridge_noise, biome_noise)
	return data


static func _terrain_height(wx: int, wz: int, continent_noise: FastNoiseLite, hill_noise: FastNoiseLite, mountain_noise: FastNoiseLite, ridge_noise: FastNoiseLite, biome: Dictionary) -> int:
	var continent := continent_noise.get_noise_2d(wx, wz)
	var hills := hill_noise.get_noise_2d(wx, wz)
	var hilliness := smoothstep(-0.35, 0.35, continent)
	var mountains := smoothstep(-0.05, 0.4, mountain_noise.get_noise_2d(wx, wz))
	var ridge := 1.0 - absf(ridge_noise.get_noise_2d(wx, wz))
	var mountain_multiplier := float(biome.get("mountain_multiplier", 1.0))
	var terrain_y := float(biome.get("base_height", 0.0))
	terrain_y += continent * float(biome.get("plains_amplitude", 6.0))
	terrain_y += hills * HILL_AMPLITUDE * float(biome.get("hill_multiplier", 1.0)) * hilliness
	terrain_y += mountains * mountain_multiplier * (MOUNTAIN_LIFT + ridge * ridge * MOUNTAIN_AMPLITUDE)
	return int(floor(terrain_y))


static func _biome_index_at(wx: int, wz: int, biome_noise: FastNoiseLite) -> int:
	var value := biome_noise.get_noise_2d(wx, wz)
	for i in biomes.size():
		if value <= float(biomes[i].get("max_value", 1.0)):
			return i
	return biomes.size() - 1


static func _is_cave(wx: int, wy: int, wz: int, cave_noise: FastNoiseLite) -> bool:
	if wy < CAVE_MIN_Y or wy > CAVE_MAX_Y:
		return false
	return absf(cave_noise.get_noise_3d(wx, wy, wz)) >= CAVE_THRESHOLD


static func _place_surface_decoration(data: Dictionary, origin: Vector3i, wx: int, ground: int, wz: int, biome: Dictionary) -> void:
	var block := int(biome.get("surface_block", 0))
	var chance := clampf(float(biome.get("surface_chance", 0.0)), 0.0, 1.0)
	if block == 0 or chance == 0.0:
		return
	if float(_hash2(wx, wz, 70) & 0xFFFF) / 65536.0 >= chance:
		return
	_put(data, origin, Vector3i(wx, ground + 1, wz), block)


# Finds candidate grid cells around this chunk. The same world-space structure
# is evaluated by every affected chunk, making structures seamless at borders.
static func _place_earth_structures(data: Dictionary, origin: Vector3i, continent_noise: FastNoiseLite, hill_noise: FastNoiseLite, mountain_noise: FastNoiseLite, ridge_noise: FastNoiseLite, biome_noise: FastNoiseLite) -> void:
	for structure_index in range(earth_structures.size()):
		var structure: Dictionary = earth_structures[structure_index]
		if not bool(structure.get("enabled", true)):
			continue

		var spacing := maxi(1, int(structure.get("spacing", 128)))
		# Derive the footprint from the shape as a safeguard if a setting is tuned
		# without updating its optional radius hint.
		var radius := maxi(int(structure.get("radius", 0)), _structure_radius(structure))
		var chance := clampf(float(structure.get("chance", 0.0)), 0.0, 1.0)
		var min_cell_x := int(floor(float(origin.x - radius) / float(spacing)))
		var max_cell_x := int(floor(float(origin.x + CHUNK_SIZE - 1 + radius) / float(spacing)))
		var min_cell_z := int(floor(float(origin.z - radius) / float(spacing)))
		var max_cell_z := int(floor(float(origin.z + CHUNK_SIZE - 1 + radius) / float(spacing)))
		var salt := 100 + structure_index * 10

		for cell_z in range(min_cell_z, max_cell_z + 1):
			for cell_x in range(min_cell_x, max_cell_x + 1):
				var roll := float(_hash2(cell_x, cell_z, salt) & 0xFFFF) / 65536.0
				if roll >= chance:
					continue

				var wx := cell_x * spacing + _hash2(cell_x, cell_z, salt + 1) % spacing
				var wz := cell_z * spacing + _hash2(cell_x, cell_z, salt + 2) % spacing
				var biome_index := _biome_index_at(wx, wz, biome_noise)
				var ground := _terrain_height(wx, wz, continent_noise, hill_noise, mountain_noise, ridge_noise, biomes[biome_index])

				match str(structure.get("shape", "")):
					"pyramid":
						_place_pyramid(data, origin, wx, ground, wz, structure)
					"monolith":
						_place_monolith(data, origin, wx, ground, wz, structure)


# Only write the part of a structure that falls in this chunk. This is crucial
# for large structures: a 63-wide pyramid no longer iterates its entire volume
# once for every one of the many chunks it overlaps.
static func _place_pyramid(data: Dictionary, origin: Vector3i, wx: int, ground: int, wz: int, structure: Dictionary) -> void:
	var block := int(structure.get("block", BLOCK_BRICK))
	var base_radius := maxi(0, int(structure.get("base_size", 9)) >> 1)
	var height := mini(maxi(1, int(structure.get("height", base_radius + 1))), base_radius + 1)
	var first_y := maxi(0, ground + 1 - origin.y)
	var last_y := mini(CHUNK_SIZE - 1, ground + height - origin.y)
	if first_y > last_y:
		return

	for y in range(first_y, last_y + 1):
		var layer_radius := base_radius - (origin.y + y - ground - 1)
		var first_x := maxi(0, wx - layer_radius - origin.x)
		var last_x := mini(CHUNK_SIZE - 1, wx + layer_radius - origin.x)
		var first_z := maxi(0, wz - layer_radius - origin.z)
		var last_z := mini(CHUNK_SIZE - 1, wz + layer_radius - origin.z)
		if first_x > last_x or first_z > last_z:
			continue
		for z in range(first_z, last_z + 1):
			for x in range(first_x, last_x + 1):
				data[Vector3i(x, y, z)] = block


static func _place_monolith(data: Dictionary, origin: Vector3i, wx: int, ground: int, wz: int, structure: Dictionary) -> void:
	var block := int(structure.get("block", BLOCK_OBSIDIAN))
	var radius := maxi(0, int(structure.get("width", 3)) >> 1)
	var height := maxi(1, int(structure.get("height", 16)))
	var first_y := maxi(0, ground + 1 - origin.y)
	var last_y := mini(CHUNK_SIZE - 1, ground + height - origin.y)
	var first_x := maxi(0, wx - radius - origin.x)
	var last_x := mini(CHUNK_SIZE - 1, wx + radius - origin.x)
	var first_z := maxi(0, wz - radius - origin.z)
	var last_z := mini(CHUNK_SIZE - 1, wz + radius - origin.z)
	if first_y > last_y or first_x > last_x or first_z > last_z:
		return

	for y in range(first_y, last_y + 1):
		for z in range(first_z, last_z + 1):
			for x in range(first_x, last_x + 1):
				data[Vector3i(x, y, z)] = block


static func _structure_radius(structure: Dictionary) -> int:
	match str(structure.get("shape", "")):
		"pyramid":
			return maxi(0, int(structure.get("base_size", 9)) >> 1)
		"monolith":
			return maxi(0, int(structure.get("width", 3)) >> 1)
	return 0


static func _max_structure_height() -> int:
	var tallest := 0
	for structure in earth_structures:
		if bool(structure.get("enabled", true)):
			tallest = maxi(tallest, maxi(1, int(structure.get("height", 0))))
	return tallest


static func _noise_for_current_thread() -> Dictionary:
	# Separate instances per thread avoid mutating or sharing a Resource while
	# background chunk workers are sampling it.
	var cache_key := "%s:%s" % [world_seed, OS.get_thread_caller_id()]
	_noise_cache_mutex.lock()
	var noise: Dictionary
	if _noise_cache.has(cache_key):
		noise = _noise_cache[cache_key]
	else:
		noise = {
			"continent": _make_noise(world_seed, 0.0025, 3),
			"hills": _make_noise(world_seed + 1, 0.012, 4),
			"mountains": _make_noise(world_seed + 2, 0.0035, 2),
			"ridges": _make_noise(world_seed + 3, 0.007, 4),
			"rock": _make_noise(world_seed + 4, 0.06, 2),
			"forest": _make_noise(world_seed + 5, 0.01, 2),
			"biomes": _make_noise(world_seed + 6, 0.0018, 2),
			"caves": _make_noise(world_seed + 7, 0.045, 1),
		}
		_noise_cache[cache_key] = noise
	_noise_cache_mutex.unlock()
	return noise


static func _make_noise(noise_seed: int, frequency: float, octaves: int) -> FastNoiseLite:
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = octaves
	noise.frequency = frequency
	noise.seed = noise_seed
	return noise


# Cheap deterministic hash of a world column, 0 to 2^32 - 1.
static func _hash2(x: int, z: int, salt: int) -> int:
	var h := (x * 374761393 + z * 668265263 + salt * 1442695041 + (world_seed & 0xFFFFFFFF) * 1274126177) & 0xFFFFFFFF
	h = ((h ^ (h >> 13)) * 1274126177) & 0xFFFFFFFF
	return h ^ (h >> 16)


static func _hash3(x: int, y: int, z: int, salt: int) -> int:
	var h := _hash2(x, z, salt) ^ ((y * 1103515245) & 0xFFFFFFFF)
	h = ((h ^ (h >> 13)) * 1274126177) & 0xFFFFFFFF
	return h ^ (h >> 16)


static func _is_stone_surface(heights: PackedInt32Array, rock: PackedFloat32Array, i: int) -> bool:
	var h := heights[i]
	var slope := maxi(
		maxi(absi(h - heights[i - 1]), absi(h - heights[i + 1])),
		maxi(absi(h - heights[i - GRID_SIZE]), absi(h - heights[i + GRID_SIZE])))
	return slope >= STEEP_SLOPE or h + rock[i] * ROCK_JITTER >= STONE_LINE


static func _tree_roll(wx: int, wz: int, forest_noise: FastNoiseLite, biome_noise: FastNoiseLite) -> int:
	var biome: Dictionary = biomes[_biome_index_at(wx, wz, biome_noise)]
	var max_chance := float(biome.get("tree_chance", 0.0))
	if max_chance <= 0.0:
		return -1
	var roll := _hash2(wx, wz, 1)
	var r := float(roll & 0xFFFF) / 65536.0
	if r >= max_chance:
		return -1
	var forest := smoothstep(-0.25, 0.35, forest_noise.get_noise_2d(wx, wz))
	if r >= lerpf(max_chance * 0.15, max_chance, forest):
		return -1
	return roll


static func _tree_at(wx: int, wz: int, forest_noise: FastNoiseLite, biome_noise: FastNoiseLite) -> bool:
	var roll := _tree_roll(wx, wz, forest_noise, biome_noise)
	if roll < 0:
		return false

	for dz in range(-TREE_SPACING, TREE_SPACING + 1):
		for dx in range(-TREE_SPACING, TREE_SPACING + 1):
			if (dx != 0 or dz != 0) and _tree_roll(wx + dx, wz + dz, forest_noise, biome_noise) >= roll:
				return false
	return true


static func _place_tree(data: Dictionary, origin: Vector3i, wx: int, wz: int, ground: int) -> void:
	var trunk := 4 + _hash2(wx, wz, 3) % 3

	for dy in range(1, trunk + 1):
		_put(data, origin, Vector3i(wx, ground + dy, wz), BLOCK_BARK)

	for dy in range(trunk - 2, trunk + 2):
		var radius := 2 if dy < trunk else 1
		for dx in range(-radius, radius + 1):
			for dz in range(-radius, radius + 1):
				if dx == 0 and dz == 0 and dy <= trunk:
					continue
				if absi(dx) == radius and absi(dz) == radius:
					if dy == trunk + 1:
						continue
					if _hash2(wx + dx, wz + dz, 4 + dy) % 2 == 0:
						continue
				_put(data, origin, Vector3i(wx + dx, ground + dy, wz + dz), BLOCK_LEAVES)


# Adds a block only if it is in this chunk and the spot is free (used for trees).
static func _put(data: Dictionary, origin: Vector3i, world_pos: Vector3i, block: int) -> void:
	var local := world_pos - origin
	if local.x < 0 or local.y < 0 or local.z < 0:
		return
	if local.x >= CHUNK_SIZE or local.y >= CHUNK_SIZE or local.z >= CHUNK_SIZE:
		return
	if not data.has(local):
		data[local] = block

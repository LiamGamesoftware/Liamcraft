class_name TerrainGenerator
extends Resource

# Can't be "Chunk.CHUNK_SIZE" due to cyclic dependency issues.
# https://github.com/godotengine/godot/issues/21461
const CHUNK_SIZE = 16
const CHUNK_AREA = CHUNK_SIZE * CHUNK_SIZE
const CHUNK_VOLUME = CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE
const WORLD_BOTTOM = -64

# Chunk data is a PackedByteArray of CHUNK_VOLUME block ids (0 = air), indexed
# (y * CHUNK_SIZE + z) * CHUNK_SIZE + x. An empty array means "nothing but air".

const RANDOM_BLOCK_PROBABILITY = 0.015

# Block ids. Chunk.gd uses the id directly as the zero-based tile index on the
# texture sheet.
const BLOCK_STONE = 1
const BLOCK_BIRCH = 20
const BLOCK_DIRT = 2
const BLOCK_GRASS = 3
const BLOCK_CACTUS = 5
const BLOCK_BRICK = 51
const BLOCK_SAND = 11
const BLOCK_BARK = 12
const BLOCK_OBSIDIAN = 21
const BLOCK_LEAVES = 26
const BLOCK_ORE = 39
const BLOCK_SNOW = 40
const BLOCK_TOM = 10

# Set this before any chunks are generated to get a different world. Prefer
# set_world_seed() when changing worlds at runtime so old cached noise is freed.
static var world_seed: int = 0
# Ensures the seed is randomized once before the first Earth-like chunk is generated.
static var _earth_seed_initialized: bool = false

# FastNoiseLite allocation/configuration was a large fixed cost for every
# chunk. Each worker gets its own immutable set, so threaded chunk generation
# does not contend on a shared Resource.
static var _noise_cache: Dictionary = {}
static var _noise_cache_mutex: Mutex = Mutex.new()

# Terrain shape (heights, biomes, trees, structures) of one column of chunks, shared
# by every chunk stacked in that column. See _get_columns().
static var _column_cache: Dictionary = {}
static var _column_cache_mutex: Mutex = Mutex.new()

# Add a biome by appending one dictionary. Entries are evaluated in max_value
# order. Every key has a safe default, so new biome definitions can stay small.
static var biomes: Array[Dictionary] = [
	{
		"name": "Plains",
		"max_value": -0.48,
		"base_height": -2.0,
		"plains_amplitude": 4.0,
		"hill_multiplier": 0.35,
		"mountain_multiplier": 0.0,
		"top_block": BLOCK_GRASS,
		"filler_block": BLOCK_DIRT,
		"filler_depth": 3,
		"tree_chance": 0.004,
	},
	{
		"name": "Desert",
		"max_value": -0.12,
		"base_height": -1.0,
		"plains_amplitude": 3.0,
		"hill_multiplier": 0.25,
		"mountain_multiplier": 0.0,
		"top_block": BLOCK_SAND,
		"filler_block": BLOCK_SAND,
		"filler_depth": 5,
		"tree_chance": 0.0,
		"cactus_chance": 0.018,
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
	},
	{
		"name": "Highlands",
		"max_value": 0.70,
		"base_height": 9.0,
		"plains_amplitude": 6.0,
		"hill_multiplier": 1.0,
		"mountain_multiplier": 1.0,
		"top_block": BLOCK_GRASS,
		"filler_block": BLOCK_DIRT,
		"filler_depth": 3,
		"tree_chance": 0.006,
	},
	{
		"name": "Birch",
		"max_value": 1.0,
		"base_height": 9.0,
		"plains_amplitude": 6.0,
		"hill_multiplier": 1.0,
		"mountain_multiplier": 1.0,
		"top_block": BLOCK_GRASS,
		"filler_block": BLOCK_DIRT,
		"filler_depth": 3,
		"btree_chance": 0.08,
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
		"block": BLOCK_TOM,
		"spacing": 512,
		"chance": 2,
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
		"chance": 2,
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

# Caves (how they are built is explained in the "earth" section below).
const CAVE_MIN_Y = WORLD_BOTTOM + 3
const CAVE_MAX_Y = 109 # Keep at or above MAX_TERRAIN_HEIGHT so mountains get caves too.
const CAVE_SURFACE_DEPTH = 5 # Solid blocks normally left between a cave and the open air.

# Trees.
const TREE_LEAF_RADIUS = 2
const TREE_SPACING = 2
const TREE_MAX_HEIGHT = 7
const PLAINS_TREE_CHANCE = 0.002
const FOREST_TREE_CHANCE = 0.03

# BirchTrees.
const BTREE_LEAF_RADIUS = 1
const BTREE_SPACING = 2
const BTREE_MAX_HEIGHT = 10
const BPLAINS_TREE_CHANCE = 0
const BIRCH_TREE_CHANCE = 0.03

# Heights are sampled for the chunk plus a border, so slopes at the chunk edge
# and trees rooted in neighbouring chunks come out the same on both sides.
const GRID_MARGIN = TREE_LEAF_RADIUS + 1
const GRID_SIZE = CHUNK_SIZE + 2 * GRID_MARGIN


static func set_world_seed(seed: int) -> void:
	world_seed = seed
	clear_noise_cache()


# Call once when the player activates Earth-like world generation, before creating
# any chunks. Do not call this from generate(), which runs once per chunk.
static func activate_earth_world() -> int:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var new_seed := rng.randi()
	set_world_seed(new_seed)
	return new_seed


# Drops everything derived from the seed. Call it after editing biomes or
# earth_structures at runtime (set_world_seed() already does).
static func clear_noise_cache() -> void:
	_noise_cache_mutex.lock()
	_noise_cache.clear()
	_noise_cache_mutex.unlock()
	_column_cache_mutex.lock()
	_column_cache.clear()
	_column_cache_mutex.unlock()


# Cheap deterministic hash of a world column, 0 to 2^32 - 1.
static func _hash2(x: int, z: int, salt: int) -> int:
	var h := (x * 374761393 + z * 668265263 + salt * 1442695041 + (world_seed & 0xFFFFFFFF) * 1274126177) & 0xFFFFFFFF
	h = ((h ^ (h >> 13)) * 1274126177) & 0xFFFFFFFF
	return h ^ (h >> 16)


static func _hash3(x: int, y: int, z: int, salt: int) -> int:
	var h := _hash2(x, z, salt) ^ ((y * 1103515245) & 0xFFFFFFFF)
	h = ((h ^ (h >> 13)) * 1274126177) & 0xFFFFFFFF
	return h ^ (h >> 16)


static func empty() -> PackedByteArray:
	return PackedByteArray()


static func random_blocks(chunk_position: Vector3i) -> PackedByteArray:
	var blocks := PackedByteArray()
	var origin := chunk_position * CHUNK_SIZE
	var any := false
	for y in CHUNK_SIZE:
		for z in CHUNK_SIZE:
			for x in CHUNK_SIZE:
				var hash := _hash3(origin.x + x, origin.y + y, origin.z + z, 40)
				if float(hash & 0xFFFF) / 65536.0 < RANDOM_BLOCK_PROBABILITY:
					if not any:
						blocks.resize(CHUNK_VOLUME)
						any = true
					blocks[(y * CHUNK_SIZE + z) * CHUNK_SIZE + x] = (hash >> 16) % 29 + 1
	return blocks


static func flat(chunk_position: Vector3i) -> PackedByteArray:
	var blocks := PackedByteArray()
	if chunk_position.y != -1:
		return blocks
	blocks.resize(CHUNK_VOLUME)
	for z in CHUNK_SIZE:
		for x in CHUNK_SIZE:
			blocks[z * CHUNK_SIZE + x] = 3 # y = 0
	return blocks


# Chunk data for one of the world types the main menu offers (0 = random blocks,
# 1 = flat grass, 2 = earth). Safe to call from worker threads.
static func generate(chunk_position: Vector3i, world_type: int) -> PackedByteArray:
	match world_type:
		0:
			_earth_seed_initialized = false
			return random_blocks(chunk_position)
		2:
			# Chunks are generated separately, so randomize only once here, not
			# inside world(), or neighbouring chunks would use different seeds.
			if not _earth_seed_initialized:
				activate_earth_world()
				_earth_seed_initialized = true
			return world(chunk_position)
		_:
			_earth_seed_initialized = false
			return flat(chunk_position)


# ------------------------------------------------------------------- earth ---
# world() builds the "earth" world (Settings.world_type == 2). Everything below
# is a pure function of the world seed and world coordinates, so a tree or a
# structure that crosses a chunk border is generated identically by both chunks,
# and any number of worker threads can generate chunks at the same time.

# Biomes blend over this much of the biome noise value (-1 to 1), so heights fade
# into each other instead of forming cliffs at the biome border.
const BIOME_BLEND = 0.12
# Simplex noise rarely gets near +-1, so stretch it until every biome shows up.
const BIOME_NOISE_GAIN = 1.4

# Caves mix three ingredients, the way Minecraft 1.18+ does:
#  - Cheese caves: big roundish caverns where a flattened 3D noise is high. They get
#    rarer toward the surface, so they don't leave paper-thin ceilings, and more
#    common deep down.
#  - Spaghetti caves: long tunnels where two 3D noise fields are both close to zero.
#    They swell and shrink as they wind along and mostly run sideways.
#  - Entrances: a 2D noise picks patches of ground where the stone cap over the caves
#    thins away (and tunnels flare open), so caves sometimes break out of the hillside.
# Thresholds are in noise units (the noise is about -1 to 1, rarely beyond +-0.6):
# a lower CHEESE_THRESHOLD gives more caverns, a higher SPAGHETTI_*_HALF wider tunnels.
const CHEESE_FREQUENCY = 0.011
const CHEESE_Y_SCALE = 1.5          # Above 1 squashes caverns flatter.
const CHEESE_THRESHOLD = 0.40
const CHEESE_DEEP_BONUS = 0.05      # Threshold drop at the world bottom (more caverns deep down).
const CHEESE_CAP_DEPTH = 22.0       # Caverns fade out over this many blocks below the surface...
const CHEESE_CAP_BIAS = 0.6         # ...by raising their threshold this much right at the surface.

const SPAGHETTI_FREQUENCY = 0.012
const SPAGHETTI_Y_SCALE = 1.25      # Above 1 makes tunnels run more sideways.
const SPAGHETTI_WIDTH_FREQUENCY = 0.03
const SPAGHETTI_MIN_HALF = 0.055    # Tunnel width swings between these two (noise units).
const SPAGHETTI_MAX_HALF = 0.13

const ENTRANCE_FREQUENCY = 0.010
const ENTRANCE_MIN = 0.12           # Entrance noise below this keeps the full stone cap.
const ENTRANCE_MAX = 0.50           # Entrance strength reaches 100% at this noise value.
const ENTRANCE_REACH = 1.5          # The cap is gone once strength * ENTRANCE_REACH reaches 1.
const ENTRANCE_WIDEN = 0.06         # Extra tunnel half-width at the surface of an entrance.

# Cave noise is only sampled every CAVE_LATTICE blocks and blended in between. That keeps
# cave walls smooth at a fraction of the cost of sampling every block, and neighbouring
# chunks share the sample points on their borders, so caves line up across chunks.
# CHUNK_SIZE must stay divisible by CAVE_LATTICE.
const CAVE_LATTICE_SHIFT = 2
const CAVE_LATTICE = 1 << CAVE_LATTICE_SHIFT
const CAVE_INV_LATTICE = 1.0 / CAVE_LATTICE
const CAVE_CELLS = CHUNK_SIZE >> CAVE_LATTICE_SHIFT
const CAVE_NODES = CAVE_CELLS + 1
const CAVE_NODES_SQ = CAVE_NODES * CAVE_NODES
const CAVE_NODE_COUNT = CAVE_NODES_SQ * CAVE_NODES

const TREE_MIN_HEIGHT = 4

# How many chunk columns of cached terrain shape to keep. Oldest are dropped first.
const COLUMN_CACHE_LIMIT = 2048


# One set of noise generators. Every thread builds its own (see _get_noise).
class NoiseSet extends RefCounted:
	var biome: FastNoiseLite
	var plains: FastNoiseLite
	var hills: FastNoiseLite
	var mountain: FastNoiseLite
	var ridge: FastNoiseLite
	var cave_cheese: FastNoiseLite
	var cave_a: FastNoiseLite
	var cave_b: FastNoiseLite
	var cave_width: FastNoiseLite
	var cave_entrance: FastNoiseLite


# Everything about a column of chunks (one chunk x/z, every y) that does not depend
# on height: the padded height grid, biomes, bare-rock flags, trees and structures.
# It is built once and reused by every chunk in the column. Treat it as read-only.
class ColumnData extends RefCounted:
	var heights := PackedInt32Array()   # GRID_SIZE x GRID_SIZE, top solid block per column.
	var biome_ids := PackedByteArray()  # Dominant biome index per grid column.
	var rocky := PackedByteArray()      # 1 where the surface is bare stone.
	var highest := 0                    # Highest ground anywhere in the padded grid.
	var cave_open := PackedByteArray()  # CHUNK_SIZE x CHUNK_SIZE, cave entrance strength 0-255 per column.
	var cave_open_max := 0              # Strongest entrance among those columns.
	var cave_top := 0                   # Highest block any cave can reach in this chunk column.
	var trees: Array[Vector4i] = []     # Regular trees: (local x, ground y, local z, trunk height)
	var birch_trees: Array[Vector4i] = [] # Birch-only trees, stored separately
	var structures: Array = []          # See _structures_near().


static func _make_noise(salt: int, noise_type: FastNoiseLite.NoiseType, frequency: float, octaves: int, fractal: FastNoiseLite.FractalType = FastNoiseLite.FRACTAL_FBM) -> FastNoiseLite:
	var noise := FastNoiseLite.new()
	noise.seed = int(_hash2(salt, salt * 31 + 7, 900) & 0x7FFFFFFF)
	noise.noise_type = noise_type
	noise.frequency = frequency
	if octaves > 1:
		noise.fractal_type = fractal
		noise.fractal_octaves = octaves
	else:
		noise.fractal_type = FastNoiseLite.FRACTAL_NONE
	return noise


static func _get_noise() -> NoiseSet:
	var thread_id := OS.get_thread_caller_id()
	_noise_cache_mutex.lock()
	var noises: NoiseSet = _noise_cache.get(thread_id)
	_noise_cache_mutex.unlock()
	if noises != null:
		return noises

	noises = NoiseSet.new()
	noises.biome = _make_noise(1, FastNoiseLite.TYPE_SIMPLEX_SMOOTH, 0.0025, 2)
	noises.plains = _make_noise(2, FastNoiseLite.TYPE_SIMPLEX_SMOOTH, 0.02, 3)
	noises.hills = _make_noise(3, FastNoiseLite.TYPE_SIMPLEX_SMOOTH, 0.008, 4)
	noises.mountain = _make_noise(4, FastNoiseLite.TYPE_SIMPLEX_SMOOTH, 0.0035, 2)
	noises.ridge = _make_noise(5, FastNoiseLite.TYPE_SIMPLEX_SMOOTH, 0.012, 4, FastNoiseLite.FRACTAL_RIDGED)
	noises.cave_cheese = _make_noise(8, FastNoiseLite.TYPE_SIMPLEX_SMOOTH, CHEESE_FREQUENCY, 2)
	noises.cave_a = _make_noise(6, FastNoiseLite.TYPE_SIMPLEX_SMOOTH, SPAGHETTI_FREQUENCY, 1)
	noises.cave_b = _make_noise(7, FastNoiseLite.TYPE_SIMPLEX_SMOOTH, SPAGHETTI_FREQUENCY, 1)
	noises.cave_width = _make_noise(9, FastNoiseLite.TYPE_SIMPLEX_SMOOTH, SPAGHETTI_WIDTH_FREQUENCY, 1)
	noises.cave_entrance = _make_noise(10, FastNoiseLite.TYPE_SIMPLEX_SMOOTH, ENTRANCE_FREQUENCY, 1)

	_noise_cache_mutex.lock()
	_noise_cache[thread_id] = noises
	_noise_cache_mutex.unlock()
	return noises


# Returns (biome A, biome B, t): terrain parameters are lerped from A to B by t.
# t is 0 well inside a biome and ramps up across BIOME_BLEND on either side of a border.
static func _biome_blend(biome_value: float) -> Vector3:
	var count := biomes.size()
	var i := 0
	while i < count - 1 and biome_value > float(biomes[i].get("max_value", 1.0)):
		i += 1
	if i > 0:
		var previous_max := float(biomes[i - 1].get("max_value", 0.0))
		if biome_value < previous_max + BIOME_BLEND:
			return Vector3(i - 1, i, smoothstep(previous_max - BIOME_BLEND, previous_max + BIOME_BLEND, biome_value))
	if i < count - 1:
		var own_max := float(biomes[i].get("max_value", 1.0))
		if biome_value > own_max - BIOME_BLEND:
			return Vector3(i, i + 1, smoothstep(own_max - BIOME_BLEND, own_max + BIOME_BLEND, biome_value))
	return Vector3(i, i, 0.0)


static func _blend_param(blend: Vector3, key: String, default_value: float) -> float:
	var first := float(biomes[int(blend.x)].get(key, default_value))
	if blend.z <= 0.0:
		return first
	return lerpf(first, float(biomes[int(blend.y)].get(key, default_value)), blend.z)


# Terrain height (top solid block) and dominant biome index of one world column.
static func _column(noises: NoiseSet, wx: int, wz: int) -> Vector2i:
	var biome_value := clampf(noises.biome.get_noise_2d(wx, wz) * BIOME_NOISE_GAIN, -1.0, 1.0)
	var blend := _biome_blend(biome_value)

	var height := _blend_param(blend, "base_height", 0.0)
	height += noises.plains.get_noise_2d(wx, wz) * _blend_param(blend, "plains_amplitude", 4.0)
	height += noises.hills.get_noise_2d(wx, wz) * HILL_AMPLITUDE * _blend_param(blend, "hill_multiplier", 0.5)

	var mountain_multiplier := _blend_param(blend, "mountain_multiplier", 0.0)
	if mountain_multiplier > 0.0:
		var mask := smoothstep(-0.05, 0.45, noises.mountain.get_noise_2d(wx, wz))
		if mask > 0.0:
			var ridge := noises.ridge.get_noise_2d(wx, wz) * 0.5 + 0.5
			height += mountain_multiplier * mask * (MOUNTAIN_LIFT + MOUNTAIN_AMPLITUDE * ridge * mask)

	height = clampf(height, WORLD_BOTTOM + 8.0, MAX_TERRAIN_HEIGHT)
	var dominant: int = int(blend.y) if blend.z >= 0.5 else int(blend.x)
	return Vector2i(floori(height), dominant)


# Solid blocks kept between a cave and the open air in a column. The cap is the full
# CAVE_SURFACE_DEPTH normally and shrinks to nothing inside a cave entrance, where caves
# are allowed to break through the surface. open is the 0-255 entrance strength.
static func _cave_seal(open: int) -> int:
	return roundi(CAVE_SURFACE_DEPTH * (1.0 - minf(open / 255.0 * ENTRANCE_REACH, 1.0)))


# Smooth blend of the 8 lattice samples around one cell. i is the index of the cell's
# lowest corner; fx, fy, fz are 0 to 1 positions inside the cell. Samples are stored as
# (y * CAVE_NODES + z) * CAVE_NODES + x, so +1 steps along x, +CAVE_NODES along z and
# +CAVE_NODES_SQ along y.
static func _blend(v: PackedFloat32Array, i: int, fx: float, fy: float, fz: float) -> float:
	var iz := i + CAVE_NODES
	var iy := i + CAVE_NODES_SQ
	var iyz := iy + CAVE_NODES
	var low := lerpf(lerpf(v[i], v[i + 1], fx), lerpf(v[iz], v[iz + 1], fx), fz)
	var high := lerpf(lerpf(v[iy], v[iy + 1], fx), lerpf(v[iyz], v[iyz + 1], fx), fz)
	return lerpf(low, high, fy)


# (lowest, highest) of the 8 lattice samples around a cell. A blended value never leaves
# this range, so it tells whether a cell can possibly hold a cave without blending.
static func _corner_range(v: PackedFloat32Array, i: int) -> Vector2:
	var iz := i + CAVE_NODES
	var iy := i + CAVE_NODES_SQ
	var iyz := iy + CAVE_NODES
	var low := minf(
			minf(minf(v[i], v[i + 1]), minf(v[iz], v[iz + 1])),
			minf(minf(v[iy], v[iy + 1]), minf(v[iyz], v[iyz + 1])))
	var high := maxf(
			maxf(maxf(v[i], v[i + 1]), maxf(v[iz], v[iz + 1])),
			maxf(maxf(v[iy], v[iy + 1]), maxf(v[iyz], v[iyz + 1])))
	return Vector2(low, high)


# One flag per block of a chunk (indexed like chunk data) that a cave carves out. Returns
# an empty array when the chunk has no caves at all. Everything is a function of world
# coordinates, so neighbouring chunks agree about caves that cross their border.
static func _build_cave_mask(noises: NoiseSet, origin: Vector3i, columns: ColumnData) -> PackedByteArray:
	var mask := PackedByteArray()
	var y_first := maxi(origin.y, CAVE_MIN_Y)
	var y_last := mini(origin.y + CHUNK_SIZE - 1, columns.cave_top)
	if y_last < y_first:
		return mask

	# Noise at the lattice nodes, only for the rows of cells that can hold caves.
	var cell_first := (y_first - origin.y) >> CAVE_LATTICE_SHIFT
	var cell_last := (y_last - origin.y) >> CAVE_LATTICE_SHIFT
	var cheese := PackedFloat32Array()
	var spag_a := PackedFloat32Array()
	var spag_b := PackedFloat32Array()
	var width := PackedFloat32Array()
	cheese.resize(CAVE_NODE_COUNT)
	spag_a.resize(CAVE_NODE_COUNT)
	spag_b.resize(CAVE_NODE_COUNT)
	width.resize(CAVE_NODE_COUNT)
	for ny in range(cell_first, cell_last + 2):
		var wy := float(origin.y + ny * CAVE_LATTICE)
		for nz in CAVE_NODES:
			var wz := float(origin.z + nz * CAVE_LATTICE)
			for nx in CAVE_NODES:
				var wx := float(origin.x + nx * CAVE_LATTICE)
				var ni := (ny * CAVE_NODES + nz) * CAVE_NODES + nx
				cheese[ni] = noises.cave_cheese.get_noise_3d(wx, wy * CHEESE_Y_SCALE, wz)
				spag_a[ni] = noises.cave_a.get_noise_3d(wx, wy * SPAGHETTI_Y_SCALE, wz)
				spag_b[ni] = noises.cave_b.get_noise_3d(wx, wy * SPAGHETTI_Y_SCALE, wz)
				width[ni] = noises.cave_width.get_noise_3d(wx, wy, wz)

	# Highest block a cave may carve in each column. Trees keep the ground under their
	# trunk, so a tree never floats over the mouth of a cave.
	var roofs := PackedInt32Array()
	roofs.resize(CHUNK_AREA)
	for lz in CHUNK_SIZE:
		for lx in CHUNK_SIZE:
			var ci := lz * CHUNK_SIZE + lx
			var ground := columns.heights[(lz + GRID_MARGIN) * GRID_SIZE + lx + GRID_MARGIN]
			roofs[ci] = mini(CAVE_MAX_Y, ground - _cave_seal(columns.cave_open[ci]))
	for tree in columns.trees:
		if tree.x >= 0 and tree.x < CHUNK_SIZE and tree.z >= 0 and tree.z < CHUNK_SIZE:
			var ti := tree.z * CHUNK_SIZE + tree.x
			roofs[ti] = mini(roofs[ti], tree.y - 1)

	# Widest a tunnel can get in this chunk, and the lowest threshold a cavern can have.
	var half_reach := SPAGHETTI_MAX_HALF + ENTRANCE_WIDEN * float(columns.cave_open_max) / 255.0
	var cheese_floor := CHEESE_THRESHOLD - CHEESE_DEEP_BONUS

	var any := false
	for cy in range(cell_first, cell_last + 1):
		for cz in CAVE_CELLS:
			for cx in CAVE_CELLS:
				var corner := (cy * CAVE_NODES + cz) * CAVE_NODES + cx
				var cheese_possible := _corner_range(cheese, corner).y > cheese_floor
				var a_range := _corner_range(spag_a, corner)
				var spaghetti_possible := a_range.x < half_reach and a_range.y > -half_reach
				if spaghetti_possible:
					var b_range := _corner_range(spag_b, corner)
					spaghetti_possible = b_range.x < half_reach and b_range.y > -half_reach
				if not cheese_possible and not spaghetti_possible:
					continue

				for dy in CAVE_LATTICE:
					var ly := (cy << CAVE_LATTICE_SHIFT) + dy
					var y := origin.y + ly
					if y < CAVE_MIN_Y or y > y_last:
						continue
					var fy := dy * CAVE_INV_LATTICE
					var deep := clampf(-float(y) / 64.0, 0.0, 1.0)
					for dz in CAVE_LATTICE:
						var lz := (cz << CAVE_LATTICE_SHIFT) + dz
						var fz := dz * CAVE_INV_LATTICE
						for dx in CAVE_LATTICE:
							var lx := (cx << CAVE_LATTICE_SHIFT) + dx
							var ci := lz * CHUNK_SIZE + lx
							if y > roofs[ci]:
								continue
							var fx := dx * CAVE_INV_LATTICE
							var ground := columns.heights[(lz + GRID_MARGIN) * GRID_SIZE + lx + GRID_MARGIN]
							var open := float(columns.cave_open[ci]) / 255.0
							# 0 at the surface, 1 once CHEESE_CAP_DEPTH blocks down.
							var cap := clampf(float(ground - y) / CHEESE_CAP_DEPTH, 0.0, 1.0)

							var carve := false
							if cheese_possible:
								var limit := CHEESE_THRESHOLD - deep * CHEESE_DEEP_BONUS + (1.0 - cap) * CHEESE_CAP_BIAS * (1.0 - open)
								carve = _blend(cheese, corner, fx, fy, fz) > limit
							if not carve and spaghetti_possible:
								var a := _blend(spag_a, corner, fx, fy, fz)
								if absf(a) < half_reach:
									var b := _blend(spag_b, corner, fx, fy, fz)
									if absf(b) < half_reach:
										var half := lerpf(SPAGHETTI_MIN_HALF, SPAGHETTI_MAX_HALF, clampf(_blend(width, corner, fx, fy, fz) * 0.5 + 0.5, 0.0, 1.0))
										half += (1.0 - cap) * open * ENTRANCE_WIDEN
										carve = absf(a) < half and absf(b) < half
							if carve:
								if not any:
									mask.resize(CHUNK_VOLUME)
									any = true
								mask[(ly * CHUNK_SIZE + lz) * CHUNK_SIZE + lx] = 1
	return mask


static func _rock_jitter(wx: int, wz: int) -> float:
	return (float(_hash2(wx, wz, 3) & 0xFFFF) / 65536.0 - 0.5) * ROCK_JITTER


# Bare stone instead of soil: steep slopes, and everything above the (ragged) stone line.
static func _is_rocky(heights: PackedInt32Array, gi: int, wx: int, wz: int) -> bool:
	var h := heights[gi]
	var slope := maxi(
			maxi(absi(h - heights[gi - 1]), absi(h - heights[gi + 1])),
			maxi(absi(h - heights[gi - GRID_SIZE]), absi(h - heights[gi + GRID_SIZE])))
	return slope >= STEEP_SLOPE or float(h) + _rock_jitter(wx, wz) > STONE_LINE


static func _in_chunk(p: Vector3i) -> bool:
	return p.x >= 0 and p.y >= 0 and p.z >= 0 and p.x < CHUNK_SIZE and p.y < CHUNK_SIZE and p.z < CHUNK_SIZE


# Highest block anything in world() can reach, used to skip chunks that are all sky.
static func _max_feature_height() -> int:
	var top := int(MAX_TERRAIN_HEIGHT) + TREE_MAX_HEIGHT + 2
	for def in earth_structures:
		if bool(def.get("enabled", true)):
			top = maxi(top, int(MAX_TERRAIN_HEIGHT) + int(def.get("height", 0)) + 1)
	return top


# Number of blocks a structure stacks up at a given distance (in blocks, square
# rings) from its center. 0 means the column is outside the structure.
static func _structure_extent(def: Dictionary, ring: int) -> int:
	var radius := int(def.get("radius", 0))
	if ring > radius:
		return 0
	var height := int(def.get("height", 1))
	if str(def.get("shape", "box")) == "pyramid":
		return mini(height, radius - ring + 1)
	return height


# Structures whose footprint touches the given world-space rectangle. Each cell of
# a structure's spawn grid holds at most one, placed with a margin so it never
# crosses into the next cell.
static func _structures_near(noises: NoiseSet, min_x: int, min_z: int, max_x: int, max_z: int) -> Array:
	var found := []
	for def_index in earth_structures.size():
		var def: Dictionary = earth_structures[def_index]
		if not bool(def.get("enabled", true)):
			continue
		var spacing := maxi(int(def.get("spacing", 512)), 1)
		var radius := int(def.get("radius", 0))
		var chance := float(def.get("chance", 0.0))
		var span := spacing - 2 * (radius + 1)
		if span <= 0 or chance <= 0.0:
			continue
		for cell_z in range(floori(float(min_z) / float(spacing)), floori(float(max_z) / float(spacing)) + 1):
			for cell_x in range(floori(float(min_x) / float(spacing)), floori(float(max_x) / float(spacing)) + 1):
				var hx := _hash2(cell_x, cell_z, 100 + def_index)
				if float(hx & 0xFFFF) / 65536.0 >= chance:
					continue
				var hz := _hash2(cell_z, cell_x, 200 + def_index)
				var cx := cell_x * spacing + radius + 1 + int((hx >> 16) % span)
				var cz := cell_z * spacing + radius + 1 + int(hz % span)
				if cx + radius < min_x or cx - radius > max_x or cz + radius < min_z or cz - radius > max_z:
					continue
				# Base level: average ground height under the footprint. Higher ground is
				# buried, lower ground gets a foundation of the structure's own block.
				var total := 0
				for oz in range(-1, 2):
					for ox in range(-1, 2):
						total += _column(noises, cx + ox * radius, cz + oz * radius).x
				found.append({"def": def, "x": cx, "z": cz, "radius": radius, "base_y": roundi(total / 9.0)})
	return found


static func _in_structure(structures: Array, wx: int, wz: int, margin: int) -> bool:
	for structure in structures:
		var reach: int = int(structure["radius"]) + margin
		if absi(wx - int(structure["x"])) <= reach and absi(wz - int(structure["z"])) <= reach:
			return true
	return false


# Trees rooted in (or close enough to touch) the chunk. A column is a candidate when
# its hash beats the biome's tree chance; within TREE_SPACING the candidate with the
# lowest hash wins. The grid is wide enough that trees rooted in neighbouring chunks
# are found here too, with exactly the same result as in their own chunk.
static func _find_trees(columns: ColumnData, origin_x: int, origin_z: int, birch_only: bool = false) -> Array[Vector4i]:
	var trees: Array[Vector4i] = []
	var tree_hash := PackedInt64Array()
	tree_hash.resize(GRID_SIZE * GRID_SIZE)
	tree_hash.fill(-1)
	var any_tree := false
	for gz in GRID_SIZE:
		for gx in GRID_SIZE:
			var gi := gz * GRID_SIZE + gx
			var biome: Dictionary = biomes[columns.biome_ids[gi]]
			var is_birch_biome := str(biome.get("name", "")) == "Birch"
			if birch_only and not is_birch_biome:
				continue
			if not birch_only and is_birch_biome:
				continue
			var tree_chance := float(biome.get("btree_chance" if birch_only else "tree_chance", 0.0))
			if tree_chance <= 0.0:
				continue
			var candidate := _hash2(origin_x + gx - GRID_MARGIN, origin_z + gz - GRID_MARGIN, 22 if birch_only else 21)
			if float(candidate & 0xFFFF) / 65536.0 < tree_chance:
				tree_hash[gi] = candidate
				any_tree = true
	if not any_tree:
		return trees

	# The border only has room to compare neighbours one column away.
	var reach := mini(TREE_SPACING - 1, GRID_MARGIN - TREE_LEAF_RADIUS)
	var low := GRID_MARGIN - TREE_LEAF_RADIUS
	var high := GRID_MARGIN + CHUNK_SIZE + TREE_LEAF_RADIUS
	for gz in range(low, high):
		for gx in range(low, high):
			var gi := gz * GRID_SIZE + gx
			var candidate := tree_hash[gi]
			if candidate < 0:
				continue
			var crowded := false
			for dz in range(-reach, reach + 1):
				for dx in range(-reach, reach + 1):
					if dx == 0 and dz == 0:
						continue
					var other := tree_hash[gi + dz * GRID_SIZE + dx]
					if other >= 0 and other <= candidate:
						crowded = true
			if crowded or columns.rocky[gi] != 0:
				continue
			var wx := origin_x + gx - GRID_MARGIN
			var wz := origin_z + gz - GRID_MARGIN
			if _in_structure(columns.structures, wx, wz, TREE_LEAF_RADIUS):
				continue
			var trunk_height := TREE_MIN_HEIGHT + int((candidate >> 16) % (TREE_MAX_HEIGHT - TREE_MIN_HEIGHT + 1))
			trees.append(Vector4i(gx - GRID_MARGIN, columns.heights[gi], gz - GRID_MARGIN, trunk_height))
	return trees


# The terrain shape of a chunk column. Chunks stacked in the same column share it, so
# the height noise, biome blending, tree search and structure search run once per
# column instead of once per chunk. Safe to call from several threads.
static func _get_columns(chunk_x: int, chunk_z: int) -> ColumnData:
	var key := Vector2i(chunk_x, chunk_z)
	_column_cache_mutex.lock()
	var cached: ColumnData = _column_cache.get(key)
	_column_cache_mutex.unlock()
	if cached != null:
		return cached

	var noises := _get_noise()
	var columns := ColumnData.new()
	var origin_x := chunk_x * CHUNK_SIZE
	var origin_z := chunk_z * CHUNK_SIZE
	columns.heights.resize(GRID_SIZE * GRID_SIZE)
	columns.biome_ids.resize(GRID_SIZE * GRID_SIZE)
	columns.rocky.resize(GRID_SIZE * GRID_SIZE)

	var highest := WORLD_BOTTOM
	for gz in GRID_SIZE:
		for gx in GRID_SIZE:
			var column := _column(noises, origin_x + gx - GRID_MARGIN, origin_z + gz - GRID_MARGIN)
			var gi := gz * GRID_SIZE + gx
			columns.heights[gi] = column.x
			columns.biome_ids[gi] = column.y
			highest = maxi(highest, column.x)
	columns.highest = highest

	# Slopes need all four neighbours, so the outermost ring of the grid has no flag.
	for gz in range(1, GRID_SIZE - 1):
		for gx in range(1, GRID_SIZE - 1):
			var gi := gz * GRID_SIZE + gx
			if _is_rocky(columns.heights, gi, origin_x + gx - GRID_MARGIN, origin_z + gz - GRID_MARGIN):
				columns.rocky[gi] = 1

	# Cave entrances: how strongly each column of the chunk is open to caves breaking
	# through the surface, and the highest block a cave can reach anywhere in the chunk.
	columns.cave_open.resize(CHUNK_AREA)
	var cave_open_max := 0
	var cave_top := WORLD_BOTTOM
	for lz in CHUNK_SIZE:
		for lx in CHUNK_SIZE:
			var entrance := noises.cave_entrance.get_noise_2d(origin_x + lx, origin_z + lz)
			var open := int(smoothstep(ENTRANCE_MIN, ENTRANCE_MAX, entrance) * 255.0)
			columns.cave_open[lz * CHUNK_SIZE + lx] = open
			cave_open_max = maxi(cave_open_max, open)
			var ground := columns.heights[(lz + GRID_MARGIN) * GRID_SIZE + lx + GRID_MARGIN]
			cave_top = maxi(cave_top, mini(CAVE_MAX_Y, ground - _cave_seal(open)))
	columns.cave_open_max = cave_open_max
	columns.cave_top = cave_top

	var pad := GRID_MARGIN + TREE_LEAF_RADIUS
	columns.structures = _structures_near(noises, origin_x - pad, origin_z - pad, origin_x + CHUNK_SIZE - 1 + pad, origin_z + CHUNK_SIZE - 1 + pad)
	columns.trees = _find_trees(columns, origin_x, origin_z, false)
	columns.birch_trees = _find_trees(columns, origin_x, origin_z, true)

	_column_cache_mutex.lock()
	if _column_cache.size() >= COLUMN_CACHE_LIMIT:
		# Dictionaries keep insertion order, so the first keys are the oldest.
		var old_keys := _column_cache.keys()
		for i in old_keys.size() >> 2:
			_column_cache.erase(old_keys[i])
	_column_cache[key] = columns
	_column_cache_mutex.unlock()
	return columns


# Writes a tree into chunk-local data. base is the trunk's lowest block in
# chunk-local coordinates and may lie outside the chunk; only the parts that
# fall inside are written. Leaves never replace existing blocks, the trunk does.
static func _place_tree(data: PackedByteArray, base: Vector3i, trunk_height: int) -> void:
	var top := base.y + trunk_height - 1
	# Two wide layers around the upper trunk, a full 3x3, then a plus-shaped tip.
	for y in range(top - 2, top + 2):
		var radius := TREE_LEAF_RADIUS if y < top else TREE_LEAF_RADIUS - 1
		var cut_corners := y != top
		for dz in range(-radius, radius + 1):
			for dx in range(-radius, radius + 1):
				if cut_corners and absi(dx) == radius and absi(dz) == radius:
					continue
				var leaf := Vector3i(base.x + dx, y, base.z + dz)
				if _in_chunk(leaf):
					var leaf_index := (leaf.y * CHUNK_SIZE + leaf.z) * CHUNK_SIZE + leaf.x
					if data[leaf_index] == 0:
						data[leaf_index] = BLOCK_LEAVES
	for y in range(base.y, base.y + trunk_height):
		var log_position := Vector3i(base.x, y, base.z)
		if _in_chunk(log_position):
			data[(log_position.y * CHUNK_SIZE + log_position.z) * CHUNK_SIZE + log_position.x] = BLOCK_BARK
			


static func _place_btree(data: PackedByteArray, base: Vector3i, trunk_height: int) -> void:
	var top := base.y + trunk_height - 1
	# Two wide layers around the upper trunk, a full 3x3, then a plus-shaped tip.
	for y in range(top - 2, top + 2):
		var radius := TREE_LEAF_RADIUS if y < top else TREE_LEAF_RADIUS - 1
		var cut_corners := y != top
		for dz in range(-radius, radius + 1):
			for dx in range(-radius, radius + 1):
				if cut_corners and absi(dx) == radius and absi(dz) == radius:
					continue
				var leaf := Vector3i(base.x + dx, y, base.z + dz)
				if _in_chunk(leaf):
					var leaf_index := (leaf.y * CHUNK_SIZE + leaf.z) * CHUNK_SIZE + leaf.x
					if data[leaf_index] == 0:
						data[leaf_index] = BLOCK_LEAVES
	for y in range(base.y, base.y + trunk_height):
		var log_position := Vector3i(base.x, y, base.z)
		if _in_chunk(log_position):
			data[(log_position.y * CHUNK_SIZE + log_position.z) * CHUNK_SIZE + log_position.x] = BLOCK_BIRCH


# Minecraft-style terrain: biomes with blended heights, hills and mountains, soil
# layers over stone, bare rock on cliffs and peaks, 3D noise caves, trees, and the
# structures listed in earth_structures.
static func world(chunk_position: Vector3i) -> PackedByteArray:
	var data := PackedByteArray()
	var origin := chunk_position * CHUNK_SIZE
	var y_min := origin.y
	var y_max := origin.y + CHUNK_SIZE - 1
	if y_max < WORLD_BOTTOM or y_min > _max_feature_height():
		return data

	var columns := _get_columns(chunk_position.x, chunk_position.z)
	if columns.structures.is_empty() and y_min > columns.highest + TREE_MAX_HEIGHT + 2:
		return data # Nothing but open sky in this chunk.

	data.resize(CHUNK_VOLUME)
	var any := false
	var heights := columns.heights
	var biome_ids := columns.biome_ids
	var rocky_flags := columns.rocky

	# Caves. Only chunks that reach below the highest cave roof get a mask at all.
	var cave_mask := PackedByteArray()
	if y_min <= columns.cave_top and y_max >= CAVE_MIN_Y:
		cave_mask = _build_cave_mask(_get_noise(), origin, columns)
	var has_caves := not cave_mask.is_empty()

	# Terrain.
	var y_bottom := maxi(y_min, WORLD_BOTTOM)
	for lz in CHUNK_SIZE:
		for lx in CHUNK_SIZE:
			var gi := (lz + GRID_MARGIN) * GRID_SIZE + lx + GRID_MARGIN
			var h := heights[gi]
			var y_top := mini(y_max, h)
			if y_top < y_bottom:
				continue

			any = true
			var biome: Dictionary = biomes[biome_ids[gi]]
			var rocky := rocky_flags[gi] != 0
			var top_block := int(biome.get("top_block", BLOCK_GRASS))
			var filler_block := int(biome.get("filler_block", BLOCK_DIRT))
			var filler_start := h - int(biome.get("filler_depth", 3))

			for y in range(y_bottom, y_top + 1):
				# The mask only ever flags blocks between CAVE_MIN_Y and the column's cave roof.
				if has_caves and cave_mask[((y - origin.y) * CHUNK_SIZE + lz) * CHUNK_SIZE + lx] != 0:
					continue
				var block := BLOCK_STONE
				if y == h:
					# Snow caps high mountain peaks, including bare-rock summits.
					block = BLOCK_SNOW if h >= 72 and str(biome.get("name", "")) != "Desert" else (BLOCK_STONE if rocky else top_block)
				elif not rocky and y >= filler_start:
					block = filler_block
				# Deterministic ore pockets replace a small fraction of deep stone.
				if block == BLOCK_STONE and y < 24:
					var ore_hash := _hash3(origin.x + lx, y, origin.z + lz, 39)
					if float(ore_hash & 0xFFFF) / 65536.0 < 0.018:
						block = BLOCK_ORE
				data[((y - origin.y) * CHUNK_SIZE + lz) * CHUNK_SIZE + lx] = block

	# Deterministic desert cactus placement. Every chunk derives the same result
	# from the world seed and world coordinates, including cacti crossing chunk Y edges.
	for lz in CHUNK_SIZE:
		for lx in CHUNK_SIZE:
			var gi := (lz + GRID_MARGIN) * GRID_SIZE + lx + GRID_MARGIN
			var biome: Dictionary = biomes[biome_ids[gi]]
			var cactus_chance := float(biome.get("cactus_chance", 0.0))
			if cactus_chance <= 0.0:
				continue
			var wx := origin.x + lx
			var wz := origin.z + lz
			var cactus_hash := _hash2(wx, wz, 61)
			if float(cactus_hash & 0xFFFF) / 65536.0 >= cactus_chance:
				continue
			var ground_y := heights[gi]
			var cactus_height := 1 + int((cactus_hash >> 16) % 3)
			for cy in range(ground_y + 1, ground_y + cactus_height + 1):
				if cy < y_min or cy > y_max:
					continue
				var cactus_index := ((cy - origin.y) * CHUNK_SIZE + lz) * CHUNK_SIZE + lx
				data[cactus_index] = BLOCK_CACTUS
				any = true

	# Trees, already worked out for the whole column of chunks.
	for tree in columns.trees:
		var ground := tree.y
		var trunk_height := tree.w
		if ground + 1 > y_max or ground + trunk_height + 1 < y_min:
			continue
		any = true
		_place_tree(data, Vector3i(tree.x, ground + 1 - origin.y, tree.z), trunk_height)

	for tree in columns.birch_trees:
		var ground := tree.y
		var trunk_height := tree.w
		if ground + 1 > y_max or ground + trunk_height + 1 < y_min:
			continue
		any = true
		_place_btree(data, Vector3i(tree.x, ground + 1 - origin.y, tree.z), trunk_height)

	# Structures go in last and replace whatever is in their way.
	for structure in columns.structures:
		var def: Dictionary = structure["def"]
		var radius: int = structure["radius"]
		var base_y: int = structure["base_y"]
		var block := int(def.get("block", BLOCK_STONE))
		for lz in CHUNK_SIZE:
			var dz := origin.z + lz - int(structure["z"])
			if absi(dz) > radius:
				continue
			for lx in CHUNK_SIZE:
				var dx := origin.x + lx - int(structure["x"])
				var extent := _structure_extent(def, maxi(absi(dx), absi(dz)))
				if extent <= 0:
					continue
				var ground := heights[(lz + GRID_MARGIN) * GRID_SIZE + lx + GRID_MARGIN]
				var first := maxi(mini(base_y, ground + 1), y_bottom)
				var last := mini(base_y + extent - 1, y_max)
				for y in range(first, last + 1):
					any = true
					data[((y - origin.y) * CHUNK_SIZE + lz) * CHUNK_SIZE + lx] = block

	if not any:
		return PackedByteArray()
	return data


# Used to create the project icon.
static func origin_grass(chunk_position: Vector3i) -> PackedByteArray:
	var blocks := PackedByteArray()
	if chunk_position == Vector3i.ZERO:
		blocks.resize(CHUNK_VOLUME)
		blocks[0] = 3
	return blocks

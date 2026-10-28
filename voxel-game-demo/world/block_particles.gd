class_name BlockParticles extends MultiMeshInstance3D
# Minecraft-style block break particles: a 4x4x4 burst of small billboarded
# fragments, each showing a random quarter-width piece of the broken block's texture.
# One MultiMesh draws every particle in a single draw call, and the simulation is a
# plain loop over packed arrays (no node per particle).
#
# VoxelWorld creates this node and calls spawn_break(). `world` must provide
# is_solid_at(Vector3) -> bool so fragments land on the ground instead of falling through.

const MAX_PARTICLES = 1024
const GRID = 4                  # 4x4x4 fragments per block, like Minecraft.
const GRAVITY = 16.0            # Blocks per second squared (0.04 per tick at 20 ticks/s).
const DRAG_PER_TICK = 0.98
const GROUND_FRICTION_PER_TICK = 0.7
const TICKS_PER_SECOND = 20.0
const TINT = 0.6                # Minecraft darkens terrain particles.
const FLOATS_PER_INSTANCE = 16  # 12 transform floats + 4 custom data floats.

const SHADER_CODE = """
shader_type spatial;
render_mode unshaded, cull_disabled;

uniform sampler2D atlas : source_color, filter_nearest;

varying vec4 piece;

void vertex() {
	piece = INSTANCE_CUSTOM; // xy = uv origin of the piece, z = piece size, w = brightness
	// Billboard: face the camera, keep the instance scale.
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(INV_VIEW_MATRIX[0], INV_VIEW_MATRIX[1], INV_VIEW_MATRIX[2], MODEL_MATRIX[3]);
	MODELVIEW_MATRIX = MODELVIEW_MATRIX * mat4(
			vec4(length(MODEL_MATRIX[0].xyz), 0.0, 0.0, 0.0),
			vec4(0.0, length(MODEL_MATRIX[1].xyz), 0.0, 0.0),
			vec4(0.0, 0.0, length(MODEL_MATRIX[2].xyz), 0.0),
			vec4(0.0, 0.0, 0.0, 1.0));
	MODELVIEW_NORMAL_MATRIX = mat3(MODELVIEW_MATRIX);
}

void fragment() {
	vec4 c = texture(atlas, piece.xy + UV * piece.z);
	if (c.a < 0.5) {
		discard;
	}
	ALBEDO = c.rgb * piece.w;
}
"""

var world: Node

var _count := 0
var _pos := PackedVector3Array()
var _vel := PackedVector3Array()
var _life := PackedFloat32Array()
var _size := PackedFloat32Array()
var _piece := PackedFloat32Array()   # 4 floats per particle: u, v, piece size, brightness.
var _on_ground := PackedByteArray()
var _buffer := PackedFloat32Array()
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	_rng.randomize()
	top_level = true
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	custom_aabb = AABB(Vector3(-1.0e6, -1.0e6, -1.0e6), Vector3(2.0e6, 2.0e6, 2.0e6))

	_pos.resize(MAX_PARTICLES)
	_vel.resize(MAX_PARTICLES)
	_life.resize(MAX_PARTICLES)
	_size.resize(MAX_PARTICLES)
	_piece.resize(MAX_PARTICLES * 4)
	_on_ground.resize(MAX_PARTICLES)
	_buffer.resize(MAX_PARTICLES * FLOATS_PER_INSTANCE)

	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = quad
	mm.instance_count = MAX_PARTICLES
	mm.visible_instance_count = 0
	multimesh = mm

	var shader := Shader.new()
	shader.code = SHADER_CODE
	var material := ShaderMaterial.new()
	material.shader = shader
	material.set_shader_parameter("atlas", Chunk.get_atlas_texture())
	material_override = material


# Bursts the fragments of a broken block. block_min_corner is the block's world
# position (its lowest corner), block_id is what was there before it was removed.
func spawn_break(block_min_corner: Vector3, block_id: int) -> void:
	if block_id == 0 or multimesh == null:
		return

	# Block id is the tile index on the texture sheet (side texture).
	var tile_size := Chunk.TEXTURE_TILE_SIZE
	var tile_u := (block_id % Chunk.TEXTURE_SHEET_WIDTH) * tile_size
	var tile_v := (block_id / Chunk.TEXTURE_SHEET_WIDTH) * tile_size
	var piece_size := tile_size / GRID

	for ix in GRID:
		for iy in GRID:
			for iz in GRID:
				var index := _count
				if index >= MAX_PARTICLES:
					index = _rng.randi() % MAX_PARTICLES # Full: recycle a random one.
				else:
					_count += 1

				var fragment := Vector3((ix + 0.5) / GRID, (iy + 0.5) / GRID, (iz + 0.5) / GRID)
				_pos[index] = block_min_corner + fragment

				# Outward from the block center plus jitter, like Minecraft's particles.
				var dir := fragment - Vector3(0.5, 0.5, 0.5) + Vector3(
						_rng.randf_range(-0.4, 0.4), _rng.randf_range(-0.4, 0.4), _rng.randf_range(-0.4, 0.4))
				if dir.length_squared() < 0.0001:
					dir = Vector3.UP
				var speed := (_rng.randf() + _rng.randf() + 1.0) * 0.15 * 0.4 * TICKS_PER_SECOND
				var velocity := dir.normalized() * speed
				velocity.y += 2.0
				_vel[index] = velocity

				_life[index] = 4.0 / (_rng.randf() * 0.9 + 0.1) / TICKS_PER_SECOND
				_size[index] = (_rng.randf() * 0.5 + 0.5) * 0.2
				_on_ground[index] = 0

				# A random sub-square of the block's texture tile.
				var o := index * 4
				_piece[o] = tile_u + _rng.randi_range(0, GRID - 1) * piece_size
				_piece[o + 1] = tile_v + _rng.randi_range(0, GRID - 1) * piece_size
				_piece[o + 2] = piece_size
				_piece[o + 3] = TINT


func _process(delta: float) -> void:
	if _count == 0:
		if multimesh.visible_instance_count != 0:
			multimesh.visible_instance_count = 0
		return

	delta = minf(delta, 0.05)
	var drag := pow(DRAG_PER_TICK, delta * TICKS_PER_SECOND)
	var friction := pow(GROUND_FRICTION_PER_TICK, delta * TICKS_PER_SECOND)

	var i := 0
	while i < _count:
		_life[i] -= delta
		if _life[i] <= 0.0:
			_remove(i) # Swaps the last particle into slot i, so don't advance.
			continue

		var p := _pos[i]
		var v := _vel[i]
		v.y -= GRAVITY * delta
		v *= drag

		# Move one axis at a time so fragments slide along walls and rest on the floor.
		var step := v * delta
		var grounded := false
		if world != null:
			var nx := Vector3(p.x + step.x, p.y, p.z)
			if world.is_solid_at(nx):
				v.x = 0.0
			else:
				p.x = nx.x
			var nz := Vector3(p.x, p.y, p.z + step.z)
			if world.is_solid_at(nz):
				v.z = 0.0
			else:
				p.z = nz.z
			var ny := Vector3(p.x, p.y + step.y, p.z)
			if world.is_solid_at(ny):
				grounded = v.y < 0.0
				v.y = 0.0
			else:
				p.y = ny.y
		else:
			p += step

		if grounded:
			v.x *= friction
			v.z *= friction
		_pos[i] = p
		_vel[i] = v

		var s := _size[i]
		var o := i * FLOATS_PER_INSTANCE
		_buffer[o] = s
		_buffer[o + 3] = p.x
		_buffer[o + 5] = s
		_buffer[o + 7] = p.y
		_buffer[o + 10] = s
		_buffer[o + 11] = p.z
		var po := i * 4
		_buffer[o + 12] = _piece[po]
		_buffer[o + 13] = _piece[po + 1]
		_buffer[o + 14] = _piece[po + 2]
		_buffer[o + 15] = _piece[po + 3]
		i += 1

	multimesh.visible_instance_count = _count
	multimesh.buffer = _buffer


# Removes particle i by moving the last live particle into its slot.
func _remove(i: int) -> void:
	_count -= 1
	if i == _count:
		return
	_pos[i] = _pos[_count]
	_vel[i] = _vel[_count]
	_life[i] = _life[_count]
	_size[i] = _size[_count]
	_on_ground[i] = _on_ground[_count]
	var o := i * 4
	var last := _count * 4
	_piece[o] = _piece[last]
	_piece[o + 1] = _piece[last + 1]
	_piece[o + 2] = _piece[last + 2]
	_piece[o + 3] = _piece[last + 3]

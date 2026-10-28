extends CharacterBody3D

const EYE_HEIGHT_STAND = 1.6
const EYE_HEIGHT_CROUCH = 1.4

const MOVEMENT_SPEED_GROUND = 0.6
const MOVEMENT_SPEED_AIR = 0.11
const MOVEMENT_SPEED_CROUCH_MODIFIER = 0.5
const MOVEMENT_FRICTION_GROUND = 0.9
const MOVEMENT_FRICTION_AIR = 0.98

var _mouse_motion = Vector2()
var _selected_block = 6
var _creative_menu_open := false
var _creative_layer: CanvasLayer
var _creative_ui: Control
var _is_flying := false
var _last_space_press_msec := -1000
const DOUBLE_TAP_WINDOW_MSEC := 350
const FLY_SPEED := 8.0

@onready var gravity = ProjectSettings.get_setting("physics/3d/default_gravity")

@onready var head = $Head
@onready var raycast = $Head/RayCast3D
@onready var camera_attributes = $Head/Camera3D.attributes
@onready var selected_block_texture = $SelectedBlock
@onready var voxel_world = $"../VoxelWorld"
@onready var crosshair = $"../PauseMenu/Crosshair"
@onready var player_mesh: Node3D = $CollisionShape3D/player
@export var first_person_camera: Camera3D
@export var third_person_camera: Camera3D

func _ready():
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	_build_creative_menu()
	update_mesh_visibility()

func _process(_delta):
	if _creative_menu_open:
		return
	# Mouse movement.
	_mouse_motion.y = clamp(_mouse_motion.y, -1560, 1560)
	transform.basis = Basis.from_euler(Vector3(0, _mouse_motion.x * -0.001, 0))
	head.transform.basis = Basis.from_euler(Vector3(_mouse_motion.y * -0.001, 0, 0))
	if is_multiplayer_authority():
		update_mesh_visibility()



func update_mesh_visibility() -> void:
	var current_camera = get_viewport().get_camera_3d()
	
	# If the active camera matches the chosen First Person camera, hide the mesh
	if current_camera == first_person_camera:
		player_mesh.hide()
	else:
		player_mesh.show()

	# Block selection.
	var ray_position = raycast.get_collision_point()
	var ray_normal = raycast.get_collision_normal()
	if Input.is_action_just_pressed(&"pick_block"):
		# Block picking.
		var block_global_position = Vector3i((ray_position - ray_normal / 2).floor())
		_selected_block = voxel_world.get_block_global_position(block_global_position)
	else:
		# Block prev/next keys.
		if Input.is_action_just_pressed(&"prev_block"):
			_selected_block -= 1
		if Input.is_action_just_pressed(&"next_block"):
			_selected_block += 1
		_selected_block = wrapi(_selected_block, 1, 101)
	# Set the appropriate texture.
	var uv = Chunk.calculate_block_uvs(_selected_block)
	selected_block_texture.texture.region = Rect2(uv[0] * 512, Vector2.ONE * 64)

	# Block breaking/placing.
	if crosshair.visible and raycast.is_colliding():
		var breaking = Input.is_action_just_pressed(&"break")
		var placing = Input.is_action_just_pressed(&"place")
		# Either both buttons were pressed or neither are, so stop.
		if breaking == placing:
			return

		if breaking:
			var block_global_position = Vector3i((ray_position - ray_normal / 2).floor())
			voxel_world.set_block_global_position(block_global_position, 0)
		elif placing:
			var block_global_position = Vector3i((ray_position + ray_normal / 2).floor())
			voxel_world.set_block_global_position(block_global_position, _selected_block)


func _physics_process(delta):
	if _creative_menu_open:
		velocity = Vector3.ZERO
		return
	camera_attributes.dof_blur_far_enabled = Settings.fog_enabled
	camera_attributes.dof_blur_far_distance = Settings.fog_distance * 1.5
	camera_attributes.dof_blur_far_transition = Settings.fog_distance * 0.125
	# Crouching.
	var crouching = Input.is_action_pressed(&"crouch")
	head.transform.origin.y = lerpf(head.transform.origin.y, EYE_HEIGHT_CROUCH if crouching else EYE_HEIGHT_STAND, 16 * delta)

	# Keyboard movement.
	var movement_vec2 = Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var movement = transform.basis * (Vector3(movement_vec2.x, 0, movement_vec2.y))

	if is_on_floor():
		movement *= MOVEMENT_SPEED_GROUND
	else:
		movement *= MOVEMENT_SPEED_AIR

	if crouching:
		movement *= MOVEMENT_SPEED_CROUCH_MODIFIER

	if _is_flying:
		# Creative flight: Space rises, crouch descends, and gravity is disabled.
		velocity.y = 0.0
		if Input.is_action_pressed(&"jump"):
			velocity.y = FLY_SPEED
		elif crouching:
			velocity.y = -FLY_SPEED
		velocity.x = movement.x * 200.0
		velocity.z = movement.z * 200.0
	else:
		# Normal walking gravity and movement.
		velocity.y -= gravity * delta
		velocity.x *= MOVEMENT_FRICTION_GROUND if is_on_floor() else MOVEMENT_FRICTION_AIR
		velocity.z *= MOVEMENT_FRICTION_GROUND if is_on_floor() else MOVEMENT_FRICTION_AIR
		velocity.x += movement.x
		velocity.z += movement.z
		if is_on_floor() and Input.is_action_pressed(&"jump"):
			velocity.y = 7.5
	move_and_slide()
	var input_dir = Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down")
	var direction = (transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()

func _input(event):
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_SPACE and not _creative_menu_open:
			var now := Time.get_ticks_msec()
			if now - _last_space_press_msec <= DOUBLE_TAP_WINDOW_MSEC:
				_is_flying = not _is_flying
				velocity.y = 1.0
				_last_space_press_msec = -1000
			else:
				_last_space_press_msec = now
		if event.keycode == KEY_E or (_creative_menu_open and event.keycode == KEY_ESCAPE):
			_toggle_creative_menu()
			get_viewport().set_input_as_handled()
			return
	if event is InputEventMouseMotion:
		if Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
			_mouse_motion += event.relative


func chunk_pos():
	return Vector3i((transform.origin / Chunk.CHUNK_SIZE).floor())

func _build_creative_menu():
	# Build a real, usable creative inventory instead of an empty Control.
	_creative_layer = CanvasLayer.new()
	_creative_layer.name = "CreativeMenuLayer"
	_creative_layer.layer = 20
	_creative_ui = Control.new()
	_creative_ui.name = "CreativeMenu"
	_creative_ui.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_creative_layer.add_child(_creative_ui)
	add_child(_creative_layer)

	var dimmer := ColorRect.new()
	dimmer.color = Color(0.0, 0.0, 0.0, 0.68)
	dimmer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_creative_ui.add_child(dimmer)

	var panel := PanelContainer.new()
	panel.name = "InventoryPanel"
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.position = Vector2(-310, -250)
	panel.size = Vector2(620, 500)
	panel.custom_minimum_size = Vector2(620, 500)
	_creative_ui.add_child(panel)

	var layout := VBoxContainer.new()
	layout.add_theme_constant_override("separation", 12)
	panel.add_child(layout)

	var heading := Label.new()
	heading.text = "CREATIVE INVENTORY"
	heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	heading.add_theme_font_size_override("font_size", 26)
	layout.add_child(heading)

	var help := Label.new()
	help.text = "Select a block. Press E or Esc to close."
	help.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	layout.add_child(help)

	var selected_label := Label.new()
	selected_label.name = "SelectedBlockLabel"
	selected_label.text = "Selected block: %d" % _selected_block
	selected_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	layout.add_child(selected_label)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	layout.add_child(scroll)

	var grid := GridContainer.new()
	grid.columns = 5
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_theme_constant_override("h_separation", 8)
	grid.add_theme_constant_override("v_separation", 8)
	scroll.add_child(grid)

	for block_id in range(1, 101):
		var block_button := Button.new()
		block_button.text = "Block %d" % block_id
		block_button.custom_minimum_size = Vector2(95, 42)
		block_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		block_button.pressed.connect(_select_creative_block.bind(block_id, selected_label))
		grid.add_child(block_button)

	_creative_layer.visible = false

func _select_creative_block(block_id: int, selected_label: Label) -> void:
	_selected_block = block_id
	selected_label.text = "Selected block: %d" % _selected_block
	var uv = Chunk.calculate_block_uvs(_selected_block)
	selected_block_texture.texture.region = Rect2(uv[0] * 512, Vector2.ONE * 64)
	_toggle_creative_menu()

func _toggle_creative_menu():
	_creative_menu_open = not _creative_menu_open
	if _creative_layer:
		_creative_layer.visible = _creative_menu_open
	if _creative_menu_open:
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	else:
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
		# Clear accumulated mouse motion so the camera doesn't snap.
		_mouse_motion = Vector2.ZERO


extends Node3D

# --- Sway Settings ---
@export_group("Sway")
@export var sway_amount: float = 0.05
@export var sway_speed: float = 8.0
@export var sway_smoothing: float = 10.0

# --- Bobbing Settings ---
@export_group("Bobbing")
@export var bob_amount: float = 0.02
@export var bob_speed: float = 12.0
@export var bob_smoothing: float = 8.0

# --- Punching Settings ---
@export_group("Punching")
@export var punch_duration: float = 0.20
@export var punch_distance: float = 0.35
@export var punch_rotation: float = 45.0

# --- References ---
@export_group("References")
@export var player_path: NodePath = ^"../../.."

@onready var character_body: CharacterBody3D = get_node_or_null(player_path)

# --- Internal Variables ---
var sway_target: Vector2 = Vector2.ZERO
var sway_current: Vector2 = Vector2.ZERO
var bob_time: float = 0.0

var base_position: Vector3
var base_rotation: Vector3

var is_punching: bool = false
var punch_time: float = 0.0

func _ready() -> void:
	base_position = position
	base_rotation = rotation


func _input(event: InputEvent) -> void:
	# Mouse movement sway
	if event is InputEventMouseMotion:
		sway_target.x -= event.relative.x
		sway_target.y += event.relative.y

	# Punch with either mouse button
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_LEFT \
		or event.button_index == MOUSE_BUTTON_RIGHT:
			start_punch()


func start_punch() -> void:
	# Prevent overlapping punches
	if is_punching:
		return

	is_punching = true
	punch_time = 0.0


func _process(delta: float) -> void:
	# --- Sway ---
	sway_current = sway_current.lerp(
		sway_target * sway_amount * 0.01,
		clampf(sway_smoothing * delta, 0.0, 1.0)
	)

	sway_target = Vector2.ZERO

	# --- Movement Bobbing ---
	var bob_offset := Vector3.ZERO

	if character_body != null:
		var horizontal_speed := Vector2(
			character_body.velocity.x,
			character_body.velocity.z
		).length()

		if horizontal_speed > 0.1 and character_body.is_on_floor():
			bob_time += delta * bob_speed
			bob_offset.y = sin(bob_time) * bob_amount
			bob_offset.x = cos(bob_time * 0.5) * bob_amount
		else:
			bob_time = 0.0

	# --- Punch Animation ---
	var punch_offset := Vector3.ZERO
	var punch_rot := 0.0

	if is_punching:
		punch_time += delta

		var progress: float = punch_time / punch_duration

		if progress >= 1.0:
			is_punching = false
		else:
			# Quick forward swing and return
			var swing: float = sin(progress * PI)

			punch_offset.z = -swing * punch_distance
			punch_rot = -deg_to_rad(punch_rotation) * swing

	# --- Apply Position ---
	var target_position: Vector3 = base_position + bob_offset + punch_offset

	position = position.lerp(
		target_position,
		clampf(bob_smoothing * delta, 0.0, 1.0)
	)

	# --- Apply Rotation ---
	var target_rotation := Vector3(
		base_rotation.x + sway_current.y + punch_rot,
		base_rotation.y + sway_current.x,
		base_rotation.z
	)

	rotation = rotation.lerp(
		target_rotation,
		clampf(sway_smoothing * delta, 0.0, 1.0)
	)

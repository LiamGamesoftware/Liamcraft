extends Node3D

@export var rotation_speed: float = 6.0 # Higher values catch up faster, lower values drag more

@onready var animation_player: AnimationPlayer = $AnimationPlayer

var last_global_pos: Vector3 = Vector3.ZERO

func _ready() -> void:
	last_global_pos = global_position
	animation_player.play("idle")

func _physics_process(delta: float) -> void:
	# 1. Track movement speed based on global position
	var current_global_pos: Vector3 = global_position
	var distance_moved: float = current_global_pos.distance_to(last_global_pos)
	var speed: float = distance_moved / maxf(delta, 0.001)
	
	last_global_pos = current_global_pos

	# 2. Extract and lag behind the Y-axis rotation of the parent (the root controller)
	var parent: Node3D = get_parent() as Node3D
	if parent:
		# Get the target Y rotation from the parent controller
		var target_y_rot: float = parent.global_transform.basis.get_euler().y
		# Get this mesh's current global Y rotation
		var current_y_rot: float = global_transform.basis.get_euler().y
		
		# Smoothly interpolate the angles using lerp_angle to handle the -PI to PI wrap seamlessly
		var weight: float = 1.0 - exp(-rotation_speed * delta)
		var next_y_rot: float = lerp_angle(current_y_rot, target_y_rot, weight)
		
		# Reconstruct the rotation basis using only the updated Y-axis rotation
		global_transform.basis = Basis.from_euler(Vector3(0, next_y_rot, 0))

	# 3. Handle Animation States
	if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) or Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
		if animation_player.current_animation != "punch":
			animation_player.play("punch")
	
	elif animation_player.current_animation != "punch":
		if speed > 0.5:
			if animation_player.current_animation != "walk":
				animation_player.play("walk")
		else:
			if animation_player.current_animation != "idle":
				animation_player.play("idle")

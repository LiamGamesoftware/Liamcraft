extends MeshInstance3D

@export var rotation_speed: float = 5.0 # Higher values mean less lag

var last_global_pos: Vector3 = Vector3.ZERO
# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	last_global_pos = global_position


func _physics_process(delta: float) -> void:
	# 1. Track movement direction and speed
	var current_global_pos: Vector3 = global_position
	var motion: Vector3 = current_global_pos - last_global_pos
	var distance_moved: float = motion.length()
	var speed: float = distance_moved / maxf(delta, 0.001)
	
	# 2. Smoothly rotate toward the direction of movement
	# Only update rotation if the object actually moved significantly to avoid jitter when stopped
	if distance_moved > 0.001:
		# Flatten the motion vector onto the XZ plane if you want character-style turning (no tilting up/down)
		var direction: Vector3 = motion.normalized()
		
		# Create a target basis facing the direction of movement (using Vector3.UP as the stable up-axis)
		var target_basis: Basis = Basis.looking_at(direction, Vector3.UP)
		var target_rotation: Quaternion = target_basis.get_rotation_quaternion()
		var current_rotation: Quaternion = global_transform.basis.get_rotation_quaternion()
		
		# Apply smooth interpolation
		var weight: float = 1.0 - exp(-rotation_speed * delta)
		var next_rotation: Quaternion = current_rotation.slerp(target_rotation, weight)
		
		global_transform.basis = Basis(next_rotation)

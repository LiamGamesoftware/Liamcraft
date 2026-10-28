extends Node3D

@export var spin_speed: float = 0.1 # Speed of rotation in radians per second

func _process(delta: float) -> void:
	# Rotate around the Y-axis (vertical spin)
	rotate_y(spin_speed * delta)

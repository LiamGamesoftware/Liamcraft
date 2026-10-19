extends Node3D

@onready var animation_player = $AnimationPlayer

# Store the global position from the frame before
var last_global_pos: Vector3 = Vector3.ZERO

func _ready():
	# Initialize with the starting position in the game world
	# Godot 3: use global_transform.origin
	# Godot 4: use global_position
	last_global_pos = global_position 

func _physics_process(delta):
	# 1. Get the current position in the world right now
	var current_global_pos = global_position
	
	# 2. Calculate the distance moved since the very last frame
	var distance_moved = current_global_pos.distance_to(last_global_pos)
	
	# 3. Convert distance to a speed (units per second)
	var speed = distance_moved / delta
	
	# 4. Play animations based on the speed threshold
	# Using 0.05 catches even very slow movements
	if speed > 0.5:
		if animation_player.current_animation != "walk":
			animation_player.play("walk")
	else:
		if animation_player.current_animation != "idle":
			animation_player.play("idle")
			
	# 5. Save the current position to compare against in the next frame
	last_global_pos = current_global_pos

extends Control

@export var speed: float = 300.0 # Speed in pixels per second

# Add this line so the main menu can assign the previous menu node
var prev_menu 

# Store the starting Y position
var start_y: float = 720.0 

func _process(delta: float) -> void:
	if position.y > -500:
		position.y -= speed * delta
		if position.y < -500:
			position.y = -500

func reset_credits() -> void:
	position.y = start_y

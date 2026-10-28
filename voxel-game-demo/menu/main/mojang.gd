extends TextureRect

# Exposes a slider in the Godot Inspector to set the delay time (default: 2.0 seconds)
@export var wait_time: float = 1.0

func _ready() -> void:
	# Start the delayed fade-out process
	fade_out_with_delay(self, wait_time)


func fade_out_with_delay(ui_node: Control, delay: float) -> void:
	var tween = create_tween()
	
	# 1. Wait for the specified number of seconds
	tween.tween_interval(delay)
	
	# 2. Fade out the alpha channel over 1.0 second
	tween.tween_property(ui_node, "modulate:a", 0.0, 1.0)
	
	# 3. Wait for the tween timeline to finish, then hide the node
	await tween.finished
	ui_node.visible = false
	

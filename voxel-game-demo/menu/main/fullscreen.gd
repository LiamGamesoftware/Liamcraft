extends CheckBox

func _ready() -> void:
	# 1. Sync this checkbox's state with the current window mode on load
	var current_mode = DisplayServer.window_get_mode()
	button_pressed = (current_mode == DisplayServer.WINDOW_MODE_FULLSCREEN or current_mode == DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN)
	
	# 2. Connect the built-in toggled signal to this script automatically
	toggled.connect(_on_toggled)

func _on_toggled(toggled_on: bool) -> void:
	if toggled_on:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
	else:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)

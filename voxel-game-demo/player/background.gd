extends TextureRect

func _ready() -> void:
	# 1. Wait for exactly 2 seconds
	await get_tree().create_timer(5.0).timeout
	
	# 2. Hide the TextureRect
	hide()

extends TextureButton

var prev_servmenu


func _on_Back_pressed():
	prev_servmenu.visible = true
	visible = false

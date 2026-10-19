extends HBoxContainer

var prev_menu
@onready var audio_player = $Click
var prev_servmenu: Control
func _on_Back_pressed():
	prev_menu.visible = true
	visible = false
	audio_player.play()

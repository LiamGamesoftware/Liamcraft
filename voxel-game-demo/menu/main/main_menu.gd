extends Control 

@onready var tree = get_tree() 
@onready var title = $TitleScreen 
@onready var start = $StartGame 
@onready var options = $Options 
@onready var multiplayer_serverlist = $Multiplayer # <--- CHANGE THIS to your actual node path
@onready var audio_player = $Click 


func _on_Start_pressed():
	start.visible = true
	title.visible = false
	audio_player.play()

func _on_Options_pressed():
	options.prev_menu = title
	options.visible = true
	title.visible = false
	audio_player.play()

func _on_Exit_pressed():
	tree.quit()
	audio_player.play()

func _on_RandomBlocks_pressed():
	Settings.world_type = 0
	tree.change_scene_to_packed(preload("res://world/world.tscn"))
	audio_player.play()

func _on_FlatGrass_pressed():
	Settings.world_type = 1
	tree.change_scene_to_packed(preload("res://world/world.tscn"))
	audio_player.play()

func _on_earth_pressed() -> void:
	Settings.world_type = 2
	tree.change_scene_to_packed(preload("res://world/world.tscn"))
	audio_player.play()

func _on_BackToTitle_pressed():
	title.visible = true
	start.visible = false
	audio_player.play()
	


func _on_multiplayer_pressed() -> void:
	multiplayer_serverlist.prev_servmenu = title
	multiplayer_serverlist.visible = true
	title.visible = false
	start.visible = false
	audio_player.play()

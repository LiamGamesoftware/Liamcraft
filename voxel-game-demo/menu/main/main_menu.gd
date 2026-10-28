extends Control

@onready var tree = get_tree()

@onready var title = $TitleScreen
@onready var start = $StartGame
@onready var credits = $Credits
@onready var options = $Options
@onready var multiplayer_serverlist = $Multiplayer
@onready var audio_player = $Click

func _ready() -> void:
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)

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
	Net.start_new_world()
	Settings.world_type = 0
	tree.change_scene_to_packed(preload("res://world/world.tscn"))
	audio_player.play()

func _on_FlatGrass_pressed():
	Net.start_new_world()
	Settings.world_type = 1
	tree.change_scene_to_packed(preload("res://world/world.tscn"))
	audio_player.play()

func _on_earth_pressed() -> void:
	Net.start_new_world()
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


func _on_start_3_pressed() -> void:
	title.visible = false
	start.visible = false
	
	# Safe check to run your reset code if the script is recognized
	if credits.has_method("reset_credits"):
		credits.call("reset_credits")
		
	credits.visible = true
	
	# Safely assign the variable without crashing if Godot is being stubborn
	credits.set("prev_menu", title) 
	
	audio_player.play()

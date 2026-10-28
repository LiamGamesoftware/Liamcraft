extends Control

@onready var render_distance_label = $RenderDistanceLabel
@onready var render_distance_slider = $RenderDistanceSlider
@onready var fov_label = $FOV
@onready var fov_slider = $FOVSlide
@onready var fog_checkbox: CheckBox = $FogCheckBox
@onready var audio_player = $"../Clickhere"

func _ready():
	render_distance_slider.value = Settings.render_distance
	render_distance_label.text = "Render distance: " + str(Settings.render_distance)
	fog_checkbox.button_pressed = Settings.fog_enabled


func _on_RenderDistanceSlider_value_changed(value):
	Settings.render_distance = value
	render_distance_label.text = "Render distance: " + str(value)
	Settings.save_settings()

func _on_FogCheckBox_pressed():
	Settings.fog_enabled = fog_checkbox.button_pressed
	Settings.save_settings()
	audio_player.play()


func _on_fov_slide_value_changed(value: float) -> void:
	Settings.FOV = value
	fov_label.text = "FOV: " + str(value)
	Settings.save_settings()


func _on_fullbox_pressed() -> void:
	audio_player.play()

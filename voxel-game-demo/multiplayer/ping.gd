extends TextureRect

# 1. Assign your connection indicator textures in the Godot Inspector
@export var texture_great : Texture2D
@export var texture_good : Texture2D
@export var texture_fair : Texture2D
@export var texture_poor : Texture2D
@export var texture_poorer : Texture2D

# 2. Define your ping thresholds (in milliseconds)
@export var great_threshold : float = 30.0
@export var good_threshold : float = 70.0
@export var fair_threshold : float = 130.0
@export var poor_threshold : float = 200.0

## Call this function whenever you receive an updated ping from your network system
func update_texture_by_ping(ping_ms: float) -> void:
	if ping_ms < 0:
		# Disconnected or invalid ping
		self.texture = texture_poorer 
	elif ping_ms <= great_threshold:
		self.texture = texture_great
	elif ping_ms <= good_threshold:
		self.texture = texture_good
	elif ping_ms <= fair_threshold:
		self.texture = texture_fair
	elif ping_ms <= poor_threshold:
		self.texture = texture_poor
	else:
		# Worst-case latency (> poor_threshold)
		self.texture = texture_poorer

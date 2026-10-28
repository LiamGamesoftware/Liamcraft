extends Node
class_name RadioManager

# The single variable holding all your song AudioStream files
@export var playlist: Array[AudioStream] = []

@onready var audio_player: AudioStreamPlayer = $AudioStreamPlayer

var current_song_index: int = 0
var is_shuffled: bool = false
var playback_order: Array[int] = []

func _ready() -> void:
	# Ensure you have an AudioStreamPlayer node attached
	if not has_node("AudioStreamPlayer"):
		var new_player = AudioStreamPlayer.new()
		add_child(new_player)
		audio_player = new_player
	
	# Connect the finished signal to automatically play the next song
	audio_player.finished.connect(_on_song_finished)
	
	# Initialize the playlist order
	setup_playback()

# Sets up the indexing order for regular or shuffled playback
func setup_playback() -> void:
	playback_order.clear()
	for i in range(playlist.size()):
		playback_order.append(i)
	
	if is_shuffled:
		playback_order.shuffle()
	
	current_song_index = 0

# Plays the song at the current index
func play_current_song() -> void:
	if playlist.is_empty():
		print("Radio Error: The playlist variable is empty!")
		return
		
	var actual_song_index = playback_order[current_song_index]
	audio_player.stream = playlist[actual_song_index]
	audio_player.play()
	print("Radio Playing: ", playlist[actual_song_index].resource_path.get_file())

# Advances to the next song and loops back to the start if finished
func next_song() -> void:
	if playlist.is_empty(): return
	
	current_song_index = (current_song_index + 1) % playlist.size()
	play_current_song()

# Goes back to the previous song
func previous_song() -> void:
	if playlist.is_empty(): return
	
	current_song_index = (current_song_index - 1 + playlist.size()) % playlist.size()
	play_current_song()

# Toggles shuffle mode on or off
func toggle_shuffle(enable: bool) -> void:
	is_shuffled = enable
	setup_playback()
	play_current_song()

# Automatically called by Godot when a song ends
func _on_song_finished() -> void:
	next_song()

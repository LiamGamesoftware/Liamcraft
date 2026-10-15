extends WorldEnvironment
# This script controls fog based on the VoxelWorld's effective render distance.

@onready var voxel_world = $"../VoxelWorld"


func _process(delta):
	environment.ambient_light_color

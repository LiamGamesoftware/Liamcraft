extends Camera3D

@onready var camera_one = self
@onready var camera_two = $head/SpringArm3D/Camera3D

func _ready() -> void:
	camera_one.current = true

func _input(event: InputEvent) -> void:
	if event.is_action_pressed("switch_camera"):
		if camera_one.current:
			camera_two.make_current()
		else:
			camera_one.make_current()

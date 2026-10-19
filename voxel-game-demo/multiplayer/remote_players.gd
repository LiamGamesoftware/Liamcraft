class_name RemotePlayers
extends Node3D
# Shows the other players as simple blocky avatars and sends the local player's position
# to everyone else. Also shows short on-screen messages for multiplayer events.
# VoxelWorld creates this node in code and assigns `local_player`.

const SEND_INTERVAL := 0.05    # 20 updates per second
const SMOOTHING := 14.0        # higher = avatars follow the network updates more tightly

# Distance from the Player node's origin down to the floor. -0.9 fits a 1.8 m tall
# capsule whose origin is its centre; use 0.0 if your Player origin is at the feet.
const PLAYER_ORIGIN_TO_FEET := -0.9

var local_player: Node3D

var _avatars: Dictionary = {}   # peer id -> avatar Node3D
var _send_timer := 0.0
var _toast: Label
var _toast_tween: Tween


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_toast()
	Net.status_changed.connect(_show_toast)
	Net.host_failed.connect(_show_toast)
	Net.player_joined.connect(func(_id: int, player_name: String) -> void: _show_toast("%s joined the game" % player_name))
	Net.player_left.connect(_on_player_left)


func _process(delta: float) -> void:
	if not Net.is_online():
		if not _avatars.is_empty():
			_clear_avatars()
		return

	_send_timer += delta
	if _send_timer >= SEND_INTERVAL:
		_send_timer = 0.0
		_send_local_state()

	_sync_avatars(delta)


func _send_local_state() -> void:
	if local_player == null or not is_instance_valid(local_player):
		return
	var yaw := local_player.global_rotation.y
	var pitch := 0.0
	var camera := get_viewport().get_camera_3d()
	if camera != null:
		yaw = camera.global_rotation.y
		pitch = camera.global_rotation.x
	Net.send_local_state(local_player.global_position, yaw, pitch)


func _sync_avatars(delta: float) -> void:
	for id in _avatars.keys():
		if not Net.remote_states.has(id):
			_avatars[id].queue_free()
			_avatars.erase(id)

	var blend := 1.0 - exp(-SMOOTHING * delta)
	for id in Net.remote_states:
		var state: Dictionary = Net.remote_states[id]
		var target: Vector3 = state["pos"] + Vector3(0.0, PLAYER_ORIGIN_TO_FEET, 0.0)
		var avatar: Node3D = _avatars.get(id)
		if avatar == null:
			avatar = _make_avatar(id)
			avatar.position = target
			avatar.rotation.y = state["yaw"]
			_avatars[id] = avatar
			add_child(avatar)
		avatar.position = avatar.position.lerp(target, blend)
		avatar.rotation.y = lerp_angle(avatar.rotation.y, state["yaw"], blend)
		var head: Node3D = avatar.get_meta("head")
		head.rotation.x = lerp_angle(head.rotation.x, state["pitch"], blend)
		var tag: Label3D = avatar.get_meta("tag")
		var wanted: String = Net.player_names.get(id, "Player")
		if tag.text != wanted:
			tag.text = wanted


func _on_player_left(id: int) -> void:
	var left_name: String = Net.player_names.get(id, "A player")
	_show_toast("%s left the game" % left_name)


func _clear_avatars() -> void:
	for avatar in _avatars.values():
		avatar.queue_free()
	_avatars.clear()


# Blocky humanoid, about 1.8 blocks tall, origin at the feet, facing -Z.
func _make_avatar(peer_id: int) -> Node3D:
	var root := Node3D.new()
	root.name = "Peer%d" % peer_id

	var shirt := Color.from_hsv(fmod(float(peer_id) * 0.618, 1.0), 0.6, 0.85)
	var skin_mat := _unshaded(Color(0.86, 0.68, 0.55))
	var shirt_mat := _unshaded(shirt)
	var pants_mat := _unshaded(Color(0.22, 0.25, 0.5))
	var eye_mat := _unshaded(Color(0.1, 0.1, 0.15))

	_add_box(root, Vector3(0.25, 0.65, 0.25), Vector3(-0.125, 0.325, 0.0), pants_mat)
	_add_box(root, Vector3(0.25, 0.65, 0.25), Vector3(0.125, 0.325, 0.0), pants_mat)
	_add_box(root, Vector3(0.5, 0.65, 0.25), Vector3(0.0, 0.975, 0.0), shirt_mat)
	_add_box(root, Vector3(0.25, 0.65, 0.25), Vector3(-0.375, 0.975, 0.0), skin_mat)
	_add_box(root, Vector3(0.25, 0.65, 0.25), Vector3(0.375, 0.975, 0.0), skin_mat)

	# The head sits on a pivot at the neck so it can pitch up and down.
	var head := Node3D.new()
	head.position = Vector3(0.0, 1.3, 0.0)
	root.add_child(head)
	_add_box(head, Vector3(0.5, 0.5, 0.5), Vector3(0.0, 0.25, 0.0), skin_mat)
	_add_box(head, Vector3(0.1, 0.1, 0.02), Vector3(-0.12, 0.28, -0.255), eye_mat)
	_add_box(head, Vector3(0.1, 0.1, 0.02), Vector3(0.12, 0.28, -0.255), eye_mat)
	root.set_meta("head", head)

	var tag := Label3D.new()
	tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	tag.pixel_size = 0.006
	tag.font_size = 48
	tag.outline_size = 12
	tag.no_depth_test = true
	tag.position = Vector3(0.0, 2.15, 0.0)
	root.add_child(tag)
	root.set_meta("tag", tag)
	return root


func _unshaded(color: Color) -> StandardMaterial3D:
	# The world is lit by baked vertex lighting, not scene lights, so avatars are unshaded.
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	return material


func _add_box(parent: Node3D, size: Vector3, pos: Vector3, material: Material) -> void:
	var mesh_instance := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	mesh_instance.mesh = box
	mesh_instance.material_override = material
	mesh_instance.position = pos
	parent.add_child(mesh_instance)


# ---------------------------------------------------------------- on-screen messages

func _build_toast() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 50
	add_child(layer)
	_toast = Label.new()
	_toast.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	_toast.offset_top = 16.0
	_toast.offset_bottom = 48.0
	_toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toast.add_theme_color_override("font_outline_color", Color.BLACK)
	_toast.add_theme_constant_override("outline_size", 6)
	_toast.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_toast.modulate.a = 0.0
	layer.add_child(_toast)


func _show_toast(text: String) -> void:
	if _toast == null:
		return
	_toast.text = text
	_toast.modulate.a = 1.0
	if _toast_tween != null:
		_toast_tween.kill()
	_toast_tween = create_tween()
	_toast_tween.tween_interval(5.0)
	_toast_tween.tween_property(_toast, "modulate:a", 0.0, 1.0)

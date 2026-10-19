extends Node

@export var player_camera: Camera3D
@export var gui: CanvasItem
@export var hand: Node3D

@export var face_resolution: int = 1024

var capturing := false

func _input(event: InputEvent) -> void:
	if event is InputEventKey:
		if event.pressed and not event.echo and event.keycode == KEY_F4:
			if not capturing:
				capture_panorama()


func capture_panorama() -> void:
	if capturing:
		return

	if player_camera == null:
		player_camera = get_viewport().get_camera_3d()

	if player_camera == null:
		push_error("No active camera found!")
		return

	capturing = true

	var original_camera := player_camera
	var original_transform := original_camera.global_transform
	var original_fov := original_camera.fov
	var original_current := original_camera.current
	var gui_was_visible := gui.visible if gui != null else false
	var hand_was_visible := hand.visible if hand != null else false

	# Hide interface and hand.
	if gui != null:
		gui.hide()
	if hand != null:
		hand.hide()


	var capture_viewport := SubViewport.new()
	capture_viewport.size = Vector2i(face_resolution, face_resolution)
	capture_viewport.transparent_bg = false
	capture_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	capture_viewport.world_3d = original_camera.get_viewport().world_3d
	add_child(capture_viewport)

	var capture_camera := Camera3D.new()
	capture_camera.fov = 90.0
	capture_camera.near = original_camera.near
	capture_camera.far = original_camera.far
	capture_viewport.add_child(capture_camera)

	var faces: Array[Image] = []
	var directions: Array[Vector3] = [
		Vector3.RIGHT,
		Vector3.LEFT,
		Vector3.UP,
		Vector3.DOWN,
		Vector3.BACK,
		Vector3.FORWARD
	]

	var up_vectors: Array[Vector3] = [
		Vector3.UP,
		Vector3.UP,
		Vector3.BACK,
		Vector3.FORWARD,
		Vector3.UP,
		Vector3.UP
	]

	for i in range(6):
		capture_camera.global_transform = Transform3D(
			Basis.looking_at(directions[i], up_vectors[i]),
			original_transform.origin
		)

		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw

		var face := capture_viewport.get_texture().get_image()
		faces.append(face)

	# Convert cube faces to a 2:1 equirectangular panorama.
	var pano_width := face_resolution * 4
	var pano_height := face_resolution * 2
	var panorama := Image.create(
		pano_width,
		pano_height,
		false,
		Image.FORMAT_RGBAF
	)

	for y in range(pano_height):
		var latitude := (0.5 - float(y) / pano_height) * PI

		for x in range(pano_width):
			var longitude := (float(x) / pano_width - 0.5) * TAU

			var direction := Vector3(
				cos(latitude) * sin(longitude),
				sin(latitude),
				cos(latitude) * cos(longitude)
			).normalized()

			var ax := absf(direction.x)
			var ay := absf(direction.y)
			var az := absf(direction.z)

			var face_index := 0
			var u := 0.0
			var v := 0.0

			if ay >= ax and ay >= az:
				if direction.y > 0.0:
					face_index = 2
					u = direction.x / ay
					v = direction.z / ay
				else:
					face_index = 3
					u = direction.x / ay
					v = -direction.z / ay
			elif ax >= az:
				if direction.x > 0.0:
					face_index = 0
					u = -direction.z / ax
					v = -direction.y / ax
				else:
					face_index = 1
					u = direction.z / ax
					v = -direction.y / ax
			else:
				if direction.z > 0.0:
					face_index = 4
					u = direction.x / az
					v = -direction.y / az
				else:
					face_index = 5
					u = -direction.x / az
					v = -direction.y / az

			var px := clampi(
				int((u + 1.0) * 0.5 * face_resolution),
				0, face_resolution - 1
			)
			var py := clampi(
				int((v + 1.0) * 0.5 * face_resolution),
				0, face_resolution - 1
			)

			panorama.set_pixel(
				x, y, faces[face_index].get_pixel(px, py)
			)

	var save_path := OS.get_system_dir(
		OS.SYSTEM_DIR_DOWNLOADS
	).path_join("PlayerPanorama.exr")

	var error := panorama.save_exr(save_path, false)

	if error == OK:
		print("360 panorama saved: ", save_path)
	else:
		push_error("Failed to save panorama. Error: %s" % error)

	# Wait one second after capture before restoring everything.
	await get_tree().create_timer(1.0).timeout

	capture_viewport.queue_free()

	if is_instance_valid(original_camera):
		original_camera.global_transform = original_transform
		original_camera.fov = original_fov
		original_camera.current = original_current

	if gui != null:
		gui.visible = gui_was_visible
	if hand != null:
		hand.visible = hand_was_visible

	capturing = false

extends Label
# Minecraft-style F3 Debug Overlay with perfectly aligned individual line highlights

@onready var player = $"../Player" 
@onready var voxel_world = $"../VoxelWorld"
@onready var player_camera = $"../Player/Head/Camera3D" 
@onready var raycast = $"../Player/RayCast3D"            

# Store text in an internal variable instead of the Label's property
var debug_text: String = ""

func _ready():
	visible = false
	
	# Hide default label text rendering entirely
	add_theme_stylebox_override(&"normal", StyleBoxEmpty.new())
	text = "" 
	
	# Explicitly set our text size
	add_theme_font_size_override(&"font_size", 12)

func _process(_delta):
	if Input.is_action_just_pressed(&"debug"):
		visible = not visible
		if $"../XYZGizmoContainer":
			$"../XYZGizmoContainer".visible = visible
		
	if not visible:
		return

	var pos = player.global_transform.origin
	var rot = player.global_transform.basis.get_euler()
	
	var f3_text = "Godot Voxel Game (1.0.0/development)\n"
	f3_text += "FPS: " + str(Engine.get_frames_per_second()) + " T: " + str(Engine.max_fps) + "\n"
	f3_text += "Mem: " + "%3.0f" % (OS.get_static_memory_usage() / 1048576.0) + "MB\n\n"
	f3_text += "XYZ: " + "%.3f / %.5f / %.3f" % [pos.x, pos.y, pos.z] + "\n"
	
	var bx = int(floor(pos.x))
	var by = int(floor(pos.y))
	var bz = int(floor(pos.z))
	f3_text += "Block: %d %d %d\n" % [bx, by, bz]
	
	var cx = bx >> 4
	var cy = by >> 4
	var cz = bz >> 4
	f3_text += "Chunk: %d %d %d in %d %d %d\n" % [bx & 15, by & 15, bz & 15, cx, cy, cz]
	
	var facing = _get_minecraft_facing(rot.y)
	var yaw_deg = rad_to_deg(rot.y)
	var pitch_deg = rad_to_deg(rot.x)
	f3_text += "Facing: %s (Towards %s) (%.1f / %.1f)\n" % [facing.dir, facing.axis, yaw_deg, pitch_deg]
	f3_text += "Client Render Distance: " + str(voxel_world.effective_render_distance) + "\n"
	
	var target_info = _get_targeted_block_string()
	if target_info != "":
		f3_text += "\n" + target_info

	debug_text = f3_text
	queue_redraw()

func _draw():
	if debug_text.is_empty():
		return

	var font = get_theme_font(&"font")
	var font_size = get_theme_font_size(&"font_size")
	var font_color = get_theme_color(&"font_color")
	
	# Fetch accurate font metrics
	var ascent = font.get_ascent(font_size)
	var line_height = font.get_height(font_size) + 2 # Minor spacing buffer
	
	var lines = debug_text.split("\n")
	var bg_color = Color(0, 0, 0, 0.5)
	var padding_x = 4 

	for i in range(lines.size()):
		var line_text = lines[i]
		
		if line_text.strip_edges().is_empty():
			continue
			
		var text_width = font.get_string_size(line_text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
		var rect_y = i * line_height
		
		# Draw the background slice
		var rect = Rect2(
			0, 
			rect_y, 
			text_width + (padding_x * 2), 
			line_height
		)
		draw_rect(rect, bg_color)
		
		# Draw the text perfectly centered vertically inside its background slice
		var text_pos = Vector2(padding_x, rect_y + ascent)
		draw_string(font, text_pos, line_text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, font_color)

func _get_minecraft_facing(angle_rad: float) -> Dictionary:
	var angle_deg = fmod(rad_to_deg(angle_rad), 360.0)
	if angle_deg < 0:
		angle_deg += 360.0
		
	if angle_deg >= 315 or angle_deg < 45:
		return {"dir": "south", "axis": "towards positive Z"}
	elif angle_deg >= 45 and angle_deg < 135:
		return {"dir": "west", "axis": "towards negative X"}
	elif angle_deg >= 135 and angle_deg < 225:
		return {"dir": "north", "axis": "towards negative Z"}
	else:
		return {"dir": "east", "axis": "towards positive X"}

func _get_targeted_block_string() -> String:
	if raycast and raycast.is_colliding():
		var pt = raycast.get_collision_point() - (raycast.get_collision_normal() * 0.1)
		return "Block at: %d, %d, %d" % [floor(pt.x), floor(pt.y), floor(pt.z)]
	return ""

extends Control
# Multiplayer screen: server list, lobby address and "host a world".
# The whole UI is built in code, so the scene only needs a plain Control node with this
# script attached (see SETUP.md). It inherits the Theme of its parent, so it picks up
# your menu's look if the main menu root has a Theme assigned.
#
# The server list comes from the lobby server (lobby_server.js): every world someone has
# opened shows up here within a moment.

# Set by main_menu.gd before the screen is shown (same as your Options screen).
var prev_servmenu: Control

var _name_edit: LineEdit
var _server_list: ItemList
var _server_keys: Array = []
var _empty_hint: Label
var _join_button: Button
var _url_edit: LineEdit
var _reconnect_button: Button
var _world_name_edit: LineEdit
var _world_type_option: OptionButton
var _host_button: Button
var _status: Label
var _busy := false


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	visible = false
	_build_ui()
	visibility_changed.connect(_on_visibility_changed)
	Net.lobby.servers_changed.connect(_refresh_server_list)
	Net.lobby.connected.connect(_on_lobby_connected)
	Net.lobby.connection_closed.connect(_on_lobby_closed)
	Net.join_failed.connect(_on_join_failed)
	Net.host_ready.connect(_on_host_ready)
	Net.host_failed.connect(_on_host_failed)


func _exit_tree() -> void:
	if not Net.lobby_needed():
		Net.lobby.close_lobby()


func _build_ui() -> void:
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.6)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(620, 0)
	center.add_child(panel)

	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 16)
	panel.add_child(margin)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	margin.add_child(box)

	var title := Label.new()
	title.text = "Multiplayer"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 26)
	box.add_child(title)

	# Player name
	var name_row := HBoxContainer.new()
	box.add_child(name_row)
	name_row.add_child(_make_label("Your name:"))
	_name_edit = LineEdit.new()
	_name_edit.text = Net.player_name
	_name_edit.max_length = 16
	_name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_name_edit.text_changed.connect(func(text: String) -> void: Net.player_name = text.strip_edges())
	name_row.add_child(_name_edit)

	# Lobby server address
	var url_row := HBoxContainer.new()
	box.add_child(url_row)
	url_row.add_child(_make_label("Lobby server:"))
	_url_edit = LineEdit.new()
	_url_edit.text = Net.lobby_url
	_url_edit.placeholder_text = "ws://192.168.1.20:8080"
	_url_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_url_edit.text_submitted.connect(func(_text: String) -> void: _on_reconnect_pressed())
	url_row.add_child(_url_edit)
	_reconnect_button = Button.new()
	_reconnect_button.text = "Reconnect"
	_reconnect_button.pressed.connect(_on_reconnect_pressed)
	url_row.add_child(_reconnect_button)

	box.add_child(HSeparator.new())

	# Server list
	box.add_child(_make_label("Open worlds:"))
	_server_list = ItemList.new()
	_server_list.custom_minimum_size = Vector2(0, 170)
	_server_list.item_selected.connect(func(_index: int) -> void: _update_buttons())
	_server_list.item_activated.connect(func(_index: int) -> void: _on_join_pressed())
	box.add_child(_server_list)

	_empty_hint = _make_label("No worlds yet. Ask a friend to open theirs (or host one below).")
	_empty_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_empty_hint)

	_join_button = Button.new()
	_join_button.text = "Join Selected World"
	_join_button.disabled = true
	_join_button.pressed.connect(_on_join_pressed)
	box.add_child(_join_button)

	box.add_child(HSeparator.new())

	# Host
	box.add_child(_make_label("Host a new world:"))
	var host_row := HBoxContainer.new()
	box.add_child(host_row)
	_world_name_edit = LineEdit.new()
	_world_name_edit.text = "My World"
	_world_name_edit.max_length = 32
	_world_name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	host_row.add_child(_world_name_edit)
	_world_type_option = OptionButton.new()
	_world_type_option.add_item("Random Blocks", 0)
	_world_type_option.add_item("Flat Grass", 1)
	_world_type_option.add_item("Earth", 2)
	_world_type_option.select(2)
	host_row.add_child(_world_type_option)
	_host_button = Button.new()
	_host_button.text = "Host World"
	_host_button.pressed.connect(_on_host_pressed)
	host_row.add_child(_host_button)

	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.custom_minimum_size = Vector2(580, 0)
	box.add_child(_status)

	var back := Button.new()
	back.text = "Back"
	back.pressed.connect(_on_back_pressed)
	box.add_child(back)


func _make_label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	return label


# ---------------------------------------------------------------- behaviour

func _on_visibility_changed() -> void:
	if is_visible_in_tree():
		_busy = false
		var notice := Net.pending_notice
		Net.pending_notice = ""
		_url_edit.text = Net.lobby_url
		_connect_lobby()
		if not notice.is_empty():
			_set_status(notice)
	else:
		if not Net.lobby_needed():
			Net.lobby.close_lobby()


func _connect_lobby() -> void:
	Net.lobby_url = _url_edit.text.strip_edges()
	var err := Net.lobby.connect_to_lobby(Net.lobby_url)
	if err != OK:
		_set_status("That lobby address is not valid. It should look like ws://192.168.1.20:8080")
	elif Net.lobby.is_open():
		_set_status("Connected to the lobby.")
	else:
		_set_status("Connecting to the lobby...")
	_refresh_server_list()


func _on_reconnect_pressed() -> void:
	Net.lobby.close_lobby()
	_busy = false
	_connect_lobby()


func _on_lobby_connected() -> void:
	_set_status("Connected to the lobby. Worlds appear below as soon as someone opens one.")
	_update_buttons()


func _on_lobby_closed(reason: String) -> void:
	_busy = false
	_set_status(reason + " Check the lobby address above, then press Reconnect.")
	_refresh_server_list()


func _refresh_server_list() -> void:
	var previous := ""
	var selected := _server_list.get_selected_items()
	if not selected.is_empty() and selected[0] < _server_keys.size():
		previous = _server_keys[selected[0]]

	_server_list.clear()
	_server_keys.clear()
	for key in Net.lobby.servers:
		var server: Dictionary = Net.lobby.servers[key]
		var text := "%s  -  hosted by %s  (%d/%d)" % [server["name"], server["host"], server["players"], server["max"]]
		if server["protocol"] != Net.PROTOCOL_VERSION:
			text += "  (different game version)"
		elif server["players"] >= server["max"]:
			text += "  (full)"
		var index := _server_list.add_item(text)
		_server_keys.append(key)
		if key == previous:
			_server_list.select(index)

	_empty_hint.visible = _server_keys.is_empty() and Net.lobby.is_open()
	_update_buttons()


func _update_buttons() -> void:
	var online := Net.lobby.is_open()
	_join_button.disabled = _busy or not online or _server_list.get_selected_items().is_empty()
	_host_button.disabled = _busy or not online
	_reconnect_button.disabled = _busy


func _on_join_pressed() -> void:
	var selected := _server_list.get_selected_items()
	if selected.is_empty() or _busy:
		return
	var server: Dictionary = Net.lobby.servers.get(_server_keys[selected[0]], {})
	if server.is_empty():
		_set_status("That world is no longer available.")
		return
	if server["protocol"] != Net.PROTOCOL_VERSION:
		_set_status("That world runs a different version of the game.")
		return
	_busy = true
	_update_buttons()
	_set_status("Joining %s ..." % server["name"])
	Net.join_game(server["room"])
	# On success Net switches to the world scene as soon as the host answers.


func _on_join_failed(reason: String) -> void:
	_busy = false
	_set_status(reason)
	_update_buttons()


func _on_host_pressed() -> void:
	if _busy:
		return
	_busy = true
	_update_buttons()
	_set_status("Opening your world...")
	Net.start_new_world()
	Settings.world_type = _world_type_option.get_selected_id()
	Net.open_world(_world_name_edit.text)


func _on_host_ready() -> void:
	if is_visible_in_tree():
		get_tree().change_scene_to_file(Net.WORLD_SCENE)


func _on_host_failed(reason: String) -> void:
	_busy = false
	_set_status(reason)
	_update_buttons()


func _on_back_pressed() -> void:
	visible = false
	if prev_servmenu != null:
		prev_servmenu.visible = true


func _set_status(text: String) -> void:
	_status.text = text

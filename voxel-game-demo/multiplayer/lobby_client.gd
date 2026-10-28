class_name LobbyClient
extends Node
# Talks to lobby_server.js over a WebSocket. This is what makes the server list work in a
# browser: the server tells us which worlds are open, hands out player ids and relays the
# WebRTC handshake. Net owns the one instance (Net.lobby).
#
# Typical use (Net does all of this for you):
#   lobby.connect_to_lobby("ws://192.168.1.20:8080")
#   lobby.servers            -> room code -> {room, name, host, players, max, world_type, protocol}
#   lobby.host_room(info)    -> hosted(room_id) or host_failed(reason)
#   lobby.join_room(code, v) -> joined(my_peer_id) or join_failed(reason)

signal connected
# Emitted when the connection could not be made, or was lost. Not emitted by close_lobby().
signal connection_closed(reason: String)
signal servers_changed
signal hosted(room_id: String)
signal host_failed(reason: String)
signal joined(peer_id: int)
signal join_failed(reason: String)
signal peer_joined(peer_id: int)      # host only: a player wants to join
signal peer_left(peer_id: int)        # host only: a player left the lobby
signal room_closed                    # joiner only: the host closed the world
signal signal_received(from_id: int, data: Dictionary)

const CONNECT_TIMEOUT_MSEC := 8000

var servers: Dictionary = {}
var url := ""

var _ws: WebSocketPeer
var _was_open := false
var _started_msec := 0


func is_open() -> bool:
	return _ws != null and _ws.get_ready_state() == WebSocketPeer.STATE_OPEN


func is_connecting() -> bool:
	return _ws != null and not _was_open


# Safe to call repeatedly: does nothing when already open/connecting to the same address.
func connect_to_lobby(p_url: String) -> Error:
	p_url = p_url.strip_edges()
	if _ws != null:
		if p_url == url:
			return OK
		close_lobby()
	var ws := WebSocketPeer.new()
	var err := ws.connect_to_url(p_url)
	if err != OK:
		return err
	_ws = ws
	url = p_url
	_was_open = false
	_started_msec = Time.get_ticks_msec()
	return OK


# Closes the connection on purpose (no connection_closed signal).
func close_lobby() -> void:
	if _ws != null:
		_ws.close()
	_ws = null
	_was_open = false
	if not servers.is_empty():
		servers.clear()
		servers_changed.emit()


func host_room(info: Dictionary) -> void:
	var message := info.duplicate()
	message["type"] = "host"
	_send(message)


func update_room(info: Dictionary) -> void:
	var message := info.duplicate()
	message["type"] = "update"
	_send(message)


func join_room(room_id: String, protocol: int) -> void:
	_send({"type": "join", "room": room_id, "protocol": protocol})


func leave_room() -> void:
	_send({"type": "leave"})


func send_signal(to_id: int, data: Dictionary) -> void:
	var message := data.duplicate()
	message["type"] = "signal"
	message["to"] = to_id
	_send(message)


func _send(message: Dictionary) -> void:
	if is_open():
		_ws.send_text(JSON.stringify(message))


func _process(_delta: float) -> void:
	if _ws == null:
		return
	_ws.poll()
	match _ws.get_ready_state():
		WebSocketPeer.STATE_CONNECTING:
			if Time.get_ticks_msec() - _started_msec > CONNECT_TIMEOUT_MSEC:
				_ws.close()
				_connection_lost()
		WebSocketPeer.STATE_OPEN:
			if not _was_open:
				_was_open = true
				connected.emit()
			# A handler may call close_lobby(), which clears _ws.
			while _ws != null and _ws.get_available_packet_count() > 0:
				_handle_packet(_ws.get_packet())
		WebSocketPeer.STATE_CLOSED:
			_connection_lost()


func _connection_lost() -> void:
	var was_open := _was_open
	var failed_url := url
	_ws = null
	_was_open = false
	servers.clear()
	servers_changed.emit()
	if was_open:
		connection_closed.emit("Lost the connection to the lobby server.")
	else:
		connection_closed.emit("Could not reach the lobby server at %s.%s" % [failed_url, _https_hint(failed_url)])


# A page loaded over https may only open wss:// connections. Browsers block plain ws://.
func _https_hint(failed_url: String) -> String:
	if OS.has_feature("web") and failed_url.begins_with("ws://") and bool(JavaScriptBridge.eval("window.location.protocol === 'https:'", true)):
		return " This page is https, so the lobby address must start with wss://."
	return ""


func _handle_packet(raw: PackedByteArray) -> void:
	var parsed = JSON.parse_string(raw.get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	var message: Dictionary = parsed
	match str(message.get("type", "")):
		"rooms":
			_set_rooms(message.get("rooms", []))
		"hosted":
			hosted.emit(str(message.get("room", "")))
		"host_failed":
			host_failed.emit(str(message.get("reason", "The lobby refused to open the world.")))
		"joined":
			joined.emit(int(message.get("id", 0)))
		"join_failed":
			join_failed.emit(str(message.get("reason", "Could not join that world.")))
		"peer_joined":
			peer_joined.emit(int(message.get("id", 0)))
		"peer_left":
			peer_left.emit(int(message.get("id", 0)))
		"room_closed":
			room_closed.emit()
		"signal":
			signal_received.emit(int(message.get("from", 0)), message)


func _set_rooms(list) -> void:
	servers.clear()
	if typeof(list) == TYPE_ARRAY:
		for item in list:
			if typeof(item) != TYPE_DICTIONARY:
				continue
			var code := str(item.get("room", ""))
			if code.is_empty():
				continue
			servers[code] = {
				"room": code,
				"name": str(item.get("name", "World")).left(40),
				"host": str(item.get("host", "?")).left(16),
				"players": int(item.get("players", 1)),
				"max": int(item.get("max", 8)),
				"world_type": int(item.get("world_type", 0)),
				"protocol": int(item.get("protocol", 0)),
			}
	servers_changed.emit()

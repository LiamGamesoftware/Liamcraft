extends Node
# AUTOLOAD: add this script in Project Settings > Globals > Autoload with the name "Net".
# Do NOT give it a class_name (it would clash with the autoload name).
#
# WEB VERSION. Browsers cannot use UDP/ENet, so players are connected with WebRTC:
#   - lobby_server.js (a small Node program) keeps the server list and relays the WebRTC
#     handshake. LobbyClient (lobby_client.gd) is our WebSocket connection to it.
#   - Once the handshake is done, the host and each joiner talk directly to each other
#     through WebRTC data channels, and Godot's normal RPCs run on top of that.
#
# Topology: host-authoritative star. The host (peer id 1) is also a player.
#   - Clients send block edits and their position to the host.
#   - The host relays them to every other client and keeps the full edit log,
#     so late joiners get the same world.
# Terrain itself is NOT sent: every machine generates it from the same seed + world type.

signal status_changed(text: String)
signal host_ready                       # the world is open and listed in the server list
signal host_failed(reason: String)
signal join_failed(reason: String)
signal player_joined(peer_id: int, player_name: String)
signal player_left(peer_id: int)
# Emitted on the host when a client edits a block, and on clients when the host relays one.
signal block_edit_received(block_pos: Vector3i, block_id: int)

const MAX_PLAYERS := 8                  # including the host
const PROTOCOL_VERSION := 2             # bump when the network messages change
const CONNECT_TIMEOUT_SEC := 20.0       # WebRTC can take a while to find a route
const EDIT_BATCH_INTS := 8000           # block edits per message (4 ints each), keeps messages small

# Adjust these two paths to match your project.
const WORLD_SCENE := "res://world/world.tscn"
const MENU_SCENE := "res://menu/main/main_menu.tscn"

# Where the lobby server is. Leave empty to auto-detect: when the game page is served by
# lobby_server.js the lobby is simply the same address. If the page lives somewhere else
# (itch.io, your own site), put the lobby address here, e.g. "wss://my-lobby.example.com".
const LOBBY_URL_OVERRIDE := ""
const LOCAL_LOBBY_URL := "ws://127.0.0.1:8080"

# STUN lets players behind different routers find each other. On a pure LAN it is not
# needed and being unreachable is harmless. Tests set this to [].
var ice_servers: Array = [{"urls": ["stun:stun.l.google.com:19302"]}]

var lobby
var lobby_url := ""

var player_name := "Player"
var world_name := ""
# VoxelWorld keeps this and TerrainGenerator.world_seed identical (see _sync_world_seed there).
var world_seed := 0

var is_host := false
var is_client := false

# peer_id -> {"pos": Vector3, "yaw": float, "pitch": float}   (other players only)
var remote_states: Dictionary = {}
# peer_id -> String   (includes the host as 1)
var player_names: Dictionary = {}
# Every block edit made this session, so chunks that are unloaded and regenerated
# (and players who join later) get them back.
# chunk position (Vector3i) -> { block position (Vector3i) -> block id (int) }
var edits: Dictionary = {}
# Text the menu shows once after something went wrong or the host closed the world.
var pending_notice := ""

var _rtc: WebRTCMultiplayerPeer
var _conns: Dictionary = {}             # peer id -> WebRTCPeerConnection
var _room_id := ""
var _host_requested := false            # waiting for the lobby to confirm "host"
var _join_requested := false            # waiting for the lobby to confirm "join"
var _connecting := false                # WebRTC handshake with the host in progress
var _attempt := 0
var _initial_edits := PackedInt32Array()
var _world_live := false                # VoxelWorld is up and listening for edits


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS   # keep networking alive while the game is paused
	randomize()
	world_seed = randi()
	player_name = _default_player_name()
	lobby_url = default_lobby_url()

	var lobby_script = load("res://multiplayer/lobby_client.gd")
	if lobby_script == null:
		push_error("Could not load res://multiplayer/lobby_client.gd")
		return
	lobby = lobby_script.new()
	lobby.name = "LobbyClient"
	add_child(lobby)
	lobby.connected.connect(_on_lobby_connected)
	lobby.connection_closed.connect(_on_lobby_closed)
	lobby.hosted.connect(_on_lobby_hosted)
	lobby.host_failed.connect(_on_lobby_host_failed)
	lobby.joined.connect(_on_lobby_joined)
	lobby.join_failed.connect(_on_lobby_join_failed)
	lobby.peer_joined.connect(_on_lobby_peer_joined)
	lobby.peer_left.connect(_on_lobby_peer_left)
	lobby.signal_received.connect(_on_lobby_signal)

	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)


static func default_lobby_url() -> String:
	if not LOBBY_URL_OVERRIDE.is_empty():
		return LOBBY_URL_OVERRIDE
	if OS.has_feature("web"):
		var host := str(JavaScriptBridge.eval("window.location.host", true))
		var secure := bool(JavaScriptBridge.eval("window.location.protocol === 'https:'", true))
		if not host.is_empty():
			return ("wss://" if secure else "ws://") + host
	return LOCAL_LOBBY_URL


func is_online() -> bool:
	return is_host or is_client


# True while the lobby connection is still needed (the menu closes it otherwise).
func lobby_needed() -> bool:
	return is_host or is_client or _host_requested or _join_requested or _connecting


# Call before starting any NEW world (menu start buttons, hosting from the menu).
func start_new_world() -> void:
	edits.clear()
	remote_states.clear()
	world_seed = randi()


# ---------------------------------------------------------------- hosting

# Opens the current world to other players: connects to the lobby (if needed), lists the
# world in the server list and starts accepting joiners. Does not change scenes, so it also
# works in the middle of a game. The result arrives as host_ready or host_failed.
func open_world(p_world_name := "") -> void:
	if is_online() or _host_requested or _join_requested:
		host_failed.emit("You are already in a multiplayer session.")
		return
	world_name = p_world_name.strip_edges()
	if world_name.is_empty():
		world_name = "%s's World" % player_name
	_host_requested = true
	if lobby.is_open():
		_send_host_request()
		return
	var err: int = lobby.connect_to_lobby(lobby_url)
	if err != OK:
		_host_requested = false
		host_failed.emit("Could not start the lobby connection (error %d). Check the lobby address." % err)


func _send_host_request() -> void:
	lobby.host_room(_room_info())


func _on_lobby_connected() -> void:
	if _host_requested:
		_send_host_request()


func _on_lobby_hosted(room_id: String) -> void:
	if not _host_requested:
		return
	_host_requested = false
	_rtc = WebRTCMultiplayerPeer.new()
	var err: int = _rtc.create_server()
	if err != OK:
		_rtc = null
		lobby.leave_room()
		host_failed.emit("Could not start the WebRTC server (error %d)." % err)
		return
	multiplayer.multiplayer_peer = _rtc
	_room_id = room_id
	is_host = true
	player_names = {1: player_name}
	remote_states.clear()
	status_changed.emit("World opened. Others can join it from the server list.")
	host_ready.emit()


func _on_lobby_host_failed(reason: String) -> void:
	_host_requested = false
	host_failed.emit(reason)


# A player picked our world in the server list: get ready for their offer.
func _on_lobby_peer_joined(id: int) -> void:
	if not is_host or id < 2:
		return
	_make_connection(id)


# The lobby socket of a player closed. Players that are already connected keep playing;
# only handshakes that never finished are cleaned up.
func _on_lobby_peer_left(id: int) -> void:
	if not is_host or _rtc == null:
		return
	if _conns.has(id) and not multiplayer.get_peers().has(id):
		_rtc.remove_peer(id)
		_conns.erase(id)


# ---------------------------------------------------------------- joining

# room_id is the key of an entry in lobby.servers. The lobby must be connected.
func join_game(room_id: String) -> void:
	if is_online() or _host_requested or _join_requested:
		join_failed.emit("You are already in a multiplayer session.")
		return
	if not lobby.is_open():
		join_failed.emit("Not connected to the lobby server.")
		return
	_join_requested = true
	lobby.join_room(room_id, PROTOCOL_VERSION)


func _on_lobby_join_failed(reason: String) -> void:
	_join_requested = false
	join_failed.emit(reason)


# The lobby gave us a player id; now build the WebRTC connection to the host.
func _on_lobby_joined(my_id: int) -> void:
	if not _join_requested:
		return
	_join_requested = false
	_rtc = WebRTCMultiplayerPeer.new()
	var err: int = _rtc.create_client(my_id)
	if err != OK:
		_rtc = null
		lobby.leave_room()
		join_failed.emit("Could not start the WebRTC client (error %d)." % err)
		return
	multiplayer.multiplayer_peer = _rtc
	is_client = true
	_connecting = true
	var conn := _make_connection(1)
	if conn == null:
		leave_session()
		join_failed.emit("Could not create the WebRTC connection (is WebRTC available?).")
		return
	conn.create_offer()
	_attempt += 1
	var attempt := _attempt
	get_tree().create_timer(CONNECT_TIMEOUT_SEC).timeout.connect(func() -> void:
		if _connecting and attempt == _attempt:
			leave_session()
			join_failed.emit("Connection timed out. The host may be on a different network, or a firewall is blocking WebRTC."))


func _on_connected_to_server() -> void:
	_connecting = false
	_rpc_hello.rpc_id(1, player_name, PROTOCOL_VERSION)


func _on_connection_failed() -> void:
	leave_session()
	join_failed.emit("Could not connect to the host.")


func _on_server_disconnected() -> void:
	var notice := pending_notice if not pending_notice.is_empty() else "Disconnected: the host closed the world."
	leave_session()
	pending_notice = notice
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	get_tree().paused = false
	var scene := get_tree().current_scene
	if scene != null and scene.scene_file_path == MENU_SCENE:
		join_failed.emit(notice)   # still in the menu: show it there instead of reloading
	else:
		get_tree().change_scene_to_file(MENU_SCENE)


# Closes the session and resets state. Safe to call at any time.
func leave_session() -> void:
	_attempt += 1
	for conn in _conns.values():
		conn.close()
	_conns.clear()
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	_rtc = null
	lobby.close_lobby()
	is_host = false
	is_client = false
	_host_requested = false
	_join_requested = false
	_connecting = false
	_world_live = false
	_room_id = ""
	remote_states.clear()
	player_names.clear()
	_initial_edits = PackedInt32Array()


func _on_lobby_closed(reason: String) -> void:
	if _host_requested:
		_host_requested = false
		host_failed.emit(reason)
	elif _join_requested:
		_join_requested = false
		join_failed.emit(reason)
	elif _connecting:
		# The handshake cannot finish without the lobby.
		leave_session()
		join_failed.emit("Lost the lobby connection while joining.")
	elif is_host:
		status_changed.emit("Lost the lobby connection: your world is no longer listed. Players already inside stay connected.")


func _on_peer_disconnected(id: int) -> void:
	remote_states.erase(id)
	_conns.erase(id)
	if multiplayer.is_server():
		player_names.erase(id)
		_rpc_player_names.rpc(player_names)
		lobby.update_room(_room_info())
	player_left.emit(id)


# ---------------------------------------------------------------- WebRTC plumbing

func _make_connection(id: int) -> WebRTCPeerConnection:
	if _rtc == null:
		return null
	var conn := WebRTCPeerConnection.new()
	if conn.initialize({"iceServers": ice_servers}) != OK:
		return null
	conn.session_description_created.connect(_on_sdp_created.bind(id))
	conn.ice_candidate_created.connect(_on_ice_candidate_created.bind(id))
	if _rtc.add_peer(conn, id) != OK:
		return null
	_conns[id] = conn
	return conn


# Our side produced an offer or answer: tell the other side through the lobby.
func _on_sdp_created(type: String, sdp: String, id: int) -> void:
	var conn: WebRTCPeerConnection = _conns.get(id)
	if conn == null:
		return
	conn.set_local_description(type, sdp)
	lobby.send_signal(id, {"kind": type, "sdp": sdp})


func _on_ice_candidate_created(media: String, index: int, candidate_name: String, id: int) -> void:
	lobby.send_signal(id, {"kind": "candidate", "mid": media, "index": index, "name": candidate_name})


func _on_lobby_signal(from_id: int, data: Dictionary) -> void:
	var conn: WebRTCPeerConnection = _conns.get(from_id)
	if conn == null:
		return
	match str(data.get("kind", "")):
		"offer":
			conn.set_remote_description("offer", str(data.get("sdp", "")))
		"answer":
			conn.set_remote_description("answer", str(data.get("sdp", "")))
		"candidate":
			conn.add_ice_candidate(str(data.get("mid", "")), int(data.get("index", 0)), str(data.get("name", "")))


# ---------------------------------------------------------------- handshake

@rpc("any_peer", "reliable")
func _rpc_hello(p_name: String, protocol: int) -> void:
	if not multiplayer.is_server():
		return
	var id := multiplayer.get_remote_sender_id()
	if protocol != PROTOCOL_VERSION:
		_reject(id, "That world runs a different version of the game.")
		return
	if player_names.size() >= MAX_PLAYERS:
		_reject(id, "That world is full.")
		return
	var clean := p_name.strip_edges().left(16)
	if clean.is_empty():
		clean = "Player%d" % id
	player_names[id] = clean
	_rpc_world_info.rpc_id(id, Settings.world_type, world_seed, world_name)
	# Block edits made so far, in small batches (data channels have a message size limit).
	var flat := _flatten_edits()
	for start in range(0, flat.size(), EDIT_BATCH_INTS):
		_rpc_edit_batch.rpc_id(id, flat.slice(start, start + EDIT_BATCH_INTS))
	_rpc_player_names.rpc(player_names)
	lobby.update_room(_room_info())
	player_joined.emit(id, clean)


func _reject(id: int, reason: String) -> void:
	_rpc_rejected.rpc_id(id, reason)
	await get_tree().create_timer(0.5).timeout   # let the message arrive first
	if multiplayer.multiplayer_peer != null and multiplayer.get_peers().has(id):
		multiplayer.multiplayer_peer.disconnect_peer(id)


@rpc("authority", "reliable")
func _rpc_rejected(reason: String) -> void:
	pending_notice = reason


# Host -> new client: everything needed to build the same world locally.
@rpc("authority", "reliable")
func _rpc_world_info(world_type: int, seed_value: int, host_world_name: String) -> void:
	Settings.world_type = world_type
	world_seed = seed_value
	world_name = host_world_name
	edits.clear()
	remote_states.clear()
	_initial_edits = PackedInt32Array()
	_world_live = false
	# The lobby is no longer needed for this player.
	lobby.close_lobby()
	get_tree().change_scene_to_file(WORLD_SCENE)


# Host -> new client: a slice of the edit log. Collected until the world scene is up,
# applied directly afterwards.
@rpc("authority", "reliable")
func _rpc_edit_batch(flat: PackedInt32Array) -> void:
	if _world_live:
		for i in range(0, flat.size() - 3, 4):
			block_edit_received.emit(Vector3i(flat[i], flat[i + 1], flat[i + 2]), flat[i + 3])
	else:
		_initial_edits.append_array(flat)


@rpc("authority", "reliable")
func _rpc_player_names(names: Dictionary) -> void:
	player_names = names


# VoxelWorld calls this once after the world scene loads to get the edits received so far.
# From then on, new edits are delivered through block_edit_received.
func take_initial_edits() -> PackedInt32Array:
	var result := _initial_edits
	_initial_edits = PackedInt32Array()
	_world_live = true
	return result


# ---------------------------------------------------------------- block edits

# Local record of an applied edit. VoxelWorld calls this for every change.
func record_edit(chunk_pos: Vector3i, block_pos: Vector3i, block_id: int) -> void:
	if not edits.has(chunk_pos):
		edits[chunk_pos] = {}
	edits[chunk_pos][block_pos] = block_id


# VoxelWorld calls this when the LOCAL player changed a block.
func send_block_edit(block_pos: Vector3i, block_id: int) -> void:
	if not is_online():
		return
	if multiplayer.is_server():
		_rpc_block_edit.rpc(block_pos, block_id)
	else:
		_rpc_block_edit_request.rpc_id(1, block_pos, block_id)


@rpc("any_peer", "reliable")
func _rpc_block_edit_request(block_pos: Vector3i, block_id: int) -> void:
	if not multiplayer.is_server() or block_id < 0 or block_id > 255:
		return
	var sender := multiplayer.get_remote_sender_id()
	block_edit_received.emit(block_pos, block_id)
	for id in multiplayer.get_peers():
		if id != sender:
			_rpc_block_edit.rpc_id(id, block_pos, block_id)


@rpc("authority", "reliable")
func _rpc_block_edit(block_pos: Vector3i, block_id: int) -> void:
	block_edit_received.emit(block_pos, block_id)


func _flatten_edits() -> PackedInt32Array:
	var out := PackedInt32Array()
	for chunk_edits in edits.values():
		for block_pos in chunk_edits:
			out.append(block_pos.x)
			out.append(block_pos.y)
			out.append(block_pos.z)
			out.append(chunk_edits[block_pos])
	return out


# ---------------------------------------------------------------- player positions

# RemotePlayers calls this ~20 times per second with the local player's state.
func send_local_state(pos: Vector3, yaw: float, pitch: float) -> void:
	if not is_online():
		return
	if multiplayer.is_server():
		for id in multiplayer.get_peers():
			_rpc_state_from_server.rpc_id(id, 1, pos, yaw, pitch)
	else:
		_rpc_state_to_server.rpc_id(1, pos, yaw, pitch)


@rpc("any_peer", "unreliable_ordered")
func _rpc_state_to_server(pos: Vector3, yaw: float, pitch: float) -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	_store_state(sender, pos, yaw, pitch)
	for id in multiplayer.get_peers():
		if id != sender:
			_rpc_state_from_server.rpc_id(id, sender, pos, yaw, pitch)


@rpc("authority", "unreliable_ordered")
func _rpc_state_from_server(peer_id: int, pos: Vector3, yaw: float, pitch: float) -> void:
	_store_state(peer_id, pos, yaw, pitch)


func _store_state(peer_id: int, pos: Vector3, yaw: float, pitch: float) -> void:
	if peer_id == multiplayer.get_unique_id():
		return
	remote_states[peer_id] = {"pos": pos, "yaw": yaw, "pitch": pitch}


# ---------------------------------------------------------------- helpers

func _room_info() -> Dictionary:
	return {
		"name": world_name,
		"host": player_name,
		"players": maxi(player_names.size(), 1),
		"max": MAX_PLAYERS,
		"protocol": PROTOCOL_VERSION,
		"world_type": Settings.world_type,
	}


func _default_player_name() -> String:
	for variable in ["USERNAME", "USER"]:
		var value := OS.get_environment(variable)
		if not value.is_empty():
			return value.left(16)
	return "Player"

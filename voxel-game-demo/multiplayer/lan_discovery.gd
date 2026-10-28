class_name LanDiscovery
extends Node
# Finds worlds opened on the local network using UDP broadcasts.
#
#  - The HOST calls start_announcing(info): a small JSON packet is broadcast every second.
#  - A player looking at the server list calls start_listening(): `servers` fills up with
#    every world heard in the last few seconds and servers_changed is emitted on changes.
#
# Net owns the one LanDiscovery instance (Net.discovery).

signal servers_changed

const DISCOVERY_PORT := 25566
const MAGIC := "VOXEL_LAN_V1"
const ANNOUNCE_INTERVAL := 1.0
const SERVER_TIMEOUT_MSEC := 4000

# server id (String) -> {name, host, players, max, port, protocol, world_type, address}
var servers: Dictionary = {}

var _last_seen: Dictionary = {}
var _announcing := false
var _announce_info: Dictionary = {}
var _announce_timer := 0.0
var _sender: PacketPeerUDP
var _listening := false
var _listener: PacketPeerUDP


func start_announcing(info: Dictionary) -> void:
	_announce_info = info
	if _sender == null:
		_sender = PacketPeerUDP.new()
		_sender.set_broadcast_enabled(true)
	_announcing = true
	_announce_timer = ANNOUNCE_INTERVAL   # send the first packet right away


# Refresh the announced data (player count changed, ...).
func update_announcement(info: Dictionary) -> void:
	if _announcing:
		_announce_info = info


func stop_announcing() -> void:
	_announcing = false
	if _sender != null:
		_sender.close()
		_sender = null


func start_listening() -> Error:
	if _listening:
		return OK
	_listener = PacketPeerUDP.new()
	var err := _listener.bind(DISCOVERY_PORT)
	if err != OK:
		_listener = null
		return err
	_listening = true
	servers.clear()
	_last_seen.clear()
	servers_changed.emit()
	return OK


func stop_listening() -> void:
	_listening = false
	if _listener != null:
		_listener.close()
		_listener = null
	servers.clear()
	_last_seen.clear()


func _process(delta: float) -> void:
	if _announcing:
		_announce_timer += delta
		if _announce_timer >= ANNOUNCE_INTERVAL:
			_announce_timer = 0.0
			_broadcast()
	if _listening:
		_poll()


func _broadcast() -> void:
	var packet := _announce_info.duplicate()
	packet["magic"] = MAGIC
	var payload := JSON.stringify(packet).to_utf8_buffer()
	for target in _broadcast_targets():
		_sender.set_dest_address(target, DISCOVERY_PORT)
		_sender.put_packet(payload)


# The global broadcast address does not reach every network adapter (VPNs, virtual
# adapters, multiple NICs), so every local /24 is addressed directly as well.
# 127.0.0.1 lets a second game window on the same PC see the world while testing.
func _broadcast_targets() -> PackedStringArray:
	var targets := PackedStringArray(["255.255.255.255", "127.0.0.1"])
	for ip in IP.get_local_addresses():
		var parts := ip.split(".")
		if parts.size() != 4:
			continue
		var is_private: bool = ip.begins_with("192.168.") or ip.begins_with("10.")
		if parts[0] == "172" and int(parts[1]) >= 16 and int(parts[1]) <= 31:
			is_private = true
		if not is_private:
			continue
		var directed := "%s.%s.%s.255" % [parts[0], parts[1], parts[2]]
		if not targets.has(directed):
			targets.append(directed)
	return targets


func _poll() -> void:
	var changed := false
	while _listener.get_available_packet_count() > 0:
		# get_packet() first: get_packet_ip() describes the packet read last.
		var raw := _listener.get_packet()
		var ip := _listener.get_packet_ip().trim_prefix("::ffff:")
		var parsed = JSON.parse_string(raw.get_string_from_utf8())
		if typeof(parsed) != TYPE_DICTIONARY or parsed.get("magic", "") != MAGIC:
			continue

		var key := str(int(parsed.get("id", 0)))
		var entry := {
			"name": str(parsed.get("name", "World")).left(40),
			"host": str(parsed.get("host", "?")).left(16),
			"players": int(parsed.get("players", 1)),
			"max": int(parsed.get("max", 8)),
			"port": int(parsed.get("port", 25565)),
			"protocol": int(parsed.get("protocol", 0)),
			"world_type": int(parsed.get("world_type", 0)),
			"address": ip,
		}
		var old: Dictionary = servers.get(key, {})
		# The same packet can arrive via several routes with different source addresses.
		# Keep the first real address so the list does not flicker.
		if not old.is_empty() and old["address"] != "127.0.0.1":
			entry["address"] = old["address"]
		if old.is_empty() or hash(old) != hash(entry):
			servers[key] = entry
			changed = true
		_last_seen[key] = Time.get_ticks_msec()

	var now := Time.get_ticks_msec()
	for key in servers.keys():
		if now - int(_last_seen.get(key, 0)) > SERVER_TIMEOUT_MSEC:
			servers.erase(key)
			_last_seen.erase(key)
			changed = true
	if changed:
		servers_changed.emit()

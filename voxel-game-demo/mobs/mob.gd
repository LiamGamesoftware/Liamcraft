## Mob AI for a voxel (Minecraft-style) world. Attach to a CharacterBody3D.
##
## Setup
##   - Give the body a CollisionShape3D (capsule, box, cylinder or sphere). Size and foot
##     position are read from it, so the node origin can be anywhere.
##   - Put the model under the body and assign it to `visual` (or leave it empty and the
##     first non-collision child is used). Only the visual bobs; collision stays put.
##   - The model should face -Z (Godot's forward direction).
##   - Predators join the group "predator", prey join "prey". Add your player to "player".
##   - Terrain is probed with rays against this body's collision_mask, so no navigation
##     mesh or baking is needed. Works on generated / streamed worlds.
class_name Mob
extends CharacterBody3D


signal damaged(amount: float)
signal died

enum State { IDLE, WANDER, CHASE, FLEE, DEAD }
enum Probe { CLEAR, JUMP, BLOCKED }


@export_group("Stats")
@export var max_health := 10.0
@export var speed := 2.5
@export var run_speed := 4.5
@export var jump_velocity := 8.0
@export var gravity := 24.0

@export_group("Behaviour")
## Hunts nearby mobs in the "prey" group.
@export var is_predator := false
## Flees from mobs in the "predator" group (and from whoever hits it).
@export var is_prey := false
## Predators only: also hunt the player.
@export var attacks_player := false
@export var attack_damage := 2.0
@export var attack_range := 1.6
@export var attack_cooldown := 1.0
@export var sight_range := 16.0
@export var wander_distance := 10.0

@export_group("Walk bounce")
## Node that bobs while walking. Auto-detected if empty.
@export var visual: Node3D
@export var bounce_height := 0.12
@export var hops_per_block := 1.0

@export_group("Terrain")
## Drops taller than this (in blocks) are treated as cliffs and avoided.
@export var max_drop := 3.0


const GROUP_PREDATOR := &"predator"
const GROUP_PREY := &"prey"
const GROUP_PLAYER := &"player"

const ACCELERATION := 20.0
const DECELERATION := 30.0
const HURT_FRICTION := 6.0
const HURT_STUN := 0.25
const KNOCKBACK := 5.0
const TURN_RATE := 10.0
const STEP_HEIGHT := 1.0           # tallest ledge the mob will jump onto
const THINK_INTERVAL := 0.15       # how often terrain probing / steering runs
const SCAN_INTERVAL := 0.3         # how often targets / threats are searched for
const LOSE_TARGET_SECONDS := 3.0
const FLEE_SECONDS := 4.0
const VOID_Y := -64.0              # mobs below this are removed
const GROUND_SEARCH_DEPTH := 160.0
const STEER_ANGLES := [0.0, 40.0, -40.0, 85.0, -85.0, 130.0, -130.0]


var state: State = State.IDLE
var health := 0.0

var _target: Node3D                # prey we are hunting
var _threat: Node3D                # what we are running from
var _target_visible := true
var _target_lost_timer := 0.0
var _hunt_cooldown := 0.0
var _stuck_strikes := 0

var _goal := Vector3.ZERO
var _wander_target := Vector3.ZERO
var _steer_dir := Vector3.ZERO
var _look_dir := Vector3.ZERO
var _move_speed := 0.0
var _want_jump := false
var _side := 1.0                   # which way to detour around obstacles (+1 / -1)

var _state_timer := 0.0
var _think_timer := 0.0
var _scan_timer := 0.0
var _attack_timer := 0.0
var _hurt_timer := 0.0
var _stuck_timer := 0.0
var _stuck_check_pos := Vector3.ZERO
var _waiting_for_terrain := false

var _bounce_phase := 0.0
var _visual_rest_y := 0.0

var _radius := 0.4
var _height := 1.8
var _foot_offset := 0.0


func _ready() -> void:
	health = max_health
	if is_predator:
		add_to_group(GROUP_PREDATOR)
	if is_prey:
		add_to_group(GROUP_PREY)
	_side = 1.0 if randf() < 0.5 else -1.0
	_scan_timer = randf() * SCAN_INTERVAL
	_measure_body()
	if visual == null:
		visual = _find_visual()
	if visual:
		_visual_rest_y = visual.position.y
	_stuck_check_pos = global_position
	_enter_idle()


func _physics_process(delta: float) -> void:
	if state == State.DEAD:
		velocity.x = move_toward(velocity.x, 0.0, DECELERATION * delta)
		velocity.z = move_toward(velocity.z, 0.0, DECELERATION * delta)
		_apply_gravity(delta)
		move_and_slide()
		return

	if global_position.y < VOID_Y:
		queue_free()
		return

	_attack_timer = maxf(0.0, _attack_timer - delta)
	_hurt_timer = maxf(0.0, _hurt_timer - delta)
	_hunt_cooldown = maxf(0.0, _hunt_cooldown - delta)

	# Freeze while the chunk below isn't loaded yet, so mobs never fall through the world.
	if _waiting_for_terrain:
		_think_timer -= delta
		if _think_timer <= 0.0:
			_think_timer = 0.25
			_waiting_for_terrain = not _terrain_below()
		return

	_think_timer -= delta
	if _think_timer <= 0.0:
		_think_timer = THINK_INTERVAL * randf_range(0.75, 1.25)
		_think()
		if _waiting_for_terrain:
			return

	_scan_timer -= delta
	if _scan_timer <= 0.0:
		_scan_timer = SCAN_INTERVAL
		_scan()

	_update_state(delta)
	_move(delta)
	_apply_gravity(delta)
	move_and_slide()
	_update_bounce(delta)


# ---------------------------------------------------------------- public API

## Call from weapons, projectiles, other mobs. Matches the old NpcAI signature.
func take_damage(amount: float, attacker: Node3D = null, knockback := Vector3.ZERO) -> void:
	if state == State.DEAD or amount <= 0.0:
		return
	health -= amount
	velocity += knockback
	_hurt_timer = HURT_STUN
	damaged.emit(amount)
	if health <= 0.0:
		_die()
		return
	if attacker != null and is_instance_valid(attacker) and attacker != self:
		if is_predator:
			_start_chase(attacker)
		else:
			_start_flee(attacker)


func is_alive() -> bool:
	return state != State.DEAD


# ---------------------------------------------------------------- states

func _update_state(delta: float) -> void:
	_move_speed = 0.0
	_look_dir = Vector3.ZERO

	match state:
		State.IDLE:
			_state_timer -= delta
			if _state_timer <= 0.0:
				_start_wander()
		State.WANDER:
			_state_timer -= delta
			_goal = _wander_target
			_move_speed = speed
			if _flat_distance(_wander_target) < 0.8 or _state_timer <= 0.0:
				_enter_idle()
		State.CHASE:
			_update_chase(delta)
		State.FLEE:
			_update_flee(delta)

	_check_stuck(delta)


func _update_chase(delta: float) -> void:
	if not _is_alive(_target):
		_end_chase()
		return

	var to_target := _target.global_position - global_position
	var flat := Vector3(to_target.x, 0.0, to_target.z)
	var distance := flat.length()
	if distance > sight_range * 1.5:
		_end_chase()
		return

	if _target_visible:
		_target_lost_timer = 0.0
	else:
		_target_lost_timer += delta
		if _target_lost_timer > LOSE_TARGET_SECONDS:
			_end_chase()
			return

	_goal = _target.global_position
	if distance <= attack_range and absf(to_target.y) <= STEP_HEIGHT + 0.5:
		_look_dir = flat.normalized()
		if _attack_timer <= 0.0:
			_attack(_target)
	else:
		_move_speed = run_speed


func _update_flee(delta: float) -> void:
	_state_timer -= delta
	if not _is_alive(_threat):
		_threat = null
		_enter_idle()
		return
	var away := global_position - _threat.global_position
	away.y = 0.0
	if away.length() > sight_range * 1.2 or _state_timer <= 0.0:
		_threat = null
		_enter_idle()
		return
	away = away.normalized() if away.length_squared() > 0.001 else -global_transform.basis.z
	_goal = global_position + away * 8.0
	_move_speed = run_speed


func _enter_idle() -> void:
	_state_timer = randf_range(1.0, 4.0)
	_steer_dir = Vector3.ZERO
	_want_jump = false
	state = State.IDLE


func _start_wander() -> void:
	var angle := randf() * TAU
	var distance := randf_range(wander_distance * 0.3, wander_distance)
	_wander_target = global_position + Vector3(cos(angle), 0.0, sin(angle)) * distance
	_goal = _wander_target
	_state_timer = distance / maxf(speed, 0.1) * 2.0 + 1.0
	_side = 1.0 if randf() < 0.5 else -1.0
	state = State.WANDER


func _start_chase(prey: Node3D) -> void:
	_target = prey
	_threat = null
	_target_visible = true
	_target_lost_timer = 0.0
	_stuck_strikes = 0
	_attack_timer = maxf(_attack_timer, 0.4)
	state = State.CHASE


func _end_chase() -> void:
	_target = null
	_enter_idle()


func _start_flee(threat: Node3D) -> void:
	_threat = threat
	_target = null
	_state_timer = FLEE_SECONDS
	state = State.FLEE


func _die() -> void:
	state = State.DEAD
	_target = null
	_threat = null
	remove_from_group(GROUP_PREDATOR)
	remove_from_group(GROUP_PREY)
	collision_layer = 0
	died.emit()
	if visual:
		create_tween().tween_property(visual, "rotation:z", deg_to_rad(90.0), 0.25)
	get_tree().create_timer(1.2).timeout.connect(queue_free)


# ---------------------------------------------------------------- targeting

func _scan() -> void:
	if state == State.DEAD:
		return
	if is_prey:
		var threat := _nearest_target(GROUP_PREDATOR, false)
		if threat != null:
			_start_flee(threat)
			return
	if is_predator and state != State.CHASE and state != State.FLEE and _hunt_cooldown <= 0.0:
		var prey := _find_prey()
		if prey != null:
			_start_chase(prey)


func _find_prey() -> Node3D:
	var prey := _nearest_target(GROUP_PREY, true)
	if attacks_player:
		var player := _nearest_target(GROUP_PLAYER, true)
		if player != null and (prey == null or global_position.distance_squared_to(player.global_position) < global_position.distance_squared_to(prey.global_position)):
			return player
	return prey


func _nearest_target(group: StringName, need_sight: bool) -> Node3D:
	var best: Node3D = null
	var best_distance := sight_range * sight_range
	for node in get_tree().get_nodes_in_group(group):
		var other := node as Node3D
		if other == null or other == self or not _is_alive(other):
			continue
		var distance := global_position.distance_squared_to(other.global_position)
		if distance >= best_distance:
			continue
		if need_sight and not _can_see(other):
			continue
		best = other
		best_distance = distance
	return best


func _can_see(other: Node3D) -> bool:
	var eye := _feet() + Vector3.UP * (_height * 0.85)
	return not _hits_terrain(eye, other.global_position + Vector3.UP * 0.9)


func _is_alive(node) -> bool:
	if not is_instance_valid(node):
		return false
	if node.is_queued_for_deletion():
		return false
	if node.has_method(&"is_alive"):
		return node.call(&"is_alive")
	return node.get("is_dead") != true


func _attack(victim: Node3D) -> void:
	_attack_timer = attack_cooldown
	if victim is Mob:
		var push := victim.global_position - global_position
		push.y = 0.0
		push = push.normalized() * KNOCKBACK + Vector3.UP * 3.0
		victim.call(&"take_damage", attack_damage, self, push)
	elif victim.has_method(&"take_damage"):
		victim.call(&"take_damage", attack_damage)


# ---------------------------------------------------------------- terrain traversal

## Runs a few times a second: checks the ground, then picks a heading and whether to jump.
func _think() -> void:
	if not is_on_floor() and not _terrain_below():
		_waiting_for_terrain = true
		velocity = Vector3.ZERO
		return

	if state == State.CHASE and _is_alive(_target):
		_target_visible = _can_see(_target)

	if state == State.WANDER or state == State.CHASE or state == State.FLEE:
		var desired := _flat_dir_to(_goal)
		if desired == Vector3.ZERO:
			_steer_dir = Vector3.ZERO
			_want_jump = false
		else:
			_pick_steering(desired)
	else:
		_steer_dir = Vector3.ZERO
		_want_jump = false


## Tries the desired heading first, then detours left/right until something is passable.
func _pick_steering(desired: Vector3) -> void:
	for angle in STEER_ANGLES:
		var dir := desired.rotated(Vector3.UP, deg_to_rad(float(angle) * _side))
		var result := _probe(dir)
		if result != Probe.BLOCKED:
			_steer_dir = dir
			_want_jump = result == Probe.JUMP
			return
	_steer_dir = Vector3.ZERO
	_want_jump = false


## Looks ahead in `dir`: flat ground, a one-block step to jump, or a wall / overhang / cliff.
func _probe(dir: Vector3) -> Probe:
	var feet := _feet()
	var ahead := dir * (_radius + 0.6)
	var top := maxf(_height - 0.1, 0.3)

	var low := _hits_terrain(feet + Vector3.UP * 0.2, feet + Vector3.UP * 0.2 + ahead)
	var high := _hits_terrain(feet + Vector3.UP * top, feet + Vector3.UP * top + ahead)

	if not low and not high:
		return Probe.BLOCKED if _is_cliff_ahead(feet, dir) else Probe.CLEAR

	if low and not high:
		var step_y := STEP_HEIGHT + 0.2
		var clear_step := not _hits_terrain(feet + Vector3.UP * step_y, feet + Vector3.UP * step_y + ahead)
		var jump_top := STEP_HEIGHT + top
		var clear_head := not _hits_terrain(feet + Vector3.UP * jump_top, feet + Vector3.UP * jump_top + ahead)
		if clear_step and clear_head:
			return Probe.JUMP

	return Probe.BLOCKED


func _is_cliff_ahead(feet: Vector3, dir: Vector3) -> bool:
	var from := feet + dir * (_radius + 0.7) + Vector3.UP * 0.5
	return _ray(from, from + Vector3.DOWN * (max_drop + 0.5)).is_empty()


func _terrain_below() -> bool:
	var from := global_position + Vector3.UP * 0.5
	return not _ray(from, from + Vector3.DOWN * GROUND_SEARCH_DEPTH).is_empty()


## Gives up on a goal if the mob barely moved for a second (boxed in, or unreachable prey).
func _check_stuck(delta: float) -> void:
	if _move_speed <= 0.0:
		_stuck_timer = 0.0
		_stuck_check_pos = global_position
		return
	_stuck_timer += delta
	if _stuck_timer < 1.0:
		return
	var moved := global_position.distance_to(_stuck_check_pos)
	_stuck_timer = 0.0
	_stuck_check_pos = global_position
	if moved >= 0.25:
		_stuck_strikes = 0
		return
	_side = -_side
	match state:
		State.WANDER:
			_enter_idle()
		State.CHASE:
			_stuck_strikes += 1
			if _stuck_strikes >= 3:
				_hunt_cooldown = 6.0
				_end_chase()


# ---------------------------------------------------------------- movement

func _move(delta: float) -> void:
	var hurt := _hurt_timer > 0.0
	var wanted := Vector3.ZERO if hurt else _steer_dir * _move_speed

	var rate := DECELERATION
	if hurt:
		rate = HURT_FRICTION
	elif wanted != Vector3.ZERO:
		rate = ACCELERATION
	velocity.x = move_toward(velocity.x, wanted.x, rate * delta)
	velocity.z = move_toward(velocity.z, wanted.z, rate * delta)

	if _want_jump and is_on_floor() and not hurt and _move_speed > 0.0:
		velocity.y = jump_velocity
		_want_jump = false

	if not hurt:
		var face := _look_dir if _look_dir != Vector3.ZERO else wanted
		if face.length_squared() > 0.01:
			var target_yaw := atan2(-face.x, -face.z)
			rotation.y = lerp_angle(rotation.y, target_yaw, clampf(TURN_RATE * delta, 0.0, 1.0))


func _apply_gravity(delta: float) -> void:
	if not is_on_floor():
		velocity.y = maxf(velocity.y - gravity * delta, -40.0)


## Hops the visual up and down while walking; one hop per `1 / hops_per_block` blocks.
func _update_bounce(delta: float) -> void:
	if visual == null:
		return
	var horizontal_speed := Vector2(velocity.x, velocity.z).length()
	if is_on_floor() and horizontal_speed > 0.3:
		_bounce_phase = fmod(_bounce_phase + horizontal_speed * hops_per_block * PI * delta, TAU)
		visual.position.y = _visual_rest_y + absf(sin(_bounce_phase)) * bounce_height
	else:
		if is_on_floor():
			_bounce_phase = 0.0
		visual.position.y = lerpf(visual.position.y, _visual_rest_y, minf(1.0, 15.0 * delta))


# ---------------------------------------------------------------- helpers

func _feet() -> Vector3:
	return global_position + Vector3.UP * _foot_offset


func _ray(from: Vector3, to: Vector3) -> Dictionary:
	var query := PhysicsRayQueryParameters3D.create(from, to, collision_mask, [get_rid()])
	return get_world_3d().direct_space_state.intersect_ray(query)


## True if terrain is in the way. Other characters (mobs, player) are ignored.
func _hits_terrain(from: Vector3, to: Vector3) -> bool:
	var hit := _ray(from, to)
	return not hit.is_empty() and not (hit.collider is CharacterBody3D)


func _flat_dir_to(point: Vector3) -> Vector3:
	var direction := point - global_position
	direction.y = 0.0
	return direction.normalized()


func _flat_distance(point: Vector3) -> float:
	var direction := point - global_position
	direction.y = 0.0
	return direction.length()


func _measure_body() -> void:
	for child in get_children():
		var shape_node := child as CollisionShape3D
		if shape_node == null or shape_node.shape == null:
			continue
		var shape := shape_node.shape
		if shape is CapsuleShape3D:
			_radius = (shape as CapsuleShape3D).radius
			_height = (shape as CapsuleShape3D).height
		elif shape is CylinderShape3D:
			_radius = (shape as CylinderShape3D).radius
			_height = (shape as CylinderShape3D).height
		elif shape is BoxShape3D:
			var size := (shape as BoxShape3D).size
			_radius = minf(size.x, size.z) * 0.5
			_height = size.y
		elif shape is SphereShape3D:
			_radius = (shape as SphereShape3D).radius
			_height = _radius * 2.0
		else:
			continue
		_foot_offset = shape_node.position.y - _height * 0.5
		return


func _find_visual() -> Node3D:
	for child in get_children():
		if child is GeometryInstance3D:
			return child as Node3D
	for child in get_children():
		if child is Node3D and not (child is CollisionShape3D) and not (child is CollisionPolygon3D):
			return child as Node3D
	return null

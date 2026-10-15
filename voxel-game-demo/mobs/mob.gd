## Reusable NPC / mob AI template for Godot 4.x.
## Attach this script to a CharacterBody3D.  Put player characters in target_group
## and optionally add a NavigationAgent3D and AnimationPlayer as children.
class_name NpcAI
extends CharacterBody3D


signal state_changed(previous_state: State, new_state: State)
signal target_changed(new_target: Node3D)
signal health_changed(current_health: float, maximum_health: float)
signal died
signal attack_landed(victim: Node3D, damage: float)


enum State { IDLE, PATROL, WANDER, CHASE, ATTACK, FLEE, RETURN_HOME, STUNNED, DEAD }
enum Temperament { PASSIVE, NEUTRAL, HOSTILE, COWARDLY }
enum AttackType { MELEE, PROJECTILE, CUSTOM }
enum DefaultBehaviour { IDLE, PATROL, WANDER }


@export_category("Identity")
@export var mob_name := "Template Mob"
@export var faction := "neutral"
@export var temperament: Temperament = Temperament.HOSTILE
@export var default_behaviour: DefaultBehaviour = DefaultBehaviour.WANDER
@export var target_group := "player"

@export_group("Node references")
@export var navigation_agent_path: NodePath
@export var animation_player_path: NodePath
@export var wall_ray_path: NodePath
@export var projectile_spawn_path: NodePath

@export_group("Health and damage")
@export_range(1.0, 10000.0, 1.0) var maximum_health := 20.0
@export var start_at_full_health := true
@export_range(0.0, 10000.0, 1.0) var starting_health := 20.0
@export var can_regenerate_health := false
@export_range(0.0, 1000.0, 0.1) var health_regenerated_per_second := 0.0
@export_range(0.0, 1.0, 0.01) var regeneration_starts_below_percent := 0.65
@export var retaliate_when_hurt := true
@export var invulnerability_seconds_after_hit := 0.15
@export var destroy_on_death := true
@export_range(0.0, 30.0, 0.1) var destroy_delay_seconds := 2.0

@export_group("Movement")
@export_range(0.0, 100.0, 0.1) var walk_speed := 3.5
@export_range(0.0, 100.0, 0.1) var chase_speed := 5.0
@export_range(0.0, 100.0, 0.1) var flee_speed := 6.0
@export_range(0.0, 1000.0, 0.1) var acceleration := 18.0
@export_range(0.0, 1000.0, 0.1) var deceleration := 24.0
@export_range(0.0, 360.0, 1.0) var turn_speed_degrees_per_second := 540.0
@export var uses_gravity := true
@export var can_fly := false
@export_range(0.0, 100.0, 0.1) var gravity_strength := 24.0
@export_range(0.05, 10.0, 0.05) var destination_reached_distance := 0.75
@export var use_navigation_agent := true
@export_range(0.1, 10.0, 0.05) var navigation_path_desired_distance := 0.5
@export_range(0.1, 10.0, 0.05) var navigation_target_desired_distance := 0.75

@export_group("Home, patrol and wandering")
@export var use_spawn_position_as_home := true
@export var home_position := Vector3.ZERO
@export_range(0.0, 10000.0, 0.5) var maximum_distance_from_home := 32.0
@export var return_home_when_tethered := true
@export var patrol_points: Array[NodePath] = []
@export var loop_patrol := true
@export_range(0.0, 60.0, 0.1) var patrol_wait_seconds := 1.5
@export_range(0.0, 1000.0, 0.5) var wander_radius := 12.0
@export_range(0.0, 60.0, 0.1) var wander_pause_minimum_seconds := 1.0
@export_range(0.0, 60.0, 0.1) var wander_pause_maximum_seconds := 4.0

@export_group("Perception and target memory")
@export_range(0.0, 1000.0, 0.5) var sight_range := 18.0
@export_range(1.0, 360.0, 1.0) var field_of_view_degrees := 120.0
@export_range(-10.0, 10.0, 0.05) var eye_height := 1.4
@export var require_line_of_sight := true
@export_flags_3d_physics var line_of_sight_collision_mask := 1
@export_range(0.02, 5.0, 0.02) var perception_refresh_seconds := 0.2
@export_range(0.0, 120.0, 0.1) var target_memory_seconds := 4.0
@export_range(0.0, 1000.0, 0.5) var give_up_chase_distance := 45.0
@export var ignore_targets_above_or_below_range := false

@export_group("Combat")
@export var can_attack := true
@export var attack_type: AttackType = AttackType.MELEE
@export_range(0.1, 100.0, 0.1) var attack_range := 2.0
@export_range(0.0, 100.0, 0.1) var preferred_ranged_distance := 10.0
@export_range(0.0, 10000.0, 0.1) var attack_damage := 4.0
@export_range(0.05, 60.0, 0.05) var attack_cooldown_seconds := 1.2
@export_range(0.0, 5.0, 0.01) var attack_range_tolerance := 0.25
@export var damage_receiver_method := &"take_damage"
@export var pass_attacker_to_damage_receiver := false
@export var projectile_scene: PackedScene
@export_range(0.0, 1000.0, 0.1) var projectile_damage := 3.0
@export_range(0.0, 1000.0, 0.1) var projectile_speed := 20.0
@export var destroy_projectile_if_no_setup_method := true

@export_group("Fleeing and crowd avoidance")
@export var flee_when_health_below_percent := 0.0
@export_range(0.0, 1000.0, 0.5) var flee_distance := 16.0
@export_range(0.0, 100.0, 0.1) var flee_safe_distance := 20.0
@export var avoid_walls := true
@export_range(0.0, 100.0, 0.1) var wall_avoidance_strength := 1.5

@export_group("Animation names")
@export var use_animations := true
@export var idle_animation := &"idle"
@export var walk_animation := &"walk"
@export var run_animation := &"run"
@export var attack_animation := &"attack"
@export var hurt_animation := &"hurt"
@export var death_animation := &"death"

@export_group("Debug")
@export var print_state_changes := false
@export var show_debug_labels := false


@onready var navigation_agent: NavigationAgent3D = _optional_node(navigation_agent_path) as NavigationAgent3D
@onready var animation_player: AnimationPlayer = _optional_node(animation_player_path) as AnimationPlayer
@onready var wall_ray: RayCast3D = _optional_node(wall_ray_path) as RayCast3D
@onready var projectile_spawn: Node3D = _optional_node(projectile_spawn_path) as Node3D

var state: State = State.IDLE
var current_health := 0.0
var current_target: Node3D
var last_seen_target_position := Vector3.ZERO

var _attack_timer := 0.0
var _invulnerability_timer := 0.0
var _perception_timer := 0.0
var _time_since_target_seen := 0.0
var _behaviour_wait_timer := 0.0
var _stun_timer := 0.0
var _patrol_index := 0
var _wander_destination := Vector3.ZERO
var _has_wander_destination := false
var _random := RandomNumberGenerator.new()


func _ready() -> void:
	_random.randomize()
	if use_spawn_position_as_home:
		home_position = global_position
	current_health = maximum_health if start_at_full_health else clampf(starting_health, 0.0, maximum_health)
	if navigation_agent:
		navigation_agent.path_desired_distance = navigation_path_desired_distance
		navigation_agent.target_desired_distance = navigation_target_desired_distance
	_resume_default_behaviour()


func _physics_process(delta: float) -> void:
	if state == State.DEAD:
		return

	_attack_timer = maxf(0.0, _attack_timer - delta)
	_invulnerability_timer = maxf(0.0, _invulnerability_timer - delta)
	_update_health_regeneration(delta)
	_update_target_awareness(delta)

	match state:
		State.IDLE:
			_run_idle(delta)
		State.PATROL:
			_run_patrol(delta)
		State.WANDER:
			_run_wander(delta)
		State.CHASE:
			_run_chase(delta)
		State.ATTACK:
			_run_attack(delta)
		State.FLEE:
			_run_flee(delta)
		State.RETURN_HOME:
			_run_return_home(delta)
		State.STUNNED:
			_run_stunned(delta)

	_apply_vertical_movement(delta)
	move_and_slide()
	_update_animation()


## Call this from a weapon, projectile, or player script.
## The optional attacker is used to make neutral mobs retaliate.
func take_damage(amount: float, attacker: Node3D = null, knockback: Vector3 = Vector3.ZERO) -> void:
	if state == State.DEAD or amount <= 0.0 or _invulnerability_timer > 0.0:
		return

	current_health = maxf(0.0, current_health - amount)
	_invulnerability_timer = invulnerability_seconds_after_hit
	health_changed.emit(current_health, maximum_health)
	if knockback != Vector3.ZERO:
		velocity += knockback
	if attacker and retaliate_when_hurt and temperament != Temperament.PASSIVE:
		set_target(attacker)
	if hurt_animation != &"":
		_play_animation(hurt_animation)
	if current_health <= 0.0:
		_die()


func stun(duration_seconds: float) -> void:
	if state == State.DEAD:
		return
	_stun_timer = maxf(_stun_timer, duration_seconds)
	_set_state(State.STUNNED)


func set_target(new_target: Node3D) -> void:
	if new_target == self or not is_instance_valid(new_target):
		return
	current_target = new_target
	last_seen_target_position = new_target.global_position
	_time_since_target_seen = 0.0
	target_changed.emit(current_target)
	_decide_combat_state()


func clear_target() -> void:
	if current_target == null:
		return
	current_target = null
	target_changed.emit(null)
	_resume_default_behaviour()


## Override this in a child script for a spell, charge, summon, etc.
func perform_custom_attack(_victim: Node3D) -> void:
	push_warning("%s uses CUSTOM attack type, but perform_custom_attack() was not overridden." % mob_name)


func _update_target_awareness(delta: float) -> void:
	if _is_target_invalid(current_target):
		clear_target()

	_perception_timer -= delta
	if _perception_timer <= 0.0:
		_perception_timer = perception_refresh_seconds
		if current_target == null and _naturally_searches_for_targets():
			var discovered_target := _find_closest_visible_target()
			if discovered_target:
				set_target(discovered_target)

	if current_target == null:
		return

	if _can_see(current_target):
		last_seen_target_position = current_target.global_position
		_time_since_target_seen = 0.0
	else:
		_time_since_target_seen += delta

	if global_position.distance_to(last_seen_target_position) > give_up_chase_distance \
		or _time_since_target_seen >= target_memory_seconds:
		clear_target()
		return

	if state != State.STUNNED:
		_decide_combat_state()


func _naturally_searches_for_targets() -> bool:
	return temperament == Temperament.HOSTILE or temperament == Temperament.COWARDLY


func _find_closest_visible_target() -> Node3D:
	var closest_target: Node3D
	var closest_distance := INF
	for candidate in get_tree().get_nodes_in_group(target_group):
		if not candidate is Node3D:
			continue
		var candidate_3d := candidate as Node3D
		if _is_target_invalid(candidate_3d) or not _can_see(candidate_3d):
			continue
		var distance := global_position.distance_squared_to(candidate_3d.global_position)
		if distance < closest_distance:
			closest_target = candidate_3d
			closest_distance = distance
	return closest_target


func _can_see(candidate: Node3D) -> bool:
	var offset := candidate.global_position - global_position
	if ignore_targets_above_or_below_range:
		offset.y = 0.0
	if offset.length() > sight_range:
		return false

	var flat_direction := offset
	flat_direction.y = 0.0
	if flat_direction.length_squared() > 0.001:
		var forward := -global_transform.basis.z
		forward.y = 0.0
		if forward.normalized().dot(flat_direction.normalized()) < cos(deg_to_rad(field_of_view_degrees * 0.5)):
			return false

	if not require_line_of_sight:
		return true
	return _has_line_of_sight_to(candidate)


func _has_line_of_sight_to(candidate: Node3D) -> bool:
	var from := global_position + Vector3.UP * eye_height
	var to := candidate.global_position + Vector3.UP * eye_height
	var query := PhysicsRayQueryParameters3D.create(from, to, line_of_sight_collision_mask, [get_rid()])
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return true
	var collider := hit.get("collider") as Node
	return collider != null and (collider == candidate or candidate.is_ancestor_of(collider) or collider.is_ancestor_of(candidate))


func _decide_combat_state() -> void:
	if current_target == null:
		return
	if _should_flee():
		_set_state(State.FLEE)
		return
	if not can_attack:
		_set_state(State.CHASE)
		return
	var distance := global_position.distance_to(current_target.global_position)
	if distance <= attack_range + attack_range_tolerance:
		_set_state(State.ATTACK)
	else:
		_set_state(State.CHASE)


func _should_flee() -> bool:
	if temperament == Temperament.COWARDLY:
		return true
	return flee_when_health_below_percent > 0.0 and _health_percent() <= flee_when_health_below_percent


func _run_idle(delta: float) -> void:
	_stop_moving(delta)
	if _is_beyond_home_tether():
		_set_state(State.RETURN_HOME)


func _run_patrol(delta: float) -> void:
	if patrol_points.is_empty():
		_set_state(State.IDLE)
		return
	if _behaviour_wait_timer > 0.0:
		_behaviour_wait_timer -= delta
		_stop_moving(delta)
		return

	var patrol_point := _optional_node(patrol_points[_patrol_index]) as Node3D
	if patrol_point == null:
		_advance_patrol_point()
		return
	_move_toward(patrol_point.global_position, walk_speed, delta)
	if _is_at_position(patrol_point.global_position):
		_behaviour_wait_timer = patrol_wait_seconds
		_advance_patrol_point()


func _run_wander(delta: float) -> void:
	if _is_beyond_home_tether():
		_set_state(State.RETURN_HOME)
		return
	if _behaviour_wait_timer > 0.0:
		_behaviour_wait_timer -= delta
		_stop_moving(delta)
		return
	if not _has_wander_destination:
		_choose_wander_destination()
	_move_toward(_wander_destination, walk_speed, delta)
	if _is_at_position(_wander_destination):
		_has_wander_destination = false
		_behaviour_wait_timer = _random.randf_range(wander_pause_minimum_seconds, wander_pause_maximum_seconds)


func _run_chase(delta: float) -> void:
	if current_target == null:
		_resume_default_behaviour()
		return
	var distance := global_position.distance_to(current_target.global_position)
	if can_attack and distance <= attack_range + attack_range_tolerance:
		_set_state(State.ATTACK)
		return
	_move_toward(last_seen_target_position, chase_speed, delta)


func _run_attack(delta: float) -> void:
	if current_target == null:
		_resume_default_behaviour()
		return
	var distance := global_position.distance_to(current_target.global_position)
	if distance > attack_range + attack_range_tolerance:
		_set_state(State.CHASE)
		return
	_stop_moving(delta)
	_face_direction(_flat_direction_to(current_target.global_position), delta)
	if _attack_timer <= 0.0:
		_attack_timer = attack_cooldown_seconds
		_perform_attack(current_target)


func _run_flee(delta: float) -> void:
	if current_target == null:
		_resume_default_behaviour()
		return
	var distance := global_position.distance_to(current_target.global_position)
	if distance >= flee_safe_distance:
		clear_target()
		return
	var away := _flat_direction_from(current_target.global_position)
	if away.length_squared() < 0.001:
		away = global_transform.basis.x.normalized()
	_move_toward(global_position + away * flee_distance, flee_speed, delta)


func _run_return_home(delta: float) -> void:
	_move_toward(home_position, walk_speed, delta)
	if _is_at_position(home_position):
		_resume_default_behaviour()


func _run_stunned(delta: float) -> void:
	_stun_timer -= delta
	_stop_moving(delta)
	if _stun_timer <= 0.0:
		if current_target:
			_decide_combat_state()
		else:
			_resume_default_behaviour()


func _perform_attack(victim: Node3D) -> void:
	if attack_animation != &"":
		_play_animation(attack_animation)
	match attack_type:
		AttackType.MELEE:
			_deal_damage_to(victim, attack_damage)
		AttackType.PROJECTILE:
			_spawn_projectile(victim)
		AttackType.CUSTOM:
			perform_custom_attack(victim)


func _deal_damage_to(victim: Node3D, damage: float) -> void:
	if victim.has_method(damage_receiver_method):
		if pass_attacker_to_damage_receiver:
			victim.call(damage_receiver_method, damage, self)
		else:
			victim.call(damage_receiver_method, damage)
		attack_landed.emit(victim, damage)


func _spawn_projectile(victim: Node3D) -> void:
	if projectile_scene == null:
		push_warning("%s has PROJECTILE attack type but no projectile_scene." % mob_name)
		return
	var projectile := projectile_scene.instantiate()
	get_tree().current_scene.add_child(projectile)
	if projectile is Node3D:
		var projectile_3d := projectile as Node3D
		projectile_3d.global_transform = (projectile_spawn if projectile_spawn else self).global_transform
		var direction := projectile_3d.global_position.direction_to(victim.global_position)
		if projectile.has_method(&"setup"):
			projectile.call(&"setup", direction, projectile_damage, projectile_speed, self)
		elif destroy_projectile_if_no_setup_method:
			push_warning("Projectile scene needs setup(direction, damage, speed, owner), or disable destroy_projectile_if_no_setup_method.")
			projectile.queue_free()


func _move_toward(destination: Vector3, speed: float, delta: float) -> void:
	var direction := _navigation_direction_to(destination)
	direction = _avoid_wall(direction)
	velocity.x = move_toward(velocity.x, direction.x * speed, acceleration * delta)
	velocity.z = move_toward(velocity.z, direction.z * speed, acceleration * delta)
	if can_fly:
		velocity.y = move_toward(velocity.y, direction.y * speed, acceleration * delta)
	_face_direction(direction, delta)


func _stop_moving(delta: float) -> void:
	velocity.x = move_toward(velocity.x, 0.0, deceleration * delta)
	velocity.z = move_toward(velocity.z, 0.0, deceleration * delta)
	if can_fly:
		velocity.y = move_toward(velocity.y, 0.0, deceleration * delta)


func _apply_vertical_movement(delta: float) -> void:
	if uses_gravity and not can_fly:
		if not is_on_floor():
			velocity.y -= gravity_strength * delta
		elif velocity.y < 0.0:
			velocity.y = -0.1


func _navigation_direction_to(destination: Vector3) -> Vector3:
	if use_navigation_agent and navigation_agent:
		navigation_agent.target_position = destination
		if not navigation_agent.is_navigation_finished():
			return _flat_direction_to(navigation_agent.get_next_path_position())
	return _flat_direction_to(destination)


func _avoid_wall(direction: Vector3) -> Vector3:
	if not avoid_walls or wall_ray == null or not wall_ray.is_colliding():
		return direction
	var steered_direction := direction + wall_ray.get_collision_normal() * wall_avoidance_strength
	return steered_direction.normalized()


func _face_direction(direction: Vector3, delta: float) -> void:
	if direction.length_squared() < 0.001:
		return
	var target_yaw := atan2(-direction.x, -direction.z)
	rotation.y = rotate_toward(rotation.y, target_yaw, deg_to_rad(turn_speed_degrees_per_second) * delta)


func _flat_direction_to(destination: Vector3) -> Vector3:
	var direction := destination - global_position
	if not can_fly:
		direction.y = 0.0
	return direction.normalized()


func _flat_direction_from(origin: Vector3) -> Vector3:
	var direction := global_position - origin
	if not can_fly:
		direction.y = 0.0
	return direction.normalized()


func _is_at_position(position: Vector3) -> bool:
	var distance_vector := position - global_position
	if not can_fly:
		distance_vector.y = 0.0
	return distance_vector.length() <= destination_reached_distance


func _is_beyond_home_tether() -> bool:
	return return_home_when_tethered and maximum_distance_from_home > 0.0 \
		and global_position.distance_to(home_position) > maximum_distance_from_home


func _choose_wander_destination() -> void:
	var angle := _random.randf_range(0.0, TAU)
	var radius := _random.randf_range(wander_radius * 0.25, wander_radius)
	_wander_destination = home_position + Vector3(cos(angle) * radius, 0.0, sin(angle) * radius)
	_has_wander_destination = true


func _advance_patrol_point() -> void:
	if patrol_points.is_empty():
		return
	if loop_patrol:
		_patrol_index = (_patrol_index + 1) % patrol_points.size()
	elif _patrol_index >= patrol_points.size() - 1:
		_set_state(State.IDLE)
	else:
		_patrol_index += 1


func _resume_default_behaviour() -> void:
	_has_wander_destination = false
	_behaviour_wait_timer = 0.0
	if _is_beyond_home_tether():
		_set_state(State.RETURN_HOME)
		return
	match default_behaviour:
		DefaultBehaviour.IDLE:
			_set_state(State.IDLE)
		DefaultBehaviour.PATROL:
			_set_state(State.PATROL)
		DefaultBehaviour.WANDER:
			_set_state(State.WANDER)


func _is_target_invalid(candidate: Node3D) -> bool:
	if candidate == null or not is_instance_valid(candidate):
		return true
	if candidate.has_method(&"is_alive"):
		return not candidate.call(&"is_alive")
	return candidate.get("is_dead") == true


func _health_percent() -> float:
	return current_health / maximum_health if maximum_health > 0.0 else 0.0


func _update_health_regeneration(delta: float) -> void:
	if not can_regenerate_health or current_health >= maximum_health:
		return
	if _health_percent() > regeneration_starts_below_percent:
		return
	current_health = minf(maximum_health, current_health + health_regenerated_per_second * delta)
	health_changed.emit(current_health, maximum_health)


func _set_state(next_state: State) -> void:
	if state == next_state:
		return
	var previous_state := state
	state = next_state
	if print_state_changes:
		print("%s: %s -> %s" % [mob_name, State.keys()[previous_state], State.keys()[state]])
	state_changed.emit(previous_state, state)


func _die() -> void:
	_set_state(State.DEAD)
	velocity = Vector3.ZERO
	died.emit()
	if death_animation != &"":
		_play_animation(death_animation)
	if destroy_on_death:
		get_tree().create_timer(destroy_delay_seconds).timeout.connect(queue_free)


func _update_animation() -> void:
	if not use_animations or animation_player == null or state == State.DEAD:
		return
	var animation := idle_animation
	if state == State.ATTACK:
		animation = attack_animation
	elif Vector2(velocity.x, velocity.z).length() > 0.1:
		animation = run_animation if state == State.CHASE or state == State.FLEE else walk_animation
	_play_animation(animation)


func _play_animation(animation: StringName) -> void:
	if animation_player and animation != &"" and animation_player.has_animation(animation) \
		and animation_player.current_animation != animation:
		animation_player.play(animation)


func _optional_node(path: NodePath) -> Node:
	if path.is_empty():
		return null
	return get_node_or_null(path)

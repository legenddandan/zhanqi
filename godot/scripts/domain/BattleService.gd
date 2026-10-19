extends RefCounted

## 与渲染无关的战斗应用服务。
## 所有命令先在工作副本上执行，成功后才提交 state，保证非法命令不会留下半套状态。

@warning_ignore_start("inference_on_variant")

const DIRECTIONS := [Vector2i.RIGHT, Vector2i.LEFT, Vector2i.DOWN, Vector2i.UP]
const ObjectiveEvaluator = preload("res://scripts/domain/ObjectiveEvaluator.gd")
const EnemyPolicy = preload("res://scripts/domain/EnemyPolicy.gd")
const AggressivePolicy = preload("res://scripts/domain/AggressivePolicy.gd")
const RangedPolicy = preload("res://scripts/domain/RangedPolicy.gd")
const ProtectPolicy = preload("res://scripts/domain/ProtectPolicy.gd")

var bundle: Dictionary = {}
var battle: Dictionary = {}
var state: Dictionary = {}
var rng := RandomNumberGenerator.new()
var objective_evaluator = ObjectiveEvaluator.new()
var enemy_policy = AggressivePolicy.new()

func configure(data_bundle: Dictionary, battle_config: Dictionary, seed: int = 1) -> Dictionary:
	bundle = data_bundle.duplicate(true)
	battle = battle_config.duplicate(true)
	rng.seed = seed
	_configure_enemy_policy()
	return _build_state()

func restore(data_bundle: Dictionary, battle_config: Dictionary, saved_state: Dictionary, seed: int = 1) -> Dictionary:
	bundle = data_bundle.duplicate(true)
	battle = battle_config.duplicate(true)
	rng.seed = seed
	_configure_enemy_policy()
	if not _validate_restored_state(saved_state):
		return _failure("saved battle state failed validation")
	state = saved_state.duplicate(true)
	if not state.has("eventFlags"):
		state["eventFlags"] = []
	if not state.has("storyFlags"):
		state["storyFlags"] = {}
	if not state.has("consumedEventIds"):
		state["consumedEventIds"] = []
	_migrate_story_flags(state)
	if not state.has("dialogue"):
		state["dialogue"] = {"active": false, "eventId": "", "speaker": "", "text": "", "choices": []}
	if not state.has("resultObjective"):
		state["resultObjective"] = {}
	if not state.has("commandLog"):
		state["commandLog"] = []
	for unit in state.get("units", []):
		if not unit.has("statuses"):
			unit["statuses"] = []
	if saved_state.has("rngState"):
		rng.state = int(saved_state.get("rngState", rng.state))
	return {"ok": true, "state": snapshot()}

func snapshot() -> Dictionary:
	return state.duplicate(true)

func execute(command: Dictionary) -> Dictionary:
	if state.is_empty():
		return _failure("battle is not started")
	if state.get("mode", "playing") != "playing":
		return _failure("battle has already ended")
	if state.get("dialogue", {}).get("active", false) and command.get("type", "") != "dialogue_choice":
		return _failure("dialogue choice is required")
	var working: Dictionary = state.duplicate(true)
	var events: Array = []
	var outcome: Dictionary = _execute_on(working, command, events)
	if not outcome.ok:
		return outcome
	working.eventLog.append_array(events)
	working.lastEvents = events
	working.commandLog.append(command.duplicate(true))
	working.rngState = rng.state
	state = working
	return {"ok": true, "events": events, "state": snapshot()}

func reachable_tiles(unit_id: String) -> Array[Vector2i]:
	var index := _unit_index(unit_id)
	if index < 0:
		return []
	var unit: Dictionary = state.units[index]
	if unit.acted or unit.moved or unit.side != "ally":
		return []
	var start: Dictionary = unit.position
	var max_move := int(unit.stats.move)
	var costs := {"%d,%d" % [start.x, start.y]: 0}
	var open: Array[Vector2i] = [Vector2i(start.x, start.y)]
	while not open.is_empty():
		var current: Vector2i = open.pop_front()
		var current_cost: int = costs["%d,%d" % [current.x, current.y]]
		for delta in DIRECTIONS:
			var next: Vector2i = current + delta
			if not _can_traverse(next, index, state):
				continue
			var next_cost := current_cost + _terrain_move_cost(next, state)
			var key := "%d,%d" % [next.x, next.y]
			if next_cost <= max_move and (not costs.has(key) or next_cost < costs[key]):
				costs[key] = next_cost
				open.append(next)
	var result: Array[Vector2i] = []
	for key in costs:
		var parts: PackedStringArray = key.split(",")
		var position := Vector2i(int(parts[0]), int(parts[1]))
		var occupant := _unit_at(position, state)
		if occupant < 0 or occupant == index:
			result.append(position)
	return result

func attackable_targets(unit_id: String) -> Array[String]:
	var index := _unit_index(unit_id)
	if index < 0:
		return []
	var unit: Dictionary = state.units[index]
	if unit.acted or not unit.moved:
		return []
	var result: Array[String] = []
	var min_range := max(0, int(unit.stats.get("minRange", 0)))
	var max_range := max(min_range, int(unit.stats.get("maxRange", min_range)))
	for target in state.units:
		var distance := _distance(unit, target)
		if target.alive and _hostile(unit, target) and distance >= min_range and distance <= max_range:
			result.append(target.instanceId)
	return result

func skill_targets(unit_id: String, skill_id: String) -> Array[String]:
	var index := _unit_index(unit_id)
	if index < 0:
		return []
	var skill: Dictionary = _find_skill(state.units[index], skill_id)
	if skill.is_empty() or skill.get("type", "") != "active" or skill.get("implementation", "planned") != "ready":
		return []
	if skill.get("targetType", "") == "self":
		return [unit_id]
	var result: Array[String] = []
	var min_range := int(skill.get("minRange", 0))
	var max_range := max(min_range, int(skill.get("maxRange", min_range)))
	for target in state.units:
		if not target.alive or target.instanceId == unit_id:
			continue
		var distance := _distance(state.units[index], target)
		if distance < min_range or distance > max_range:
			continue
		if skill.get("targetType", "") in ["enemy_single", "enemy_area"] and _hostile(state.units[index], target):
			result.append(target.instanceId)
		elif skill.get("targetType", "") in ["ally_single", "ally_area"] and not _hostile(state.units[index], target):
			result.append(target.instanceId)
	return result

func _build_state() -> Dictionary:
	var result: Dictionary = {"ok": true, "errors": []}
	var units: Array[Dictionary] = []
	for source in battle.get("units", []):
		var character: Dictionary = bundle.characters.get(source.get("characterId", ""), {})
		var resolved_class_id: String = source.get("classId", character.get("classId", ""))
		var class_data: Dictionary = bundle.classes.get(resolved_class_id, {})
		var unit: Dictionary = source.duplicate(true)
		var level := max(1, int(source.get("level", 1)))
		unit["level"] = level
		unit["exp"] = clampi(int(source.get("exp", 0)), 0, 99)
		var stats: Dictionary = _calculate_stats(character, class_data, level)
		var unit_skills: Array = []
		for skill_id in class_data.get("skillIds", []):
			if bundle.skills.has(skill_id):
				unit_skills.append(bundle.skills[skill_id].duplicate(true))
		for skill_id in character.get("skillIds", []):
			if bundle.skills.has(skill_id):
				unit_skills.append(bundle.skills[skill_id].duplicate(true))
		stats = _apply_passives(stats, unit_skills)
		stats = _apply_equipment(stats, unit.get("equipmentIds", []), class_data.get("id", ""))
		unit["classId"] = resolved_class_id
		unit["className"] = class_data.get("name", "")
		unit["stats"] = stats
		unit["skills"] = unit_skills
		unit["hp"] = clampi(int(unit.get("initialHp", stats.get("maxHp", 1))), 1, int(stats.get("maxHp", 1)))
		unit["maxHp"] = stats.get("maxHp", 1)
		unit["mp"] = clampi(int(unit.get("initialMp", stats.get("maxMp", 0))), 0, int(stats.get("maxMp", 0)))
		unit["maxMp"] = stats.get("maxMp", 0)
		unit["alive"] = true
		unit["moved"] = false
		unit["acted"] = false
		unit["guarded"] = false
		unit["statuses"] = []
		units.append(unit)
	state = {
		"schemaVersion": 1,
		"battleId": battle.get("id", ""),
		"turn": 1,
		"phase": "ally",
		"mode": "playing",
		"units": units,
		"eventLog": ["第 1 回合开始，我方行动。"],
		"lastEvents": [],
		"rngSeed": rng.seed,
		"rngState": rng.state,
		"eventFlags": [],
		"storyFlags": {},
		"consumedEventIds": [],
		"dialogue": {"active": false, "eventId": "", "speaker": "", "text": "", "choices": []},
		"resultObjective": {},
		"commandLog": [],
	}
	var opening_events: Array = []
	_emit_story_events(state, "battle_start", {}, opening_events)
	_check_result(state, opening_events)
	state.lastEvents = opening_events
	return result

func _execute_on(working: Dictionary, command: Dictionary, events: Array) -> Dictionary:
	var command_type: String = command.get("type", "")
	match command_type:
		"move": return _command_move(working, command, events)
		"attack": return _command_attack(working, command, events)
		"skill": return _command_skill(working, command, events)
		"item": return _command_item(working, command, events)
		"dialogue_choice": return _command_dialogue_choice(working, command, events)
		"end_turn": return _command_end_turn(working, events)
		_: return _failure("unknown command: %s" % command_type)

func _command_dialogue_choice(working: Dictionary, command: Dictionary, events: Array) -> Dictionary:
	var dialogue: Dictionary = working.get("dialogue", {})
	if not dialogue.get("active", false):
		return _failure("no active dialogue")
	var choice_id: String = command.get("choiceId", "")
	var selected: Dictionary = {}
	for choice in dialogue.get("choices", []):
		if choice.get("id", "") == choice_id:
			selected = choice
			break
	if selected.is_empty():
		return _failure("dialogue choice is invalid")
	for flag in selected.get("setFlags", []):
		_set_story_flag(working, flag)
	var choice_text: String = selected.get("text", choice_id)
	working.eventLog.append(choice_text)
	events.append({"type": "dialogue_choice", "eventId": dialogue.get("eventId", ""), "choiceId": choice_id, "text": choice_text})
	working.dialogue = {"active": false, "eventId": "", "speaker": "", "text": "", "choices": []}
	_emit_story_events(working, "after_dialogue", {"choiceId": choice_id}, events)
	return {"ok": true}

func _command_item(working: Dictionary, command: Dictionary, events: Array) -> Dictionary:
	var user_id: String = command.get("unitId", "")
	var target_id: String = command.get("targetId", user_id)
	var item_id: String = command.get("itemId", "")
	var user_index := _unit_index(user_id, working)
	var target_index := _unit_index(target_id, working)
	if not _valid_ally_action(user_index, working) or target_index < 0:
		return _failure("invalid item participants")
	var user: Dictionary = working.units[user_index]
	var target: Dictionary = working.units[target_index]
	if _hostile(user, target) or not target.alive:
		return _failure("item requires an ally target")
	var item: Dictionary = bundle.get("items", {}).get(item_id, {})
	if item.is_empty() or item.get("category", "") != "consumable":
		return _failure("item is not usable")
	var effect: Dictionary = item.get("battleEffect", {})
	match effect.get("type", ""):
		"heal":
			var healed := mini(int(effect.get("amount", 0)), int(target.maxHp) - int(target.hp))
			if healed <= 0:
				return _failure("target does not need healing")
			target.hp += healed
			events.append({"type": "item_used", "itemId": item_id, "unitId": user_id, "targetId": target_id, "amount": healed})
		"restore_mp":
			var restored := mini(int(effect.get("amount", 0)), int(target.maxMp) - int(target.mp))
			if restored <= 0:
				return _failure("target does not need MP")
			target.mp += restored
			events.append({"type": "item_used", "itemId": item_id, "unitId": user_id, "targetId": target_id, "amount": restored})
		"cleanse":
			var statuses: Array = target.get("statuses", [])
			var kept: Array = []
			var removed := 0
			for status in statuses:
				if status.get("id", "") in effect.get("statusIds", []):
					removed += 1
				else:
					kept.append(status)
			if removed == 0:
				return _failure("target has no removable status")
			target.statuses = kept
			_refresh_unit_stats(target)
			events.append({"type": "item_used", "itemId": item_id, "unitId": user_id, "targetId": target_id, "removed": removed})
		_: return _failure("item effect is not implemented")
	working.units[target_index] = target
	_finish_action(working, user_index)
	return {"ok": true}

func _command_move(working: Dictionary, command: Dictionary, events: Array) -> Dictionary:
	var unit_id: String = command.get("unitId", "")
	var index := _unit_index(unit_id, working)
	if not _valid_ally_action(index, working):
		return _failure("unit cannot move")
	var target := Vector2i(int(command.get("x", -1)), int(command.get("y", -1)))
	if target not in _reachable_for(index, working):
		return _failure("target tile is not reachable")
	working.units[index].position = {"x": target.x, "y": target.y}
	working.units[index].moved = true
	events.append({"type": "unit_moved", "unitId": unit_id, "to": {"x": target.x, "y": target.y}})
	return {"ok": true}

func _command_attack(working: Dictionary, command: Dictionary, events: Array) -> Dictionary:
	var attacker_id: String = command.get("attackerId", "")
	var target_id: String = command.get("targetId", "")
	var attacker_index := _unit_index(attacker_id, working)
	var target_index := _unit_index(target_id, working)
	if not _valid_ally_action(attacker_index, working) or target_index < 0:
		return _failure("invalid attack participants")
	var attacker: Dictionary = working.units[attacker_index]
	var target: Dictionary = working.units[target_index]
	if not attacker.moved or not _hostile(attacker, target) or not _in_attack_range(attacker, target):
		return _failure("target is outside attack range")
	_apply_damage(working, attacker_index, target_index, "physical" if attacker.classId != "mage" and attacker.classId != "healer" else "magic", 1.0, 0, events)
	_finish_action(working, attacker_index)
	events.append({"type": "action_finished", "unitId": attacker_id})
	_check_result(working, events)
	return {"ok": true}

func _command_skill(working: Dictionary, command: Dictionary, events: Array) -> Dictionary:
	var attacker_id: String = command.get("attackerId", "")
	var target_id: String = command.get("targetId", attacker_id)
	var attacker_index := _unit_index(attacker_id, working)
	var target_index := _unit_index(target_id, working)
	if not _valid_ally_action(attacker_index, working) or target_index < 0:
		return _failure("invalid skill participants")
	var skill: Dictionary = _find_skill(working.units[attacker_index], command.get("skillId", ""))
	if skill.is_empty() or skill.type != "active" or skill.implementation != "ready":
		return _failure("skill is unavailable")
	var target: Dictionary = working.units[target_index]
	var attacker: Dictionary = working.units[attacker_index]
	var target_type: String = skill.get("targetType", "")
	if target_type in ["enemy_single", "enemy_area"] and not _hostile(attacker, target):
		return _failure("skill requires an enemy target")
	if target_type in ["ally_single", "ally_area"] and _hostile(attacker, target):
		return _failure("skill requires an ally target")
	if target_type == "self" and target_index != attacker_index:
		return _failure("skill requires self target")
	var min_range := int(skill.get("minRange", 0))
	var max_range := int(skill.get("maxRange", min_range))
	if _distance(attacker, target) < min_range or _distance(attacker, target) > max_range:
		return _failure("skill target is outside range")
	var mp_cost := int(skill.get("mpCost", 0))
	if int(attacker.mp) < mp_cost:
		return _failure("not enough MP")
	working.units[attacker_index].mp -= mp_cost
	var effect: Dictionary = skill.get("effect", {})
	var affected: Array[int] = _skill_affected_targets(working, target_index, attacker_index, skill, effect)
	if affected.is_empty():
		return _failure("skill has no valid targets")
	match effect.get("type", ""):
		"damage":
			for affected_index in affected:
				_apply_damage(working, attacker_index, affected_index, effect.get("damageType", "physical"), float(effect.get("power", 1.0)), int(effect.get("hitBonus", 0)), events)
				if not effect.get("statusId", "").is_empty() and working.units[affected_index].alive:
					_apply_status(working, affected_index, effect.get("statusId", ""), attacker_id, events)
		"heal":
			for affected_index in affected:
				var heal_target: Dictionary = working.units[affected_index]
				var amount := int(round(float(attacker.stats.magicAttack) * float(effect.get("power", 1.0))))
				working.units[affected_index].hp = min(int(heal_target.maxHp), int(heal_target.hp) + amount)
				events.append({"type": "healed", "sourceId": attacker_id, "targetId": heal_target.instanceId, "amount": amount})
		"status":
			for affected_index in affected:
				_apply_status(working, affected_index, effect.get("statusId", ""), attacker_id, events)
		"guard":
			working.units[attacker_index].guarded = true
			events.append({"type": "guard_started", "unitId": attacker_id})
		_: return _failure("skill effect is not implemented")
	_finish_action(working, attacker_index)
	_check_result(working, events)
	return {"ok": true}

func _skill_affected_targets(working: Dictionary, target_index: int, attacker_index: int, skill: Dictionary, effect: Dictionary) -> Array[int]:
	var target: Dictionary = working.units[target_index]
	var target_type: String = skill.get("targetType", "")
	var radius := max(0, int(effect.get("area", 0)))
	if radius == 0 or target_type not in ["enemy_area", "ally_area"]:
		return [target_index]
	var result: Array[int] = []
	for index in range(working.units.size()):
		var candidate: Dictionary = working.units[index]
		if not candidate.alive:
			continue
		var same_side := not _hostile(working.units[attacker_index], candidate)
		if (target_type == "enemy_area" and same_side) or (target_type == "ally_area" and not same_side):
			continue
		if abs(int(candidate.position.x) - int(target.position.x)) + abs(int(candidate.position.y) - int(target.position.y)) <= radius:
			result.append(index)
	return result

func _apply_status(working: Dictionary, target_index: int, status_id: String, source_id: String, events: Array) -> void:
	if status_id.is_empty() or not bundle.get("statuses", {}).has(status_id):
		return
	var target: Dictionary = working.units[target_index]
	var definition: Dictionary = bundle.statuses[status_id]
	var character: Dictionary = bundle.characters.get(target.get("characterId", ""), {})
	var class_data: Dictionary = bundle.classes.get(target.get("classId", character.get("classId", "")), {})
	var resistance := clampf(float(class_data.get("statusResistances", {}).get(status_id, 0.0)), 0.0, 1.0)
	if resistance > 0.0 and rng.randf() < resistance:
		events.append({"type": "status_resisted", "statusId": status_id, "targetId": target.instanceId, "resistance": resistance})
		return
	var statuses: Array = target.get("statuses", [])
	var found := false
	for index in range(statuses.size()):
		if statuses[index].get("id", "") == status_id:
			if definition.get("stackable", false):
				continue
			statuses[index]["turns"] = int(definition.get("duration", 1))
			statuses[index]["sourceId"] = source_id
			found = true
			break
	if not found:
		statuses.append({"id": status_id, "turns": int(definition.get("duration", 1)), "sourceId": source_id})
	working.units[target_index]["statuses"] = statuses
	_refresh_unit_stats(working.units[target_index])
	events.append({"type": "status_applied", "statusId": status_id, "targetId": target.instanceId, "sourceId": source_id})

func _advance_statuses(working: Dictionary, events: Array) -> void:
	for index in range(working.units.size()):
		if not working.units[index].alive:
			continue
		var statuses: Array = working.units[index].get("statuses", [])
		var remaining: Array = []
		for status in statuses:
			var definition: Dictionary = bundle.get("statuses", {}).get(status.get("id", ""), {})
			var tick: Dictionary = definition.get("tick", {})
			if tick.get("type", "") == "damage":
				var amount := max(1, int(tick.get("amount", 1)))
				working.units[index].hp = max(0, int(working.units[index].hp) - amount)
				events.append({"type": "status_tick", "statusId": status.get("id", ""), "targetId": working.units[index].instanceId, "amount": amount})
				if working.units[index].hp <= 0:
					working.units[index].alive = false
					events.append({"type": "unit_defeated", "unitId": working.units[index].instanceId})
			var turns_left := int(status.get("turns", 1)) - 1
			if turns_left > 0 and working.units[index].alive:
				status["turns"] = turns_left
				remaining.append(status)
		working.units[index]["statuses"] = remaining
		_refresh_unit_stats(working.units[index])
	_check_result(working, events)

func _refresh_unit_stats(unit: Dictionary) -> void:
	var character: Dictionary = bundle.characters.get(unit.get("characterId", ""), {})
	var class_data: Dictionary = bundle.classes.get(unit.get("classId", character.get("classId", "")), {})
	var old_max_hp := int(unit.get("maxHp", 1))
	var old_max_mp := int(unit.get("maxMp", 0))
	var old_hp := int(unit.get("hp", old_max_hp))
	var old_mp := int(unit.get("mp", old_max_mp))
	var stats := _apply_passives(_calculate_stats(character, class_data, int(unit.get("level", 1))), unit.get("skills", []))
	stats = _apply_equipment(stats, unit.get("equipmentIds", []), class_data.get("id", ""))
	for status in unit.get("statuses", []):
		var definition: Dictionary = bundle.get("statuses", {}).get(status.get("id", ""), {})
		for stat in definition.get("statModifiers", {}):
			if stats.has(stat):
				stats[stat] = int(stats[stat]) + int(definition.statModifiers[stat])
	unit["stats"] = stats
	unit["maxHp"] = int(stats.get("maxHp", old_max_hp))
	unit["maxMp"] = int(stats.get("maxMp", old_max_mp))
	unit["hp"] = min(int(unit.maxHp), old_hp + max(0, int(unit.maxHp) - old_max_hp))
	unit["mp"] = min(int(unit.maxMp), old_mp + max(0, int(unit.maxMp) - old_max_mp))

func _command_end_turn(working: Dictionary, events: Array) -> Dictionary:
	if working.phase != "ally":
		return _failure("not ally phase")
	working.phase = "enemy"
	events.append({"type": "phase_changed", "phase": "enemy"})
	# AI 是服务层策略，未来可替换成不同的 IEnemyPolicy，不进入渲染脚本。
	for index in range(working.units.size()):
		if working.units[index].alive and working.units[index].side == "enemy":
			_enemy_action(working, index, events)
			if working.mode != "playing":
				return {"ok": true}
	_advance_statuses(working, events)
	if working.mode != "playing":
		return {"ok": true}
	working.turn += 1
	working.phase = "ally"
	for unit in working.units:
		if unit.alive and unit.side != "enemy":
			unit.moved = false
			unit.acted = false
	_apply_terrain_recovery(working, events)
	working.eventLog.append("第 %d 回合开始，我方行动。" % working.turn)
	events.append({"type": "turn_started", "turn": working.turn, "phase": "ally"})
	_emit_story_events(working, "turn_start", {"turn": working.turn}, events)
	_check_result(working, events)
	return {"ok": true}

func _enemy_action(working: Dictionary, index: int, events: Array) -> void:
	var target_index := enemy_policy.select_target(working, index)
	if target_index < 0:
		target_index = _nearest_ally(working, index)
	if target_index < 0:
		return
	var enemy: Dictionary = working.units[index]
	var target: Dictionary = working.units[target_index]
	# Ready offensive/support skills are attempted before the ordinary attack.
	# The same target chosen by the policy is used for offensive skills so the
	# result stays deterministic and the AI does not silently retarget.
	if _enemy_try_skill(working, index, target_index, events):
		return
	if _in_attack_range(enemy, target):
		_apply_damage(working, index, target_index, "physical" if enemy.classId != "mage" and enemy.classId != "healer" else "magic", 1.0, 0, events)
		_finish_action(working, index)
		_check_result(working, events)
		return
	var movement := _find_enemy_move_path(working, index, target_index)
	var path: Array = movement.get("path", [])
	if path.size() > 1:
		var from_position: Vector2i = path[0]
		var destination: Vector2i = path[path.size() - 1]
		working.units[index].position = {"x": destination.x, "y": destination.y}
		events.append({
			"type": "enemy_move",
			"unitId": enemy.instanceId,
			"targetId": target.instanceId,
			"from": {"x": from_position.x, "y": from_position.y},
			"to": {"x": destination.x, "y": destination.y},
			"path": _path_to_dicts(path),
			"cost": int(movement.get("cost", 0)),
			"targetDistance": int(movement.get("targetDistance", _distance(working.units[index], target)))
		})
	elif not path.is_empty():
		# Keep a blocked/no-budget result observable in a replay without making
		# the regular adjacent attack trace noisy.
		events.append({
			"type": "enemy_move",
			"unitId": enemy.instanceId,
			"targetId": target.instanceId,
			"from": _position_to_dict(path[0]),
			"to": _position_to_dict(path[0]),
			"path": _path_to_dicts(path),
			"cost": int(movement.get("cost", 0)),
			"targetDistance": int(movement.get("targetDistance", _distance(enemy, target))),
			"moved": false
		})
	working.units[index].moved = true
	if _enemy_try_skill(working, index, target_index, events):
		return
	if _in_attack_range(working.units[index], working.units[target_index]):
		_apply_damage(working, index, target_index, "physical" if enemy.classId != "mage" and enemy.classId != "healer" else "magic", 1.0, 0, events)
	_finish_action(working, index)

func _enemy_try_skill(working: Dictionary, enemy_index: int, policy_target_index: int, events: Array) -> bool:
	var enemy: Dictionary = working.units[enemy_index]
	for skill in enemy.get("skills", []):
		if skill.get("type", "") != "active" or skill.get("implementation", "planned") != "ready":
			continue
		var mp_cost := int(skill.get("mpCost", 0))
		if int(enemy.get("mp", 0)) < mp_cost:
			continue
		var target_index := _enemy_skill_target(working, enemy_index, policy_target_index, skill)
		if target_index < 0:
			continue
		var target: Dictionary = working.units[target_index]
		var affected: Array[int] = _skill_affected_targets(working, target_index, enemy_index, skill, skill.get("effect", {}))
		if affected.is_empty():
			continue
		working.units[enemy_index].mp -= mp_cost
		var effect: Dictionary = skill.get("effect", {})
		match effect.get("type", ""):
			"damage":
				for affected_index in affected:
					_apply_damage(working, enemy_index, affected_index, effect.get("damageType", "physical"), float(effect.get("power", 1.0)), int(effect.get("hitBonus", 0)), events)
					if not effect.get("statusId", "").is_empty() and working.units[affected_index].alive:
						_apply_status(working, affected_index, effect.get("statusId", ""), enemy.instanceId, events)
			"heal":
				for affected_index in affected:
					var heal_target: Dictionary = working.units[affected_index]
					var amount := int(round(float(enemy.stats.magicAttack) * float(effect.get("power", 1.0))))
					var actual := mini(amount, int(heal_target.maxHp) - int(heal_target.hp))
					if actual > 0:
						working.units[affected_index].hp += actual
						events.append({"type": "healed", "sourceId": enemy.instanceId, "targetId": heal_target.instanceId, "amount": actual})
			"status":
				for affected_index in affected:
					_apply_status(working, affected_index, effect.get("statusId", ""), enemy.instanceId, events)
			_: 
				working.units[enemy_index].mp += mp_cost
				continue
		events.append({
			"type": "enemy_skill",
			"unitId": enemy.instanceId,
			"skillId": skill.get("id", ""),
			"targetId": target.instanceId,
			"targetType": skill.get("targetType", ""),
			"mpCost": mp_cost,
			"affectedIds": _unit_ids(working, affected)
		})
		_finish_action(working, enemy_index)
		_check_result(working, events)
		return true
	return false

func _enemy_skill_target(working: Dictionary, enemy_index: int, policy_target_index: int, skill: Dictionary) -> int:
	var enemy: Dictionary = working.units[enemy_index]
	var target_type: String = skill.get("targetType", "")
	if target_type in ["enemy_single", "enemy_area"]:
		if policy_target_index < 0 or policy_target_index >= working.units.size():
			return -1
		var target: Dictionary = working.units[policy_target_index]
		var min_range := int(skill.get("minRange", 0))
		var max_range := max(min_range, int(skill.get("maxRange", min_range)))
		if target.alive and _hostile(enemy, target) and _distance(enemy, target) >= min_range and _distance(enemy, target) <= max_range:
			return policy_target_index
		return -1
	if target_type in ["ally_single", "ally_area"]:
		var best := -1
		var best_ratio := 1.0
		var min_range := int(skill.get("minRange", 0))
		var max_range := max(min_range, int(skill.get("maxRange", min_range)))
		for index in range(working.units.size()):
			var candidate: Dictionary = working.units[index]
			if not candidate.alive or _hostile(enemy, candidate) or index == enemy_index:
				continue
			var distance := _distance(enemy, candidate)
			if distance < min_range or distance > max_range or int(candidate.hp) >= int(candidate.maxHp):
				continue
			var ratio := float(candidate.hp) / float(max(1, int(candidate.maxHp)))
			if ratio < best_ratio:
				best_ratio = ratio
				best = index
		return best
	# Self skills are intentionally left for the player command path in this
	# first AI slice; the enemy contract starts with offensive/support skills.
	return -1

func _unit_ids(working: Dictionary, indices: Array[int]) -> Array[String]:
	var result: Array[String] = []
	for index in indices:
		if index >= 0 and index < working.units.size():
			result.append(working.units[index].instanceId)
	return result

func _find_enemy_move_path(working: Dictionary, moving_index: int, target_index: int) -> Dictionary:
	var enemy: Dictionary = working.units[moving_index]
	var target: Dictionary = working.units[target_index]
	var start := Vector2i(int(enemy.position.x), int(enemy.position.y))
	var target_position := Vector2i(int(target.position.x), int(target.position.y))
	var movement_points := max(0, int(enemy.stats.get("move", 0)))
	var start_key := _position_key(start)
	var costs: Dictionary = {start_key: 0}
	var paths: Dictionary = {start_key: [start]}
	var open: Array = [{"position": start, "cost": 0}]

	# Dijkstra is sufficient here: terrain costs are positive and the board is
	# small. Every occupied tile is blocked, so an enemy cannot pass through a
	# friendly or hostile unit while searching for a destination.
	while not open.is_empty():
		var current_index := _lowest_path_cost_index(open)
		var current: Dictionary = open.pop_at(current_index)
		var current_position: Vector2i = current.position
		var current_key := _position_key(current_position)
		if int(current.cost) != int(costs.get(current_key, 999999)):
			continue
		for delta in DIRECTIONS:
			var next: Vector2i = current_position + delta
			if not _enemy_can_enter(next, moving_index, working):
				continue
			var next_cost := int(current.cost) + _terrain_move_cost(next, working)
			if next_cost > movement_points:
				continue
			var next_key := _position_key(next)
			if costs.has(next_key) and next_cost >= int(costs[next_key]):
				continue
			costs[next_key] = next_cost
			var next_path: Array = paths[current_key].duplicate()
			next_path.append(next)
			paths[next_key] = next_path
			open.append({"position": next, "cost": next_cost})

	var best_key := start_key
	for key in costs.keys():
		var candidate: Vector2i = _position_from_key(String(key))
		if candidate == start:
			continue
		if _enemy_destination_is_better(candidate, int(costs[key]), _position_from_key(best_key), int(costs[best_key]), target_position, enemy):
			best_key = String(key)
	var selected_path: Array = paths.get(best_key, [start]).duplicate()
	var destination: Vector2i = _position_from_key(best_key)
	return {
		"path": selected_path,
		"cost": int(costs.get(best_key, 0)),
		"targetDistance": abs(destination.x - target_position.x) + abs(destination.y - target_position.y)
	}

func _lowest_path_cost_index(open: Array) -> int:
	var best_index := 0
	for index in range(1, open.size()):
		var candidate: Dictionary = open[index]
		var best: Dictionary = open[best_index]
		if int(candidate.get("cost", 0)) < int(best.get("cost", 0)):
			best_index = index
	return best_index

func _enemy_destination_is_better(candidate: Vector2i, candidate_cost: int, current: Vector2i, current_cost: int, target: Vector2i, enemy: Dictionary) -> bool:
	var candidate_distance: int = abs(candidate.x - target.x) + abs(candidate.y - target.y)
	var current_distance: int = abs(current.x - target.x) + abs(current.y - target.y)
	var min_range := max(0, int(enemy.stats.get("minRange", 0)))
	var max_range := max(min_range, int(enemy.stats.get("maxRange", min_range)))
	var candidate_gap := _distance_to_attack_band(candidate_distance, min_range, max_range)
	var current_gap := _distance_to_attack_band(current_distance, min_range, max_range)
	if candidate_gap != current_gap:
		return candidate_gap < current_gap
	if candidate_distance != current_distance:
		return candidate_distance < current_distance
	if candidate_cost != current_cost:
		return candidate_cost < current_cost
	# Stable tie-breaker keeps replay traces deterministic across runs.
	if candidate.y != current.y:
		return candidate.y < current.y
	return candidate.x < current.x

func _distance_to_attack_band(distance: int, min_range: int, max_range: int) -> int:
	if distance < min_range:
		return min_range - distance
	if distance > max_range:
		return distance - max_range
	return 0

func _enemy_can_enter(position: Vector2i, moving_index: int, source_state: Dictionary) -> bool:
	if position.x < 0 or position.y < 0 or position.x >= int(battle.board.width) or position.y >= int(battle.board.height):
		return false
	var terrain_id: String = battle.board.tiles[position.y][position.x]
	if not bundle.terrains.get(terrain_id, {}).get("walkable", false):
		return false
	var occupant := _unit_at(position, source_state)
	return occupant < 0 or occupant == moving_index

func _position_key(position: Vector2i) -> String:
	return "%d,%d" % [position.x, position.y]

func _position_from_key(key: String) -> Vector2i:
	var parts: PackedStringArray = key.split(",")
	return Vector2i(int(parts[0]), int(parts[1]))

func _position_to_dict(position: Vector2i) -> Dictionary:
	return {"x": position.x, "y": position.y}

func _path_to_dicts(path: Array) -> Array:
	var result: Array = []
	for position in path:
		result.append(_position_to_dict(position))
	return result

func _apply_damage(working: Dictionary, attacker_index: int, target_index: int, damage_type: String, power: float, hit_bonus: int, events: Array) -> void:
	var attacker: Dictionary = working.units[attacker_index]
	var target: Dictionary = working.units[target_index]
	var attack_value := int(attacker.stats.magicAttack if damage_type == "magic" else attacker.stats.attack)
	var defense_value := int(target.stats.magicDefense if damage_type == "magic" else target.stats.defense)
	var target_terrain: Dictionary = _terrain_for_unit(target)
	defense_value += int(target_terrain.get("magicDefenseBonus" if damage_type == "magic" else "physicalDefenseBonus", 0))
	if target.guarded:
		defense_value = int(round(defense_value * 1.5))
	var accuracy := int(attacker.stats.hit) + hit_bonus + int(_terrain_for_unit(attacker).get("hitBonus", 0))
	var evasion := int(target.stats.evasion) + int(target_terrain.get("evasionBonus", 0))
	if accuracy < evasion and rng.randf() >= max(0.0, (100.0 + accuracy - evasion) / 100.0):
		events.append({"type": "missed", "attackerId": attacker.instanceId, "targetId": target.instanceId})
		return
	var amount := max(1, int(round(float(attack_value - defense_value) * power)))
	working.units[target_index].hp = max(0, int(target.hp) - amount)
	events.append({"type": "damaged", "attackerId": attacker.instanceId, "targetId": target.instanceId, "amount": amount, "damageType": damage_type})
	working.units[target_index].guarded = false
	if working.units[target_index].hp <= 0:
		working.units[target_index].alive = false
		events.append({"type": "unit_defeated", "unitId": target.instanceId})
		_award_combat_experience(working, attacker_index, target_index, damage_type, true, events)

func _award_combat_experience(working: Dictionary, attacker_index: int, target_index: int, damage_type: String, killed: bool, events: Array) -> void:
	var attacker: Dictionary = working.units[attacker_index]
	var target: Dictionary = working.units[target_index]
	if attacker.side == target.side:
		return
	var rules: Dictionary = bundle.get("progression", {}).get("combatExperience", {})
	var table: Dictionary = rules.get("magicAttack" if damage_type == "magic" else "physicalAttack", {})
	var level_delta := int(target.get("level", 1)) - int(attacker.get("level", 1))
	var amount := int(table.get("sameLevel", 8))
	if level_delta < 0:
		if damage_type == "magic":
			amount += int(floor(float(abs(level_delta)) / 2.0)) * int(table.get("targetLowerPerTwoLevels", -1))
		else:
			amount += abs(level_delta) * int(table.get("targetLowerPerLevel", -1))
	elif level_delta > 0:
		amount += level_delta * int(table.get("targetHigherPerLevel", 2 if damage_type != "magic" else 4))
	amount = clampi(amount, int(table.get("min", 1)), int(table.get("maxBeforeKillMultiplier", 100)))
	if killed:
		amount *= int(rules.get("killMultiplier", 4))
	_award_experience(working, attacker_index, amount, events)

func _award_experience(working: Dictionary, unit_index: int, amount: int, events: Array) -> void:
	if amount <= 0 or unit_index < 0 or unit_index >= working.units.size():
		return
	var unit: Dictionary = working.units[unit_index]
	if unit.side == "enemy":
		return
	var progression: Dictionary = bundle.get("progression", {})
	var max_level := max(1, int(progression.get("maxLevel", 50)))
	var exp_to_level := max(1, int(progression.get("expToNextLevel", 100)))
	var before_level := int(unit.get("level", 1))
	var total := int(unit.get("exp", 0)) + amount
	var level := before_level
	while total >= exp_to_level and level < max_level:
		total -= exp_to_level
		level += 1
	if level >= max_level:
		total = min(total, exp_to_level - 1)
	unit["level"] = level
	unit["exp"] = total
	working.units[unit_index] = unit
	events.append({"type": "experience_gained", "unitId": unit.instanceId, "amount": amount, "level": level, "exp": total})
	if level > before_level:
		_recalculate_unit_stats(working.units[unit_index], before_level, level)
		events.append({"type": "unit_level_up", "unitId": unit.instanceId, "fromLevel": before_level, "toLevel": level})

func _recalculate_unit_stats(unit: Dictionary, _old_level: int, new_level: int) -> void:
	unit["level"] = new_level
	_refresh_unit_stats(unit)

func _apply_equipment(stats: Dictionary, equipment_ids: Array, class_id: String) -> Dictionary:
	var result: Dictionary = stats.duplicate(true)
	for equipment_id in equipment_ids:
		var equipment: Dictionary = bundle.get("equipment", {}).get(equipment_id, {})
		if equipment.is_empty() or (not equipment.get("allowedClasses", []).is_empty() and class_id not in equipment.get("allowedClasses", [])):
			continue
		var quality_factor := 1.0 + float(equipment.get("qualityBonusPercent", 0)) / 100.0
		for stat in equipment.get("statModifiers", {}):
			if result.has(stat):
				var modifier := int(round(float(equipment.statModifiers[stat]) * quality_factor))
				result[stat] = int(result[stat]) + modifier
	return result

func _validate_restored_state(saved_state: Dictionary) -> bool:
	if int(saved_state.get("schemaVersion", -1)) != 1:
		return false
	if saved_state.get("mode", "") not in ["playing", "victory", "defeat"]:
		return false
	var saved_units = saved_state.get("units", [])
	if not saved_units is Array or saved_units.is_empty():
		return false
	for unit in saved_units:
		if not unit is Dictionary or String(unit.get("instanceId", "")).is_empty():
			return false
		if not unit.has("position") or not unit.has("hp") or not unit.has("maxHp"):
			return false
		if unit.has("statuses") and not unit.get("statuses", []) is Array:
			return false
		for status in unit.get("statuses", []):
			if not status is Dictionary or not bundle.get("statuses", {}).has(status.get("id", "")):
				return false
	return true

func _check_result(working: Dictionary, events: Array) -> void:
	var outcome: Dictionary = objective_evaluator.evaluate(battle, working)
	var result: String = outcome.get("mode", "playing")
	if result == "playing":
		return
	working.mode = result
	# Terminal states expose their result as the phase as well, matching the
	# replay adapter and preventing a stale ally/enemy phase in replays.
	working.phase = result
	working.resultObjective = outcome.get("objective", {}).duplicate(true)
	events.append({"type": "battle_ended", "result": result, "objective": working.resultObjective.duplicate(true)})
	_emit_story_events(working, "battle_end", {"result": result}, events)

func _calculate_stats(character: Dictionary, class_data: Dictionary, level: int) -> Dictionary:
	var stats: Dictionary = class_data.get("baseStats", {}).duplicate(true)
	for stat in stats.keys():
		stats[stat] = int(stats[stat]) + _growth(class_data.get("growth", {}).get(stat, {}), level)
		stats[stat] = int(stats[stat]) + int(character.get("statModifiers", {}).get("base", {}).get(stat, 0))
		stats[stat] = int(stats[stat]) + _growth(character.get("statModifiers", {}).get("growth", {}).get(stat, {}), level)
	return stats

func _growth(rule: Dictionary, level: int) -> int:
	if rule.is_empty() or level < int(rule.get("firstAtLevel", 2)):
		return 0
	var every := max(1, int(rule.get("everyLevels", 1)))
	return int(floor(float(level - int(rule.get("firstAtLevel", 2))) / every) + 1) * int(rule.get("amount", 0))

func _apply_passives(stats: Dictionary, unit_skills: Array) -> Dictionary:
	var result: Dictionary = stats.duplicate(true)
	for skill in unit_skills:
		var effect: Dictionary = skill.get("effect", {})
		if skill.get("implementation", "planned") == "ready" and skill.get("type", "") == "passive" and effect.get("type", "") == "stat_add" and result.has(effect.get("stat", "")):
			var stat: String = effect.get("stat", "")
			if effect.get("mode", "flat") == "percent":
				result[stat] = round(float(result[stat]) * (1.0 + float(effect.get("value", 0)) / 100.0))
			else:
				result[stat] += int(effect.get("value", 0))
	return result

func _reachable_for(index: int, source_state: Dictionary) -> Array[Vector2i]:
	var old_state := state
	state = source_state
	var result := reachable_tiles(source_state.units[index].instanceId)
	state = old_state
	return result

func _valid_ally_action(index: int, source_state: Dictionary) -> bool:
	return index >= 0 and index < source_state.units.size() and source_state.phase == "ally" and source_state.units[index].alive and source_state.units[index].side == "ally" and not source_state.units[index].acted

func _find_skill(unit: Dictionary, skill_id: String) -> Dictionary:
	for skill in unit.get("skills", []):
		if skill.get("id", "") == skill_id:
			return skill
	return {}

func _finish_action(source_state: Dictionary, index: int) -> void:
	source_state.units[index].moved = true
	source_state.units[index].acted = true

func _unit_index(unit_id: String, source_state: Dictionary = state) -> int:
	for index in range(source_state.units.size()):
		if source_state.units[index].instanceId == unit_id:
			return index
	return -1

func _unit_at(position: Vector2i, source_state: Dictionary) -> int:
	for index in range(source_state.units.size()):
		var unit: Dictionary = source_state.units[index]
		if unit.alive and int(unit.position.x) == position.x and int(unit.position.y) == position.y:
			return index
	return -1

func _can_traverse(position: Vector2i, moving_index: int, source_state: Dictionary) -> bool:
	if position.x < 0 or position.y < 0 or position.x >= int(battle.board.width) or position.y >= int(battle.board.height):
		return false
	var terrain_id: String = battle.board.tiles[position.y][position.x]
	if not bundle.terrains.get(terrain_id, {}).get("walkable", false):
		return false
	var occupant := _unit_at(position, source_state)
	if occupant < 0 or occupant == moving_index:
		return true
	return not _hostile(source_state.units[moving_index], source_state.units[occupant])

func _terrain_move_cost(position: Vector2i, source_state: Dictionary) -> int:
	var terrain_id: String = battle.board.tiles[position.y][position.x]
	return max(1, int(bundle.terrains.get(terrain_id, {}).get("moveCost", 1)))

func _terrain_for_unit(unit: Dictionary) -> Dictionary:
	var position: Dictionary = unit.get("position", {})
	var x := int(position.get("x", -1))
	var y := int(position.get("y", -1))
	if y < 0 or y >= battle.get("board", {}).get("tiles", []).size():
		return {}
	var row: Array = battle.board.tiles[y]
	if x < 0 or x >= row.size():
		return {}
	return bundle.terrains.get(row[x], {})

func _apply_terrain_recovery(working: Dictionary, events: Array) -> void:
	for unit in working.units:
		if not unit.alive:
			continue
		var terrain: Dictionary = _terrain_for_unit(unit)
		var hp_restore := int(terrain.get("restoreHp", 0))
		var mp_restore := int(terrain.get("restoreMp", 0))
		if hp_restore <= 0 and mp_restore <= 0:
			continue
		var old_hp := int(unit.hp)
		var old_mp := int(unit.mp)
		unit.hp = min(int(unit.maxHp), old_hp + hp_restore)
		unit.mp = min(int(unit.maxMp), old_mp + mp_restore)
		if unit.hp != old_hp or unit.mp != old_mp:
			events.append({"type": "terrain_recovery", "unitId": unit.instanceId, "hp": unit.hp - old_hp, "mp": unit.mp - old_mp})

func _hostile(a: Dictionary, b: Dictionary) -> bool:
	return (a.side == "enemy") != (b.side == "enemy")

func _distance(a: Dictionary, b: Dictionary) -> int:
	return abs(int(a.position.x) - int(b.position.x)) + abs(int(a.position.y) - int(b.position.y))

func _in_attack_range(attacker: Dictionary, target: Dictionary) -> bool:
	var min_range := max(0, int(attacker.get("stats", {}).get("minRange", 0)))
	var max_range := max(min_range, int(attacker.get("stats", {}).get("maxRange", min_range)))
	var distance := _distance(attacker, target)
	return distance >= min_range and distance <= max_range

func _nearest_ally(source_state: Dictionary, enemy_index: int) -> int:
	var best := -1
	var best_distance := 99999
	for index in range(source_state.units.size()):
		if source_state.units[index].alive and source_state.units[index].side != "enemy":
			var distance := _distance(source_state.units[enemy_index], source_state.units[index])
			if distance < best_distance:
				best_distance = distance
				best = index
	return best

func _configure_enemy_policy() -> void:
	var policy_id: String = battle.get("rules", {}).get("aiPolicy", "aggressive")
	match policy_id:
		"ranged": enemy_policy = RangedPolicy.new()
		"protect": enemy_policy = ProtectPolicy.new()
		_: enemy_policy = AggressivePolicy.new()

func _emit_story_events(target_state: Dictionary, trigger: String, context: Dictionary, events: Array) -> void:
	var flags: Dictionary = target_state.get("storyFlags", {})
	var consumed: Array = target_state.get("consumedEventIds", [])
	for story_event in battle.get("events", []):
		if story_event.get("trigger", "") != trigger:
			continue
		var event_id: String = story_event.get("id", "%s-%s" % [trigger, story_event.get("text", "")])
		if event_id in consumed:
			continue
		if story_event.has("turn") and int(story_event.get("turn", 0)) != int(context.get("turn", -1)):
			continue
		if story_event.has("minTurn") and int(context.get("turn", 0)) < int(story_event.get("minTurn", 0)):
			continue
		if story_event.has("result") and story_event.get("result", "") != context.get("result", ""):
			continue
		var required_flags: Array = story_event.get("requiresFlags", [])
		var forbidden_flags: Array = story_event.get("forbiddenFlags", [])
		var has_required := true
		for required in required_flags:
			if not flags.get(required, false):
				has_required = false
				break
		if not has_required:
			continue
		var forbidden := false
		for blocked in forbidden_flags:
			if flags.get(blocked, false):
				forbidden = true
				break
		if forbidden:
			continue
		consumed.append(event_id)
		for flag in story_event.get("setFlags", []):
			_set_story_flag(target_state, flag)
		var text: String = story_event.get("text", "")
		target_state.eventLog.append(text)
		var emitted: Dictionary = {"type": "story_event", "eventId": event_id, "text": text}
		var choices: Array = story_event.get("choices", [])
		if not choices.is_empty():
			target_state.dialogue = {"active": true, "eventId": event_id, "speaker": story_event.get("speaker", ""), "text": text, "choices": choices.duplicate(true)}
			emitted["dialogue"] = target_state.dialogue.duplicate(true)
		events.append(emitted)
	target_state.storyFlags = flags
	target_state.consumedEventIds = consumed
	_sync_legacy_event_flags(target_state)

func _set_story_flag(target_state: Dictionary, flag: String) -> void:
	if flag.is_empty():
		return
	var flags: Dictionary = target_state.get("storyFlags", {})
	flags[flag] = true
	target_state.storyFlags = flags

func _sync_legacy_event_flags(target_state: Dictionary) -> void:
	var legacy: Array = []
	for event_id in target_state.get("consumedEventIds", []):
		legacy.append(event_id)
	for flag in target_state.get("storyFlags", {}).keys():
		if flag not in legacy:
			legacy.append(flag)
	target_state.eventFlags = legacy

func _migrate_story_flags(target_state: Dictionary) -> void:
	var story_flags: Dictionary = target_state.get("storyFlags", {})
	var consumed: Array = target_state.get("consumedEventIds", [])
	for legacy_flag in target_state.get("eventFlags", []):
		var is_event_id := false
		for story_event in battle.get("events", []):
			if story_event.get("id", "") == legacy_flag:
				is_event_id = true
				break
		if is_event_id:
			if legacy_flag not in consumed:
				consumed.append(legacy_flag)
		else:
			story_flags[legacy_flag] = true
	target_state.storyFlags = story_flags
	target_state.consumedEventIds = consumed
	_sync_legacy_event_flags(target_state)

func _failure(error_message: String) -> Dictionary:
	return {"ok": false, "error": error_message, "state": snapshot()}


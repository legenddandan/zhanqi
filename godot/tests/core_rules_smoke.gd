extends SceneTree

## 阶段 1 第一批核心规则 smoke：只覆盖现有数据字段和普通攻击射程边界。

const BattleService = preload("res://scripts/domain/BattleService.gd")
const DataRepository = preload("res://scripts/data/DataRepository.gd")
const ReplayService = preload("res://scripts/domain/ReplayService.gd")

func _init() -> void:
	var failures: Array[String] = []
	var repository = DataRepository.new()
	var loaded: Dictionary = repository.load_bundle("res://data")
	if not loaded.ok:
		failures.append("data bundle failed: %s" % loaded.errors)
	else:
		var bundle: Dictionary = loaded.bundle.duplicate(true)
		_test_terrain_move_cost(bundle, failures)
		_test_terrain_defense(bundle, failures)
		_test_terrain_recovery(bundle, failures)
		_test_attack_min_range(bundle, failures)
		_test_enemy_pathfinding(bundle, failures)
		_test_enemy_path_replay_trace(bundle, failures)
		_test_enemy_skill_contract(bundle, failures)
		_test_result_flows(bundle, failures)
	if failures.is_empty():
		print("[Core rules smoke] PASS: terrain cost, terrain defense/recovery, attack minRange, enemy pathfinding and enemy skill contract")
	else:
		for failure in failures:
			push_error("[Core rules smoke] " + failure)
	quit(1 if not failures.is_empty() else 0)

func _test_terrain_move_cost(bundle: Dictionary, failures: Array[String]) -> void:
	# 让步兵移动力为 2：林地（2）可进入，但再走一格平地已超预算。
	bundle.classes["infantry"].baseStats.move = 2
	var battle := _battle_definition(
		5,
		2,
		[["plain", "forest", "plain", "plain", "plain"], ["plain", "plain", "plain", "plain", "plain"]],
		[
			_unit("ally", "ally_infantry", "infantry-a", 0, 0),
			_unit("enemy", "enemy_infantry", "infantry-a", 4, 1)
		]
	)
	var service = _configured_service(bundle, battle)
	if service == null:
		failures.append("terrain move cost fixture failed to configure")
		return
	var reachable: Array[Vector2i] = service.reachable_tiles("ally_infantry")
	if Vector2i(1, 0) not in reachable:
		failures.append("forest tile with moveCost 2 was not reachable with two movement points")
	if Vector2i(2, 0) in reachable:
		failures.append("plain tile beyond forest move cost was incorrectly reachable")
	var rejected: Dictionary = service.execute({"type": "move", "unitId": "ally_infantry", "x": 2, "y": 0})
	if rejected.ok or service.snapshot().units[0].position != {"x": 0, "y": 0}:
		failures.append("illegal move through terrain cost changed state")
	var moved: Dictionary = service.execute({"type": "move", "unitId": "ally_infantry", "x": 1, "y": 0})
	if not moved.ok or service.snapshot().units[0].position != {"x": 1, "y": 0}:
		failures.append("legal move onto forest was not committed")

func _test_terrain_defense(bundle: Dictionary, failures: Array[String]) -> void:
	var plain_damage := _attack_damage(bundle, "plain")
	var village_damage := _attack_damage(bundle, "village")
	if plain_damage < 0 or village_damage < 0:
		failures.append("terrain defense fixture did not produce a damage event")
	elif village_damage >= plain_damage:
		failures.append("village physicalDefenseBonus did not reduce incoming damage")

func _attack_damage(bundle: Dictionary, target_terrain: String) -> int:
	var battle := _battle_definition(
		3,
		1,
		[["plain", target_terrain, "plain"]],
		[
			_unit("ally", "attacker", "infantry-a", 0, 0),
			_unit("enemy", "target", "infantry-a", 1, 0)
		]
	)
	var service = _configured_service(bundle, battle)
	if service == null:
		return -1
	service.state.units[0].moved = true
	var result: Dictionary = service.execute({"type": "attack", "attackerId": "attacker", "targetId": "target"})
	if not result.ok:
		return -1
	for event in result.get("events", []):
		if event.get("type", "") == "damaged":
			return int(event.get("amount", -1))
	return -1

func _test_terrain_recovery(bundle: Dictionary, failures: Array[String]) -> void:
	var battle := _battle_definition(
		5,
		3,
		[["village", "plain", "plain", "plain", "plain"], ["plain", "plain", "plain", "plain", "plain"], ["plain", "plain", "plain", "plain", "plain"]],
		[
			_unit("ally", "recovering_ally", "healer-a", 0, 0),
			_unit("enemy", "distant_enemy", "infantry-a", 4, 2)
		]
	)
	var service = _configured_service(bundle, battle)
	if service == null:
		failures.append("terrain recovery fixture failed to configure")
		return
	service.state.units[0].hp = 50
	service.state.units[0].mp = 0
	var result: Dictionary = service.execute({"type": "end_turn"})
	if not result.ok:
		failures.append("end turn for terrain recovery fixture failed")
		return
	var recovered: Dictionary = service.snapshot().units[0]
	if int(recovered.hp) != 58 or int(recovered.mp) != 4:
		failures.append("village recovery expected +8 HP/+4 MP, got %d HP/%d MP" % [recovered.hp - 50, recovered.mp])
	var recovery_event_found := false
	for event in result.get("events", []):
		if event.get("type", "") == "terrain_recovery" and event.get("unitId", "") == "recovering_ally":
			recovery_event_found = true
	if not recovery_event_found:
		failures.append("terrain recovery event was not emitted")

func _test_attack_min_range(bundle: Dictionary, failures: Array[String]) -> void:
	var battle := _battle_definition(
		4,
		1,
		[["plain", "plain", "plain", "plain"]],
		[
			_unit("ally", "archer", "archer-a", 0, 0),
			_unit("enemy", "near_enemy", "infantry-a", 1, 0),
			_unit("enemy", "far_enemy", "infantry-a", 2, 0)
		]
	)
	var service = _configured_service(bundle, battle)
	if service == null:
		failures.append("attack minRange fixture failed to configure")
		return
	service.state.units[0].moved = true
	var targets: Array[String] = service.attackable_targets("archer")
	if "near_enemy" in targets or "far_enemy" not in targets:
		failures.append("attackable_targets did not enforce archer minRange 2")
	var rejected: Dictionary = service.execute({"type": "attack", "attackerId": "archer", "targetId": "near_enemy"})
	if rejected.ok or service.snapshot().units[0].acted:
		failures.append("adjacent archer attack was accepted despite minRange 2")
	var accepted: Dictionary = service.execute({"type": "attack", "attackerId": "archer", "targetId": "far_enemy"})
	if not accepted.ok or not service.snapshot().units[0].acted:
		failures.append("in-range archer attack was rejected")

func _test_result_flows(bundle: Dictionary, failures: Array[String]) -> void:
	var victory_battle := _battle_definition(
		2,
		1,
		[["plain", "plain"]],
		[
			_unit("ally", "victory_attacker", "infantry-a", 0, 0),
			_unit("enemy", "victory_target", "infantry-a", 1, 0)
		]
	)
	var victory_service = _configured_service(bundle, victory_battle)
	if victory_service == null:
		failures.append("victory fixture failed to configure")
	else:
		victory_service.state.units[0].moved = true
		victory_service.state.units[1].hp = 1
		var victory: Dictionary = victory_service.execute({"type": "attack", "attackerId": "victory_attacker", "targetId": "victory_target"})
		if not victory.ok or victory_service.snapshot().get("mode", "playing") != "victory":
			failures.append("defeating the last enemy did not end the battle in victory")

	var defeat_battle := _battle_definition(
		2,
		1,
		[["plain", "plain"]],
		[
			_unit("ally", "defeat_target", "infantry-a", 0, 0),
			_unit("enemy", "defeat_attacker", "infantry-a", 1, 0)
		]
	)
	var defeat_service = _configured_service(bundle, defeat_battle)
	if defeat_service == null:
		failures.append("defeat fixture failed to configure")
	else:
		defeat_service.state.units[0].hp = 1
		var defeat: Dictionary = defeat_service.execute({"type": "end_turn"})
		if not defeat.ok or defeat_service.snapshot().get("mode", "playing") != "defeat":
			failures.append("enemy defeat of the last ally did not end the battle in defeat")

func _test_enemy_pathfinding(bundle: Dictionary, failures: Array[String]) -> void:
	# 1) 绕过不可通行格，并在移动力内选择离目标最近的可达格。
	var around_bundle: Dictionary = bundle.duplicate(true)
	around_bundle.classes["infantry"].baseStats.move = 4
	var around_battle := _battle_definition(
		5,
		3,
		[["plain", "plain", "wall", "plain", "plain"], ["plain", "plain", "wall", "plain", "plain"], ["plain", "plain", "plain", "plain", "plain"]],
		[
			_unit("enemy", "path_enemy", "infantry-a", 0, 1),
			_unit("ally", "path_target", "infantry-a", 4, 1)
		]
	)
	var around_service = _configured_service(around_bundle, around_battle)
	if around_service == null:
		failures.append("enemy path around obstacle fixture failed to configure")
	else:
		var around_result: Dictionary = around_service.execute({"type": "end_turn"})
		var around_enemy: Dictionary = around_service.snapshot().units[0]
		var around_event := _find_event(around_result.get("events", []), "enemy_move")
		if around_event.is_empty():
			failures.append("enemy path around obstacle did not emit movement event")
		else:
			if around_enemy.position == {"x": 0, "y": 1}:
				failures.append("enemy path around obstacle did not move")
			if around_event.get("to", {}) != {"x": 3, "y": 2} or around_event.get("path", []).size() != 5:
				failures.append("enemy path around obstacle did not choose the closest reachable detour")
			for step in around_event.get("path", []):
				var terrain_id: String = around_battle.board.tiles[int(step.y)][int(step.x)]
				if terrain_id == "wall":
					failures.append("enemy path entered a wall tile")
					break

	# 2) 移动成本必须计入预算，不能把森林当成平地。
	var cost_bundle: Dictionary = bundle.duplicate(true)
	cost_bundle.classes["infantry"].baseStats.move = 2
	var cost_battle := _battle_definition(
		4,
		1,
		[["plain", "forest", "plain", "plain"]],
		[
			_unit("enemy", "cost_enemy", "infantry-a", 0, 0),
			_unit("ally", "cost_target", "infantry-a", 3, 0)
		]
	)
	var cost_service = _configured_service(cost_bundle, cost_battle)
	if cost_service == null:
		failures.append("enemy terrain cost fixture failed to configure")
	else:
		var cost_result: Dictionary = cost_service.execute({"type": "end_turn"})
		var cost_event := _find_event(cost_result.get("events", []), "enemy_move")
		if cost_event.is_empty() or int(cost_event.get("cost", 0)) != 2:
			failures.append("enemy movement did not report forest moveCost 2")
		elif cost_event.get("to", {}) != {"x": 1, "y": 0}:
			failures.append("enemy movement exceeded terrain-cost budget")

	# 3) 目标被完全隔离时，敌方停在起点并记录不可达结果。
	var blocked_bundle: Dictionary = bundle.duplicate(true)
	blocked_bundle.classes["infantry"].baseStats.move = 3
	var blocked_battle := _battle_definition(
		3,
		3,
		[["plain", "wall", "plain"], ["wall", "wall", "plain"], ["plain", "plain", "plain"]],
		[
			_unit("enemy", "blocked_enemy", "infantry-a", 0, 0),
			_unit("ally", "blocked_target", "infantry-a", 2, 0)
		]
	)
	var blocked_service = _configured_service(blocked_bundle, blocked_battle)
	if blocked_service == null:
		failures.append("unreachable enemy path fixture failed to configure")
	else:
		var blocked_result: Dictionary = blocked_service.execute({"type": "end_turn"})
		var blocked_event := _find_event(blocked_result.get("events", []), "enemy_move")
		if blocked_service.snapshot().units[0].position != {"x": 0, "y": 0}:
			failures.append("unreachable enemy moved through an obstacle")
		if blocked_event.is_empty() or blocked_event.get("moved", true):
			failures.append("unreachable enemy did not report a blocked movement result")

	# 4) 另一个单位不能被当作路径节点穿过。
	var unit_block_bundle: Dictionary = bundle.duplicate(true)
	unit_block_bundle.classes["infantry"].baseStats.move = 3
	var unit_block_battle := _battle_definition(
		5,
		1,
		[["plain", "plain", "plain", "plain", "plain"]],
		[
			_unit("enemy", "unit_block_enemy", "infantry-a", 0, 0),
			_unit("enemy", "unit_blocker", "infantry-a", 1, 0),
			_unit("ally", "unit_block_target", "infantry-a", 4, 0)
		]
	)
	var unit_block_service = _configured_service(unit_block_bundle, unit_block_battle)
	if unit_block_service == null:
		failures.append("unit blocking fixture failed to configure")
	else:
		var unit_block_result: Dictionary = unit_block_service.execute({"type": "end_turn"})
		var unit_block_event := _find_event(unit_block_result.get("events", []), "enemy_move")
		if unit_block_service.snapshot().units[0].position != {"x": 0, "y": 0}:
			failures.append("enemy path passed through an occupied tile")
		if unit_block_event.is_empty() or unit_block_event.get("moved", true):
			failures.append("occupied path result was not reported as blocked")

func _find_event(events: Array, event_type: String) -> Dictionary:
	for event in events:
		if event.get("type", "") == event_type:
			return event
	return {}

func _test_enemy_path_replay_trace(bundle: Dictionary, failures: Array[String]) -> void:
	var replay_bundle: Dictionary = bundle.duplicate(true)
	replay_bundle.classes["infantry"].baseStats.move = 2
	var battle := _battle_definition(
		4,
		1,
		[["plain", "plain", "plain", "plain"]],
		[
			_unit("enemy", "trace_enemy", "infantry-a", 0, 0),
			_unit("ally", "trace_target", "infantry-a", 3, 0)
		]
	)
	var replay = ReplayService.new().replay(replay_bundle, battle, 424242, [{"type": "end_turn"}])
	if not replay.get("ok", false):
		failures.append("enemy path replay fixture failed: %s" % replay.get("error", "unknown error"))
		return
	var movement_found := false
	for entry in replay.get("trace", []):
		if not entry.has("enemyMovement"):
			continue
		movement_found = true
		var movement: Dictionary = entry.enemyMovement[0]
		if movement.get("path", []).size() < 2 or movement.get("to", {}) != {"x": 2, "y": 0}:
			failures.append("enemy path was not preserved in replay trace")
		break
	if not movement_found:
		failures.append("enemy movement path missing from replay trace")

func _test_enemy_skill_contract(bundle: Dictionary, failures: Array[String]) -> void:
	var skill_bundle: Dictionary = bundle.duplicate(true)
	var battle := _battle_definition(
		5,
		1,
		[["plain", "plain", "plain", "plain", "plain"]],
		[
			_unit("enemy", "skill_enemy", "mage-a", 0, 0),
			_unit("ally", "skill_target", "infantry-a", 2, 0)
		]
	)
	var service = _configured_service(skill_bundle, battle)
	if service == null:
		failures.append("enemy skill fixture failed to configure")
		return
	var before_mp := int(service.snapshot().units[0].mp)
	var before_hp := int(service.snapshot().units[1].hp)
	var result: Dictionary = service.execute({"type": "end_turn"})
	if not result.ok:
		failures.append("enemy skill turn failed: %s" % result.get("error", "unknown error"))
		return
	var skill_event := _find_event(result.get("events", []), "enemy_skill")
	if skill_event.is_empty() or skill_event.get("skillId", "") != "class_mage_flame":
		failures.append("enemy mage did not use the ready in-range flame skill")
	else:
		if int(service.snapshot().units[0].mp) != before_mp - 12:
			failures.append("enemy skill did not consume the declared MP cost")
		if int(service.snapshot().units[1].hp) >= before_hp:
			failures.append("enemy skill did not apply damage to its legal target")
		if skill_event.get("targetId", "") != "skill_target" or "skill_target" not in skill_event.get("affectedIds", []):
			failures.append("enemy skill event did not preserve target trace")

	var replay_battle := _battle_definition(
		5,
		1,
		[["plain", "plain", "plain", "plain", "plain"]],
		[
			_unit("enemy", "trace_skill_enemy", "mage-a", 0, 0),
			_unit("ally", "trace_skill_target", "infantry-a", 2, 0)
		]
	)
	var replay = ReplayService.new().replay(skill_bundle, replay_battle, 424242, [{"type": "end_turn"}])
	if not replay.get("ok", false):
		failures.append("enemy skill replay fixture failed: %s" % replay.get("error", "unknown error"))
	else:
		var trace_found := false
		for entry in replay.get("trace", []):
			if entry.has("enemySkill"):
				trace_found = true
				var traced: Dictionary = entry.enemySkill[0]
				if traced.get("skillId", "") != "class_mage_flame" or int(traced.get("mpCost", 0)) != 12:
					failures.append("enemy skill replay trace lost skill id or MP cost")
				break
		if not trace_found:
			failures.append("enemy skill replay trace was not emitted")

	var low_mp_service = _configured_service(skill_bundle, battle)
	if low_mp_service == null:
		failures.append("enemy low-MP fixture failed to configure")
	else:
		low_mp_service.state.units[0].mp = 0
		var low_mp_result: Dictionary = low_mp_service.execute({"type": "end_turn"})
		if not low_mp_result.ok or not _find_event(low_mp_result.get("events", []), "enemy_skill").is_empty():
			failures.append("enemy skill ignored MP availability")

	var range_bundle: Dictionary = bundle.duplicate(true)
	range_bundle.classes["mage"].baseStats.move = 1
	var range_battle := _battle_definition(
		8,
		1,
		[["plain", "plain", "plain", "plain", "plain", "plain", "plain", "plain"]],
		[
			_unit("enemy", "range_enemy", "mage-a", 0, 0),
			_unit("ally", "range_target", "infantry-a", 7, 0)
		]
	)
	var range_service = _configured_service(range_bundle, range_battle)
	if range_service == null:
		failures.append("enemy skill range fixture failed to configure")
	else:
		var range_before_mp := int(range_service.snapshot().units[0].mp)
		var range_result: Dictionary = range_service.execute({"type": "end_turn"})
		if not range_result.ok:
			failures.append("enemy skill range fixture failed: %s" % range_result.get("error", "unknown error"))
		elif not _find_event(range_result.get("events", []), "enemy_skill").is_empty():
			failures.append("enemy skill ignored its declared range")
		elif int(range_service.snapshot().units[0].mp) != range_before_mp:
			failures.append("out-of-range enemy skill consumed MP")

func _configured_service(bundle: Dictionary, battle: Dictionary):
	var service = BattleService.new()
	var configured: Dictionary = service.configure(bundle, battle, 424242)
	return service if configured.get("ok", false) else null

func _unit(side: String, instance_id: String, character_id: String, x: int, y: int) -> Dictionary:
	return {
		"instanceId": instance_id,
		"characterId": character_id,
		"displayName": instance_id,
		"side": side,
		"position": {"x": x, "y": y},
		"level": 1,
		"exp": 0
	}

func _battle_definition(width: int, height: int, tiles: Array, units: Array) -> Dictionary:
	return {
		"id": "core-rules-smoke",
		"name": "Core rules smoke",
		"board": {"width": width, "height": height, "tiles": tiles},
		"units": units,
		"objectives": {
			"victory": [{"type": "defeat_all", "side": "enemy"}],
			"defeat": [{"type": "all_units_dead", "side": "ally"}]
		},
		"rules": {
			"turnOrder": "ally_then_enemy",
			"allowFriendlyFire": false,
			"fogOfWar": false,
			"maxTurns": null,
			"aiPolicy": "aggressive",
			"carryOverHp": false
		}
	}

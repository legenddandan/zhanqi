extends RefCounted

const BattleService = preload("res://scripts/domain/BattleService.gd")

## 使用显式 seed 和命令日志重放战斗，用于回归测试和定位平衡问题。
func replay(data_bundle: Dictionary, battle_definition: Dictionary, seed: int, commands: Array) -> Dictionary:
	var service = BattleService.new()
	var started: Dictionary = service.configure(data_bundle, battle_definition, seed)
	if not started.ok:
		return started
	var trace: Array = [{"step": 0, "state": _summary(service.snapshot())}]
	for command in commands:
		var result: Dictionary = service.execute(command)
		if not result.ok:
			return {"ok": false, "error": result.get("error", "replay command failed"), "at": service.snapshot().get("commandLog", []).size()}
		var trace_entry: Dictionary = {
			"step": trace.size(),
			"command": command.duplicate(true),
			"state": _summary(result.get("state", service.snapshot()))
		}
		var enemy_movements := _enemy_movement_events(result.get("events", []))
		if not enemy_movements.is_empty():
			trace_entry["enemyMovement"] = enemy_movements
		var enemy_skills := _enemy_skill_events(result.get("events", []))
		if not enemy_skills.is_empty():
			trace_entry["enemySkill"] = enemy_skills
		trace.append(trace_entry)
	return {"ok": true, "state": service.snapshot(), "trace": trace}

func _enemy_movement_events(events: Array) -> Array:
	var result: Array = []
	for event in events:
		if event.get("type", "") != "enemy_move":
			continue
		result.append({
			"unitId": event.get("unitId", ""),
			"targetId": event.get("targetId", ""),
			"from": event.get("from", {}),
			"to": event.get("to", {}),
			"path": event.get("path", []),
			"cost": int(event.get("cost", 0)),
			"targetDistance": int(event.get("targetDistance", 0)),
			"moved": bool(event.get("moved", true))
		})
	return result

func _enemy_skill_events(events: Array) -> Array:
	var result: Array = []
	for event in events:
		if event.get("type", "") != "enemy_skill":
			continue
		result.append({
			"unitId": event.get("unitId", ""),
			"skillId": event.get("skillId", ""),
			"targetId": event.get("targetId", ""),
			"targetType": event.get("targetType", ""),
			"mpCost": int(event.get("mpCost", 0)),
			"affectedIds": event.get("affectedIds", [])
		})
	return result

## Replay smoke compares the stable fields exposed by the Godot runtime.
## Presentation logs, story flags and engine-specific RNG internals stay out of
## this summary until the two runtimes share those contracts.
func _summary(snapshot: Dictionary) -> Dictionary:
	var units: Array = []
	for unit in snapshot.get("units", []):
		var position: Dictionary = unit.get("position", {})
		units.append({
			"instanceId": unit.get("instanceId", ""),
			"side": unit.get("side", ""),
			"position": {"x": int(position.get("x", -1)), "y": int(position.get("y", -1))},
			"hp": int(unit.get("hp", 0)),
			"maxHp": int(unit.get("maxHp", 0)),
			"mp": int(unit.get("mp", 0)),
			"maxMp": int(unit.get("maxMp", 0)),
			"level": int(unit.get("level", 1)),
			"exp": int(unit.get("exp", 0)),
			"alive": bool(unit.get("alive", false)),
			"moved": bool(unit.get("moved", false)),
			"acted": bool(unit.get("acted", false))
		})
	return {
		"mode": snapshot.get("mode", ""),
		"phase": snapshot.get("phase", ""),
		"turn": int(snapshot.get("turn", 1)),
		"units": units
	}

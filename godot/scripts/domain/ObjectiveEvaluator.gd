extends RefCounted

## 关卡目标判定器：只读取 BattleDefinition 和 BattleState，不修改状态。
## 新增关卡目标时优先扩展这里，而不是把关卡分支塞进 BattleService。

func evaluate(battle: Dictionary, state: Dictionary) -> Dictionary:
	var objectives: Dictionary = battle.get("objectives", {})
	if objectives.is_empty():
		objectives = {"victory": [{"type": "defeat_all", "side": "enemy"}], "defeat": [{"type": "all_units_dead", "side": "ally"}]}
	for objective in objectives.get("defeat", []):
		if is_satisfied(objective, state):
			return {"mode": "defeat", "objective": objective.duplicate(true)}
	for objective in objectives.get("victory", []):
		if is_satisfied(objective, state):
			return {"mode": "victory", "objective": objective.duplicate(true)}
	var max_turns_value = battle.get("rules", {}).get("maxTurns", 0)
	var max_turns := 0 if max_turns_value == null else int(max_turns_value)
	if max_turns > 0 and int(state.get("turn", 1)) > max_turns:
		return {"mode": "defeat", "objective": {"type": "max_turns", "value": max_turns}}
	return {"mode": "playing", "objective": {}}

func is_satisfied(objective: Dictionary, state: Dictionary) -> bool:
	var objective_type: String = objective.get("type", "")
	match objective_type:
		"defeat_all", "all_units_dead":
			return _all_units_dead(state, objective.get("side", "enemy"))
		"defeat_unit":
			return _unit_dead(state, objective.get("unitId", ""))
		"protect_unit":
			return _unit_dead(state, objective.get("unitId", ""))
		"survive_turns":
			return int(state.get("turn", 1)) >= int(objective.get("turns", objective.get("value", 1)))
		"reach_tile":
			return _unit_on_tile(state, objective.get("unitId", ""), int(objective.get("x", -1)), int(objective.get("y", -1)))
		"capture_tile":
			return _side_on_tile(state, objective.get("side", "ally"), int(objective.get("x", -1)), int(objective.get("y", -1)))
		_:
			return false

func _all_units_dead(state: Dictionary, side: String) -> bool:
	var found := false
	for unit in state.get("units", []):
		if _unit_matches_side(unit, side):
			found = true
			if unit.get("alive", false):
				return false
	return found

func _unit_dead(state: Dictionary, unit_id: String) -> bool:
	if unit_id.is_empty():
		return false
	for unit in state.get("units", []):
		if unit.get("instanceId", "") == unit_id:
			return not unit.get("alive", false)
	return false

func _unit_on_tile(state: Dictionary, unit_id: String, x: int, y: int) -> bool:
	for unit in state.get("units", []):
		if unit.get("instanceId", "") == unit_id and unit.get("alive", false):
			var position: Dictionary = unit.get("position", {})
			return int(position.get("x", -1)) == x and int(position.get("y", -1)) == y
	return false

func _side_on_tile(state: Dictionary, side: String, x: int, y: int) -> bool:
	for unit in state.get("units", []):
		if unit.get("alive", false) and _unit_matches_side(unit, side):
			var position: Dictionary = unit.get("position", {})
			if int(position.get("x", -1)) == x and int(position.get("y", -1)) == y:
				return true
	return false

func _unit_matches_side(unit: Dictionary, side: String) -> bool:
	if side == "ally":
		return unit.get("side", "") != "enemy"
	return unit.get("side", "") == side

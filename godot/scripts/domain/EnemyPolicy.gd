extends RefCounted

## 敌方策略接口。策略只负责目标选择，移动/攻击执行仍由 BattleService 保证规则一致性。

func select_target(state: Dictionary, enemy_index: int) -> int:
	return -1

func _distance(a: Dictionary, b: Dictionary) -> int:
	return abs(int(a.get("position", {}).get("x", 0)) - int(b.get("position", {}).get("x", 0))) + abs(int(a.get("position", {}).get("y", 0)) - int(b.get("position", {}).get("y", 0)))

func _allies(state: Dictionary) -> Array[int]:
	var result: Array[int] = []
	for index in range(state.get("units", []).size()):
		var unit: Dictionary = state.units[index]
		if unit.get("alive", false) and unit.get("side", "") != "enemy":
			result.append(index)
	return result

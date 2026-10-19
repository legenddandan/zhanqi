extends "res://scripts/domain/EnemyPolicy.gd"

## 简单的压迫策略：优先攻击当前 HP 百分比最低的我方单位。
func select_target(state: Dictionary, enemy_index: int) -> int:
	var best := -1
	var best_ratio := 2.0
	for index in _allies(state):
		var target: Dictionary = state.units[index]
		var ratio := float(target.get("hp", 0)) / float(max(1, int(target.get("maxHp", 1))))
		if ratio < best_ratio:
			best_ratio = ratio
			best = index
	return best

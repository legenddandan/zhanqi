extends "res://scripts/domain/EnemyPolicy.gd"

## 远程单位优先攻击脆弱目标；无法攻击时仍向最近目标靠近。
func select_target(state: Dictionary, enemy_index: int) -> int:
	var best := -1
	var best_score := -INF
	var enemy: Dictionary = state.units[enemy_index]
	for index in _allies(state):
		var target: Dictionary = state.units[index]
		var distance := _distance(enemy, target)
		var max_hp: int = maxi(1, int(target.get("maxHp", 1)))
		var health_score := 1.0 - float(target.get("hp", 0)) / float(max_hp)
		var range_bonus := 1.0 if distance <= int(enemy.get("stats", {}).get("maxRange", 1)) else 0.0
		var score := health_score * 3.0 + range_bonus * 2.0 - float(distance) * 0.05
		if score > best_score:
			best_score = score
			best = index
	return best

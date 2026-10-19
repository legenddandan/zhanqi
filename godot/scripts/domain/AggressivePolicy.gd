extends "res://scripts/domain/EnemyPolicy.gd"

func select_target(state: Dictionary, enemy_index: int) -> int:
	var best := -1
	var best_distance := 99999
	var enemy: Dictionary = state.units[enemy_index]
	for index in _allies(state):
		var distance := _distance(enemy, state.units[index])
		if distance < best_distance:
			best_distance = distance
			best = index
	return best

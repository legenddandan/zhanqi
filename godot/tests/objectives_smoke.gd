extends SceneTree

const ObjectiveEvaluator = preload("res://scripts/domain/ObjectiveEvaluator.gd")

func _init() -> void:
	var evaluator = ObjectiveEvaluator.new()
	var battle := {
		"objectives": {
			"victory": [{"type": "reach_tile", "unitId": "hero", "x": 2, "y": 1}],
			"defeat": [{"type": "protect_unit", "unitId": "hero"}]
		},
		"rules": {"maxTurns": 4}
	}
	var state := {"turn": 1, "units": [
		{"instanceId": "hero", "side": "ally", "alive": true, "position": {"x": 0, "y": 1}},
		{"instanceId": "enemy", "side": "enemy", "alive": true, "position": {"x": 4, "y": 1}}
	]}
	var failures: Array[String] = []
	if evaluator.evaluate(battle, state).mode != "playing":
		failures.append("initial objective state should be playing")
	state.units[0].position = {"x": 2, "y": 1}
	if evaluator.evaluate(battle, state).mode != "victory":
		failures.append("reach_tile victory was not detected")
	state.units[0].position = {"x": 0, "y": 1}
	state.turn = 5
	if evaluator.evaluate(battle, state).mode != "defeat":
		failures.append("max_turns defeat was not detected")
	state.turn = 1
	state.units[0].alive = false
	if evaluator.evaluate(battle, state).mode != "defeat":
		failures.append("protect_unit defeat was not detected")
	if failures.is_empty():
		print("[Objectives smoke] PASS: victory, defeat and turn-limit objectives")
	else:
		for failure in failures:
			push_error("[Objectives smoke] " + failure)
	quit(1 if not failures.is_empty() else 0)

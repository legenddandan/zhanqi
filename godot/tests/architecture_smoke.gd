extends SceneTree

const GameSession = preload("res://scripts/app/GameSession.gd")
const SmokeStorage = preload("res://tests/smoke_storage.gd")

func _init() -> void:
	var failures: Array[String] = []
	var storage_dir := SmokeStorage.create("architecture")
	var session = GameSession.new("res://data", storage_dir)
	var initialized: Dictionary = session.initialize()
	if not initialized.ok:
		failures.append("repository validation failed: %s" % initialized.errors)
	else:
		var started: Dictionary = session.start_battle("yingchuan-01", 20261017, true)
		if not started.ok:
			failures.append("battle start failed: %s" % started)
		else:
			if session.snapshot().get("dialogue", {}).get("active", false):
				var opening_choice := session.dispatch({"type": "dialogue_choice", "choiceId": "hold_line"})
				if not opening_choice.ok:
					failures.append("opening dialogue choice failed")
			var before: Dictionary = session.snapshot()
			var first_id: String = before.units[0].instanceId
			var reachable: Array[Vector2i] = session.reachable_tiles(first_id)
			if reachable.is_empty():
				failures.append("reachable tile list is empty")
			else:
				var destination: Vector2i = reachable[reachable.size() - 1]
				var moved: Dictionary = session.dispatch({"type": "move", "unitId": first_id, "x": destination.x, "y": destination.y})
				if not moved.ok or not moved.state.units[0].moved:
					failures.append("move command was not committed")
			var stable_before: String = JSON.stringify(session.snapshot())
			var rejected: Dictionary = session.dispatch({"type": "move", "unitId": first_id, "x": -1, "y": -1})
			if rejected.ok or JSON.stringify(session.snapshot()) != stable_before:
				failures.append("invalid command changed state")
			var ended: Dictionary = session.dispatch({"type": "end_turn"})
			if not ended.ok:
				failures.append("end turn failed: %s" % ended.error)
			var saved: Dictionary = session.save_campaign("architecture-smoke", {"completedBattles": ["yingchuan-01"], "roster": {}, "gold": 100})
			if not saved.ok:
				failures.append("save failed: %s" % saved.error)
			else:
				var loaded: Dictionary = session.load_campaign("architecture-smoke")
				if not loaded.ok or not loaded.campaign.completedBattles.has("yingchuan-01"):
					failures.append("save round-trip failed")
	if failures.is_empty():
		print("[Architecture smoke] PASS: repository validation, transactional commands, enemy phase")
	else:
		for failure in failures:
			push_error("[Architecture smoke] " + failure)
	SmokeStorage.cleanup(storage_dir)
	quit(1 if not failures.is_empty() else 0)


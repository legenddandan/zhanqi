extends SceneTree

## 读取回放 smoke fixture，用 Godot 主线执行命令并输出稳定状态轨迹。

const DataRepository = preload("res://scripts/data/DataRepository.gd")
const ReplayService = preload("res://scripts/domain/ReplayService.gd")
const FIXTURE_PATH := "res://data/replays/replay-parity.json"

func _init() -> void:
	var failures: Array[String] = []
	var fixture_value = JSON.parse_string(FileAccess.get_file_as_string(FIXTURE_PATH))
	if fixture_value == null or not fixture_value is Dictionary:
		_fail_and_quit(["Godot replay smoke fixture is invalid JSON"])
		return
	var fixture: Dictionary = fixture_value
	var repository = DataRepository.new()
	var loaded: Dictionary = repository.load_bundle("res://data")
	if not loaded.get("ok", false):
		_fail_and_quit(["data bundle failed: %s" % loaded.get("errors", [])])
		return

	var output: Dictionary = {
		"version": int(fixture.get("version", 0)),
		"seed": int(fixture.get("seed", 1)),
		"scenarios": []
	}
	for scenario in fixture.get("scenarios", []):
		var replay = ReplayService.new()
		var result: Dictionary = replay.replay(
			loaded.get("bundle", {}),
			scenario.get("battle", {}),
			int(fixture.get("seed", 1)),
			scenario.get("commands", [])
		)
		if not result.get("ok", false):
			failures.append("%s: %s" % [scenario.get("id", ""), result.get("error", "replay failed")])
			continue
		output.scenarios.append({
			"id": scenario.get("id", ""),
			"trace": result.get("trace", [])
		})

	if not failures.is_empty():
		_fail_and_quit(failures)
		return
	print("PARITY_RESULT " + JSON.stringify(output))
	quit(0)

func _fail_and_quit(failures: Array[String]) -> void:
	for failure in failures:
		push_error("[Replay smoke Godot] " + failure)
	quit(1)

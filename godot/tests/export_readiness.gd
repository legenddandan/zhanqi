extends SceneTree

## 导出前静态门禁：不要求安装 export templates，也不伪造导出成功。

const DataRepository = preload("res://scripts/data/DataRepository.gd")

func _init() -> void:
	var failures: Array[String] = []
	if not FileAccess.file_exists("res://project.godot"):
		failures.append("project.godot is missing")
	if not ResourceLoader.exists("res://Campaign.tscn") or not ResourceLoader.exists("res://Main.tscn"):
		failures.append("main scenes are missing")
	var repository = DataRepository.new()
	var loaded: Dictionary = repository.load_bundle("res://data")
	if not loaded.ok:
		failures.append("data bundle failed: %s" % loaded.errors)
	else:
		for battle_id in ["yingchuan-01", "yingchuan-02"]:
			var battle := repository.load_battle("res://data", battle_id, loaded.bundle)
			if not battle.ok:
				failures.append("battle %s failed: %s" % [battle_id, battle.errors])
	if failures.is_empty():
		print("[Export readiness] PASS: project, scenes and data bundle are export-ready")
	else:
		for failure in failures:
			push_error("[Export readiness] " + failure)
	quit(1 if not failures.is_empty() else 0)

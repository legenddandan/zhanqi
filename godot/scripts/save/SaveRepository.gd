extends RefCounted

## 版本化、可恢复的单机存档仓库。存档只保存 campaign state，不保存临时渲染状态。

const SAVE_VERSION := 1
const SAVE_DIR := "user://saves"

func save_battle(slot: String, battle_id: String, battle_definition: Dictionary, battle_state: Dictionary, rng_seed: int) -> Dictionary:
	if not _valid_slot(slot) or battle_id.is_empty():
		return {"ok": false, "error": "invalid battle save arguments"}
	var payload := {"schemaVersion": SAVE_VERSION, "battleId": battle_id, "battle": battle_definition.duplicate(true), "state": battle_state.duplicate(true), "rngSeed": rng_seed}
	return _write_atomic("%s/%s.battle.json" % [SAVE_DIR, slot], payload)

func restore_battle_snapshot(slot: String, battle_id: String, battle_definition: Dictionary, battle_state: Dictionary, rng_seed: int) -> Dictionary:
	if not _valid_slot(slot) or battle_id.is_empty():
		return {"ok": false, "error": "invalid battle restore arguments"}
	var payload := {"schemaVersion": SAVE_VERSION, "battleId": battle_id, "battle": battle_definition.duplicate(true), "state": battle_state.duplicate(true), "rngSeed": rng_seed}
	return _write_atomic("%s/%s.battle.json" % [SAVE_DIR, slot], payload, false)

func load_battle(slot: String) -> Dictionary:
	if not _valid_slot(slot):
		return {"ok": false, "error": "invalid save slot"}
	var path := "%s/%s.battle.json" % [SAVE_DIR, slot]
	if not FileAccess.file_exists(path):
		return {"ok": true, "exists": false}
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	if parsed == null or not parsed is Dictionary:
		return _recover_battle_backup(path, "battle save is not valid JSON")
	if int(parsed.get("schemaVersion", -1)) != SAVE_VERSION:
		return _recover_battle_backup(path, "unsupported battle save schema version")
	if String(parsed.get("battleId", "")).is_empty() or not parsed.get("battle", {}) is Dictionary or not parsed.get("state", {}) is Dictionary or not _validate_battle_state(parsed.get("state", {})):
		return _recover_battle_backup(path, "battle save data failed validation")
	return {"ok": true, "exists": true, "battleId": parsed.battleId, "battle": parsed.battle, "state": parsed.state, "rngSeed": int(parsed.get("rngSeed", 1))}

func _recover_battle_backup(path: String, original_error: String) -> Dictionary:
	var backup_path := "%s.bak" % path
	if FileAccess.file_exists(backup_path):
		var backup = JSON.parse_string(FileAccess.get_file_as_string(backup_path))
		if backup is Dictionary and int(backup.get("schemaVersion", -1)) == SAVE_VERSION and String(backup.get("battleId", "")).is_empty() == false and backup.get("state", {}) is Dictionary and _validate_battle_state(backup.state):
			return {"ok": true, "exists": true, "battleId": backup.battleId, "battle": backup.get("battle", {}), "state": backup.state, "rngSeed": int(backup.get("rngSeed", 1)), "recovered": true}
	return {"ok": false, "error": original_error}

func clear_battle(slot: String) -> Dictionary:
	if not _valid_slot(slot):
		return {"ok": false, "error": "invalid save slot"}
	var path := "%s/%s.battle.json" % [SAVE_DIR, slot]
	if FileAccess.file_exists(path):
		var error := DirAccess.remove_absolute(path)
		if error != OK:
			return {"ok": false, "error": "cannot clear battle save: %s" % error}
	return {"ok": true}

func save_campaign(slot: String, campaign: Dictionary) -> Dictionary:
	if not _valid_slot(slot):
		return {"ok": false, "error": "invalid save slot"}
	var payload := {"schemaVersion": SAVE_VERSION, "campaign": campaign.duplicate(true)}
	return _write_atomic("%s/%s.json" % [SAVE_DIR, slot], payload)

func restore_campaign_snapshot(slot: String, campaign: Dictionary) -> Dictionary:
	if not _valid_slot(slot):
		return {"ok": false, "error": "invalid save slot"}
	var payload := {"schemaVersion": SAVE_VERSION, "campaign": campaign.duplicate(true)}
	return _write_atomic("%s/%s.json" % [SAVE_DIR, slot], payload, false)

func clear_campaign(slot: String) -> Dictionary:
	if not _valid_slot(slot):
		return {"ok": false, "error": "invalid save slot"}
	var path := "%s/%s.json" % [SAVE_DIR, slot]
	if FileAccess.file_exists(path):
		var error := DirAccess.remove_absolute(path)
		if error != OK:
			return {"ok": false, "error": "cannot clear campaign save: %s" % error}
	return {"ok": true}

func load_campaign(slot: String) -> Dictionary:
	if not _valid_slot(slot):
		return {"ok": false, "error": "invalid save slot"}
	var path := "%s/%s.json" % [SAVE_DIR, slot]
	if not FileAccess.file_exists(path):
		return {"ok": true, "exists": false, "campaign": _default_campaign()}
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	if parsed == null or not parsed is Dictionary:
		return _recover_campaign_backup(path, "save is not valid JSON")
	if int(parsed.get("schemaVersion", -1)) != SAVE_VERSION:
		return _recover_campaign_backup(path, "unsupported save schema version")
	var campaign: Dictionary = parsed.get("campaign", {})
	if not _validate_campaign(campaign):
		return _recover_campaign_backup(path, "save data failed validation")
	return {"ok": true, "exists": true, "campaign": campaign}

func _recover_campaign_backup(path: String, original_error: String) -> Dictionary:
	var backup_path := "%s.bak" % path
	if FileAccess.file_exists(backup_path):
		var backup = JSON.parse_string(FileAccess.get_file_as_string(backup_path))
		if backup is Dictionary and int(backup.get("schemaVersion", -1)) == SAVE_VERSION and _validate_campaign(backup.get("campaign", {})):
			return {"ok": true, "exists": true, "campaign": backup.campaign, "recovered": true}
	return {"ok": false, "error": original_error}

func _valid_slot(slot: String) -> bool:
	return not slot.is_empty() and not slot.contains("/") and not slot.contains("\\")

func _write_atomic(target: String, payload: Dictionary, keep_backup: bool = true) -> Dictionary:
	var directory := DirAccess.open("user://")
	if directory == null:
		return {"ok": false, "error": "cannot open user data directory"}
	directory.make_dir_recursive("saves")
	var temporary := "%s.tmp" % target
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null:
		return {"ok": false, "error": "cannot write temporary save"}
	file.store_string(JSON.stringify(payload, "\t"))
	file.close()
	if keep_backup and FileAccess.file_exists(target):
		var old_data := FileAccess.get_file_as_string(target)
		var backup_file := FileAccess.open("%s.bak" % target, FileAccess.WRITE)
		if backup_file != null:
			backup_file.store_string(old_data)
			backup_file.close()
	var rename_error := DirAccess.rename_absolute(temporary, target)
	if rename_error != OK:
		return {"ok": false, "error": "cannot commit save: %s" % rename_error}
	return {"ok": true, "path": target}

func _default_campaign() -> Dictionary:
	return {"schemaVersion": 1, "completedBattles": [], "roster": {}, "gold": 0}

func _validate_campaign(campaign: Dictionary) -> bool:
	if not campaign.has("completedBattles") or not campaign.has("roster") or not campaign.has("gold"):
		return false
	if not campaign.get("completedBattles") is Array or not campaign.get("roster") is Dictionary or int(campaign.get("gold", -1)) < 0:
		return false
	for instance_id in campaign.roster:
		var entry = campaign.roster[instance_id]
		if not entry is Dictionary or String(entry.get("instanceId", instance_id)).is_empty():
			return false
		if int(entry.get("level", 1)) < 1 or int(entry.get("exp", 0)) < 0:
			return false
		if int(entry.get("lastHp", 0)) < 0 or int(entry.get("lastMp", 0)) < 0:
			return false
		if int(entry.get("maxHp", 0)) < 0 or int(entry.get("maxMp", 0)) < 0:
			return false
		if entry.has("equipmentIds") and not entry.get("equipmentIds", []) is Array:
			return false
	if campaign.has("inventory") and not campaign.get("inventory", []) is Array:
		return false
	if campaign.has("inventoryCounts"):
		if not campaign.get("inventoryCounts", {}) is Dictionary:
			return false
		for equipment_id in campaign.inventoryCounts:
			if String(equipment_id).is_empty() or int(campaign.inventoryCounts[equipment_id]) < 0:
				return false
	if campaign.has("itemInventory"):
		if not campaign.get("itemInventory", {}) is Dictionary:
			return false
		for item_id in campaign.itemInventory:
			if int(campaign.itemInventory[item_id]) < 0:
				return false
	if campaign.has("formation"):
		if not campaign.formation is Array:
			return false
		for instance_id in campaign.formation:
			if not campaign.roster.has(instance_id):
				return false
	return true

func _validate_battle_state(state: Dictionary) -> bool:
	if int(state.get("schemaVersion", -1)) != SAVE_VERSION:
		return false
	if state.get("mode", "") not in ["playing", "victory", "defeat"] or not state.get("units", []) is Array or state.get("units", []).is_empty():
		return false
	var ids: Dictionary = {}
	for unit in state.get("units", []):
		if not unit is Dictionary or String(unit.get("instanceId", "")).is_empty():
			return false
		if ids.has(unit.instanceId):
			return false
		ids[unit.instanceId] = true
		var position: Dictionary = unit.get("position", {})
		if not position is Dictionary or int(position.get("x", -1)) < 0 or int(position.get("y", -1)) < 0:
			return false
		if int(unit.get("maxHp", 1)) < 1 or int(unit.get("hp", 0)) < 0 or int(unit.get("hp", 0)) > int(unit.get("maxHp", 1)):
			return false
	if state.has("storyFlags") and not state.get("storyFlags", {}) is Dictionary:
		return false
	if state.has("consumedEventIds") and not state.get("consumedEventIds", []) is Array:
		return false
	if state.has("commandLog") and not state.get("commandLog", []) is Array:
		return false
	return true


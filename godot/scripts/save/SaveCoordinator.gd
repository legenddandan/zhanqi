extends RefCounted

## 组合战役存档与战斗存档的最佳努力事务协调器。
## 两个文件仍保持向后兼容，但任一阶段失败都会恢复到调用前快照。

var repository

func _init(save_repository) -> void:
	repository = save_repository

func save_checkpoint(slot: String, campaign: Dictionary, battle_id: String, battle_definition: Dictionary, battle_state: Dictionary, rng_seed: int) -> Dictionary:
	var old_campaign: Dictionary = repository.load_campaign(slot)
	var old_battle: Dictionary = repository.load_battle(slot)
	var campaign_saved: Dictionary = repository.save_campaign(slot, campaign)
	if not campaign_saved.ok:
		return campaign_saved
	var battle_saved: Dictionary = repository.save_battle(slot, battle_id, battle_definition, battle_state, rng_seed)
	if battle_saved.ok:
		return {"ok": true, "campaign": campaign_saved, "battle": battle_saved}
	_restore_campaign(slot, old_campaign)
	_restore_battle(slot, old_battle)
	return {"ok": false, "error": "checkpoint failed: %s" % battle_saved.get("error", "battle save failed"), "rolledBack": true}

func clear_checkpoint(slot: String) -> Dictionary:
	var battle_result: Dictionary = repository.clear_battle(slot)
	if not battle_result.ok:
		return battle_result
	return {"ok": true}

func _restore_campaign(slot: String, previous: Dictionary) -> void:
	if previous.get("exists", false):
		repository.restore_campaign_snapshot(slot, previous.get("campaign", {}))
	else:
		repository.clear_campaign(slot)

func _restore_battle(slot: String, previous: Dictionary) -> void:
	if previous.get("exists", false):
		repository.restore_battle_snapshot(slot, previous.get("battleId", ""), previous.get("battle", {}), previous.get("state", {}), int(previous.get("rngSeed", 1)))
	else:
		repository.clear_battle(slot)

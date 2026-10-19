extends RefCounted

## 应用层组合根：数据、战斗领域服务和存档互相隔离。
## UI 只需要调用 start_battle/dispatch/snapshot，不接触 JSON 和规则细节。

const DataRepository = preload("res://scripts/data/DataRepository.gd")
const BattleService = preload("res://scripts/domain/BattleService.gd")
const SaveRepository = preload("res://scripts/save/SaveRepository.gd")
const SaveCoordinator = preload("res://scripts/save/SaveCoordinator.gd")
const CampaignService = preload("res://scripts/app/CampaignService.gd")

var data_repository = DataRepository.new()
var save_repository = SaveRepository.new()
var save_coordinator = SaveCoordinator.new(save_repository)
var battle_service = BattleService.new()
var campaign_service = CampaignService.new(save_repository, "res://data")
var data_root := "res://data"
var bundle: Dictionary = {}
var active_battle_id := ""
var active_battle: Dictionary = {}

func _init(root: String = "res://data") -> void:
	data_root = root

func initialize() -> Dictionary:
	var result: Dictionary = data_repository.load_bundle(data_root)
	if result.ok:
		bundle = result.bundle
		var first_battle_id := _first_catalog_battle_id()
		if first_battle_id.is_empty():
			return {"ok": false, "error": "battle catalog is empty"}
		var first_battle_result: Dictionary = data_repository.load_battle(data_root, first_battle_id, bundle)
		if not first_battle_result.ok:
			return first_battle_result
		var campaign_result: Dictionary = campaign_service.initialize(bundle, first_battle_result.battle)
		if not campaign_result.ok:
			return campaign_result
		var resumed := _restore_saved_battle()
		if not resumed.ok:
			return resumed
	return result

func new_campaign() -> Dictionary:
	if bundle.is_empty():
		var initialized := initialize()
		if not initialized.ok:
			return initialized
	var loaded: Dictionary = data_repository.load_battle(data_root, _first_catalog_battle_id(), bundle)
	if not loaded.ok:
		return loaded
	var result := campaign_service.new_campaign(loaded.battle)
	if result.ok:
		active_battle_id = ""
		active_battle = {}
		save_coordinator.clear_checkpoint("campaign-1")
	return result

func campaign_snapshot() -> Dictionary:
	return campaign_service.snapshot()

func campaign_catalog() -> Array:
	return campaign_service.catalog()

func start_battle(battle_id: String, seed: int = 1, force_restart: bool = false) -> Dictionary:
	if bundle.is_empty():
		var initialized := initialize()
		if not initialized.ok:
			return initialized
	if not active_battle_id.is_empty():
		if active_battle_id == battle_id and not force_restart:
			return {"ok": true, "resumed": true, "state": battle_service.snapshot()}
		if active_battle_id != battle_id:
			return {"ok": false, "error": "another battle is already in progress"}
		active_battle_id = ""
		active_battle = {}
		save_repository.clear_battle("campaign-1")
	var loaded: Dictionary = data_repository.load_battle(data_root, battle_id, bundle)
	if not loaded.ok:
		return loaded
	var prepared_battle: Dictionary = campaign_service.prepare_battle(loaded.battle)
	var previous_campaign: Dictionary = campaign_service.snapshot()
	var started: Dictionary = battle_service.configure(bundle, prepared_battle, seed)
	if started.ok:
		active_battle_id = battle_id
		active_battle = prepared_battle.duplicate(true)
		campaign_service.campaign.currentBattleId = battle_id
		var checkpoint := save_coordinator.save_checkpoint("campaign-1", campaign_service.snapshot(), battle_id, prepared_battle, battle_service.snapshot(), seed)
		if not checkpoint.ok:
			active_battle_id = ""
			active_battle = {}
			campaign_service.campaign = previous_campaign
			return checkpoint
		started["state"] = battle_service.snapshot()
	return started

func dispatch(command: Dictionary) -> Dictionary:
	var previous_state: Dictionary = battle_service.snapshot()
	var previous_campaign: Dictionary = campaign_service.snapshot()
	var consumed_item_id: String = command.get("itemId", "") if command.get("type", "") == "item" else ""
	if not consumed_item_id.is_empty() and campaign_service.item_count(consumed_item_id) <= 0:
		return {"ok": false, "error": "item is not available", "state": previous_state}
	var result := battle_service.execute(command)
	if result.ok and not active_battle_id.is_empty():
		if not consumed_item_id.is_empty():
			campaign_service.campaign.itemInventory[consumed_item_id] = campaign_service.item_count(consumed_item_id) - 1
		var checkpoint := save_coordinator.save_checkpoint("campaign-1", campaign_service.snapshot(), active_battle_id, active_battle, battle_service.snapshot(), int(battle_service.snapshot().get("rngSeed", 1)))
		if not checkpoint.ok:
			battle_service.restore(bundle, active_battle, previous_state, int(previous_state.get("rngSeed", 1)))
			campaign_service.campaign = previous_campaign
			return {"ok": false, "error": checkpoint.get("error", "checkpoint failed"), "state": previous_state, "rolledBack": true}
	return result

func snapshot() -> Dictionary:
	return battle_service.snapshot()

func current_battle() -> Dictionary:
	return active_battle.duplicate(true)

func finish_battle() -> Dictionary:
	if active_battle_id.is_empty():
		return {"ok": false, "error": "no active battle"}
	var result := campaign_service.commit_battle(active_battle_id, battle_service.snapshot(), active_battle)
	if result.ok:
		active_battle_id = ""
		active_battle = {}
		var cleared := save_coordinator.clear_checkpoint("campaign-1")
		if not cleared.ok:
			result["saveWarning"] = cleared.error
	return result

func has_active_battle() -> bool:
	return not active_battle_id.is_empty() and not battle_service.snapshot().is_empty()

func _restore_saved_battle() -> Dictionary:
	var saved := save_repository.load_battle("campaign-1")
	if not saved.ok or not saved.get("exists", false):
		return saved if not saved.ok else {"ok": true}
	var battle_id: String = saved.get("battleId", "")
	var restored := battle_service.restore(bundle, saved.get("battle", {}), saved.get("state", {}), int(saved.get("rngSeed", 1)))
	if not restored.ok:
		return restored
	active_battle_id = battle_id
	active_battle = saved.get("battle", {}).duplicate(true)
	return {"ok": true, "resumed": true}

func reorder_formation(first_id: String, second_id: String) -> Dictionary:
	return campaign_service.reorder_formation(first_id, second_id)

func equip_item(instance_id: String, equipment_id: String) -> Dictionary:
	return campaign_service.equip_item(instance_id, equipment_id)

func unequip_item(instance_id: String, equipment_id: String = "") -> Dictionary:
	return campaign_service.unequip_item(instance_id, equipment_id)

func available_advancements(instance_id: String) -> Array:
	return campaign_service.available_advancements(instance_id)

func advance_unit(instance_id: String, advancement_id: String) -> Dictionary:
	return campaign_service.advance_unit(instance_id, advancement_id)

func rest_at_camp(gold_cost_per_unit: int = 20) -> Dictionary:
	if has_active_battle():
		return {"ok": false, "error": "cannot rest during an active battle"}
	return campaign_service.rest_at_camp(gold_cost_per_unit)

func buy_item(item_id: String, quantity: int = 1) -> Dictionary:
	return campaign_service.buy_item(item_id, quantity)

func buy_equipment(equipment_id: String, quantity: int = 1) -> Dictionary:
	return campaign_service.buy_equipment(equipment_id, quantity)

func item_count(item_id: String) -> int:
	return campaign_service.item_count(item_id)

func equipment_count(equipment_id: String) -> int:
	return campaign_service.equipment_count(equipment_id)

func equipped_count(equipment_id: String) -> int:
	return campaign_service.equipped_count(equipment_id)

func reachable_tiles(unit_id: String) -> Array[Vector2i]:
	return battle_service.reachable_tiles(unit_id)

func attackable_targets(unit_id: String) -> Array[String]:
	return battle_service.attackable_targets(unit_id)

func skill_targets(unit_id: String, skill_id: String) -> Array[String]:
	return battle_service.skill_targets(unit_id, skill_id)

func save_campaign(slot: String, campaign: Dictionary) -> Dictionary:
	return save_repository.save_campaign(slot, campaign)

func load_campaign(slot: String) -> Dictionary:
	return save_repository.load_campaign(slot)

func _first_catalog_battle_id() -> String:
	var entries: Array = campaign_service.catalog()
	return entries[0].get("id", "") if not entries.is_empty() else ""


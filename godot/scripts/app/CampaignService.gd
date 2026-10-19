extends RefCounted

## 永久战役层：只保存跨关卡数据，不保存 BattleState 临时状态。

const SAVE_SLOT := "campaign-1"
const CAMPAIGN_VERSION := 1

var save_repository
var data_root := "res://data"
var bundle: Dictionary = {}
var campaign: Dictionary = {}

func _init(repository, root: String = "res://data") -> void:
	save_repository = repository
	data_root = root

func initialize(data_bundle: Dictionary, first_battle: Dictionary) -> Dictionary:
	bundle = data_bundle
	var loaded: Dictionary = save_repository.load_campaign(SAVE_SLOT)
	if not loaded.ok:
		return loaded
	if loaded.get("exists", false):
		campaign = loaded.campaign.duplicate(true)
		_migrate_campaign()
		return {"ok": true, "created": false, "campaign": snapshot()}
	campaign = _new_campaign(first_battle)
	return {"ok": true, "created": true, "campaign": snapshot()}

func new_campaign(first_battle: Dictionary) -> Dictionary:
	campaign = _new_campaign(first_battle)
	return save()

func snapshot() -> Dictionary:
	return campaign.duplicate(true)

func save() -> Dictionary:
	return save_repository.save_campaign(SAVE_SLOT, campaign)

func catalog() -> Array:
	var index_path := "%s/battles/index.json" % data_root
	if not FileAccess.file_exists(index_path):
		return []
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(index_path))
	if parsed == null or not parsed is Dictionary:
		return []
	return parsed.get("battles", [])

func prepare_battle(battle_definition: Dictionary) -> Dictionary:
	var prepared: Dictionary = battle_definition.duplicate(true)
	var formation: Array = campaign.get("formation", [])
	var ally_units: Array = []
	var positions: Array = []
	for unit in prepared.get("units", []):
		if unit.get("side", "") == "ally":
			ally_units.append(unit)
			positions.append(unit.get("position", {}).duplicate(true))
	var ordered: Array = []
	for instance_id in formation:
		for unit in ally_units:
			if unit.get("instanceId", "") == instance_id:
				ordered.append(unit)
	for unit in ally_units:
		if unit not in ordered:
			ordered.append(unit)
	for index in range(ordered.size()):
		var unit: Dictionary = ordered[index]
		var roster_entry: Dictionary = campaign.get("roster", {}).get(unit.get("instanceId", ""), {})
		if not roster_entry.is_empty():
			unit["classId"] = roster_entry.get("classId", unit.get("classId", character_class_id(unit.get("characterId", ""))))
			unit["level"] = int(roster_entry.get("level", unit.get("level", 1)))
			unit["exp"] = int(roster_entry.get("exp", unit.get("exp", 0)))
			unit["displayName"] = roster_entry.get("displayName", unit.get("displayName", ""))
			unit["equipmentIds"] = roster_entry.get("equipmentIds", []).duplicate()
			if battle_definition.get("rules", {}).get("carryOverHp", false) and int(roster_entry.get("lastHp", 0)) > 0:
				unit["initialHp"] = int(roster_entry.get("lastHp", 0))
				unit["initialMp"] = int(roster_entry.get("lastMp", 0))
		if index < positions.size():
			unit["position"] = positions[index].duplicate(true)
	return prepared

func equip_item(instance_id: String, equipment_id: String) -> Dictionary:
	var roster: Dictionary = campaign.get("roster", {})
	if not roster.has(instance_id):
		return {"ok": false, "error": "unit is not in roster"}
	if equipment_id not in campaign.get("inventory", []):
		return {"ok": false, "error": "equipment is not in inventory"}
	var equipment: Dictionary = bundle.get("equipment", {}).get(equipment_id, {})
	if equipment.is_empty():
		return {"ok": false, "error": "unknown equipment"}
	var entry: Dictionary = roster[instance_id]
	var equipment_ids: Array = entry.get("equipmentIds", []).duplicate()
	var already_equipped := equipment_id in equipment_ids
	if not already_equipped and equipment_count(equipment_id) <= equipped_count(equipment_id):
		return {"ok": false, "error": "all copies of this equipment are already equipped"}
	var class_id: String = entry.get("classId", "")
	var allowed: Array = equipment.get("allowedClasses", [])
	if not allowed.is_empty() and class_id not in allowed:
		return {"ok": false, "error": "equipment is not compatible with this class"}
	var slot: String = equipment.get("slot", "")
	for index in range(equipment_ids.size() - 1, -1, -1):
		var old: Dictionary = bundle.get("equipment", {}).get(equipment_ids[index], {})
		if old.get("slot", "") == slot:
			equipment_ids.remove_at(index)
	if equipment_id not in equipment_ids:
		equipment_ids.append(equipment_id)
	entry["equipmentIds"] = equipment_ids
	roster[instance_id] = entry
	campaign["roster"] = roster
	return save()

func unequip_item(instance_id: String, equipment_id: String = "") -> Dictionary:
	var roster: Dictionary = campaign.get("roster", {})
	if not roster.has(instance_id):
		return {"ok": false, "error": "unit is not in roster"}
	var entry: Dictionary = roster[instance_id]
	var equipment_ids: Array = entry.get("equipmentIds", []).duplicate()
	if equipment_id.is_empty():
		equipment_ids.clear()
	else:
		equipment_ids.erase(equipment_id)
	entry["equipmentIds"] = equipment_ids
	roster[instance_id] = entry
	campaign["roster"] = roster
	return save()

func available_advancements(instance_id: String) -> Array:
	var entry: Dictionary = campaign.get("roster", {}).get(instance_id, {})
	if entry.is_empty():
		return []
	var result: Array = []
	for advancement in bundle.get("advancements", {}).values():
		if advancement.get("fromClass", "") != entry.get("classId", ""):
			continue
		var item_id: String = advancement.get("itemId", "")
		var eligible := int(entry.get("level", 1)) >= int(advancement.get("requiredLevel", 1)) and int(campaign.get("gold", 0)) >= int(advancement.get("goldCost", 0))
		if not item_id.is_empty() and equipment_count(item_id) <= 0:
			eligible = false
		var option: Dictionary = advancement.duplicate(true)
		option["eligible"] = eligible
		result.append(option)
	return result

func advance_unit(instance_id: String, advancement_id: String) -> Dictionary:
	var roster: Dictionary = campaign.get("roster", {})
	if not roster.has(instance_id):
		return {"ok": false, "error": "unit is not in roster"}
	var advancement: Dictionary = bundle.get("advancements", {}).get(advancement_id, {})
	if advancement.is_empty():
		return {"ok": false, "error": "unknown advancement"}
	var entry: Dictionary = roster[instance_id]
	if entry.get("classId", "") != advancement.get("fromClass", ""):
		return {"ok": false, "error": "unit class cannot use this advancement"}
	if int(entry.get("level", 1)) < int(advancement.get("requiredLevel", 1)):
		return {"ok": false, "error": "unit level is too low"}
	var gold_cost := int(advancement.get("goldCost", 0))
	if int(campaign.get("gold", 0)) < gold_cost:
		return {"ok": false, "error": "not enough gold"}
	var item_id: String = advancement.get("itemId", "")
	if not item_id.is_empty() and equipment_count(item_id) <= 0:
		return {"ok": false, "error": "required advancement item is missing"}
	campaign["gold"] = int(campaign.get("gold", 0)) - gold_cost
	if not item_id.is_empty():
		_consume_equipment_item(item_id)
	entry["classId"] = advancement.get("toClass", "")
	entry["equipmentIds"] = _sanitize_equipment(entry.get("equipmentIds", []), entry.classId)
	roster[instance_id] = entry
	campaign["roster"] = roster
	return save()

func rest_at_camp(gold_cost_per_unit: int = 20) -> Dictionary:
	var wounded: Array = []
	for instance_id in campaign.get("roster", {}):
		var entry: Dictionary = campaign.roster[instance_id]
		var max_hp := int(entry.get("maxHp", 0))
		if max_hp > 0 and int(entry.get("lastHp", 0)) < max_hp:
			wounded.append(instance_id)
	if wounded.is_empty():
		return {"ok": true, "rested": 0, "cost": 0, "campaign": snapshot()}
	var cost: int = wounded.size() * maxi(0, gold_cost_per_unit)
	if int(campaign.get("gold", 0)) < cost:
		return {"ok": false, "error": "not enough gold for camp rest"}
	campaign.gold = int(campaign.get("gold", 0)) - cost
	for instance_id in wounded:
		campaign.roster[instance_id]["lastHp"] = int(campaign.roster[instance_id].get("maxHp", 0))
		campaign.roster[instance_id]["lastMp"] = int(campaign.roster[instance_id].get("maxMp", 0))
	var saved := save()
	if not saved.ok:
		return saved
	return {"ok": true, "rested": wounded.size(), "cost": cost, "campaign": snapshot()}

func item_count(item_id: String) -> int:
	return int(campaign.get("itemInventory", {}).get(item_id, 0))

func buy_item(item_id: String, quantity: int = 1) -> Dictionary:
	var previous_campaign := snapshot()
	var item: Dictionary = bundle.get("items", {}).get(item_id, {})
	var amount := maxi(1, quantity)
	if item.is_empty() or item.get("category", "") != "consumable":
		return {"ok": false, "error": "unknown consumable"}
	var cost := int(item.get("price", 0)) * amount
	if int(campaign.get("gold", 0)) < cost:
		return {"ok": false, "error": "not enough gold"}
	campaign.gold = int(campaign.get("gold", 0)) - cost
	var inventory: Dictionary = campaign.get("itemInventory", {})
	inventory[item_id] = int(inventory.get(item_id, 0)) + amount
	campaign.itemInventory = inventory
	var saved := save()
	if not saved.ok:
		campaign = previous_campaign
		return saved
	return {"ok": true, "itemId": item_id, "quantity": amount, "cost": cost, "campaign": snapshot()}

func equipment_count(equipment_id: String) -> int:
	var counts: Dictionary = campaign.get("inventoryCounts", {})
	if counts.has(equipment_id):
		return maxi(0, int(counts[equipment_id]))
	return 1 if equipment_id in campaign.get("inventory", []) else 0

func equipped_count(equipment_id: String) -> int:
	var total := 0
	for entry in campaign.get("roster", {}).values():
		if equipment_id in entry.get("equipmentIds", []):
			total += 1
	return total

func buy_equipment(equipment_id: String, quantity: int = 1) -> Dictionary:
	var previous_campaign := snapshot()
	var equipment: Dictionary = bundle.get("equipment", {}).get(equipment_id, {})
	var amount := maxi(1, quantity)
	if equipment.is_empty():
		return {"ok": false, "error": "unknown equipment"}
	var max_copies := int(equipment.get("maxCopies", 0))
	var owned := equipment_count(equipment_id)
	if max_copies > 0 and owned + amount > max_copies:
		return {"ok": false, "error": "equipment purchase exceeds copy limit"}
	var cost := int(equipment.get("price", 0)) * amount
	if int(campaign.get("gold", 0)) < cost:
		return {"ok": false, "error": "not enough gold"}
	campaign.gold = int(campaign.get("gold", 0)) - cost
	_add_equipment_copies(equipment_id, amount)
	var saved := save()
	if not saved.ok:
		campaign = previous_campaign
		return saved
	return {"ok": true, "equipmentId": equipment_id, "quantity": amount, "cost": cost, "campaign": snapshot()}

func commit_battle(battle_id: String, battle_state: Dictionary, battle_definition: Dictionary = {}) -> Dictionary:
	var result: String = battle_state.get("mode", "playing")
	if result == "playing":
		return {"ok": false, "error": "battle is still in progress"}
	if result == "victory":
		for unit in battle_state.get("units", []):
			if unit.get("side", "enemy") != "enemy" and campaign.get("roster", {}).has(unit.get("instanceId", "")):
				var entry: Dictionary = campaign.roster[unit.instanceId]
				entry["level"] = int(unit.get("level", entry.get("level", 1)))
				entry["exp"] = int(unit.get("exp", entry.get("exp", 0)))
				entry["lastHp"] = int(unit.get("hp", 0))
				entry["lastMp"] = int(unit.get("mp", 0))
				entry["maxHp"] = int(unit.get("maxHp", entry.get("maxHp", 0)))
				entry["maxMp"] = int(unit.get("maxMp", entry.get("maxMp", 0)))
				campaign.roster[unit.instanceId] = entry
		if battle_id not in campaign.completedBattles:
			campaign.completedBattles.append(battle_id)
			campaign.gold = int(campaign.get("gold", 0)) + int(battle_definition.get("rewards", {}).get("gold", 100))
			_unlock_battles(battle_id, battle_definition)
			for equipment_id in battle_definition.get("rewards", {}).get("equipmentIds", []):
				_add_equipment_copies(equipment_id, 1)
	campaign.lastResult = {"battleId": battle_id, "result": result, "turn": battle_state.get("turn", 0)}
	campaign.currentBattleId = ""
	var saved := save()
	if not saved.ok:
		return saved
	return {"ok": true, "campaign": snapshot()}

func reorder_formation(first_id: String, second_id: String) -> Dictionary:
	var formation: Array = campaign.get("formation", [])
	var first := formation.find(first_id)
	var second := formation.find(second_id)
	if first < 0 or second < 0:
		return {"ok": false, "error": "unit is not in formation"}
	var temp = formation[first]
	formation[first] = formation[second]
	formation[second] = temp
	campaign.formation = formation
	return save()

func _new_campaign(first_battle: Dictionary) -> Dictionary:
	var roster := {}
	var formation: Array = []
	for unit in first_battle.get("units", []):
		if unit.get("side", "") != "ally":
			continue
		var character: Dictionary = bundle.characters.get(unit.get("characterId", ""), {})
		var class_id: String = character.get("classId", "")
		roster[unit.get("instanceId", "")] = {
			"instanceId": unit.get("instanceId", ""),
			"characterId": unit.get("characterId", ""),
			"displayName": unit.get("displayName", ""),
			"classId": class_id,
			"level": int(unit.get("level", 1)),
			"exp": int(unit.get("exp", 0)),
			"lastHp": 0,
			"lastMp": 0,
			"maxHp": 0,
			"maxMp": 0,
			"equipmentIds": _starter_equipment(class_id),
		}
		formation.append(unit.get("instanceId", ""))
	return {
		"schemaVersion": CAMPAIGN_VERSION,
		"campaignId": "campaign-1",
		"completedBattles": [],
		"unlockedBattles": [first_battle.get("id", "")],
		"currentBattleId": "",
		"formation": formation,
		"roster": roster,
		"gold": 0,
		"inventory": ["iron_sword", "war_horse", "hunter_bow", "fire_talisman", "doctor_staff"],
		"inventoryCounts": {"iron_sword": 1, "war_horse": 1, "hunter_bow": 1, "fire_talisman": 1, "doctor_staff": 1},
		"itemInventory": {"healing_herb": 2, "mana_potion": 1, "antidote": 1},
		"flags": {},
		"lastResult": {},
	}

func _migrate_campaign() -> void:
	if not campaign.has("schemaVersion"):
		campaign.schemaVersion = CAMPAIGN_VERSION
	if not campaign.has("unlockedBattles"):
		campaign.unlockedBattles = []
	if not campaign.has("formation"):
		campaign.formation = campaign.roster.keys()
	if not campaign.has("flags"):
		campaign.flags = {}
	if not campaign.has("lastResult"):
		campaign.lastResult = {}
	if not campaign.has("inventory"):
		campaign.inventory = ["iron_sword", "war_horse", "hunter_bow", "fire_talisman", "doctor_staff"]
	if not campaign.has("inventoryCounts") or not campaign.inventoryCounts is Dictionary:
		campaign.inventoryCounts = {}
		for equipment_id in campaign.get("inventory", []):
			campaign.inventoryCounts[equipment_id] = int(campaign.inventoryCounts.get(equipment_id, 0)) + 1
	if not campaign.has("itemInventory") or not campaign.itemInventory is Dictionary:
		campaign.itemInventory = {"healing_herb": 2, "mana_potion": 1, "antidote": 1}
	else:
		var valid_items: Dictionary = {}
		for item_id in campaign.itemInventory:
			if bundle.get("items", {}).has(item_id) and int(campaign.itemInventory[item_id]) > 0:
				valid_items[item_id] = int(campaign.itemInventory[item_id])
		campaign.itemInventory = valid_items
	var valid_inventory: Array = []
	var valid_counts: Dictionary = {}
	for equipment_id in campaign.get("inventory", []):
		if bundle.get("equipment", {}).has(equipment_id):
			valid_counts[equipment_id] = maxi(1, int(campaign.inventoryCounts.get(equipment_id, 1)))
			if equipment_id not in valid_inventory:
				valid_inventory.append(equipment_id)
	for equipment_id in campaign.inventoryCounts:
		if bundle.get("equipment", {}).has(equipment_id) and int(campaign.inventoryCounts[equipment_id]) > 0:
			valid_counts[equipment_id] = int(campaign.inventoryCounts[equipment_id])
			if equipment_id not in valid_inventory:
				valid_inventory.append(equipment_id)
	campaign.inventory = valid_inventory
	campaign.inventoryCounts = valid_counts
	var used_equipment: Dictionary = {}
	for instance_id in campaign.get("roster", {}):
		if not campaign.roster[instance_id].has("classId"):
			var character: Dictionary = bundle.characters.get(campaign.roster[instance_id].get("characterId", ""), {})
			campaign.roster[instance_id]["classId"] = character.get("classId", "")
		elif not bundle.get("classes", {}).has(campaign.roster[instance_id].get("classId", "")):
			var fallback_character: Dictionary = bundle.characters.get(campaign.roster[instance_id].get("characterId", ""), {})
			campaign.roster[instance_id]["classId"] = fallback_character.get("classId", "")
		if not campaign.roster[instance_id].has("lastHp"):
			campaign.roster[instance_id]["lastHp"] = 0
		if not campaign.roster[instance_id].has("lastMp"):
			campaign.roster[instance_id]["lastMp"] = 0
		if not campaign.roster[instance_id].has("maxHp"):
			campaign.roster[instance_id]["maxHp"] = 0
		if not campaign.roster[instance_id].has("maxMp"):
			campaign.roster[instance_id]["maxMp"] = 0
		if not campaign.roster[instance_id].has("equipmentIds"):
			campaign.roster[instance_id]["equipmentIds"] = _starter_equipment(campaign.roster[instance_id].get("classId", ""))
		var valid_equipment: Array = []
		for equipment_id in campaign.roster[instance_id].get("equipmentIds", []):
			var owned := equipment_count(equipment_id)
			var used := int(used_equipment.get(equipment_id, 0))
			if equipment_id in campaign.inventory and equipment_id not in valid_equipment and used < owned:
				valid_equipment.append(equipment_id)
				used_equipment[equipment_id] = used + 1
		var sanitized_equipment := _sanitize_equipment(valid_equipment, campaign.roster[instance_id].get("classId", ""))
		campaign.roster[instance_id]["equipmentIds"] = sanitized_equipment
		for equipped_id in valid_equipment:
			if equipped_id not in sanitized_equipment:
				used_equipment[equipped_id] = maxi(0, int(used_equipment.get(equipped_id, 0)) - 1)

func _starter_equipment(class_id: String) -> Array:
	var by_class := {
		"infantry": ["iron_sword"],
		"cavalry": ["war_horse"],
		"archer": ["hunter_bow"],
		"mage": ["fire_talisman"],
		"healer": ["doctor_staff"],
	}
	return by_class.get(class_id, []).duplicate()

func _sanitize_equipment(equipment_ids: Array, class_id: String) -> Array:
	var result: Array = []
	var slots: Dictionary = {}
	for equipment_id in equipment_ids:
		var definition: Dictionary = bundle.get("equipment", {}).get(equipment_id, {})
		if definition.is_empty():
			continue
		var allowed: Array = definition.get("allowedClasses", [])
		var slot: String = definition.get("slot", "")
		if not allowed.is_empty() and class_id not in allowed:
			continue
		if slots.has(slot):
			continue
		slots[slot] = true
		result.append(equipment_id)
	return result

func character_class_id(character_id: String) -> String:
	return bundle.get("characters", {}).get(character_id, {}).get("classId", "")

func _add_equipment_copies(equipment_id: String, amount: int) -> void:
	if not bundle.get("equipment", {}).has(equipment_id) or amount <= 0:
		return
	var counts: Dictionary = campaign.get("inventoryCounts", {})
	counts[equipment_id] = int(counts.get(equipment_id, 0)) + amount
	campaign.inventoryCounts = counts
	if equipment_id not in campaign.get("inventory", []):
		campaign.inventory.append(equipment_id)

func _remove_equipment_copy(equipment_id: String) -> void:
	var counts: Dictionary = campaign.get("inventoryCounts", {})
	var remaining := maxi(0, int(counts.get(equipment_id, 0)) - 1)
	if remaining == 0:
		counts.erase(equipment_id)
		campaign.inventory.erase(equipment_id)
	else:
		counts[equipment_id] = remaining
	campaign.inventoryCounts = counts

func _consume_equipment_item(equipment_id: String) -> void:
	var free_copies := equipment_count(equipment_id) - equipped_count(equipment_id)
	if free_copies <= 0:
		for instance_id in campaign.get("roster", {}):
			var ids: Array = campaign.roster[instance_id].get("equipmentIds", []).duplicate()
			if equipment_id in ids:
				ids.erase(equipment_id)
				campaign.roster[instance_id]["equipmentIds"] = ids
				break
	_remove_equipment_copy(equipment_id)

func _unlock_next_battle(battle_id: String) -> void:
	var entries: Array = catalog()
	for index in range(entries.size()):
		if entries[index].get("id", "") == battle_id and index + 1 < entries.size():
			var next_id: String = entries[index + 1].get("id", "")
			if next_id not in campaign.unlockedBattles:
				campaign.unlockedBattles.append(next_id)

func _unlock_battles(battle_id: String, battle_definition: Dictionary) -> void:
	var explicit: Array = battle_definition.get("unlocks", [])
	if explicit.is_empty():
		var unlock_config = battle_definition.get("unlock", {})
		if unlock_config is Dictionary:
			explicit = unlock_config.get("battles", [])
	if not explicit.is_empty():
		for next_id in explicit:
			if next_id not in campaign.unlockedBattles:
				campaign.unlockedBattles.append(next_id)
		return
	_unlock_next_battle(battle_id)


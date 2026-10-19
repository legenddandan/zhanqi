extends RefCounted

## 唯一的数据入口。UI 和规则层不直接读取 JSON，所有外部数据先经过
## 解析、版本检查、引用检查和结构校验，避免坏存档/坏配置污染战斗状态。

@warning_ignore_start("inference_on_variant")

const SUPPORTED_DATA_VERSION := 1

func load_bundle(data_root: String) -> Dictionary:
	var result := {"ok": false, "errors": [], "warnings": [], "bundle": {}}
	var characters_result := _read_json("%s/characters.json" % data_root)
	var classes_result := _read_json("%s/classes.json" % data_root)
	var terrains_result := _read_json("%s/terrains.json" % data_root)
	var skills_result := _read_json("%s/skills.json" % data_root)
	var progression_result := _read_json("%s/progression.json" % data_root)
	var equipment_result := _read_json("%s/equipment.json" % data_root)
	var statuses_result := _read_json("%s/statuses.json" % data_root)
	var advancements_result := _read_json("%s/class_advancements.json" % data_root)
	var items_result := _read_json("%s/items.json" % data_root)
	for loaded in [characters_result, classes_result, terrains_result, skills_result, progression_result, equipment_result, statuses_result, advancements_result, items_result]:
		if not loaded.ok:
			result.errors.append(loaded.error)
	_validate_document_version(characters_result, "characters", result.errors)
	_validate_document_version(classes_result, "classes", result.errors)
	_validate_document_version(terrains_result, "terrains", result.errors)
	_validate_document_version(skills_result, "skills", result.errors)
	_validate_document_version(progression_result, "progression", result.errors)
	_validate_document_version(equipment_result, "equipment", result.errors)
	_validate_document_version(statuses_result, "statuses", result.errors)
	_validate_document_version(advancements_result, "class_advancements", result.errors)
	_validate_document_version(items_result, "items", result.errors)
	if not result.errors.is_empty():
		return result
	var bundle := {
		"characters": _index_by_id(characters_result.value.get("characters", []), "characters", result.errors),
		"classes": _index_by_id(classes_result.value.get("classes", []), "classes", result.errors),
		"terrains": _index_by_id(terrains_result.value.get("terrains", []), "terrains", result.errors),
		"skills": _index_by_id(skills_result.value.get("skills", []), "skills", result.errors),
		"progression": progression_result.value,
		"equipment": _index_by_id(equipment_result.value.get("equipment", []), "equipment", result.errors),
		"statuses": _index_by_id(statuses_result.value.get("statuses", []), "statuses", result.errors),
		"advancements": _index_by_id(advancements_result.value.get("advancements", []), "advancements", result.errors),
		"items": _index_by_id(items_result.value.get("items", []), "items", result.errors),
	}
	bundle["classes"] = _resolve_class_inheritance(bundle.classes, result.errors)
	_validate_references(bundle, result.errors)
	_validate_equipment(bundle, result.errors)
	_validate_items(bundle, result.errors)
	if result.errors.is_empty():
		result.ok = true
		result.bundle = bundle
	return result

func load_battle(data_root: String, battle_id: String, bundle: Dictionary) -> Dictionary:
	var result := {"ok": false, "errors": [], "battle": {}}
	var loaded := _read_json("%s/battles/%s.json" % [data_root, battle_id])
	if not loaded.ok:
		result.errors.append(loaded.error)
		return result
	var battle: Dictionary = loaded.value
	_validate_document_version(loaded, "battle:%s" % battle_id, result.errors)
	if battle.get("id", "") != battle_id:
		result.errors.append("battle id mismatch: expected %s" % battle_id)
	_validate_battle(battle, bundle, result.errors)
	if result.errors.is_empty():
		result.ok = true
		result.battle = battle
	return result

func calculate_stats(character: Dictionary, class_data: Dictionary, level: int) -> Dictionary:
	var stats: Dictionary = class_data.get("baseStats", {}).duplicate(true)
	var character_modifiers: Dictionary = character.get("statModifiers", {})
	var base_modifiers: Dictionary = character_modifiers.get("base", {})
	var growth_modifiers: Dictionary = character_modifiers.get("growth", {})
	for stat in stats.keys():
		stats[stat] = int(stats[stat]) + _growth_value(class_data.get("growth", {}).get(stat, {}), level)
		stats[stat] = int(stats[stat]) + int(base_modifiers.get(stat, 0))
		stats[stat] = int(stats[stat]) + _growth_value(growth_modifiers.get(stat, {}), level)
	return stats

func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {"ok": false, "error": "missing data file: %s" % path}
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	if parsed == null or not parsed is Dictionary:
		return {"ok": false, "error": "invalid JSON object: %s" % path}
	return {"ok": true, "value": parsed}

func _validate_document_version(loaded: Dictionary, label: String, errors: Array) -> void:
	if not loaded.get("ok", false):
		return
	var version = loaded.get("value", {}).get("version", null)
	if version == null or int(version) <= 0:
		errors.append("%s is missing a positive schema version" % label)

func _index_by_id(items: Array, label: String, errors: Array) -> Dictionary:
	var indexed := {}
	for item in items:
		if not item is Dictionary or String(item.get("id", "")) == "":
			errors.append("%s contains an item without id" % label)
			continue
		var id: String = item.get("id", "")
		if indexed.has(id):
			errors.append("duplicate %s id: %s" % [label, id])
		else:
			indexed[id] = item
	return indexed

func _validate_references(bundle: Dictionary, errors: Array) -> void:
	for character_id in bundle.characters:
		var character: Dictionary = bundle.characters[character_id]
		if not bundle.classes.has(character.get("classId", "")):
			errors.append("character %s references missing class %s" % [character_id, character.get("classId", "")])
		for skill_id in character.get("skillIds", []):
			if not bundle.skills.has(skill_id):
				errors.append("character %s references missing skill %s" % [character_id, skill_id])
	for class_id in bundle.classes:
		var class_data: Dictionary = bundle.classes[class_id]
		for skill_id in class_data.get("skillIds", []):
			if not bundle.skills.has(skill_id):
				errors.append("class %s references missing skill %s" % [class_id, skill_id])
	for skill_id in bundle.skills:
		var effect: Dictionary = bundle.skills[skill_id].get("effect", {})
		var status_id: String = effect.get("statusId", "")
		if not status_id.is_empty() and not bundle.statuses.has(status_id):
			errors.append("skill %s references missing status %s" % [skill_id, status_id])
	for advancement_id in bundle.advancements:
		var advancement: Dictionary = bundle.advancements[advancement_id]
		if not bundle.classes.has(advancement.get("fromClass", "")):
			errors.append("advancement %s references missing source class" % advancement_id)
		if not bundle.classes.has(advancement.get("toClass", "")):
			errors.append("advancement %s references missing target class" % advancement_id)
		var item_id: String = advancement.get("itemId", "")
		if not item_id.is_empty() and not bundle.equipment.has(item_id):
			errors.append("advancement %s references missing item %s" % [advancement_id, item_id])
	for item_id in bundle.items:
		var item: Dictionary = bundle.items[item_id]
		var effect: Dictionary = item.get("battleEffect", {})
		for status_id in effect.get("statusIds", []):
			if not bundle.statuses.has(status_id):
				errors.append("item %s references missing status %s" % [item_id, status_id])

func _validate_items(bundle: Dictionary, errors: Array) -> void:
	for item_id in bundle.items:
		var item: Dictionary = bundle.items[item_id]
		if int(item.get("price", 0)) < 0:
			errors.append("item %s has negative price" % item_id)

func _validate_equipment(bundle: Dictionary, errors: Array) -> void:
	for equipment_id in bundle.equipment:
		var equipment: Dictionary = bundle.equipment[equipment_id]
		if int(equipment.get("price", 0)) < 0:
			errors.append("equipment %s has negative price" % equipment_id)
		if int(equipment.get("maxCopies", 0)) < 0:
			errors.append("equipment %s has invalid maxCopies" % equipment_id)
		if float(equipment.get("qualityBonusPercent", 0)) < -100.0:
			errors.append("equipment %s has invalid quality bonus" % equipment_id)

func _resolve_class_inheritance(classes: Dictionary, errors: Array) -> Dictionary:
	var resolved: Dictionary = {}
	var resolving: Dictionary = {}
	for class_id in classes:
		_resolve_class(class_id, classes, resolved, resolving, errors)
	return resolved

func _resolve_class(class_id: String, classes: Dictionary, resolved: Dictionary, resolving: Dictionary, errors: Array) -> Dictionary:
	if resolved.has(class_id):
		return resolved[class_id]
	if not classes.has(class_id):
		errors.append("class %s is missing" % class_id)
		return {}
	if resolving.has(class_id):
		errors.append("class inheritance cycle at %s" % class_id)
		return classes[class_id]
	resolving[class_id] = true
	var current: Dictionary = classes[class_id].duplicate(true)
	var base_id: String = current.get("baseClass", "")
	if not base_id.is_empty():
		var base: Dictionary = _resolve_class(base_id, classes, resolved, resolving, errors)
		var merged: Dictionary = base.duplicate(true)
		merged.merge(current, true)
		current = merged
	resolved[class_id] = current
	resolving.erase(class_id)
	return current

func _validate_battle(battle: Dictionary, bundle: Dictionary, errors: Array) -> void:
	var board: Dictionary = battle.get("board", {})
	var width := int(board.get("width", 0))
	var height := int(board.get("height", 0))
	var tiles: Array = board.get("tiles", [])
	if width <= 0 or height <= 0 or tiles.size() != height:
		errors.append("battle %s has invalid board dimensions" % battle.get("id", ""))
		return
	for y in range(height):
		if not tiles[y] is Array or tiles[y].size() != width:
			errors.append("battle %s has invalid tile row %d" % [battle.get("id", ""), y])
			continue
		for terrain_id in tiles[y]:
			if not bundle.terrains.has(terrain_id):
				errors.append("battle %s references missing terrain %s" % [battle.get("id", ""), terrain_id])
	var ids := {}
	for unit in battle.get("units", []):
		if not unit is Dictionary:
			errors.append("battle %s contains a non-object unit" % battle.get("id", ""))
			continue
		var instance_id: String = unit.get("instanceId", "")
		if instance_id == "" or ids.has(instance_id):
			errors.append("battle %s has duplicate/empty instanceId" % battle.get("id", ""))
		else:
			ids[instance_id] = true
		if not bundle.characters.has(unit.get("characterId", "")):
			errors.append("unit %s references missing character" % instance_id)
		var side: String = unit.get("side", "")
		if side not in ["ally", "enemy", "friend"]:
			errors.append("unit %s has invalid side %s" % [instance_id, side])
		var position: Dictionary = unit.get("position", {})
		if int(position.get("x", -1)) < 0 or int(position.get("x", -1)) >= width or int(position.get("y", -1)) < 0 or int(position.get("y", -1)) >= height:
			errors.append("unit %s is outside board" % instance_id)
	for equipment_id in battle.get("rewards", {}).get("equipmentIds", []):
		if not bundle.equipment.has(equipment_id):
			errors.append("battle %s rewards missing equipment %s" % [battle.get("id", ""), equipment_id])
	for story_event in battle.get("events", []):
		if not story_event is Dictionary or String(story_event.get("id", "")).is_empty() or String(story_event.get("trigger", "")).is_empty():
			errors.append("battle %s contains invalid story event" % battle.get("id", ""))
	_validate_objectives(battle, errors)
	var max_turns_value = battle.get("rules", {}).get("maxTurns", 0)
	var max_turns := 0 if max_turns_value == null else int(max_turns_value)
	if max_turns < 0:
		errors.append("battle %s has invalid maxTurns" % battle.get("id", ""))
	if battle.has("unlocks") and not battle.get("unlocks", []) is Array:
		errors.append("battle %s unlocks must be an array" % battle.get("id", ""))
	if battle.get("rules", {}).has("aiPolicy") and String(battle.rules.get("aiPolicy", "")).is_empty():
		errors.append("battle %s has invalid aiPolicy" % battle.get("id", ""))

func _validate_objectives(battle: Dictionary, errors: Array) -> void:
	var objectives: Dictionary = battle.get("objectives", {})
	if not objectives is Dictionary:
		errors.append("battle %s objectives must be an object" % battle.get("id", ""))
		return
	for result in ["victory", "defeat"]:
		if not objectives.get(result, []) is Array:
			errors.append("battle %s %s objectives must be an array" % [battle.get("id", ""), result])
			continue
		for objective in objectives.get(result, []):
			if not objective is Dictionary or String(objective.get("type", "")).is_empty():
				errors.append("battle %s contains invalid %s objective" % [battle.get("id", ""), result])

func _growth_value(rule: Dictionary, level: int) -> int:
	if rule.is_empty() or level < int(rule.get("firstAtLevel", 2)):
		return 0
	var every := max(1, int(rule.get("everyLevels", 1)))
	return int(floor(float(level - int(rule.get("firstAtLevel", 2))) / every) + 1) * int(rule.get("amount", 0))


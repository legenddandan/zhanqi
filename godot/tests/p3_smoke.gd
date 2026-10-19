extends SceneTree

const GameSession = preload("res://scripts/app/GameSession.gd")

func _init() -> void:
	var failures: Array[String] = []
	var session = GameSession.new("res://data")
	var initialized: Dictionary = session.initialize()
	if not initialized.ok:
		failures.append("initialization failed")
	else:
		var unequipped := session.unequip_item("wei_archer_01", "hunter_bow")
		if not unequipped.ok:
			failures.append("equipment unequip failed")
		var equipped := session.equip_item("wei_archer_01", "hunter_bow")
		if not equipped.ok or "hunter_bow" not in session.campaign_snapshot().roster.wei_archer_01.equipmentIds:
			failures.append("equipment equip failed")
		var rejected_equipment := session.equip_item("wei_infantry_01", "fire_talisman")
		if rejected_equipment.ok:
			failures.append("class-incompatible equipment was accepted")
		session.campaign_service.campaign.gold = 500
		session.campaign_service.campaign.roster.wei_infantry_01.level = 3
		var advanced := session.advance_unit("wei_infantry_01", "infantry_guard")
		if not advanced.ok or session.campaign_snapshot().roster.wei_infantry_01.classId != "guard":
			failures.append("class advancement failed")
		var started := session.start_battle("yingchuan-01", 23, true)
		if not started.ok:
			failures.append("P3 battle start failed")
		else:
			var service = session.battle_service
			if not service.snapshot().dialogue.active:
				failures.append("opening dialogue was not created")
			else:
				var choice := session.dispatch({"type": "dialogue_choice", "choiceId": "press_attack"})
				if not choice.ok or "aggressive" not in service.snapshot().eventFlags:
					failures.append("dialogue choice did not set flag")
			var healer_index: int = service._unit_index("wei_healer_01")
			service.state.units[healer_index].hp = max(1, int(service.state.units[healer_index].maxHp) - 20)
			var item_result: Dictionary = session.dispatch({"type": "item", "unitId": "wei_healer_01", "targetId": "wei_healer_01", "itemId": "healing_herb"})
			if not item_result.ok or session.item_count("healing_herb") != 1:
				failures.append("consumable item command failed")
			var mage_index: int = service._unit_index("wei_mage_01")
			service.state.units[mage_index].position = {"x": 8, "y": 1}
			service.state.units[mage_index].moved = true
			service.state.units[5].position = {"x": 9, "y": 1}
			service.state.units[6].position = {"x": 9, "y": 2}
			if int(service.state.units[mage_index].stats.magicAttack) < 58:
				failures.append("equipment modifiers were not applied")
			var targets := session.skill_targets("wei_mage_01", "class_mage_burst")
			if targets.is_empty():
				failures.append("area skill has no targets")
			else:
				var used := session.dispatch({"type": "skill", "attackerId": "wei_mage_01", "targetId": targets[0], "skillId": "class_mage_burst"})
				if not used.ok:
					failures.append("area skill failed")
				var applied := false
				for unit in service.state.units:
					if unit.instanceId in targets and not unit.get("statuses", []).is_empty():
						applied = true
				if not applied:
					failures.append("status effect was not applied")
				var story_found := false
				for line in service.state.eventLog:
					if line is String and line.find("斥候") >= 0:
						story_found = true
				if not story_found:
					failures.append("battle story event was not emitted")
				var poisoned_hp := int(service.state.units[5].hp)
				var ended_turn := session.dispatch({"type": "end_turn"})
				if not ended_turn.ok or int(service.state.units[5].hp) >= poisoned_hp:
					failures.append("status tick did not apply damage")
				if "yingchuan-01-turn-2" not in service.snapshot().eventFlags:
					failures.append("conditional turn event was not emitted")
		if not session.new_campaign().ok:
			failures.append("test cleanup failed")
	if failures.is_empty():
		print("[P3 smoke] PASS: equipment, dialogue flags, advancement, area skill, status effect, conditional story")
	else:
		for failure in failures:
			push_error("[P3 smoke] " + failure)
	quit(1 if not failures.is_empty() else 0)

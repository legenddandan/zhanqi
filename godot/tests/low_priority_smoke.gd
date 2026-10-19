extends SceneTree

const GameSession = preload("res://scripts/app/GameSession.gd")

func _init() -> void:
	var failures: Array[String] = []
	var session = GameSession.new("res://data")
	var initialized: Dictionary = session.initialize()
	if not initialized.ok:
		failures.append("initialization failed")
	else:
		var campaign := session.campaign_snapshot()
		if int(campaign.get("inventoryCounts", {}).get("iron_sword", 0)) < 1:
			failures.append("equipment counts were not initialized")
		session.campaign_service.campaign.gold = 500
		var before := session.equipment_count("iron_sword")
		var bought := session.buy_equipment("iron_sword", 1)
		if not bought.ok or session.equipment_count("iron_sword") != before + 1:
			failures.append("equipment purchase did not increase quantity")
		var rejected := session.buy_equipment("iron_sword", 10)
		if rejected.ok:
			failures.append("equipment copy limit was not enforced")
		var loaded: Dictionary = session.data_repository.load_bundle("res://data")
		if not loaded.ok:
			failures.append("bundle reload failed")
		else:
			var mage: Dictionary = loaded.bundle.classes.get("mage", {})
			if mage.is_empty():
				failures.append("mage class missing")
		if not session.new_campaign().ok:
			failures.append("test cleanup failed")
	if failures.is_empty():
		print("[Low priority smoke] PASS: equipment quantities, shop purchase and copy limits")
	else:
		for failure in failures:
			push_error("[Low priority smoke] " + failure)
	quit(1 if not failures.is_empty() else 0)

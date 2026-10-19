extends Control

## 战役地图/编队入口。永久状态来自 GameApp.session，进入战斗时不复制一份私有存档。

@warning_ignore_start("inference_on_variant")

const InputController = preload("res://scripts/presentation/InputController.gd")

var session
var input_controller = InputController.new()
var campaign: Dictionary = {}
var message := ""
var button_rects: Dictionary = {}
var formation_selection := ""
var equipment_selection := ""
var shop_open := false
var cached_font: Font

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	cached_font = ThemeDB.fallback_font
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	session = GameApp.session
	if not GameApp.ensure_initialized():
		message = "数据加载失败，请检查 data/ 文件。"
	else:
		_refresh_campaign()
	add_child(input_controller)
	input_controller.pointer_pressed.connect(_on_pointer_pressed)
	input_controller.key_pressed.connect(_on_key_pressed)
	queue_redraw()

func _process(_delta: float) -> void:
	queue_redraw()

func _refresh_campaign() -> void:
	campaign = session.campaign_snapshot()
	if session.has_active_battle():
		message = "检测到未完成的战斗：%s，进入后将从上次进度继续。" % session.current_battle().get("name", session.snapshot().get("battleId", ""))
	elif message.is_empty():
		message = "选择关卡，或进入队伍编成。"

func _draw() -> void:
	var viewport: Vector2 = get_viewport_rect().size
	button_rects.clear()
	draw_rect(Rect2(Vector2.ZERO, viewport), Color("101522"))
	draw_rect(Rect2(0, 0, viewport.x, 70), Color("19243a"))
	draw_string(cached_font, Vector2(34, 44), "汉末烽火", HORIZONTAL_ALIGNMENT_LEFT, -1, 28, Color("f6d58b"))
	draw_string(cached_font, Vector2(220, 42), "单机战役", HORIZONTAL_ALIGNMENT_LEFT, -1, 18, Color("c7d2e8"))
	var x := 64.0
	var y := 122.0
	draw_string(cached_font, Vector2(x, y), "战役进度", HORIZONTAL_ALIGNMENT_LEFT, -1, 23, Color("f6d58b"))
	draw_string(cached_font, Vector2(x, y + 32), "金币：%d    装备：%d    已完成关卡：%d" % [campaign.get("gold", 0), _total_equipment_count(), campaign.get("completedBattles", []).size()], HORIZONTAL_ALIGNMENT_LEFT, -1, 15, Color("d6deef"))
	draw_string(cached_font, Vector2(x, y + 62), message, HORIZONTAL_ALIGNMENT_LEFT, 680, 14, Color("9fb1cf"))
	var new_rect := Rect2(viewport.x - 250, 92, 190, 40)
	button_rects["new_campaign"] = new_rect
	draw_rect(new_rect, Color("2d3b55"), true)
	draw_string(cached_font, new_rect.position + Vector2(0, 26), "新建/重置战役", HORIZONTAL_ALIGNMENT_CENTER, new_rect.size.x, 14, Color("d6deef"))
	var camp_rect := Rect2(viewport.x - 460, 92, 190, 40)
	button_rects["camp_rest"] = camp_rect
	draw_rect(camp_rect, Color("2d5a4b"), true)
	draw_string(cached_font, camp_rect.position + Vector2(0, 26), "营地休整（20金/人）", HORIZONTAL_ALIGNMENT_CENTER, camp_rect.size.x, 14, Color("d6deef"))
	var shop_rect := Rect2(viewport.x - 670, 92, 190, 40)
	button_rects["item_shop"] = shop_rect
	draw_rect(shop_rect, Color("5a4a2d"), true)
	draw_string(cached_font, shop_rect.position + Vector2(0, 26), "补给商店", HORIZONTAL_ALIGNMENT_CENTER, shop_rect.size.x, 14, Color("d6deef"))
	var cards: Array = session.campaign_catalog()
	for index in range(cards.size()):
		_draw_battle_card(x, 230.0 + index * 170.0, cards[index])
	_draw_roster(760.0, 112.0)
	if shop_open:
		_draw_shop(760.0, 440.0)
	else:
		_draw_equipment_panel(760.0, 440.0)
	_draw_footer(viewport)

func _draw_battle_card(x: float, y: float, entry: Dictionary) -> void:
	var battle_id: String = entry.get("id", "")
	var card := Rect2(x, y, 620, 145)
	draw_rect(card, Color("182237"), true)
	draw_rect(card, Color("3a4b69"), false, 1.0)
	draw_string(cached_font, Vector2(x + 26, y + 38), entry.get("name", battle_id), HORIZONTAL_ALIGNMENT_LEFT, -1, 20, Color("ffffff"))
	draw_string(cached_font, Vector2(x + 26, y + 68), entry.get("description", ""), HORIZONTAL_ALIGNMENT_LEFT, 560, 13, Color("b9c9e6"))
	var unlocked: bool = battle_id in campaign.get("unlockedBattles", [])
	var completed: bool = battle_id in campaign.get("completedBattles", [])
	draw_string(cached_font, Vector2(x + 26, y + 96), ("已完成" if completed else "已解锁") if unlocked else "未解锁", HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color("91d0a6") if unlocked else Color("77839a"))
	var battle_rect := Rect2(x + 350, y + 78, 240, 44)
	button_rects["start_battle:%s" % battle_id] = battle_rect
	draw_rect(battle_rect, Color("3b79a9") if unlocked else Color("3b4353"), true)
	var active_here: bool = session.has_active_battle() and session.snapshot().get("battleId", "") == battle_id
	draw_string(cached_font, battle_rect.position + Vector2(0, 30), "继续战斗" if active_here else ("进入战场" if unlocked else "未解锁"), HORIZONTAL_ALIGNMENT_CENTER, battle_rect.size.x, 16, Color("ffffff"))

func _draw_roster(x: float, y: float) -> void:
	draw_string(cached_font, Vector2(x, y), "队伍编成", HORIZONTAL_ALIGNMENT_LEFT, -1, 23, Color("f6d58b"))
	draw_string(cached_font, Vector2(x, y + 30), "点击两名单位交换出场顺序", HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color("8fa5c7"))
	var row_y := y + 62.0
	for instance_id in campaign.get("formation", []):
		var entry: Dictionary = campaign.get("roster", {}).get(instance_id, {})
		var equipment_names: Array[String] = []
		for equipment_id in entry.get("equipmentIds", []):
			equipment_names.append(session.bundle.get("equipment", {}).get(equipment_id, {}).get("name", equipment_id))
		var row := Rect2(x, row_y - 20, 420, 42)
		button_rects["formation:%s" % instance_id] = row
		draw_rect(row, Color("31527b") if instance_id == formation_selection else Color("1b2940"), true)
		draw_string(cached_font, row.position + Vector2(14, 27), "%s   Lv.%d   EXP %d/100   %s" % [entry.get("displayName", instance_id), entry.get("level", 1), entry.get("exp", 0), "、".join(equipment_names)], HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color("ffffff"))
		row_y += 52

func _draw_equipment_panel(x: float, y: float) -> void:
	if equipment_selection.is_empty():
		return
	var entry: Dictionary = campaign.get("roster", {}).get(equipment_selection, {})
	if entry.is_empty():
		return
	draw_string(cached_font, Vector2(x, y), "装备与进阶：%s" % entry.get("displayName", equipment_selection), HORIZONTAL_ALIGNMENT_LEFT, -1, 17, Color("f6d58b"))
	draw_string(cached_font, Vector2(x, y + 24), "点击装备名称更换；已装备条目可卸下", HORIZONTAL_ALIGNMENT_LEFT, 420, 12, Color("8fa5c7"))
	var row_y := y + 48.0
	for equipment_id in campaign.get("inventory", []):
		var equipment: Dictionary = session.bundle.get("equipment", {}).get(equipment_id, {})
		if equipment.is_empty():
			continue
		var rect := Rect2(x, row_y - 16, 320, 28)
		button_rects["equip:%s:%s" % [equipment_selection, equipment_id]] = rect
		draw_rect(rect, _rarity_color(equipment.get("rarity", "common")), true)
		var count_text := "×%d · 已装 %d" % [session.equipment_count(equipment_id), session.equipped_count(equipment_id)]
		draw_string(cached_font, rect.position + Vector2(8, 19), "%s  [%s]  %s" % [equipment.get("name", equipment_id), equipment.get("rarity", "common"), count_text], HORIZONTAL_ALIGNMENT_LEFT, rect.size.x - 16, 11, Color("ffffff"))
		row_y += 32
	for equipped_id in entry.get("equipmentIds", []):
		var rect := Rect2(x + 330, y + 32, 110, 28)
		button_rects["unequip:%s:%s" % [equipment_selection, equipped_id]] = rect
		draw_rect(rect, Color("704652"), true)
		draw_string(cached_font, rect.position + Vector2(4, 19), "卸下 %s" % session.bundle.get("equipment", {}).get(equipped_id, {}).get("name", equipped_id), HORIZONTAL_ALIGNMENT_CENTER, rect.size.x - 8, 10, Color("ffffff"))
	var options: Array = session.available_advancements(equipment_selection)
	if not options.is_empty():
		draw_string(cached_font, Vector2(x, row_y + 8), "可用进阶", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color("f6d58b"))
		row_y += 30
		for advancement in options:
			var advancement_id: String = advancement.get("id", "")
			var rect := Rect2(x, row_y - 16, 320, 28)
			button_rects["advance:%s:%s" % [equipment_selection, advancement_id]] = rect
			draw_rect(rect, Color("3b79a9") if advancement.get("eligible", false) else Color("3b4353"), true)
			draw_string(cached_font, rect.position + Vector2(8, 19), "%s  Lv.%d / %d金" % [advancement.get("name", advancement_id), advancement.get("requiredLevel", 1), advancement.get("goldCost", 0)], HORIZONTAL_ALIGNMENT_LEFT, rect.size.x - 16, 11, Color("ffffff") if advancement.get("eligible", false) else Color("7888a4"))
			row_y += 32

func _draw_shop(x: float, y: float) -> void:
	draw_string(cached_font, Vector2(x, y), "补给商店", HORIZONTAL_ALIGNMENT_LEFT, -1, 17, Color("f6d58b"))
	draw_string(cached_font, Vector2(x, y + 24), "购买消耗品与装备；装备受品质和复制上限约束", HORIZONTAL_ALIGNMENT_LEFT, 460, 12, Color("8fa5c7"))
	var row_y := y + 50.0
	for item_id in session.bundle.get("items", {}).keys():
		var item: Dictionary = session.bundle.items[item_id]
		var rect := Rect2(x, row_y - 16, 380, 30)
		button_rects["buy:%s" % item_id] = rect
		draw_rect(rect, Color("5a4a2d"), true)
		draw_string(cached_font, rect.position + Vector2(8, 20), "%s  %d金  库存 %d" % [item.get("name", item_id), item.get("price", 0), session.item_count(item_id)], HORIZONTAL_ALIGNMENT_LEFT, rect.size.x - 16, 12, Color("ffffff"))
		row_y += 36
	draw_string(cached_font, Vector2(x, row_y + 8), "装备", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color("f6d58b"))
	row_y += 30
	for equipment_id in session.bundle.get("equipment", {}).keys():
		var equipment: Dictionary = session.bundle.equipment[equipment_id]
		var max_copies := int(equipment.get("maxCopies", 0))
		var owned: int = session.equipment_count(equipment_id)
		var rect := Rect2(x, row_y - 16, 460, 30)
		button_rects["buy_equipment:%s" % equipment_id] = rect
		draw_rect(rect, _rarity_color(equipment.get("rarity", "common")), true)
		var limit_text := "上限 %d" % max_copies if max_copies > 0 else "不限"
		draw_string(cached_font, rect.position + Vector2(8, 20), "%s  [%s]  %d金  %d/%s" % [equipment.get("name", equipment_id), equipment.get("rarity", "common"), equipment.get("price", 0), owned, limit_text], HORIZONTAL_ALIGNMENT_LEFT, rect.size.x - 16, 11, Color("ffffff"))
		row_y += 36

func _draw_footer(viewport: Vector2) -> void:
	draw_string(cached_font, Vector2(64, viewport.y - 42), "Enter 进入战场   R 新建战役   点击编队条目交换顺序", HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color("778baa"))

func _on_pointer_pressed(position: Vector2) -> void:
	for key in button_rects:
		if not button_rects[key].has_point(position):
			continue
		if String(key).begins_with("start_battle:"):
			_start_battle(String(key).substr(13))
		elif key == "new_campaign":
			_new_campaign()
		elif key == "camp_rest":
			_rest_at_camp()
		elif key == "item_shop":
			shop_open = not shop_open
			equipment_selection = ""
			_refresh_campaign()
		elif String(key).begins_with("buy:"):
			_buy_item(String(key).substr(4))
		elif String(key).begins_with("buy_equipment:"):
			_buy_equipment(String(key).substr(14))
		elif String(key).begins_with("formation:"):
			_select_formation(String(key).substr(10))
		elif String(key).begins_with("equip:"):
			var parts := String(key).split(":")
			_equip(parts[1], parts[2])
		elif String(key).begins_with("unequip:"):
			var parts := String(key).split(":")
			_unequip(parts[1], parts[2])
		elif String(key).begins_with("advance:"):
			var parts := String(key).split(":")
			_advance(parts[1], parts[2])
		return

func _start_battle(battle_id: String = "yingchuan-01") -> void:
	var started: Dictionary = session.start_battle(battle_id, 20261017)
	if not started.ok:
		AudioManager.play_event("ui_error")
		message = "无法进入战场：%s" % started.get("error", "未知错误")
		return
	AudioManager.play_event("ui_confirm")
	get_tree().change_scene_to_file("res://Main.tscn")

func _new_campaign() -> void:
	var result: Dictionary = session.new_campaign()
	if result.ok:
		AudioManager.play_event("ui_confirm")
		_refresh_campaign()
		message = "已创建新战役，永久进度已保存。"
		formation_selection = ""
	else:
		AudioManager.play_event("ui_error")
		message = "创建失败：%s" % result.get("error", "未知错误")

func _rest_at_camp() -> void:
	var result: Dictionary = session.rest_at_camp()
	message = "营地休整完成，花费 %d 金。" % int(result.get("cost", 0)) if result.ok else "休整失败：%s" % result.get("error", "未知错误")
	AudioManager.play_event("ui_confirm" if result.ok else "ui_error")
	_refresh_campaign()

func _buy_item(item_id: String) -> void:
	var result: Dictionary = session.buy_item(item_id, 1)
	message = "已购买。" if result.ok else "购买失败：%s" % result.get("error", "未知错误")
	AudioManager.play_event("ui_confirm" if result.ok else "ui_error")
	_refresh_campaign()

func _buy_equipment(equipment_id: String) -> void:
	var result: Dictionary = session.buy_equipment(equipment_id, 1)
	message = "已购买装备。" if result.ok else "购买失败：%s" % result.get("error", "未知错误")
	AudioManager.play_event("ui_confirm" if result.ok else "ui_error")
	_refresh_campaign()

func _select_formation(instance_id: String) -> void:
	equipment_selection = instance_id
	if formation_selection.is_empty():
		formation_selection = instance_id
		message = "已选择 %s，再点击一名单位交换。" % campaign.get("roster", {}).get(instance_id, {}).get("displayName", instance_id)
	else:
		var result: Dictionary = session.reorder_formation(formation_selection, instance_id)
		message = "编队已保存。" if result.ok else "编队保存失败：%s" % result.get("error", "未知错误")
		formation_selection = ""
		_refresh_campaign()

func _equip(instance_id: String, equipment_id: String) -> void:
	var result: Dictionary = session.equip_item(instance_id, equipment_id)
	message = "已装备。" if result.ok else "装备失败：%s" % result.get("error", "未知错误")
	_refresh_campaign()

func _unequip(instance_id: String, equipment_id: String) -> void:
	var result: Dictionary = session.unequip_item(instance_id, equipment_id)
	message = "已卸下。" if result.ok else "卸下失败：%s" % result.get("error", "未知错误")
	_refresh_campaign()

func _advance(instance_id: String, advancement_id: String) -> void:
	var result: Dictionary = session.advance_unit(instance_id, advancement_id)
	message = "进阶成功。" if result.ok else "进阶失败：%s" % result.get("error", "未知错误")
	_refresh_campaign()

func _on_key_pressed(keycode: Key) -> void:
	if keycode == KEY_ENTER:
		_start_battle(_first_unlocked_battle())
	elif keycode == KEY_R:
		_new_campaign()

func _first_unlocked_battle() -> String:
	for entry in session.campaign_catalog():
		if entry.get("id", "") in campaign.get("unlockedBattles", []):
			return entry.get("id", "yingchuan-01")
	return "yingchuan-01"

func _total_equipment_count() -> int:
	var total := 0
	for amount in campaign.get("inventoryCounts", {}).values():
		total += int(amount)
	if total == 0:
		total = campaign.get("inventory", []).size()
	return total

func _rarity_color(rarity: String) -> Color:
	match rarity:
		"rare": return Color("31527b")
		"epic": return Color("67417d")
		"legendary": return Color("8a5e28")
		_: return Color("26354e")


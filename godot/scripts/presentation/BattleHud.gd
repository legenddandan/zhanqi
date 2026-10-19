extends Control

## 战斗 HUD：只显示快照，不直接修改领域状态。

@warning_ignore_start("inference_on_variant")

const PANEL_WIDTH := 360.0
var bundle: Dictionary = {}
var item_inventory: Dictionary = {}
var snapshot: Dictionary = {}
var message := ""
var selected_id := ""
var active_skill_id := ""
var button_rects: Dictionary = {}
var cached_font: Font

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	cached_font = ThemeDB.fallback_font

func configure(data_bundle: Dictionary, inventory: Dictionary = {}) -> void:
	bundle = data_bundle
	item_inventory = inventory.duplicate(true)
	queue_redraw()

func set_item_inventory(inventory: Dictionary) -> void:
	item_inventory = inventory.duplicate(true)
	queue_redraw()

func set_view_state(next_snapshot: Dictionary, next_message: String, next_selected_id: String, next_active_skill_id: String) -> void:
	snapshot = next_snapshot.duplicate(true)
	message = next_message
	selected_id = next_selected_id
	active_skill_id = next_active_skill_id
	queue_redraw()

func action_at(position: Vector2) -> String:
	for key in button_rects:
		if button_rects[key].has_point(position):
			return key
	return ""

func _process(_delta: float) -> void:
	queue_redraw()

func _draw() -> void:
	var viewport: Vector2 = get_viewport_rect().size
	var panel_x := viewport.x - PANEL_WIDTH - 24.0
	var panel_rect := Rect2(panel_x, 78, PANEL_WIDTH, viewport.y - 102)
	draw_rect(panel_rect, Color("182237"), true)
	draw_rect(panel_rect, Color("3a4b69"), false, 1.0)
	button_rects.clear()
	var x := panel_x + 20.0
	var y := 108.0
	draw_string(cached_font, Vector2(x, y), "战场状态", HORIZONTAL_ALIGNMENT_LEFT, -1, 20, Color("f6d58b"))
	y += 28
	draw_string(cached_font, Vector2(x, y), "第 %d 回合 · %s · %s" % [snapshot.get("turn", 1), "我方行动" if snapshot.get("phase", "ally") == "ally" else "敌方行动", snapshot.get("mode", "playing")], HORIZONTAL_ALIGNMENT_LEFT, PANEL_WIDTH - 40, 14, Color("b9c9e6"))
	y += 24
	draw_string(cached_font, Vector2(x, y), message, HORIZONTAL_ALIGNMENT_LEFT, PANEL_WIDTH - 40, 14, Color("ffffff"))
	y += 30
	draw_line(Vector2(x, y), Vector2(panel_x + PANEL_WIDTH - 20, y), Color("3a4b69"), 1)
	y += 25
	var selected: Dictionary = _selected_unit()
	var dialogue: Dictionary = snapshot.get("dialogue", {})
	if dialogue.get("active", false):
		y = _draw_dialogue(dialogue, x, y, panel_x)
		y += 12
	if selected.is_empty():
		draw_string(cached_font, Vector2(x, y), "12×10 棋盘 · 10 个单位 · 5V5", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color("d6deef"))
		y += 24
		draw_string(cached_font, Vector2(x, y), "胜利：击败全部敌军", HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color("8fd8aa"))
		y += 21
		draw_string(cached_font, Vector2(x, y), "移动：点击蓝色格 · 攻击：点击红色目标", HORIZONTAL_ALIGNMENT_LEFT, PANEL_WIDTH - 40, 13, Color("91a6c8"))
	else:
		y = _draw_selected(selected, x, y, panel_x)

	var panel_end := panel_rect.end.y
	var log_y := panel_end - 150.0
	draw_string(cached_font, Vector2(x, log_y), "战斗记录", HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color("f6d58b"))
	for i in range(min(5, snapshot.get("eventLog", []).size())):
		var raw_line = snapshot.eventLog[snapshot.eventLog.size() - 1 - i] if snapshot.eventLog.size() > 0 else ""
		var line_text: String = raw_line if raw_line is String else _format_event(raw_line)
		draw_string(cached_font, Vector2(x, log_y + 22 + i * 18), line_text, HORIZONTAL_ALIGNMENT_LEFT, PANEL_WIDTH - 40, 11, Color("9eacc5"))
	var reset_rect := Rect2(panel_x + 20, panel_end - 112, PANEL_WIDTH - 40, 34)
	button_rects["reset"] = reset_rect
	draw_rect(reset_rect, Color("2d3b55"), true)
	draw_string(cached_font, reset_rect.position + Vector2(0, 22), "重置战场 (R)", HORIZONTAL_ALIGNMENT_CENTER, reset_rect.size.x, 13, Color("c7d2e8"))
	var end_rect := Rect2(panel_x + 20, panel_end - 64, PANEL_WIDTH - 40, 40)
	button_rects["end_turn"] = end_rect
	draw_rect(end_rect, Color("b14f57") if snapshot.get("phase", "ally") == "ally" else Color("46536d"), true)
	draw_string(cached_font, end_rect.position + Vector2(0, 26), "结束我方回合 (E)", HORIZONTAL_ALIGNMENT_CENTER, end_rect.size.x, 15, Color("ffffff"))

func _selected_unit() -> Dictionary:
	for unit in snapshot.get("units", []):
		if unit.get("instanceId", "") == selected_id:
			return unit
	return {}

func _format_event(event: Dictionary) -> String:
	match event.get("type", ""):
		"damaged": return "%s 受到 %d 点%s伤害" % [event.get("targetId", "单位"), event.get("amount", 0), "魔法" if event.get("damageType", "") == "magic" else ""]
		"healed": return "%s 恢复 %d HP" % [event.get("targetId", "单位"), event.get("amount", 0)]
		"status_applied": return "%s 获得状态：%s" % [event.get("targetId", "单位"), event.get("statusId", "")]
		"status_tick": return "%s 的 %s 造成 %d 点持续伤害" % [event.get("targetId", "单位"), event.get("statusId", ""), event.get("amount", 0)]
		"item_used": return "%s 使用了 %s" % [event.get("targetId", "单位"), bundle.get("items", {}).get(event.get("itemId", ""), {}).get("name", event.get("itemId", "道具"))]
		"terrain_recovery": return "%s 从地形恢复 HP/MP" % event.get("unitId", "单位")
		"status_resisted": return "%s 抵抗了 %s" % [event.get("targetId", "单位"), event.get("statusId", "状态")]
		"dialogue_choice": return "选择：%s" % event.get("text", "")
		"story_event": return event.get("text", "")
		_: return str(event.get("type", "战斗事件"))

func _draw_selected(unit: Dictionary, x: float, y_start: float, panel_x: float) -> float:
	var y := y_start
	draw_string(cached_font, Vector2(x, y), "%s · Lv.%d" % [unit.get("displayName", ""), unit.get("level", 1)], HORIZONTAL_ALIGNMENT_LEFT, -1, 18, Color("ffffff"))
	y += 23
	draw_string(cached_font, Vector2(x, y), "%s  |  HP %d/%d  MP %d/%d" % [unit.get("className", ""), unit.get("hp", 0), unit.get("maxHp", 0), unit.get("mp", 0), unit.get("maxMp", 0)], HORIZONTAL_ALIGNMENT_LEFT, PANEL_WIDTH - 40, 13, Color("d5e1f4"))
	y += 22
	var stats: Dictionary = unit.get("stats", {})
	draw_string(cached_font, Vector2(x, y), "攻 %d  防 %d  法攻 %d  法防 %d" % [stats.get("attack", 0), stats.get("defense", 0), stats.get("magicAttack", 0), stats.get("magicDefense", 0)], HORIZONTAL_ALIGNMENT_LEFT, PANEL_WIDTH - 40, 12, Color("a9bad7"))
	y += 21
	draw_string(cached_font, Vector2(x, y), "命中 %d  闪避 %d  移动 %d  射程 %d" % [stats.get("hit", 0), stats.get("evasion", 0), stats.get("move", 0), stats.get("maxRange", 0)], HORIZONTAL_ALIGNMENT_LEFT, PANEL_WIDTH - 40, 12, Color("a9bad7"))
	y += 28
	var status_names: Array[String] = []
	for status in unit.get("statuses", []):
		var status_data: Dictionary = bundle.get("statuses", {}).get(status.get("id", ""), {})
		status_names.append("%s(%d)" % [status_data.get("name", status.get("id", "")), status.get("turns", 0)])
	if status_names.is_empty():
		draw_string(cached_font, Vector2(x, y), "状态：无", HORIZONTAL_ALIGNMENT_LEFT, PANEL_WIDTH - 40, 12, Color("8495b2"))
	else:
		draw_string(cached_font, Vector2(x, y), "状态：" + "、".join(status_names), HORIZONTAL_ALIGNMENT_LEFT, PANEL_WIDTH - 40, 12, Color("e6b76b"))
	y += 21
	var equipment_names: Array[String] = []
	for equipment_id in unit.get("equipmentIds", []):
		var equipment: Dictionary = bundle.get("equipment", {}).get(equipment_id, {})
		equipment_names.append("%s[%s]" % [equipment.get("name", equipment_id), equipment.get("rarity", "common")])
	draw_string(cached_font, Vector2(x, y), "装备：" + ("、".join(equipment_names) if not equipment_names.is_empty() else "无"), HORIZONTAL_ALIGNMENT_LEFT, PANEL_WIDTH - 40, 11, Color("b9c9e6"))
	y += 25
	draw_string(cached_font, Vector2(x, y), "技能", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color("f6d58b"))
	y += 20
	var skill_no := 0
	for skill in unit.get("skills", []):
		if skill_no >= 4:
			break
		var skill_id: String = skill.get("id", "")
		var ready: bool = skill.get("implementation", "planned") == "ready"
		if skill.get("type", "") == "active":
			var skill_rect := Rect2(panel_x + 20, y - 15, PANEL_WIDTH - 40, 27)
			button_rects["skill:%s" % skill_id] = skill_rect
			draw_rect(skill_rect, Color("31527b") if active_skill_id == skill_id else Color("26354e"), true)
			draw_string(cached_font, skill_rect.position + Vector2(8, 18), "%s%s  MP %d" % [skill.get("name", ""), "" if ready else " (未实装)", skill.get("mpCost", 0)], HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color("ffffff") if ready else Color("7888a4"))
			y += 31
		else:
			draw_string(cached_font, Vector2(x + 8, y), "· %s（被动）" % skill.get("name", ""), HORIZONTAL_ALIGNMENT_LEFT, PANEL_WIDTH - 48, 12, Color("91d0a6") if ready else Color("7888a4"))
			y += 22
		skill_no += 1
	draw_string(cached_font, Vector2(x, y + 4), "道具", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color("f6d58b"))
	y += 20
	for item_id in bundle.get("items", {}).keys():
		var count := int(item_inventory.get(item_id, 0))
		if count <= 0:
			continue
		var item: Dictionary = bundle.items[item_id]
		var item_rect := Rect2(panel_x + 20, y - 15, PANEL_WIDTH - 40, 27)
		button_rects["item:%s" % item_id] = item_rect
		draw_rect(item_rect, Color("48614d"), true)
		draw_string(cached_font, item_rect.position + Vector2(8, 18), "%s ×%d" % [item.get("name", item_id), count], HORIZONTAL_ALIGNMENT_LEFT, item_rect.size.x - 16, 12, Color("ffffff"))
		y += 31
	return y

func _draw_dialogue(dialogue: Dictionary, x: float, y_start: float, panel_x: float) -> float:
	var y := y_start
	draw_rect(Rect2(panel_x + 12, y - 18, PANEL_WIDTH - 24, 142), Color("2a3550"), true)
	draw_string(cached_font, Vector2(x, y + 4), dialogue.get("speaker", "剧情"), HORIZONTAL_ALIGNMENT_LEFT, PANEL_WIDTH - 40, 14, Color("f6d58b"))
	draw_string(cached_font, Vector2(x, y + 28), dialogue.get("text", ""), HORIZONTAL_ALIGNMENT_LEFT, PANEL_WIDTH - 40, 12, Color("ffffff"))
	y += 56
	for choice in dialogue.get("choices", []):
		var choice_id: String = choice.get("id", "")
		var choice_rect := Rect2(panel_x + 20, y - 15, PANEL_WIDTH - 40, 27)
		button_rects["dialogue:%s" % choice_id] = choice_rect
		draw_rect(choice_rect, Color("31527b"), true)
		draw_string(cached_font, choice_rect.position + Vector2(8, 18), choice.get("text", choice_id), HORIZONTAL_ALIGNMENT_LEFT, choice_rect.size.x - 16, 12, Color("ffffff"))
		y += 31
	return y


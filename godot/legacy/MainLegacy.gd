extends Node2D

@warning_ignore_start("inference_on_variant")

## 《汉末烽火》Godot 移植版的第一条可玩垂直切片。
##
## 规则与资源继续读取原项目的 JSON/PNG，而不是重新发明一套数据：
## data -> 计算属性 -> 战场状态 -> Canvas 渲染。后续可以把规则拆成
## Resource/Scene，而不影响现有战场文件。

const BOARD_MARGIN := Vector2(28, 86)
const PANEL_WIDTH := 360.0
const BOARD_GAP := 28.0
const MIN_TILE := 46.0
const GameSession = preload("res://scripts/app/GameSession.gd")

var battle: Dictionary = {}
var classes: Dictionary = {}
var characters: Dictionary = {}
var terrains: Dictionary = {}
var skills: Dictionary = {}
var progression: Dictionary = {}
var terrain_textures: Dictionary = {}
var unit_textures: Dictionary = {}

var units: Array[Dictionary] = []
var selected_index := -1
var reachable: Array[Vector2i] = []
var attackable: Array[int] = []
var active_skill_id := ""
var phase := "ally"
var turn := 1
var mode := "playing"
var message := "请选择一名单位"
var log_lines: Array[String] = []
var last_events: Array[String] = []

var board_origin := BOARD_MARGIN
var tile_size := 56.0
var board_size := Vector2i.ZERO
var button_rects: Dictionary = {}
var cached_font: Font
var session = GameSession.new("res://data")

func _ready() -> void:
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	cached_font = ThemeDB.fallback_font
	var repository_result: Dictionary = session.initialize()
	if not repository_result.ok:
		push_error("GameSession initialization failed: %s" % repository_result.errors)
	_load_registries()
	_load_battle("yingchuan-01")
	queue_redraw()
	print("[Godot] 汉末烽火 loaded: %d×%d, %d units" % [board_size.x, board_size.y, units.size()])
	if DisplayServer.get_name() == "headless":
		_run_smoke_checks()

func _process(_delta: float) -> void:
	# 保证窗口缩放后棋盘和右侧面板立即适配。
	queue_redraw()

func _load_json(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		push_error("Missing data file: " + path)
		return {}
	var text := FileAccess.get_file_as_string(path)
	var value = JSON.parse_string(text)
	if value == null:
		push_error("Invalid JSON: " + path)
		return {}
	return value

func _load_registries() -> void:
	var class_root: Dictionary = _load_json("res://data/classes.json")
	for item in class_root.get("classes", []):
		classes[item.get("id", "")] = item
	var character_root: Dictionary = _load_json("res://data/characters.json")
	for item in character_root.get("characters", []):
		characters[item.get("id", "")] = item
	var terrain_root: Dictionary = _load_json("res://data/terrains.json")
	for item in terrain_root.get("terrains", []):
		terrains[item.get("id", "")] = item
		var texture_path: String = item.get("texture", "")
		if texture_path != "":
			terrain_textures[item.get("id", "")] = load("res://" + texture_path)
	var skill_root: Dictionary = _load_json("res://data/skills.json")
	for item in skill_root.get("skills", []):
		skills[item.get("id", "")] = item
	progression = _load_json("res://data/progression.json")
	for class_id in classes:
		var class_data: Dictionary = classes[class_id]
		var sprite: String = class_data.get("sprite", "")
		if sprite != "":
			unit_textures[class_id] = load("res://" + sprite)

func _load_battle(battle_id: String) -> void:
	battle = _load_json("res://data/battles/%s.json" % battle_id)
	var started: Dictionary = session.start_battle(battle_id, 20261017)
	if not started.ok:
		push_error("GameSession battle start failed: %s" % started)
	var board: Dictionary = battle.get("board", {})
	board_size = Vector2i(int(board.get("width", 0)), int(board.get("height", 0)))
	_build_units()
	phase = "ally"
	turn = 1
	mode = "playing"
	selected_index = -1
	active_skill_id = ""
	reachable.clear()
	attackable.clear()
	message = "第 1 回合开始，我方行动。"
	log_lines.clear()
	_add_log(message)
	_update_layout()

func _sync_from_session() -> void:
	var current: Dictionary = session.snapshot()
	if current.is_empty():
		return
	units = current.get("units", []).duplicate(true)
	phase = current.get("phase", phase)
	turn = int(current.get("turn", turn))
	mode = current.get("mode", mode)

func _build_units() -> void:
	units.clear()
	for source in battle.get("units", []):
		var unit: Dictionary = source.duplicate(true)
		var character: Dictionary = characters.get(unit.get("characterId", ""), {})
		var class_id: String = character.get("classId", "")
		var class_data: Dictionary = classes.get(class_id, {})
		var level: int = max(1, int(unit.get("level", 1)))
		var stats: Dictionary = _calculate_stats(character, class_data, level)
		var unit_skills: Array = []
		for skill_id in class_data.get("skillIds", []):
			if skills.has(skill_id):
				unit_skills.append(skills[skill_id].duplicate(true))
		for skill_id in character.get("skillIds", []):
			if skills.has(skill_id):
				unit_skills.append(skills[skill_id].duplicate(true))
		stats = _apply_passive_stats(stats, unit_skills)
		unit["classId"] = class_id
		unit["className"] = class_data.get("name", class_id)
		unit["stats"] = stats
		unit["skills"] = unit_skills
		unit["hp"] = stats.get("maxHp", 1)
		unit["maxHp"] = stats.get("maxHp", 1)
		unit["mp"] = stats.get("maxMp", 0)
		unit["maxMp"] = stats.get("maxMp", 0)
		unit["alive"] = true
		unit["moved"] = false
		unit["acted"] = false
		unit["guarded"] = false
		unit["expToNext"] = int(progression.get("expToNextLevel", 100))
		units.append(unit)

func _calculate_stats(character: Dictionary, class_data: Dictionary, level: int) -> Dictionary:
	var result: Dictionary = class_data.get("baseStats", {}).duplicate(true)
	var growth: Dictionary = class_data.get("growth", {})
	var modifiers: Dictionary = character.get("statModifiers", {})
	var base_modifiers: Dictionary = modifiers.get("base", {})
	var growth_modifiers: Dictionary = modifiers.get("growth", {})
	for stat in result.keys():
		var class_rule: Dictionary = growth.get(stat, {})
		result[stat] = int(result[stat]) + _growth_value(class_rule, level)
		result[stat] = int(result[stat]) + int(base_modifiers.get(stat, 0))
		result[stat] = int(result[stat]) + _growth_value(growth_modifiers.get(stat, {}), level)
	return result

func _growth_value(rule: Dictionary, level: int) -> int:
	if rule.is_empty():
		return 0
	var first: int = int(rule.get("firstAtLevel", 2))
	var every: int = max(1, int(rule.get("everyLevels", 1)))
	if level < first:
		return 0
	return int(floor(float(level - first) / float(every)) + 1) * int(rule.get("amount", 0))

func _apply_passive_stats(stats: Dictionary, unit_skills: Array) -> Dictionary:
	var result: Dictionary = stats.duplicate(true)
	var modifiers: Dictionary = {}
	for skill in unit_skills:
		if skill.get("implementation", "planned") != "ready" or skill.get("type", "") != "passive":
			continue
		var effect: Dictionary = skill.get("effect", {})
		if effect.get("type", "") != "stat_add":
			continue
		var stat: String = effect.get("stat", "")
		if not result.has(stat):
			continue
		if not modifiers.has(stat):
			modifiers[stat] = {"flat": 0, "percent": 0}
		if effect.get("mode", "flat") == "percent":
			modifiers[stat]["percent"] += float(effect.get("value", 0))
		else:
			modifiers[stat]["flat"] += float(effect.get("value", 0))
	for stat in modifiers:
		var modifier: Dictionary = modifiers[stat]
		result[stat] = round((float(result[stat]) + modifier["flat"]) * (1.0 + modifier["percent"] / 100.0))
	return result

func _update_layout() -> void:
	var size: Vector2 = get_viewport_rect().size
	var available_width: float = max(540.0, size.x - PANEL_WIDTH - BOARD_MARGIN.x * 2.0 - BOARD_GAP)
	var available_height: float = max(500.0, size.y - BOARD_MARGIN.y - 32.0)
	tile_size = min(available_width / max(1, board_size.x), available_height / max(1, board_size.y))
	tile_size = max(MIN_TILE, tile_size)
	board_origin = Vector2(BOARD_MARGIN.x, BOARD_MARGIN.y)

func _draw() -> void:
	_update_layout()
	var viewport := get_viewport_rect().size
	draw_rect(Rect2(Vector2.ZERO, viewport), Color("101522"))
	_draw_header(viewport)
	_draw_board()
	_draw_panel(viewport)

func _draw_header(viewport: Vector2) -> void:
	draw_rect(Rect2(0, 0, viewport.x, 62), Color("19243a"))
	draw_string(cached_font, Vector2(28, 38), "汉末烽火", HORIZONTAL_ALIGNMENT_LEFT, -1, 25, Color("f6d58b"))
	draw_string(cached_font, Vector2(190, 36), "Godot 移植垂直切片  ·  %s" % battle.get("name", ""), HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color("c7d2e8"))
	draw_string(cached_font, Vector2(viewport.x - 265, 36), "E 结束回合   R 重置   ESC 清除选择", HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color("8b9bb8"))

func _draw_board() -> void:
	var board_rect := Rect2(board_origin, Vector2(board_size.x * tile_size, board_size.y * tile_size))
	draw_rect(board_rect.grow(8), Color("26334a"), true)
	var tiles: Array = battle.get("board", {}).get("tiles", [])
	for y in range(board_size.y):
		for x in range(board_size.x):
			var terrain_id: String = tiles[y][x]
			var rect := Rect2(board_origin + Vector2(x, y) * tile_size, Vector2.ONE * tile_size)
			var texture: Texture2D = terrain_textures.get(terrain_id)
			if texture:
				draw_texture_rect(texture, rect, false, Color(1, 1, 1, 0.96))
			else:
				draw_rect(rect, Color("33445d"), true)
			draw_rect(rect, Color("61718a", 0.35), false, 1.0)
			if not bool(terrains.get(terrain_id, {}).get("walkable", false)):
				draw_rect(rect, Color(0.08, 0.1, 0.16, 0.28), true)

	for tile in reachable:
		var rect := _cell_rect(tile.x, tile.y)
		draw_rect(rect.grow(-3), Color(0.25, 0.65, 1.0, 0.35), true)
		draw_rect(rect.grow(-3), Color("6cb6ff"), false, 2.0)
	for tile in _attack_tiles():
		var rect := _cell_rect(tile.x, tile.y)
		draw_rect(rect.grow(-4), Color(0.95, 0.26, 0.28, 0.28), true)
		draw_rect(rect.grow(-4), Color("ff6969"), false, 2.0)

	for unit_index in range(units.size()):
		var unit: Dictionary = units[unit_index]
		if not unit.get("alive", false):
			continue
		_draw_unit(unit_index, unit)

func _draw_unit(unit_index: int, unit: Dictionary) -> void:
	var pos: Dictionary = unit.get("position", {})
	var rect := _cell_rect(int(pos.get("x", 0)), int(pos.get("y", 0)))
	var center := rect.position + rect.size / 2.0
	var ally: bool = unit.get("side", "enemy") != "enemy"
	var side_color := Color("3ea7ff") if ally else Color("e25662")
	if unit_index == selected_index:
		draw_circle(center, tile_size * 0.42, Color("f2c45d"))
		draw_circle(center, tile_size * 0.36, Color("111827"))
	else:
		draw_circle(center, tile_size * 0.40, Color(0.05, 0.07, 0.12, 0.70))
		draw_circle(center, tile_size * 0.37, side_color)
	var texture: Texture2D = unit_textures.get(unit.get("classId", ""))
	if texture:
		var inset := rect.grow(-tile_size * 0.08)
		draw_texture_rect(texture, inset, false, Color(1, 1, 1, 0.92 if not unit.get("acted", false) else 0.56))
	var hp_ratio := clamp(float(unit.get("hp", 0)) / max(1.0, float(unit.get("maxHp", 1))), 0.0, 1.0)
	var bar_rect := Rect2(rect.position + Vector2(4, 4), Vector2(tile_size - 8, 5))
	draw_rect(bar_rect, Color("421d2b"), true)
	draw_rect(Rect2(bar_rect.position, Vector2(bar_rect.size.x * hp_ratio, bar_rect.size.y)), Color("7ee081"), true)
	draw_string(cached_font, rect.position + Vector2(5, tile_size - 7), "%s %d" % [unit.get("className", ""), unit.get("level", 1)], HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color("ffffff"))
	if unit.get("guarded", false):
		draw_circle(rect.position + Vector2(tile_size - 10, 12), 5, Color("f5d76e"))

func _draw_panel(viewport: Vector2) -> void:
	var panel_x := viewport.x - PANEL_WIDTH - 24.0
	var panel_rect := Rect2(panel_x, 78, PANEL_WIDTH, viewport.y - 102)
	draw_rect(panel_rect, Color("182237"), true)
	draw_rect(panel_rect, Color("3a4b69"), false, 1.0)
	var x := panel_x + 20
	var y := 108.0
	draw_string(cached_font, Vector2(x, y), "战场状态", HORIZONTAL_ALIGNMENT_LEFT, -1, 20, Color("f6d58b"))
	y += 28
	draw_string(cached_font, Vector2(x, y), "第 %d 回合 · %s · %s" % [turn, "我方行动" if phase == "ally" else "敌方行动", mode], HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color("b9c9e6"))
	y += 24
	draw_string(cached_font, Vector2(x, y), message, HORIZONTAL_ALIGNMENT_LEFT, PANEL_WIDTH - 40, 14, Color("ffffff"))
	y += 30
	draw_line(Vector2(x, y), Vector2(panel_x + PANEL_WIDTH - 20, y), Color("3a4b69"), 1)
	y += 25

	if selected_index >= 0 and selected_index < units.size():
		var unit: Dictionary = units[selected_index]
		y = _draw_unit_panel(unit, x, y, panel_x)
	else:
		draw_string(cached_font, Vector2(x, y), "12×10 棋盘 · 10 个单位 · 5V5", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color("d6deef"))
		y += 24
		draw_string(cached_font, Vector2(x, y), "胜利：击败全部敌军", HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color("8fd8aa"))
		y += 21
		draw_string(cached_font, Vector2(x, y), "移动：点击蓝色格 · 攻击：点击红色目标", HORIZONTAL_ALIGNMENT_LEFT, PANEL_WIDTH - 40, 13, Color("91a6c8"))
		y += 35

	button_rects.clear()
	var end_rect := Rect2(panel_x + 20, panel_rect.end.y - 64, PANEL_WIDTH - 40, 40)
	button_rects["end_turn"] = end_rect
	draw_rect(end_rect, Color("b14f57") if phase == "ally" else Color("46536d"), true)
	draw_string(cached_font, end_rect.position + Vector2(0, 26), "结束我方回合 (E)", HORIZONTAL_ALIGNMENT_CENTER, end_rect.size.x, 15, Color("ffffff"))
	var reset_rect := Rect2(panel_x + 20, panel_rect.end.y - 112, PANEL_WIDTH - 40, 34)
	button_rects["reset"] = reset_rect
	draw_rect(reset_rect, Color("2d3b55"), true)
	draw_string(cached_font, reset_rect.position + Vector2(0, 22), "重置战场 (R)", HORIZONTAL_ALIGNMENT_CENTER, reset_rect.size.x, 13, Color("c7d2e8"))

	var log_y := panel_rect.end.y - 150
	draw_string(cached_font, Vector2(x, log_y), "战斗记录", HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color("f6d58b"))
	for i in range(min(5, log_lines.size())):
		var line: String = log_lines[log_lines.size() - 1 - i]
		draw_string(cached_font, Vector2(x, log_y + 22 + i * 18), line, HORIZONTAL_ALIGNMENT_LEFT, PANEL_WIDTH - 40, 11, Color("9eacc5"))

func _draw_unit_panel(unit: Dictionary, x: float, y_start: float, panel_x: float) -> float:
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
	return y

func _cell_rect(x: int, y: int) -> Rect2:
	return Rect2(board_origin + Vector2(x, y) * tile_size, Vector2.ONE * tile_size)

func _attack_tiles() -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	for index in attackable:
		if index >= 0 and index < units.size():
			var pos: Dictionary = units[index].get("position", {})
			result.append(Vector2i(int(pos.get("x", 0)), int(pos.get("y", 0))))
	return result

func _unit_at(x: int, y: int) -> int:
	for i in range(units.size()):
		var unit: Dictionary = units[i]
		var pos: Dictionary = unit.get("position", {})
		if unit.get("alive", false) and int(pos.get("x", -1)) == x and int(pos.get("y", -1)) == y:
			return i
	return -1

func _distance(a: Dictionary, b: Dictionary) -> int:
	var ap: Dictionary = a.get("position", {})
	var bp: Dictionary = b.get("position", {})
	return abs(int(ap.get("x", 0)) - int(bp.get("x", 0))) + abs(int(ap.get("y", 0)) - int(bp.get("y", 0)))

func _is_hostile(a: Dictionary, b: Dictionary) -> bool:
	return (a.get("side", "enemy") == "enemy") != (b.get("side", "enemy") == "enemy")

func _is_walkable(x: int, y: int) -> bool:
	if x < 0 or y < 0 or x >= board_size.x or y >= board_size.y:
		return false
	var terrain_id: String = battle.get("board", {}).get("tiles", [])[y][x]
	return bool(terrains.get(terrain_id, {}).get("walkable", false))

func _can_traverse(x: int, y: int, moving_index: int) -> bool:
	if not _is_walkable(x, y):
		return false
	var occupant := _unit_at(x, y)
	if occupant < 0 or occupant == moving_index:
		return true
	return _is_hostile(units[moving_index], units[occupant]) == false

func _compute_reachable(index: int) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	if index < 0 or index >= units.size() or units[index].get("acted", false) or units[index].get("moved", false):
		return result
	if session != null and units[index].has("instanceId"):
		return session.reachable_tiles(units[index].get("instanceId", ""))
	var unit: Dictionary = units[index]
	var start: Dictionary = unit.get("position", {})
	var max_move := int(unit.get("stats", {}).get("move", 0))
	var costs: Dictionary = {"%d,%d" % [start.get("x", 0), start.get("y", 0)]: 0}
	var open: Array = [Vector2i(int(start.get("x", 0)), int(start.get("y", 0)))]
	while not open.is_empty():
		var current: Vector2i = open.pop_front()
		var current_key := "%d,%d" % [current.x, current.y]
		var current_cost: int = costs[current_key]
		for delta in [Vector2i.RIGHT, Vector2i.LEFT, Vector2i.DOWN, Vector2i.UP]:
			var next: Vector2i = current + delta
			if not _can_traverse(next.x, next.y, index):
				continue
			var next_cost := current_cost + 1
			var next_key := "%d,%d" % [next.x, next.y]
			if next_cost <= max_move and (not costs.has(next_key) or next_cost < costs[next_key]):
				costs[next_key] = next_cost
				open.append(next)
	for key in costs:
		var parts: PackedStringArray = key.split(",")
		var pos: Vector2i = Vector2i(int(parts[0]), int(parts[1]))
		var occupant: int = _unit_at(pos.x, pos.y)
		if occupant < 0 or occupant == index:
			result.append(pos)
	return result

func _compute_attackable(index: int) -> Array[int]:
	var result: Array[int] = []
	if index < 0 or index >= units.size():
		return result
	if session != null and units[index].has("instanceId"):
		for target_id in session.attackable_targets(units[index].get("instanceId", "")):
			var target_index := _unit_index_by_id(target_id)
			if target_index >= 0:
				result.append(target_index)
		return result
	var unit: Dictionary = units[index]
	var max_range := max(1, int(unit.get("stats", {}).get("maxRange", 1)))
	for target_index in range(units.size()):
		var target: Dictionary = units[target_index]
		if target.get("alive", false) and _is_hostile(unit, target) and _distance(unit, target) <= max_range:
			result.append(target_index)
	return result

func _unit_index_by_id(unit_id: String) -> int:
	for index in range(units.size()):
		if units[index].get("instanceId", "") == unit_id:
			return index
	return -1

func _compute_skill_targets(index: int, skill: Dictionary) -> Array[int]:
	var result: Array[int] = []
	var unit: Dictionary = units[index]
	var target_type: String = skill.get("targetType", "")
	if target_type == "self":
		result.append(index)
		return result
	var min_range := int(skill.get("minRange", 0))
	var max_range := max(min_range, int(skill.get("maxRange", min_range)))
	for target_index in range(units.size()):
		var target: Dictionary = units[target_index]
		if not target.get("alive", false) or target_index == index:
			continue
		var distance := _distance(unit, target)
		if distance < min_range or distance > max_range:
			continue
		if target_type == "enemy_single" and _is_hostile(unit, target):
			result.append(target_index)
		elif target_type in ["ally_single", "ally_area"] and not _is_hostile(unit, target):
			result.append(target_index)
	return result

func _select_unit(index: int) -> void:
	if index < 0 or index >= units.size():
		return
	selected_index = index
	active_skill_id = ""
	attackable.clear()
	if phase != "ally":
		message = "现在是敌方行动阶段"
		reachable.clear()
		queue_redraw()
		return
	var unit: Dictionary = units[index]
	reachable = _compute_reachable(index)
	if unit.get("moved", false) and not unit.get("acted", false):
		attackable = _compute_attackable(index)
	message = "%s 已移动，可选择红色目标攻击" % unit.get("displayName", "单位") if unit.get("moved", false) else "请选择蓝色格移动"
	queue_redraw()

func _move_unit(index: int, x: int, y: int) -> void:
	if Vector2i(x, y) not in reachable:
		return
	var command_result: Dictionary = session.dispatch({"type": "move", "unitId": units[index].get("instanceId", ""), "x": x, "y": y})
	if not command_result.ok:
		message = command_result.error
		queue_redraw()
		return
	_sync_from_session()
	reachable.clear()
	attackable = _compute_attackable(index)
	message = "%s 已移动，可攻击" % units[index].get("displayName", "单位")
	_add_log(message)
	queue_redraw()

func _normal_attack(attacker_index: int, target_index: int) -> void:
	var attacker: Dictionary = units[attacker_index]
	var target: Dictionary = units[target_index]
	var command_result: Dictionary = session.dispatch({"type": "attack", "attackerId": attacker.get("instanceId", ""), "targetId": target.get("instanceId", "")})
	if not command_result.ok:
		message = command_result.error
		queue_redraw()
		return
	_sync_from_session()
	message = "%s 攻击了 %s" % [attacker.get("displayName", ""), target.get("displayName", "")]
	_add_log(message)
	_check_result()
	queue_redraw()

func _use_skill(attacker_index: int, target_index: int, skill: Dictionary) -> void:
	var command_result: Dictionary = session.dispatch({"type": "skill", "attackerId": units[attacker_index].get("instanceId", ""), "targetId": units[target_index].get("instanceId", ""), "skillId": skill.get("id", "")})
	if not command_result.ok:
		message = command_result.error
		active_skill_id = ""
		queue_redraw()
		return
	_sync_from_session()
	message = "%s 使用了 %s" % [units[attacker_index].get("displayName", ""), skill.get("name", "技能")]
	_add_log(message)
	active_skill_id = ""
	_check_result()
	queue_redraw()

func _apply_damage(attacker_index: int, target_index: int, damage_type: String, power: float, hit_bonus: int) -> void:
	var attacker: Dictionary = units[attacker_index]
	var target: Dictionary = units[target_index]
	var attacker_stats: Dictionary = attacker.get("stats", {})
	var target_stats: Dictionary = target.get("stats", {})
	var accuracy := int(attacker_stats.get("hit", 0)) + hit_bonus
	var evasion := int(target_stats.get("evasion", 0))
	var hit: bool = accuracy >= evasion or randf() < max(0.0, (100.0 + accuracy - evasion) / 100.0)
	if not hit:
		last_events.append("未命中")
		return
	var attack_value := int(attacker_stats.get("magicAttack" if damage_type == "magic" else "attack", 0))
	var defense_value := int(target_stats.get("magicDefense" if damage_type == "magic" else "defense", 0))
	if target.get("guarded", false):
		defense_value = int(round(float(defense_value) * 1.5))
	var damage := max(1, int(round(float(attack_value - defense_value) * power)))
	units[target_index]["hp"] = max(0, int(target.get("hp", 0)) - damage)
	last_events.append("-%d" % damage)
	if int(units[target_index].get("hp", 0)) <= 0:
		units[target_index]["alive"] = false
		units[target_index]["guarded"] = false
		_add_log("%s 被击败" % target.get("displayName", ""))
	else:
		units[target_index]["guarded"] = false

func _finish_action(index: int) -> void:
	units[index]["moved"] = true
	units[index]["acted"] = true
	reachable.clear()
	attackable.clear()

func _check_result() -> void:
	var enemies_alive := false
	var allies_alive := false
	for unit in units:
		if unit.get("alive", false):
			if unit.get("side", "enemy") == "enemy":
				enemies_alive = true
			else:
				allies_alive = true
		if enemies_alive and allies_alive:
			break
	if not enemies_alive:
		mode = "victory"
		message = "战斗胜利！敌军已全部击败。"
		_add_log(message)
	elif not allies_alive:
		mode = "defeat"
		message = "战斗失败，我方全军覆没。"
		_add_log(message)

func _end_turn() -> void:
	if mode != "playing" or phase != "ally":
		return
	var command_result: Dictionary = session.dispatch({"type": "end_turn"})
	if not command_result.ok:
		message = command_result.error
		queue_redraw()
		return
	_sync_from_session()
	active_skill_id = ""
	reachable.clear()
	attackable.clear()
	selected_index = -1
	message = "第 %d 回合开始，我方行动。" % turn if mode == "playing" else ("战斗胜利！" if mode == "victory" else "战斗失败。")
	_add_log(message)
	queue_redraw()

func _enemy_action(index: int) -> void:
	var target_index := _nearest_ally(index)
	if target_index < 0:
		return
	if _distance(units[index], units[target_index]) <= int(units[index].get("stats", {}).get("maxRange", 1)):
		_normal_attack(index, target_index)
		return
	var from: Dictionary = units[index].get("position", {})
	var to: Dictionary = units[target_index].get("position", {})
	var candidates: Array[Vector2i] = []
	var dx: int = sign(int(to.get("x", 0)) - int(from.get("x", 0)))
	var dy: int = sign(int(to.get("y", 0)) - int(from.get("y", 0)))
	if dx != 0:
		candidates.append(Vector2i(int(from.get("x", 0)) + dx, int(from.get("y", 0))))
	if dy != 0:
		candidates.append(Vector2i(int(from.get("x", 0)), int(from.get("y", 0)) + dy))
	for candidate in candidates:
		if _can_traverse(candidate.x, candidate.y, index) and _unit_at(candidate.x, candidate.y) < 0:
			units[index]["position"] = {"x": candidate.x, "y": candidate.y}
			break
	if _distance(units[index], units[target_index]) <= int(units[index].get("stats", {}).get("maxRange", 1)):
		_normal_attack(index, target_index)
	else:
		units[index]["acted"] = true
		units[index]["moved"] = true

func _nearest_ally(enemy_index: int) -> int:
	var best := -1
	var best_distance := 99999
	for index in range(units.size()):
		if units[index].get("alive", false) and units[index].get("side", "enemy") != "enemy":
			var distance := _distance(units[enemy_index], units[index])
			if distance < best_distance:
				best_distance = distance
				best = index
	return best

func _add_log(text: String) -> void:
	log_lines.append(text)
	if log_lines.size() > 8:
		log_lines.pop_front()

func _reset_battle() -> void:
	_load_battle("yingchuan-01")

func _handle_board_click(position: Vector2) -> void:
	var local := position - board_origin
	var x := int(floor(local.x / tile_size))
	var y := int(floor(local.y / tile_size))
	if x < 0 or y < 0 or x >= board_size.x or y >= board_size.y:
		return
	var clicked_index := _unit_at(x, y)
	if active_skill_id != "" and selected_index >= 0:
		var skill: Dictionary = _find_skill(units[selected_index], active_skill_id)
		if clicked_index in _compute_skill_targets(selected_index, skill):
			_use_skill(selected_index, clicked_index, skill)
		else:
			message = "该单位不在技能范围内"
			queue_redraw()
		return
	if clicked_index >= 0:
		if clicked_index == selected_index and not units[clicked_index].get("moved", false):
			_move_unit(clicked_index, x, y)
		elif selected_index >= 0 and clicked_index in attackable:
			_normal_attack(selected_index, clicked_index)
		else:
			_select_unit(clicked_index)
		return
	if selected_index >= 0 and Vector2i(x, y) in reachable:
		_move_unit(selected_index, x, y)

func _find_skill(unit: Dictionary, skill_id: String) -> Dictionary:
	for skill in unit.get("skills", []):
		if skill.get("id", "") == skill_id:
			return skill
	return {}

func _handle_panel_click(position: Vector2) -> void:
	for key in button_rects:
		var rect: Rect2 = button_rects[key]
		if not rect.has_point(position):
			continue
		if key == "end_turn":
			_end_turn()
		elif key == "reset":
			_reset_battle()
		elif String(key).begins_with("skill:") and selected_index >= 0:
			var skill_id := String(key).substr(6)
			var skill: Dictionary = _find_skill(units[selected_index], skill_id)
			if skill.get("implementation", "planned") != "ready":
				message = "%s 尚未实装" % skill.get("name", "技能")
			else:
				active_skill_id = skill_id
				reachable.clear()
				attackable = _compute_skill_targets(selected_index, skill)
				message = "请选择 %s 的目标" % skill.get("name", "技能")
			queue_redraw()
			return

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_update_layout()
		var p: Vector2 = event.position
		var viewport := get_viewport_rect().size
		if p.x >= viewport.x - PANEL_WIDTH - 24:
			_handle_panel_click(p)
		else:
			_handle_board_click(p)
	elif event is InputEventKey and event.pressed:
		if event.keycode == KEY_ESCAPE:
			active_skill_id = ""
			reachable.clear()
			attackable.clear()
			message = "已清除选择"
			queue_redraw()
		elif event.keycode == KEY_E:
			_end_turn()
		elif event.keycode == KEY_R:
			_reset_battle()

## 给后续自动化/调试使用的稳定快照，用于自动化和调试的稳定快照。
func render_game_to_text() -> String:
	var alive_units: Array[String] = []
	for unit in units:
		if unit.get("alive", false):
			var pos: Dictionary = unit.get("position", {})
			alive_units.append("%s@%d,%d HP=%d" % [unit.get("displayName", ""), pos.get("x", 0), pos.get("y", 0), unit.get("hp", 0)])
	return "mode=%s phase=%s turn=%d selected=%d message=%s\\n%s" % [mode, phase, turn, selected_index, message, " | ".join(alive_units)]

func _run_smoke_checks() -> void:
	var failures: Array[String] = []
	if board_size != Vector2i(12, 10):
		failures.append("battle board is not 12x10")
	if units.size() != 10:
		failures.append("battle does not contain 10 units")
	if classes.size() < 5 or characters.size() < 5 or terrains.size() < 9:
		failures.append("registry data is incomplete")
	_select_unit(0)
	if reachable.is_empty():
		failures.append("ally infantry has no reachable tile")
	else:
		var move_target := reachable[reachable.size() - 1]
		_move_unit(0, move_target.x, move_target.y)
		if not units[0].get("moved", false):
			failures.append("move command did not update unit state")
	_reset_battle()
	if failures.is_empty():
		print("[Godot smoke] PASS: JSON, stats, movement and reset")
	else:
		for failure in failures:
			push_error("[Godot smoke] " + failure)


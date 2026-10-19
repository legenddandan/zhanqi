extends Control

## 战斗场景组合根：把输入映射到 GameSession，再把快照交给两个纯视图。

@warning_ignore_start("inference_on_variant")

const BoardView = preload("res://scripts/presentation/BoardView.gd")
const BattleHud = preload("res://scripts/presentation/BattleHud.gd")
const InputController = preload("res://scripts/presentation/InputController.gd")

var session
var board_view = BoardView.new()
var battle_hud = BattleHud.new()
var input_controller = InputController.new()
var selected_id := ""
var active_skill_id := ""
var message := "请选择一名单位"
var cached_font: Font

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	cached_font = ThemeDB.fallback_font
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	add_child(board_view)
	add_child(battle_hud)
	add_child(input_controller)
	input_controller.pointer_pressed.connect(_on_pointer_pressed)
	input_controller.key_pressed.connect(_on_key_pressed)
	session = GameApp.session
	if not GameApp.ensure_initialized():
		push_error("GameSession initialization failed")
		return
	var started: Dictionary = {"ok": true}
	if not session.has_active_battle():
		started = session.start_battle("yingchuan-01", 20261017)
		if not started.ok:
			push_error("Battle start failed: %s" % started)
			return
	board_view.configure(session.current_battle(), session.bundle)
	battle_hud.configure(session.bundle, session.campaign_snapshot().get("itemInventory", {}))
	for event in session.snapshot().get("lastEvents", []):
		if event.get("type", "") == "story_event":
			message = event.get("text", message)
	_refresh_views()
	queue_redraw()
	print("[Godot] BattleScene ready: %s" % session.current_battle().get("name", ""))

func _process(_delta: float) -> void:
	queue_redraw()

func _draw() -> void:
	var viewport: Vector2 = get_viewport_rect().size
	draw_rect(Rect2(Vector2.ZERO, viewport), Color("101522"))
	draw_rect(Rect2(0, 0, viewport.x, 62), Color("19243a"))
	draw_string(cached_font, Vector2(28, 38), "汉末烽火", HORIZONTAL_ALIGNMENT_LEFT, -1, 25, Color("f6d58b"))
	draw_string(cached_font, Vector2(190, 36), "Godot 单机架构版  ·  %s" % session.current_battle().get("name", ""), HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color("c7d2e8"))
	draw_string(cached_font, Vector2(viewport.x - 265, 36), "E 结束回合   R 重置   ESC 清除选择", HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color("8b9bb8"))

func _refresh_views() -> void:
	var state: Dictionary = session.snapshot()
	var reachable: Array[Vector2i] = []
	var targets: Array[String] = []
	if selected_id != "":
		var selected: Dictionary = _unit_by_id(selected_id, state)
		if not selected.is_empty() and selected.get("alive", false) and selected.get("side", "enemy") == "ally":
			if not selected.get("moved", false) and not selected.get("acted", false):
				reachable = session.reachable_tiles(selected_id)
			elif not selected.get("acted", false):
				targets = session.attackable_targets(selected_id)
			if active_skill_id != "":
				targets = session.skill_targets(selected_id, active_skill_id)
	board_view.set_view_state(state, selected_id, reachable, targets)
	battle_hud.set_view_state(state, message, selected_id, active_skill_id)

func _on_pointer_pressed(position: Vector2) -> void:
	var action := battle_hud.action_at(position)
	if action != "":
		_handle_hud_action(action)
		return
	if board_view.is_inside_board(position):
		_handle_board_cell(board_view.cell_from_position(position))

func _handle_hud_action(action: String) -> void:
	if action == "reset":
		_reset_battle()
		return
	if action == "end_turn":
		_dispatch({"type": "end_turn"})
		return
	if action.begins_with("dialogue:"):
		_dispatch({"type": "dialogue_choice", "choiceId": action.substr(9)})
		return
	if action.begins_with("item:") and selected_id != "":
		_dispatch({"type": "item", "unitId": selected_id, "targetId": selected_id, "itemId": action.substr(5)})
		return
	if action.begins_with("skill:") and selected_id != "":
		var skill_id := action.substr(6)
		var selected: Dictionary = _unit_by_id(selected_id, session.snapshot())
		var skill: Dictionary = _find_skill(selected, skill_id)
		if skill.is_empty() or skill.get("implementation", "planned") != "ready":
			message = "%s 尚未实装" % skill.get("name", "技能")
		else:
			active_skill_id = skill_id
			message = "请选择 %s 的目标" % skill.get("name", "技能")
		_refresh_views()

func _handle_board_cell(cell: Vector2i) -> void:
	var state: Dictionary = session.snapshot()
	var clicked: Dictionary = _unit_at_cell(cell, state)
	if active_skill_id != "" and selected_id != "":
		if not clicked.is_empty() and clicked.get("instanceId", "") in session.skill_targets(selected_id, active_skill_id):
			_dispatch({"type": "skill", "attackerId": selected_id, "targetId": clicked.get("instanceId", ""), "skillId": active_skill_id})
		else:
			message = "该单位不在技能范围内"
			_refresh_views()
		return
	if not clicked.is_empty():
		var clicked_id: String = clicked.get("instanceId", "")
		if selected_id != "" and clicked_id in session.attackable_targets(selected_id):
			_dispatch({"type": "attack", "attackerId": selected_id, "targetId": clicked_id})
		elif clicked_id == selected_id and not clicked.get("moved", false):
			_dispatch({"type": "move", "unitId": selected_id, "x": cell.x, "y": cell.y})
		else:
			_select_unit(clicked_id)
		return
	if selected_id != "" and cell in session.reachable_tiles(selected_id):
		_dispatch({"type": "move", "unitId": selected_id, "x": cell.x, "y": cell.y})

func _select_unit(unit_id: String) -> void:
	selected_id = unit_id
	active_skill_id = ""
	var unit: Dictionary = _unit_by_id(unit_id, session.snapshot())
	message = "请选择 %s 的移动位置" % unit.get("displayName", "单位") if unit.get("side", "enemy") == "ally" and not unit.get("moved", false) else "%s 属性查看" % unit.get("displayName", "单位")
	_refresh_views()

func _dispatch(command: Dictionary) -> void:
	var result: Dictionary = session.dispatch(command)
	if not result.ok:
		AudioManager.play_event("ui_error")
		message = result.error
		_refresh_views()
		return
	active_skill_id = ""
	var state: Dictionary = result.state
	if state.get("mode", "playing") == "victory":
		message = "战斗胜利！敌军已全部击败。"
		AudioManager.play_event("victory")
		var committed: Dictionary = session.finish_battle()
		if not committed.ok:
			message = "胜利但存档失败：%s" % committed.error
	elif state.get("mode", "playing") == "defeat":
		message = "战斗失败，我方全军覆没。"
		AudioManager.play_event("defeat")
		var defeated_commit: Dictionary = session.finish_battle()
		if not defeated_commit.ok:
			message = "战斗失败且无法清理存档：%s" % defeated_commit.error
	elif command.get("type", "") == "end_turn":
		message = "第 %d 回合开始，我方行动。" % state.get("turn", 1)
	else:
		message = "命令已执行"
	match command.get("type", ""):
		"move": AudioManager.play_event("move")
		"attack": AudioManager.play_event("attack")
		"skill": AudioManager.play_event("skill")
		"item": AudioManager.play_event("item")
	for event in result.get("events", []):
		if event.get("type", "") == "story_event":
			message = event.get("text", message)
	battle_hud.set_item_inventory(session.campaign_snapshot().get("itemInventory", {}))
	_refresh_views()

func _reset_battle() -> void:
	var started: Dictionary = session.start_battle("yingchuan-01", 20261017, true)
	if not started.ok:
		AudioManager.play_event("ui_error")
		message = started.get("error", "重置失败")
		return
	selected_id = ""
	active_skill_id = ""
	message = "第 1 回合开始，我方行动。"
	_refresh_views()

func _on_key_pressed(keycode: Key) -> void:
	match keycode:
		KEY_ESCAPE:
			if session != null and session.snapshot().get("mode", "playing") != "playing":
				get_tree().change_scene_to_file("res://Campaign.tscn")
				return
			selected_id = ""
			active_skill_id = ""
			message = "已清除选择"
			_refresh_views()
		KEY_E:
			_dispatch({"type": "end_turn"})
		KEY_R:
			_reset_battle()

func _unit_at_cell(cell: Vector2i, state: Dictionary) -> Dictionary:
	for unit in state.get("units", []):
		var position: Dictionary = unit.get("position", {})
		if unit.get("alive", false) and int(position.get("x", -1)) == cell.x and int(position.get("y", -1)) == cell.y:
			return unit
	return {}

func _unit_by_id(unit_id: String, state: Dictionary) -> Dictionary:
	for unit in state.get("units", []):
		if unit.get("instanceId", "") == unit_id:
			return unit
	return {}

func _find_skill(unit: Dictionary, skill_id: String) -> Dictionary:
	for skill in unit.get("skills", []):
		if skill.get("id", "") == skill_id:
			return skill
	return {}


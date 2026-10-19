extends Node

## 场景级第一关闭环 smoke：从真实 Control 场景触发输入，再检查应用层状态。
## 该脚本必须作为 scene_smoke.tscn 运行，这样项目 autoload（GameApp/AudioManager）会生效。

const GameSession = preload("res://scripts/app/GameSession.gd")
const SmokeStorage = preload("res://tests/smoke_storage.gd")

func _ready() -> void:
	await _run_smoke()

func _run_smoke() -> void:
	var failures: Array[String] = []
	var storage_dir := SmokeStorage.create("scene")
	GameApp.session = GameSession.new("res://data", storage_dir)
	GameApp.initialized = false
	if not GameApp.ensure_initialized():
		failures.append("isolated GameApp session failed to initialize")
		_finish(failures, storage_dir)
		return

	var campaign_scene = load("res://Campaign.tscn").instantiate()
	add_child(campaign_scene)
	await _frames(2)
	if campaign_scene.session != GameApp.session:
		failures.append("CampaignScene did not bind the GameApp session")
	if campaign_scene._first_unlocked_battle() != "yingchuan-01":
		failures.append("CampaignScene did not expose the first unlocked battle")

	# Use the campaign card's real pointer dispatch, while suppressing the scene
	# replacement so this harness can keep driving the next scene in-process.
	campaign_scene.navigate_to_battle = false
	campaign_scene.queue_redraw()
	await _frames(2)
	var campaign_button: Rect2 = campaign_scene.button_rects.get("start_battle:yingchuan-01", Rect2())
	if campaign_button.size == Vector2.ZERO:
		failures.append("CampaignScene did not expose the yingchuan-01 entry button")
	else:
		campaign_scene._on_pointer_pressed(campaign_button.position + campaign_button.size / 2.0)
		await _frames(1)
	var started: Dictionary = GameApp.session.snapshot()
	if started.is_empty() or started.get("battleId", "") != "yingchuan-01":
		failures.append("CampaignScene entry did not start yingchuan-01")
	if not GameApp.session.has_active_battle():
		failures.append("CampaignScene entry did not create an active battle")
	if not GameApp.session.has_active_battle():
		_finish(failures, storage_dir)
		return

	var battle_scene = load("res://Main.tscn").instantiate()
	add_child(battle_scene)
	await _frames(3)
	if battle_scene.session != GameApp.session:
		failures.append("BattleScene did not bind the GameApp session")
	if battle_scene.board_view == null or battle_scene.battle_hud == null or battle_scene.input_controller == null:
		failures.append("BattleScene did not create its board, HUD and input controller")

	# Opening dialogue is rendered by the HUD and dispatched through its input signal.
	if not await _click_hud(battle_scene, "dialogue:hold_line"):
		failures.append("opening dialogue choice was not exposed as a HUD action")
	elif GameApp.session.snapshot().get("dialogue", {}).get("active", false):
		failures.append("HUD dialogue action did not close the opening dialogue")

	var first_id := "wei_infantry_01"
	var first_unit: Dictionary = _unit(GameApp.session.snapshot(), first_id)
	var first_position := _position(first_unit)
	await _click_board(battle_scene, first_position)
	if battle_scene.selected_id != first_id:
		failures.append("board input did not select an ally unit")

	var reachable: Array[Vector2i] = GameApp.session.reachable_tiles(first_id)
	var destination := first_position
	for tile in reachable:
		if tile != first_position:
			destination = tile
			break
	if destination == first_position:
		failures.append("selected ally had no reachable destination")
	else:
		await _click_board(battle_scene, destination)
		var moved_unit: Dictionary = _unit(GameApp.session.snapshot(), first_id)
		if not moved_unit.get("moved", false) or _position(moved_unit) != destination:
			failures.append("board input did not dispatch the move command")

	# End-turn input must run the enemy phase and return to the next ally turn.
	battle_scene.input_controller.key_pressed.emit(KEY_E)
	await _frames(2)
	var after_end_turn: Dictionary = GameApp.session.snapshot()
	if after_end_turn.get("phase", "") != "ally" or int(after_end_turn.get("turn", 0)) != 2:
		failures.append("E input did not complete the enemy phase")
	var enemy_event_seen := false
	for event in after_end_turn.get("lastEvents", []):
		if String(event.get("type", "")).begins_with("enemy_"):
			enemy_event_seen = true
			break
	if not enemy_event_seen:
		failures.append("enemy phase produced no enemy action event")

	# Reset uses the same scene command path and restores a fresh turn-one state.
	battle_scene.input_controller.key_pressed.emit(KEY_R)
	await _frames(2)
	var after_reset: Dictionary = GameApp.session.snapshot()
	if after_reset.get("mode", "") != "playing" or int(after_reset.get("turn", 0)) != 1:
		failures.append("R input did not reset the battle")

	# Test a real active skill through HUD selection and board targeting.
	if not await _click_hud(battle_scene, "dialogue:hold_line"):
		failures.append("reset battle did not expose the opening dialogue")
	await _click_board(battle_scene, Vector2i(1, 8))
	await _frames(1)
	if not await _click_hud(battle_scene, "skill:class_infantry_guard"):
		failures.append("selected infantry did not expose the guard skill")
	else:
		await _click_board(battle_scene, Vector2i(1, 8))
		var guarded_unit: Dictionary = _unit(GameApp.session.snapshot(), first_id)
		if not guarded_unit.get("acted", false) or not guarded_unit.get("guarded", false):
			failures.append("HUD skill selection did not dispatch the self-target skill")

	# Configure a tiny terminal fixture inside the live service, then attack via board input.
	battle_scene.input_controller.key_pressed.emit(KEY_R)
	await _frames(2)
	var victory_state: Dictionary = GameApp.session.battle_service.state
	_set_dialogue_inactive(victory_state)
	var victory_ally := _state_unit(victory_state, first_id)
	victory_ally.position = {"x": 1, "y": 8}
	victory_ally.moved = true
	victory_ally.acted = false
	victory_ally.alive = true
	victory_ally.hp = int(victory_ally.maxHp)
	for unit in victory_state.units:
		if unit.side == "enemy":
			unit.alive = false
			unit.hp = 0
	var victory_target = victory_state.units[5]
	victory_target.alive = true
	victory_target.hp = 1
	victory_target.position = {"x": 0, "y": 8}
	victory_state.phase = "ally"
	victory_state.mode = "playing"
	battle_scene._refresh_views()
	await _click_board(battle_scene, Vector2i(1, 8))
	await _click_board(battle_scene, Vector2i(0, 8))
	await _frames(2)
	if GameApp.session.snapshot().get("mode", "") != "victory":
		failures.append("board attack did not reach the victory state")
	if GameApp.session.has_active_battle():
		failures.append("victory scene path did not finish the active battle")

	# Reset after victory, then exercise the defeat path through end-turn input.
	battle_scene.input_controller.key_pressed.emit(KEY_R)
	await _frames(2)
	var defeat_state: Dictionary = GameApp.session.battle_service.state
	_set_dialogue_inactive(defeat_state)
	for unit in defeat_state.units:
		if unit.side == "ally":
			unit.alive = unit.instanceId == first_id
			unit.hp = 1 if unit.instanceId == first_id else 0
			unit.position = {"x": 1, "y": 8} if unit.instanceId == first_id else unit.position
			unit.moved = false
			unit.acted = false
		else:
			unit.alive = false
			unit.hp = 0
	var defeat_enemy = defeat_state.units[5]
	defeat_enemy.alive = true
	defeat_enemy.hp = int(defeat_enemy.maxHp)
	defeat_enemy.position = {"x": 2, "y": 8}
	defeat_enemy.moved = false
	defeat_enemy.acted = false
	defeat_state.phase = "ally"
	defeat_state.mode = "playing"
	battle_scene._refresh_views()
	battle_scene.input_controller.key_pressed.emit(KEY_E)
	await _frames(2)
	if GameApp.session.snapshot().get("mode", "") != "defeat":
		failures.append("E input did not reach the defeat state")

	battle_scene.queue_free()
	campaign_scene.queue_free()
	await _frames(1)
	_finish(failures, storage_dir)

func _click_hud(scene, action: String) -> bool:
	await _frames(2)
	var rect: Rect2 = scene.battle_hud.button_rects.get(action, Rect2())
	if rect.size == Vector2.ZERO:
		return false
	scene.input_controller.pointer_pressed.emit(rect.position + rect.size / 2.0)
	await _frames(1)
	return true

func _click_board(scene, cell: Vector2i) -> void:
	scene.board_view._update_layout()
	var point: Vector2 = scene.board_view.board_origin + Vector2(cell.x, cell.y) * scene.board_view.tile_size + Vector2.ONE * scene.board_view.tile_size * 0.5
	scene.input_controller.pointer_pressed.emit(point)
	await _frames(1)

func _frames(count: int) -> void:
	for _index in range(count):
		await get_tree().process_frame

func _unit(snapshot: Dictionary, instance_id: String) -> Dictionary:
	for unit in snapshot.get("units", []):
		if unit.get("instanceId", "") == instance_id:
			return unit
	return {}

func _state_unit(state: Dictionary, instance_id: String) -> Dictionary:
	for unit in state.units:
		if unit.get("instanceId", "") == instance_id:
			return unit
	return {}

func _position(unit: Dictionary) -> Vector2i:
	var position: Dictionary = unit.get("position", {})
	return Vector2i(int(position.get("x", -1)), int(position.get("y", -1)))

func _set_dialogue_inactive(state: Dictionary) -> void:
	state.dialogue = {"active": false, "eventId": "", "speaker": "", "text": "", "choices": []}

func _finish(failures: Array[String], storage_dir: String) -> void:
	SmokeStorage.cleanup(storage_dir)
	if failures.is_empty():
		print("[Scene smoke] PASS: CampaignScene/BattleScene input path, move, enemy turn, skill, victory, defeat and reset")
	else:
		for failure in failures:
			push_error("[Scene smoke] " + failure)
	get_tree().quit(1 if not failures.is_empty() else 0)

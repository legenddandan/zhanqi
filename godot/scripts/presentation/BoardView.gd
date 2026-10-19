extends Control

## 纯表现层棋盘：不计算移动/伤害，只渲染 BattleState 快照和选择覆盖层。

@warning_ignore_start("inference_on_variant")

const BOARD_MARGIN := Vector2(28, 86)
const PANEL_WIDTH := 360.0
const BOARD_GAP := 28.0
const MIN_TILE := 46.0

var battle: Dictionary = {}
var bundle: Dictionary = {}
var terrain_textures: Dictionary = {}
var unit_textures: Dictionary = {}
var snapshot: Dictionary = {}
var reachable: Array[Vector2i] = []
var target_ids: Array[String] = []
var selected_id := ""
var board_origin := BOARD_MARGIN
var tile_size := 56.0
var board_size := Vector2i.ZERO
var cached_font: Font

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	cached_font = ThemeDB.fallback_font

func configure(battle_definition: Dictionary, data_bundle: Dictionary) -> void:
	battle = battle_definition.duplicate(true)
	bundle = data_bundle
	board_size = Vector2i(int(battle.get("board", {}).get("width", 0)), int(battle.get("board", {}).get("height", 0)))
	terrain_textures.clear()
	unit_textures.clear()
	for terrain_id in bundle.get("terrains", {}):
		var texture_path: String = bundle.terrains[terrain_id].get("texture", "")
		if texture_path != "":
			terrain_textures[terrain_id] = load("res://" + texture_path)
	for class_id in bundle.get("classes", {}):
		var sprite: String = bundle.classes[class_id].get("sprite", "")
		if sprite != "":
			unit_textures[class_id] = load("res://" + sprite)
	_update_layout()
	queue_redraw()

func set_view_state(next_snapshot: Dictionary, next_selected_id: String, next_reachable: Array[Vector2i], next_target_ids: Array[String]) -> void:
	snapshot = next_snapshot.duplicate(true)
	selected_id = next_selected_id
	reachable = next_reachable.duplicate()
	target_ids = next_target_ids.duplicate()
	queue_redraw()

func cell_from_position(position: Vector2) -> Vector2i:
	_update_layout()
	var local := position - board_origin
	return Vector2i(int(floor(local.x / tile_size)), int(floor(local.y / tile_size)))

func is_inside_board(position: Vector2) -> bool:
	var cell := cell_from_position(position)
	return cell.x >= 0 and cell.y >= 0 and cell.x < board_size.x and cell.y < board_size.y

func _process(_delta: float) -> void:
	queue_redraw()

func _update_layout() -> void:
	var size: Vector2 = get_viewport_rect().size
	var available_width: float = max(540.0, size.x - PANEL_WIDTH - BOARD_MARGIN.x * 2.0 - BOARD_GAP)
	var available_height: float = max(500.0, size.y - BOARD_MARGIN.y - 32.0)
	tile_size = max(MIN_TILE, min(available_width / max(1, board_size.x), available_height / max(1, board_size.y)))
	board_origin = BOARD_MARGIN

func _draw() -> void:
	_update_layout()
	_draw_board()

func _draw_board() -> void:
	var board_rect := Rect2(board_origin, Vector2(board_size.x * tile_size, board_size.y * tile_size))
	draw_rect(board_rect.grow(8), Color("26334a"), true)
	var tiles: Array = battle.get("board", {}).get("tiles", [])
	for y in range(board_size.y):
		for x in range(board_size.x):
			var terrain_id: String = tiles[y][x]
			var rect := _cell_rect(x, y)
			var texture: Texture2D = terrain_textures.get(terrain_id)
			if texture:
				draw_texture_rect(texture, rect, false, Color(1, 1, 1, 0.96))
			else:
				draw_rect(rect, Color("33445d"), true)
			draw_rect(rect, Color("61718a", 0.35), false, 1.0)
			if not bool(bundle.terrains.get(terrain_id, {}).get("walkable", false)):
				draw_rect(rect, Color(0.08, 0.1, 0.16, 0.28), true)
	for tile in reachable:
		var rect := _cell_rect(tile.x, tile.y)
		draw_rect(rect.grow(-3), Color(0.25, 0.65, 1.0, 0.35), true)
		draw_rect(rect.grow(-3), Color("6cb6ff"), false, 2.0)
	for unit in snapshot.get("units", []):
		if not unit.get("alive", false):
			continue
		if unit.get("instanceId", "") in target_ids:
			var target_position: Dictionary = unit.get("position", {})
			var target_rect := _cell_rect(int(target_position.get("x", 0)), int(target_position.get("y", 0)))
			draw_rect(target_rect.grow(-4), Color(0.95, 0.26, 0.28, 0.28), true)
			draw_rect(target_rect.grow(-4), Color("ff6969"), false, 2.0)
	for unit in snapshot.get("units", []):
		if unit.get("alive", false):
			_draw_unit(unit)

func _draw_unit(unit: Dictionary) -> void:
	var position: Dictionary = unit.get("position", {})
	var rect := _cell_rect(int(position.get("x", 0)), int(position.get("y", 0)))
	var center := rect.position + rect.size / 2.0
	var ally: bool = unit.get("side", "enemy") != "enemy"
	var side_color := Color("3ea7ff") if ally else Color("e25662")
	if unit.get("instanceId", "") == selected_id:
		draw_circle(center, tile_size * 0.42, Color("f2c45d"))
		draw_circle(center, tile_size * 0.36, Color("111827"))
	else:
		draw_circle(center, tile_size * 0.40, Color(0.05, 0.07, 0.12, 0.70))
		draw_circle(center, tile_size * 0.37, side_color)
	var texture: Texture2D = unit_textures.get(unit.get("classId", ""))
	if texture:
		draw_texture_rect(texture, rect.grow(-tile_size * 0.08), false, Color(1, 1, 1, 0.92 if not unit.get("acted", false) else 0.56))
	var hp_ratio: float = clamp(float(unit.get("hp", 0)) / max(1.0, float(unit.get("maxHp", 1))), 0.0, 1.0)
	var bar_rect := Rect2(rect.position + Vector2(4, 4), Vector2(tile_size - 8, 5))
	draw_rect(bar_rect, Color("421d2b"), true)
	draw_rect(Rect2(bar_rect.position, Vector2(bar_rect.size.x * hp_ratio, bar_rect.size.y)), Color("7ee081"), true)
	draw_string(cached_font, rect.position + Vector2(5, tile_size - 7), "%s %d" % [unit.get("className", ""), unit.get("level", 1)], HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color("ffffff"))
	if unit.get("guarded", false):
		draw_circle(rect.position + Vector2(tile_size - 10, 12), 5, Color("f5d76e"))

func _cell_rect(x: int, y: int) -> Rect2:
	return Rect2(board_origin + Vector2(x, y) * tile_size, Vector2.ONE * tile_size)


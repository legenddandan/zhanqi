extends Node

## 资源可选的音频门面。领域层只发出语义事件，缺少音频文件时静默运行。

const EVENT_FILES := {
	"move": "res://audio/move.ogg",
	"attack": "res://audio/attack.ogg",
	"skill": "res://audio/skill.ogg",
	"item": "res://audio/item.ogg",
	"victory": "res://audio/victory.ogg",
	"defeat": "res://audio/defeat.ogg",
	"ui_confirm": "res://audio/ui_confirm.ogg",
	"ui_error": "res://audio/ui_error.ogg",
}

var muted := false
var master_volume_db := 0.0
var streams: Dictionary = {}
var players: Dictionary = {}

func _ready() -> void:
	for event_id in EVENT_FILES:
		var path: String = EVENT_FILES[event_id]
		if ResourceLoader.exists(path):
			var stream = load(path)
			if stream is AudioStream:
				streams[event_id] = stream

func play_event(event_id: String, volume_db: float = 0.0) -> void:
	if muted or not streams.has(event_id):
		return
	var player: AudioStreamPlayer = players.get(event_id)
	if player == null:
		player = AudioStreamPlayer.new()
		player.name = "Event_%s" % event_id
		add_child(player)
		players[event_id] = player
	player.stream = streams[event_id]
	player.volume_db = master_volume_db + volume_db
	player.play()

func register_event_stream(event_id: String, stream: AudioStream) -> void:
	if event_id.is_empty() or stream == null:
		return
	streams[event_id] = stream

func set_muted(value: bool) -> void:
	muted = value
	if muted:
		for player in players.values():
			player.stop()

func set_master_volume_db(value: float) -> void:
	master_volume_db = clampf(value, -40.0, 6.0)
	for player in players.values():
		player.volume_db = master_volume_db

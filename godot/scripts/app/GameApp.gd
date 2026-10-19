extends Node

## 跨场景的应用单例：CampaignScene 与 BattleScene 共享同一个 GameSession。

const GameSession = preload("res://scripts/app/GameSession.gd")
var session = GameSession.new("res://data")
var initialized := false

func _ready() -> void:
	var result: Dictionary = session.initialize()
	initialized = result.ok
	if not initialized:
		push_error("GameApp initialization failed: %s" % result)

func ensure_initialized() -> bool:
	if initialized:
		return true
	var result: Dictionary = session.initialize()
	initialized = result.ok
	return initialized


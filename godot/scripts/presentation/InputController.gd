extends Node

## 把平台输入转换成应用层理解的最小事件，不让场景脚本依赖 InputEvent 细节。

signal pointer_pressed(position: Vector2)
signal key_pressed(keycode: Key)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		pointer_pressed.emit(event.position)
	elif event is InputEventKey and event.pressed:
		key_pressed.emit(event.keycode)


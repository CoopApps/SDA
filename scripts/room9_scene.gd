extends "res://scripts/intro_scene_player.gd"

## Room 9 "The Hallway" — maid & ghost jump-scare. No dialogue (ROM-confirmed
## zero text events for this scene). Door cel-swaps open (shape 70) partway
## through; maid and ghost APPEAR instantly (not walk-in) per the ROM's own
## move-before-actor_room mechanism, then the ghost walks in and scares twice.
## Timeline is baked into assets/intros/room9_data.json (see work/room9_mockup.html
## for the full byte-cited derivation of every position/timing here).

var _door_black: ColorRect
var _door_lo: Sprite2D
var _door_hi: Sprite2D
var _door_open := false


func _extra_ready() -> void:
	var door: Dictionary = DATA.get("door", {}).get("70", {})
	if door.is_empty():
		return
	var dx := float(door.get("x", 0))
	var dy := float(door.get("y", 0))
	var pos := Vector2(_scroll_x + dx, _room_y + dy)
	# The door cel STAMPS the nametable -- it replaces, not composites. Without
	# clearing the rect first, whatever's transparent in the low-priority cel
	# lets the OLD (closed-door) background art show through instead of the
	# black opening.
	_door_black = ColorRect.new()
	_door_black.color = Color.BLACK
	_door_black.size = Vector2(float(door.get("w", 0)), float(door.get("h", 0)))
	_door_black.position = pos
	_door_black.z_index = -16
	_door_black.visible = false
	add_child(_door_black)
	_door_lo = _make_sprite(_b64_tex(String(door.get("lo", ""))), -15)
	_door_lo.position = pos
	_door_lo.visible = false
	_door_hi = _make_sprite(_b64_tex(String(door.get("hi", ""))), 150)
	_door_hi.position = pos
	_door_hi.visible = false


func _handle_custom_step(step: Dictionary) -> bool:
	if String(step.get("t", "")) == "door":
		_door_open = true
		if _door_black != null:
			_door_black.visible = true
		if _door_lo != null:
			_door_lo.visible = true
		if _door_hi != null:
			_door_hi.visible = true
		return true
	return false

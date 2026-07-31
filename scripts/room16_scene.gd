extends "res://scripts/intro_scene_player.gd"

## Room 16 "The Lobby" — Blake dismisses the party, then leaves; gameplay
## begins here. Adds the looping fireplace flame, loaded from the SAME
## ROM-lifted frames + cycle.json the gameplay flame uses
## (assets/data/hotel/room_16/), so the intro and gameplay flame are identical.
## The flame is a resident sprite actor (entity 40, source_13 frames
## 0x0060/0x006E, 8 VBLANK frames each) — see cycle.json's note for the full
## ROM provenance. The old base64 GIF-capture flame was removed.

const FLAME_DIR := "res://assets/data/hotel/room_16"
# FRAME_MS (1000/60, VBLANK-frame ms) is inherited from intro_scene_player.gd.

var _flame_imgs: Array = []
var _flame_pos := Vector2.ZERO
var _flame_hold_ms := 8.0 * FRAME_MS
var _flame_frame := 0
var _flame_ms := 0.0
var _flame_node: Sprite2D


func _extra_ready() -> void:
	var cyc: Dictionary = Game.load_json(FLAME_DIR + "/cycle.json")
	var n := int(cyc.get("frames", 0))
	var pos: Array = cyc.get("pos", [0, 0])
	_flame_pos = Vector2(float(pos[0]), float(pos[1]))
	# CycleAnim advances every (period_ticks + 1) VBLANK frames.
	_flame_hold_ms = float(int(cyc.get("period_ticks", 7)) + 1) * FRAME_MS
	for i in range(n):
		var tex := Game.load_texture("%s/cycle_%02d.png" % [FLAME_DIR, i])
		if tex != null:
			_flame_imgs.append(tex)
	_flame_node = Sprite2D.new()
	_flame_node.centered = false
	_flame_node.z_index = int(cyc.get("z", 62))
	add_child(_flame_node)
	_update_flame_frame()


func _extra_tick(ms: float) -> void:
	if _flame_imgs.size() < 2:
		return
	_flame_ms += ms
	if _flame_ms >= _flame_hold_ms:
		_flame_ms = 0.0
		_flame_frame = (_flame_frame + 1) % _flame_imgs.size()
		_update_flame_frame()


func _update_flame_frame() -> void:
	if _flame_imgs.is_empty():
		return
	# cycle.json pos is the frame's top-left in room space (0xAD5A screen =
	# pos - hotspot, already applied), so place it directly.
	_flame_node.texture = _flame_imgs[_flame_frame]
	_flame_node.position = Vector2(_scroll_x + _flame_pos.x, _room_y + _flame_pos.y)

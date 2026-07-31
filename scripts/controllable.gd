extends "res://scripts/actor.gd"

## A player-controllable character (Shaggy or Scooby). Only the ACTIVE
## character reads input; the other idles. Two-player switch design
## (verbs.json players = Shaggy, Scooby).
##
## Click-to-walk now PATHFINDS around obstacles via Room.find_path (A* over the
## ROM walkability grid) instead of walking straight and sliding on walls.

## ROM walk velocity (row 236 / 0x548E): the dominant-axis step is speed*256 in
## 8.8 fixed-point = `speed` pixels per 30fps tick. Shaggy's speed scalar (~3) at
## 30 ticks/s ~= 90 px/s. Kept as one tunable until per-actor speed is lifted.
const SPEED := 90.0
const ARRIVE_EPS := 2.0

var active := false
var walk_target = null
var _path: PackedVector2Array = PackedVector2Array()
var _path_i := 0

func setup(bank_dir: String, anim_map: Dictionary, flip_map: Dictionary = {}) -> void:
	state_to_anim = anim_map
	state_flip = flip_map
	load_bank(bank_dir)
	play("idle")
	update_depth()

func walk_to(world_pos: Vector2) -> void:
	# NOT gated on `active`: the companion is walked by _companion_tick /
	# _separate_companion while the player drives the other character. Only
	# keyboard/pad input is active-only (see _process).
	if room != null:
		_path = room.find_path(position, world_pos)
		_path_i = 0
		walk_target = _path[0] if _path.size() > 0 else null
	else:
		_path = PackedVector2Array()
		walk_target = world_pos

func _clear_walk() -> void:
	_path = PackedVector2Array()
	_path_i = 0
	walk_target = null

func _advance_waypoint() -> void:
	_path_i += 1
	if _path_i < _path.size():
		walk_target = _path[_path_i]
	else:
		_clear_walk()

func _process(delta: float) -> void:
	var dir := Vector2.ZERO
	var kb := Vector2.ZERO
	if active:
		if Input.is_key_pressed(KEY_LEFT) or Input.is_key_pressed(KEY_A):
			kb.x -= 1
		if Input.is_key_pressed(KEY_RIGHT) or Input.is_key_pressed(KEY_D):
			kb.x += 1
		if Input.is_key_pressed(KEY_UP) or Input.is_key_pressed(KEY_W):
			kb.y -= 1
		if Input.is_key_pressed(KEY_DOWN) or Input.is_key_pressed(KEY_S):
			kb.y += 1
	if kb != Vector2.ZERO:
		_clear_walk()                        # manual drive cancels the path
		dir = kb.normalized()
	elif walk_target != null:
		var to_target: Vector2 = walk_target - position
		if to_target.length() <= ARRIVE_EPS:
			_advance_waypoint()              # reached this waypoint -> next
			if walk_target != null:
				to_target = walk_target - position
				if to_target.length() > ARRIVE_EPS:
					dir = to_target.normalized()
		else:
			dir = to_target.normalized()

	if dir != Vector2.ZERO:
		var step: float = SPEED * scale.x * delta
		var next: Vector2 = position + dir * step
		if room == null:
			position = next
		elif not room.is_blocked(next.x, next.y):
			position = next
		elif not room.is_blocked(position.x, next.y):
			position.y = next.y            # slide (safety; A* cells are walkable)
		elif not room.is_blocked(next.x, position.y):
			position.x = next.x
		else:
			_clear_walk()                    # boxed in -> stop cleanly

	face_and_animate(dir, delta)
	update_depth()

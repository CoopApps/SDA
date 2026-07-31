extends Node2D
class_name Actor

## Base actor: plays the game's own lifted animation sequences
## (sprites/source_NN/anims.json, cited to sprite_port_data.json's
## animation_index_table). Each state maps to an animation index; the
## sequence carries per-step frame + duration + loop point, so frame
## ORDER and TIMING match the original (no hand-picked ranges, no
## flipping — the game stores dedicated left/right sets).

## An animation step's `dur` is a count of VBLANK FRAMES, not 30fps ticks.
## Consumer: render_sprites 0x00AF24's tail (0xAFC4-0xAFD4) does
## `subq.w #1,(-2,A0)` over the six slot countdowns at $FF0618, and 0xAF24 has
## exactly one caller -- 0xA694, inside gameplay_per_frame 0xA65C, which is the
## $FF0000 routine the VBLANK ISR 0x0008BC jumps to. Once per VBLANK = 60Hz.
## The $FF09DC bit-6 gate does not halve it: 0xA684 clears it on entry and
## 0xA6B4 re-arms it before leaving the same invocation.
const TICK := 1.0 / 60.0

var frames: Array[ImageTexture] = []
var _frame_hotspots: Array = []      # parallel to frames[]: Vector2 hotspot or null
var sprite: Sprite2D
var room: Node2D
var facing := "down"

var animations: Array = []           # loaded anims.json "animations"
var state_to_anim: Dictionary = {}   # "walk_left" -> anim index, etc.
var state_flip: Dictionary = {}      # "walk_left" -> true (h-flip this state)
var _cur_state := ""
var _cur_steps: Array = []
var _cur_loop := 0
var _step_i := 0
var _step_time := 0.0

func _init() -> void:
	sprite = Sprite2D.new()
	sprite.centered = false
	add_child(sprite)

func load_bank(dir_path: String) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		push_error("Cannot open sprite dir: " + dir_path)
		return
	# Reset -- a shape-change (set_actor_shape_index) reloads a DIFFERENT bank
	# into the same Actor; without clearing, old frames/animations would still
	# be indexed (frame_index values are bank-relative) and stale ones would
	# leak in from the previous bank.
	frames.clear()
	_frame_hotspots.clear()
	animations = []
	_cur_state = ""; _cur_steps = []; _step_i = 0; _step_time = 0.0
	# Real per-frame hotspots (SEGA `screen = pos - hotspot`; work/gen_hotspots.py).
	# Keyed by frame file; a frame absent from the table has no valid descriptor
	# (lift artifact) -- _apply_step HOLDS the previous frame for those, so no
	# glitch frame and no horizontal wobble.
	var hs: Dictionary = {}
	var hs_path := dir_path + "/hotspots.json"
	if FileAccess.file_exists(hs_path):
		var hp: Variant = JSON.parse_string(FileAccess.get_file_as_string(hs_path))
		if hp is Dictionary:
			hs = hp
	var names: Array[String] = []
	dir.list_dir_begin()
	var n := dir.get_next()
	while n != "":
		if n.ends_with(".png"):
			names.append(n)
		n = dir.get_next()
	names.sort()
	for fn in names:
		var tex := Game.load_texture(dir_path + "/" + fn)
		if tex != null:
			frames.append(tex)
			var hv: Variant = hs.get(fn)
			_frame_hotspots.append(Vector2(float(hv[0]), float(hv[1])) if hv is Array else null)
	# Load the lifted animation sequences for this bank.
	var anims_path := dir_path + "/anims.json"
	if FileAccess.file_exists(anims_path):
		var data: Variant = Game.load_json(anims_path)
		if data is Dictionary and data.has("animations"):
			animations = data["animations"]

## Play a raw animation index directly (room-object scripts drive actors by
## numeric seq/word0 value, e.g. start_anim_sequence_and_wait's `seq` or
## actor_word0's `value` -- not by the named states set up for the player
## characters). Bypasses state_to_anim entirely.
func play_anim_index(ai: int) -> void:
	if ai < 0 or ai >= animations.size():
		return
	_cur_state = "anim_%d" % ai       # distinct per index so play() state-caching can't skip it
	_cur_steps = animations[ai]["steps"]
	var lp: Variant = animations[ai].get("loop_to_step")
	_cur_loop = int(lp) if lp != null else -1     # -1 = no loop, hold last step
	_step_i = 0
	_step_time = 0.0
	_apply_step()

## True once a non-looping anim (loop_to_step == null) has advanced onto its
## last step. Looping anims are never "done" by this measure.
func anim_done() -> bool:
	if _cur_steps.is_empty():
		return true
	var last := _cur_steps.size() - 1
	var lp: Variant = animations[_state_anim_index()].get("loop_to_step") if _state_anim_index() >= 0 else null
	return lp == null and _step_i >= last

func _state_anim_index() -> int:
	if _cur_state.begins_with("anim_"):
		return int(_cur_state.substr(5))
	return state_to_anim.get(_cur_state, -1)

func play(state: String) -> void:
	if state == _cur_state:
		return
	if not state_to_anim.has(state):
		return
	var ai: int = state_to_anim[state]
	if ai < 0 or ai >= animations.size():
		return
	_cur_state = state
	_cur_steps = animations[ai]["steps"]
	var lp: Variant = animations[ai].get("loop_to_step")
	_cur_loop = int(lp) if lp != null else 0
	_step_i = 0
	_step_time = 0.0
	_apply_step()

## A step is renderable iff its frame was exported AND has a valid hotspot.
func _step_renderable(i: int) -> bool:
	var fi_v: Variant = _cur_steps[i].get("frame_index")
	if fi_v == null:
		return false
	var fi := int(fi_v)
	if fi < 0 or fi >= frames.size() or fi >= _frame_hotspots.size():
		return false
	return _frame_hotspots[fi] != null

func _apply_step() -> void:
	if _cur_steps.is_empty():
		return
	# Skip unrenderable steps: frame not exported (frame_index null) OR no valid
	# per-frame hotspot (invalid descriptor / lift artifact). Landing on the next
	# valid step avoids both a blank first frame and a glitch/wobble mid-cycle.
	var guard := 0
	while guard < _cur_steps.size() and not _step_renderable(_step_i):
		_step_i = (_step_i + 1) % _cur_steps.size()
		guard += 1
	var fi: int = int(_cur_steps[_step_i].get("frame_index", -1))
	if fi >= 0 and fi < frames.size():
		var hotspot: Variant = _frame_hotspots[fi] if fi < _frame_hotspots.size() else null
		if hotspot == null:
			return                      # all steps unrenderable -- hold whatever is shown
		sprite.texture = frames[fi]
		var flip: bool = bool(state_flip.get(_cur_state, false))
		sprite.flip_h = flip
		var w := float(sprite.texture.get_width())
		var hx: float = hotspot.x
		var hy: float = hotspot.y
		# SEGA `screen = pos - hotspot`, with the hotspot mirrored for a flipped
		# frame (rawHx = w - hx; room10-outside-hotel memory). The node origin
		# (position) then lands exactly on the sprite's logical point.
		sprite.offset = Vector2((hx - w) if flip else -hx, -hy)

func advance_anim(delta: float) -> void:
	if _cur_steps.is_empty():
		return
	if _cur_loop == -1 and _step_i >= _cur_steps.size() - 1:
		return                          # one-shot anim already parked on its last step
	_step_time += delta
	var dur: float = float(_cur_steps[_step_i].get("dur", 2)) * TICK
	if _step_time >= dur:
		_step_time -= dur
		_step_i += 1
		if _step_i >= _cur_steps.size():
			_step_i = _cur_loop if _cur_loop >= 0 else _cur_steps.size() - 1
		_apply_step()

func update_depth() -> void:
	# Characters shrink toward the back (user ground truth, lobby + intro). This is
	# now the REAL ROM curve, not a guess: scale = (255-bound)/256 (ROM 0xB52A),
	# where bound is the interpolation of the actor's Y through the room zone table
	# ($FF0692) at 0x7136/0x71CC, gated by $FF09E8 bit3. Per-room near/far scale +
	# Y anchors were derived by EXECUTING that path over a Y sweep
	# (exporters/gen_depth_scale.py -> depth_scale.json); NO save-state/capture.
	# Rooms whose zone table is flat get enabled:false and stay at scale 1.0.
	if room == null:
		return
	var s := 1.0
	if Game.depth_scale:
		var ds: Dictionary = Game.depth_scale.get("%s.%d" % [Game.cluster, room.room_id], {})
		if ds.get("enabled", false):
			var yf: float = float(ds["y_far"])
			var yn: float = float(ds["y_near"])
			var sf: float = float(ds["far_scale"])
			var sn: float = float(ds["near_scale"])
			var tt: float = clampf((position.y - yf) / (yn - yf), 0.0, 1.0)
			s = lerpf(sf, sn, tt)
	scale = Vector2(s, s)
	z_index = int(position.y)

## Turn to face `point` and stand idle (no walk step) — used after arriving at
## an object so the character looks at what it's acting on (SCUMM behaviour).
func face_toward(point: Vector2) -> void:
	var d := point - position
	if d == Vector2.ZERO:
		return
	if absf(d.x) > absf(d.y):
		facing = "left" if d.x < 0 else "right"
	else:
		facing = "up" if d.y < 0 else "down"
	play("idle_" + facing if state_to_anim.has("idle_" + facing) else "idle")

func face_and_animate(dir: Vector2, delta: float) -> void:
	if dir == Vector2.ZERO:
		# Stand still on the current facing (first frame of that walk),
		# frozen — do not advance the cycle while idle.
		play("idle_" + facing if state_to_anim.has("idle_" + facing) else "idle")
		return
	if absf(dir.x) > absf(dir.y):
		facing = "left" if dir.x < 0 else "right"
	else:
		facing = "up" if dir.y < 0 else "down"
	play("walk_" + facing)
	advance_anim(delta)

extends Node2D
class_name IntroPlayer

## Boot intro sequence — five logo screens (SEGA / TITLE / ACCLAIM / SUNSOFT /
## ILLUSIONS), each a STILL VDP picture whose MOTION is pure palette animation,
## replayed one-shot from data synthesized by exporters/scooby_intro_anim.py from
## the ROM's own lifted routines:
##   0x9E7E fade-in (7 passes, +1 CRAM level/channel toward target)
##   0x9DE0 fade-out (7 passes toward black)
##   0x9BC  SEGA streak (rotate palette-0 colours 3..10, 8 steps)
##   sequencer 0x9AA..0xC90 hold lengths (sync_pc_wait D0+1 frames)
## Each screen's assets/screens/<name>/intro_anim.json is {fps, sequence:[...]}
## where a segment is either {kind:"frames",dwell,palettes:[[4][16][3]...]} or
## {kind:"hold",frames,palette:[4][16][3]}.  Nothing here is hand-timed.

signal finished

const VDPScreenScript := preload("res://scripts/vdp_screen.gd")
const SCREENS := ["sega", "title", "acclaim", "sunsoft", "illusions"]
const FPS := 60.0

var display: Sprite2D
var _screen  # VDPScreen (untyped: class_name resolution needs an editor-built
             # .godot/ cache, which doesn't exist for this project yet --
             # see the same gotcha noted in memory/scooby_godot_port.md)
var idx := -1
var _skipped := false

# one-shot sequence playback state
var _seq: Array = []
var _seg := 0            # index into _seq
var _fis := 0           # frames elapsed within the current segment
var _accum := 0.0       # delta accumulator, stepped at FPS
var _tex_cache: Dictionary = {}   # idx path -> ImageTexture (illusions cels)
var _bg_layer: Sprite2D          # acclaim: scrolling plane B (behind plane A)
var _bg_wrap: Sprite2D           # acclaim: wrap copy 512px over (plane B wraps)
const PLANE_WRAP := 512

func _ready() -> void:
	_next_screen()

func _next_screen() -> void:
	if _skipped:
		return
	idx += 1
	if idx >= SCREENS.size():
		_leave()
		return
	var name: String = SCREENS[idx]
	var dir := "res://assets/screens/%s/" % name
	if display != null:
		display.queue_free()
	_free_layers()
	_screen = VDPScreenScript.new(dir)
	display = _screen.make_sprite()
	# Render each screen at its NATIVE resolution so the window stretches it without
	# losing detail. The title/copyright card is native 320 wide (ROM runs H40); the
	# others are 256. Downscaling 320->256 dropped the fine copyright text, so instead
	# we set the viewport base size to the screen's own size and stretch to the window.
	var sw: int = _screen.width if _screen.width > 0 else 256
	var sh: int = _screen.height if _screen.height > 0 else 224
	display.scale = Vector2.ONE
	get_window().content_scale_size = Vector2i(sw, sh)
	add_child(display)

	var anim := _load_json(dir + "intro_anim.json")
	_seq = anim.get("sequence", [])
	_seg = 0
	_fis = 0
	_accum = 0.0
	_tex_cache.clear()
	# Apply the opening palette immediately so the screen doesn't flash at full
	# brightness for one frame before the fade-in's first (near-black) step.
	if not _seq.is_empty():
		_apply_seg_opening(_seq[0])

func _process(delta: float) -> void:
	if _seq.is_empty():
		return
	_accum += delta
	var step := 1.0 / FPS
	while _accum >= step:
		_accum -= step
		_advance_frame()
		if _seq.is_empty():
			return

func _advance_frame() -> void:
	var seg: Dictionary = _seq[_seg]
	var kind := String(seg.get("kind", ""))
	if kind == "layers":
		_setup_layers(seg)
		_next_seg()
	elif kind == "scroll":
		if _fis == 0 and seg.has("palette"):
			_apply_palette(seg["palette"])
		var frm: int = int(seg["from"])
		var to: int = int(seg["to"])
		var step: int = int(seg["step"])
		var dwell: int = int(seg.get("dwell", 1))
		var total: int = int(abs(to - frm) / max(1, abs(step)))
		if _bg_layer != null:
			# ROM 0xB0E loop is increment-THEN-store-THEN-test (D0+=4; store;
			# if D0<48 loop), so the LAST stored value always lands exactly
			# on `to`. `(_fis/dwell)+1` mirrors that -- using `_fis/dwell`
			# alone (no +1) computes 76 values that stop one step short
			# (-256..44, never 48) and then "hold" never updates position
			# again, permanently parking the scroll 4px short of target.
			var x: int = frm + step * ((_fis / dwell) + 1)
			x = min(x, to) if step > 0 else max(x, to)
			_bg_layer.position.x = float(x)
			_bg_wrap.position.x = float(x - PLANE_WRAP)
		_fis += 1
		if _fis >= total * dwell:
			_next_seg()
	elif kind == "picture":
		# instant: set the still picture (illusions cel/final) and move on.
		display.texture = _get_tex(String(seg["src"]))
		_next_seg()
	elif kind == "picture_anim":
		# illusions filmstrip: swap the index texture every `dwell` frames
		# through `order`, palette fixed at full.
		var order: Array = seg["order"]
		var dwell: int = int(seg.get("dwell", 3))
		if _fis == 0 and seg.has("palette"):
			_apply_palette(seg["palette"])
		if _fis % dwell == 0:
			var i: int = _fis / dwell
			if i < order.size():
				display.texture = _get_tex(String(seg["src_fmt"]) % int(order[i]))
		_fis += 1
		if _fis >= order.size() * dwell:
			_next_seg()
	elif kind == "frames":
		var pals: Array = seg["palettes"]
		var dwell: int = int(seg.get("dwell", 1))
		if _fis % dwell == 0:
			var pi: int = _fis / dwell
			if pi < pals.size():
				_apply_palette(pals[pi])
		_fis += 1
		if _fis >= pals.size() * dwell:
			_next_seg()
	else:   # hold
		if _fis == 0 and seg.has("palette"):
			_apply_palette(seg["palette"])
		_fis += 1
		if _fis >= int(seg.get("frames", 1)):
			_next_seg()

func _get_tex(src: String) -> Texture2D:
	if not _tex_cache.has(src):
		_tex_cache[src] = _screen.load_index_texture(src)
	return _tex_cache[src]

## acclaim two-layer setup: plane B (opaque, behind) + a wrap copy 512px over,
## and plane A as the transparent front (index 0 lets plane B show through).
func _setup_layers(seg: Dictionary) -> void:
	_free_layers()
	var back := _get_tex(String(seg["back"]))
	var front := _get_tex(String(seg["front"]))
	var back_x := float(int(seg.get("back_x", 0)))
	_bg_layer = _screen.make_layer(back, true)
	_bg_wrap = _screen.make_layer(back, true)
	for lyr in [_bg_layer, _bg_wrap]:
		lyr.z_index = -1
		lyr.scale = display.scale
		add_child(lyr)
	_bg_layer.position.x = back_x
	_bg_wrap.position.x = back_x - PLANE_WRAP
	display.texture = front
	display.material = _screen.front_material()

func _free_layers() -> void:
	for lyr in [_bg_layer, _bg_wrap]:
		if lyr != null:
			lyr.queue_free()
	_bg_layer = null
	_bg_wrap = null

func _next_seg() -> void:
	_seg += 1
	_fis = 0
	if _seg >= _seq.size():
		_next_screen()

func _apply_seg_opening(seg: Dictionary) -> void:
	var kind := String(seg.get("kind", ""))
	if kind == "layers":
		_setup_layers(seg)
	elif kind == "picture":
		display.texture = _get_tex(String(seg["src"]))
	elif kind == "frames" and not seg["palettes"].is_empty():
		_apply_palette(seg["palettes"][0])
	elif seg.has("palette"):
		_apply_palette(seg["palette"])

func _apply_palette(frame: Array) -> void:
	# frame = [4][16][3] rgb — push straight into the shader palette texture.
	_screen.palettes = frame
	_screen.apply_palette()

# ------------------------------------------------------------------ skip / exit
func _unhandled_input(event: InputEvent) -> void:
	if (event is InputEventKey and event.pressed) \
			or (event is InputEventJoypadButton and event.pressed) \
			or (event is InputEventScreenTouch and event.pressed) \
			or (event is InputEventMouseButton and event.pressed):
		_skip()

func _skip() -> void:
	if _skipped:
		return
	_skipped = true
	_leave()

func _leave() -> void:
	_seq = []        # stop playback (guards the _process while-loop)
	get_window().content_scale_size = Vector2i(320, 200)   # PC-port menu/gameplay canvas
	emit_signal("finished")
	# PreMenuAnim.tscn isn't ported into scoobygodot yet (next Phase 2 step)
	# -- guard rather than hard-crash so the boot logos are independently
	# runnable/validatable before the rest of the menu chain exists.
	if ResourceLoader.exists("res://PreMenuAnim.tscn"):
		get_tree().change_scene_to_file("res://PreMenuAnim.tscn")
	else:
		push_warning("IntroPlayer: PreMenuAnim.tscn not ported yet, staying on last frame")

static func _load_json(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("IntroPlayer: missing " + path)
		return {}
	var d: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	return d if d is Dictionary else {}

extends Node2D

## Pre-menu -> main-menu: a single continuous state machine (matches the ROM's
## own behaviour — nothing reloads between the mansion/lightning/bats/logo-
## dissolve intro and the interactive main menu, it's one continuous loop).
## Direct GDScript port of the validated "pre-menu / main menu" mockup
## (claude.ai/code/artifact/2aee386a-6ed3-4af1-8c4f-c27d6b5da10d) — every
## mechanic below (dissolve wave-offset, bat-loop 5-frame cadence, lightning
## palette cycling, arm-cursor menu) was found, cited to a ROM address, and
## bug-fixed in that mockup before being ported here.
##
## Assets: assets/screens/menu/ + assets/screens/pre_menu/ (real ROM-decoded
## data from exporters/scooby_menu_decode.py — screen.idx, palettes.json,
## dissolve.json, lightning.json, strikes.json, bats.json, arm*.idx,
## logo_scooby_dash.idx, logo_doo.idx).

const MenuDissolveScript := preload("res://scripts/menu_dissolve.gd")
const PALETTE_SHADER := preload("res://shaders/palette.gdshader")
const DIR := "res://assets/screens/menu/"
const PRE_MENU_DIR := "res://assets/screens/pre_menu/"

const FPS := 60.0

# ---- lightning (shared between both phases) ----
var _lit_wait := 24
var _lit_step := -1
var _lit_step_t := 0
var _cur_strike := -1
var _lit_order: Array = [3, 2, 1, 0]
var _lit_fps_step := 2
var _lit_interval_max := 200
var _lit_palettes: Array = []
var _base_pal2: Array = []
var _strike_variants: Array = []

# ---- bats (pre-menu only) ----
const BAT_LOOP_DWELL := 5
const BAT_LOOP_ITERATIONS := 28
var _bat_frames: Array = []   # Texture2D, full 256x224 overlay per frame
var _bat_i := 0
var _bat_loop_t := 0

# ---- logo dissolve ----
var _dissolve: RefCounted
var _logo_sco_src: PackedByteArray
var _logo_doo_src: PackedByteArray
var _mask_count := 0
var _logo_step := 0
var _logo_buf := PackedByteArray()
var _logo_dirty := true

# ---- wave phase ($FF000C) ----
var _wave_index := 0
var _wave_countdown := 3
const WAVE_WRAP := 0x4E
const WAVE_STEP := 2

# ---- logo bob (menu phase only) ----
var _bob_ctr := 0
var _bob_down := false
const BOB_MAX := 0x40
const BOB_STEP := 2
const BOB_SHIFT := 3

# ---- arm cursor (menu phase only) ----
const ARM_SEQ := [0, 1, 2, 1]
const ARM_YS := [84, 108, 132]
const ARM_X := 40
var _arm_tex: Array = []
var _cursor := 0
var _arm_seq_i := 0
var _arm_timer := 0.0
const ARM_FRAME_TIME := 10.0 / 60.0
const MENU_ITEMS := ["PLAY BLAKE'S HOTEL", "PLAY HA HA CARNIVAL", "SOUND TEST"]

const PRE_MENU_FRAMES := BAT_LOOP_ITERATIONS * BAT_LOOP_DWELL

var _phase := "premenu"   # "premenu" | "menu"
var _frame := 0
var _accum := 0.0

var _palettes: Array = []   # [4][16] of [r,g,b], mutable (line 2 cycles)
var _pal_tex: ImageTexture
var _index_tex: ImageTexture
var _screen_img: Image
var _screen_sprite: Sprite2D
var _mat: ShaderMaterial

var _pre_menu_w := 256
var _pre_menu_h := 224
var _pre_menu_bg: PackedByteArray   # index bytes, packed idx|pal<<4 like paintIndexBuffer expects
var _menu_bg: PackedByteArray
var _menu_w := 256
var _menu_h := 224


func _ready() -> void:
	_load_assets()
	_reset_state()
	set_process(true)


func _load_assets() -> void:
	_palettes = _load_json(DIR + "palettes.json")
	var lightning: Dictionary = _load_json(DIR + "lightning.json")
	_lit_order = lightning.get("order", [3, 2, 1, 0])
	_lit_fps_step = int(lightning.get("frames_per_step", 2))
	_lit_interval_max = int(lightning.get("interval_frames_max", 200))
	_lit_palettes = lightning.get("palettes", [])
	_base_pal2 = (_lit_palettes[_lit_order[_lit_order.size() - 1]] as Array) if not _lit_palettes.is_empty() else _palettes[2]

	var strikes: Dictionary = _load_json(DIR + "strikes.json")
	_strike_variants = strikes.get("variants", [])

	var bats: Dictionary = _load_json(DIR + "bats.json")
	_bat_frames = []
	for rel in (bats.get("frames", []) as Array):
		_bat_frames.append(DIR + String(rel))

	_dissolve = MenuDissolveScript.new(DIR + "dissolve.json")
	_logo_sco_src = MenuDissolveScript.load_idx_indices(DIR + "logo_scooby_dash.idx")
	_logo_doo_src = MenuDissolveScript.load_idx_indices(DIR + "logo_doo.idx")
	_mask_count = _dissolve.mask_steps.size()

	for i in range(3):
		var p := DIR + "arm%d.idx" % i
		if FileAccess.file_exists(p):
			_arm_tex.append(p)

	_pre_menu_bg = _read_idx_packed(PRE_MENU_DIR + "screen.idx")
	_menu_bg = _read_idx_packed(DIR + "screen.idx")

	_mat = ShaderMaterial.new()
	_mat.shader = PALETTE_SHADER
	_mat.set_shader_parameter("opaque_backdrop", true)
	_screen_img = Image.create(256, 224, false, Image.FORMAT_RGBA8)
	_screen_sprite = Sprite2D.new()
	_screen_sprite.centered = false
	_screen_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	# Native Genesis art (256x224) scaled to fill the PC port's 320x200 canvas.
	_screen_sprite.scale = Vector2(320.0 / 256.0, 200.0 / 224.0)
	add_child(_screen_sprite)


func _reset_state() -> void:
	_phase = "premenu"
	_frame = 0
	_accum = 0.0
	_lit_wait = 24
	_lit_step = -1
	_lit_step_t = 0
	_cur_strike = -1
	if _palettes.size() > 2:
		_palettes[2] = _dup_pal(_base_pal2)
	_bat_i = 0
	_bat_loop_t = 0
	_logo_step = _mask_count - 1
	_logo_dirty = true
	_logo_buf = PackedByteArray()
	_logo_buf.resize(256 * 120)
	_wave_index = 0
	_wave_countdown = 3
	_bob_ctr = 0
	_bob_down = false
	_cursor = 0
	_arm_seq_i = 0
	_arm_timer = 0.0


func _enter_menu() -> void:
	if _phase == "menu":
		return
	_phase = "menu"
	_logo_step = 0
	_logo_dirty = true


func _process(delta: float) -> void:
	_accum += delta
	var step := 1.0 / FPS
	var guard := 0
	while _accum >= step and guard < 10000:
		_accum -= step
		_advance_frame(step)
		_tick_arm(step)
		guard += 1
	_draw()


func _advance_frame(_dt: float) -> void:
	_frame += 1
	_tick_wave()
	_tick_lightning()
	_tick_loop_iteration()
	_tick_bob()
	if _phase == "premenu" and _frame >= PRE_MENU_FRAMES:
		_enter_menu()


func _tick_wave() -> void:
	_wave_countdown -= 1
	if _wave_countdown < 0:
		_wave_countdown = 3
		_wave_index += WAVE_STEP
		if _wave_index >= WAVE_WRAP:
			_wave_index = 0


func _tick_lightning() -> void:
	if _lit_step < 0:
		_lit_wait -= 1
		if _lit_wait <= 0:
			_lit_step = 0
			_lit_step_t = 0
			_cur_strike = randi() % _strike_variants.size() if not _strike_variants.is_empty() else -1
	if _lit_step >= 0:
		if _lit_step_t == 0:
			var fi: int = int(_lit_order[_lit_step])
			if fi < _lit_palettes.size():
				_palettes[2] = _dup_pal(_lit_palettes[fi])
		_lit_step_t += 1
		if _lit_step_t >= _lit_fps_step:
			_lit_step_t = 0
			_lit_step += 1
			if _lit_step >= _lit_order.size():
				_lit_step = -1
				_palettes[2] = _dup_pal(_base_pal2)
				_cur_strike = -1
				_lit_wait = (randi() % _lit_interval_max) + 20


func _tick_loop_iteration() -> void:
	_bat_loop_t += 1
	if _bat_loop_t < BAT_LOOP_DWELL:
		return
	_bat_loop_t = 0
	var iter_n := _frame / BAT_LOOP_DWELL
	if _phase == "premenu" and iter_n <= BAT_LOOP_ITERATIONS and _bat_i < _bat_frames.size() - 1:
		_bat_i += 1
	var sco: PackedByteArray = _dissolve.render("sco", _logo_sco_src, _logo_step, _logo_step, _wave_index, true)
	_dissolve.render("doo", _logo_doo_src, _logo_step, _logo_step, _wave_index, true, sco)
	_logo_buf = sco
	_logo_dirty = true
	if _logo_step > 0:
		_logo_step = maxi(0, _logo_step - 32)


func _tick_bob() -> void:
	if _phase != "menu":
		return
	if _bob_down:
		_bob_ctr -= BOB_STEP
		if _bob_ctr <= 0:
			_bob_ctr = 0
			_bob_down = false
	else:
		_bob_ctr += BOB_STEP
		if _bob_ctr >= BOB_MAX:
			_bob_ctr = BOB_MAX
			_bob_down = true


func _tick_arm(delta: float) -> void:
	if _phase != "menu":
		return
	_arm_timer += delta
	while _arm_timer >= ARM_FRAME_TIME:
		_arm_timer -= ARM_FRAME_TIME
		_arm_seq_i = (_arm_seq_i + 1) % ARM_SEQ.size()


func move_cursor(d: int) -> void:
	if _phase != "menu":
		return
	_cursor = (_cursor + d + 3) % 3
	_arm_seq_i = 0
	_arm_timer = 0.0


func select_cursor() -> void:
	if _phase != "menu":
		return
	if _cursor == 0:
		get_tree().change_scene_to_file("res://IntroChapterHotel.tscn")
	else:
		# Carnival intro / sound test: not wired yet, same honest-gap pattern
		# as the launch sub-menu note in the reference mockup.
		print("MENU SELECTED (not yet wired): ", MENU_ITEMS[_cursor])


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_up"):
		move_cursor(-1)
	elif event.is_action_pressed("ui_down"):
		move_cursor(1)
	elif event.is_action_pressed("ui_accept"):
		select_cursor()


## ------------------------------------------------------------------ draw ---
func _draw() -> void:
	var w := 256
	var h := 224
	var buf := _screen_img.get_data()
	buf.fill(0)
	var bg := _menu_bg if _phase == "menu" else _pre_menu_bg
	_paint_packed(buf, w, h, bg, w, h, 0, 0, true)
	if _lit_step >= 0 and _cur_strike >= 0 and _cur_strike < _strike_variants.size():
		var s: Dictionary = _strike_variants[_cur_strike]
		var idx := MenuDissolveScript.load_idx_indices(DIR + String(s["idx"]))
		_paint_indices(buf, w, h, idx, int(s["w"]), int(s["h"]), int(s["x"]), int(s["y"]), 2, false)
	if _phase == "premenu" and _bat_i < _bat_frames.size():
		var bp: String = _bat_frames[_bat_i]
		if FileAccess.file_exists(bp):
			var bidx := MenuDissolveScript.load_idx_indices(bp)
			_paint_indices(buf, w, h, bidx, w, h, 0, 0, 0, false)
	var bob_y := (_bob_ctr >> BOB_SHIFT) if _phase == "menu" else 0
	for y in range(120):
		var oy := y + bob_y
		if oy < 0 or oy >= 224:
			continue
		for x in range(256):
			var idxv := _logo_buf[y * 256 + x]
			if idxv == 0:
				continue
			var c: Array = _palettes[0][idxv]
			var o := (oy * 256 + x) * 4
			buf[o] = int(c[0]); buf[o + 1] = int(c[1]); buf[o + 2] = int(c[2]); buf[o + 3] = 255
	if _phase == "menu" and not _arm_tex.is_empty():
		var ap: String = _arm_tex[ARM_SEQ[_arm_seq_i] % _arm_tex.size()]
		var aidx := MenuDissolveScript.load_idx_indices(ap)
		_paint_indices(buf, w, h, aidx, 32, 32, ARM_X, ARM_YS[_cursor], 0, false)
	_screen_img.set_data(w, h, false, Image.FORMAT_RGBA8, buf)
	_screen_sprite.texture = ImageTexture.create_from_image(_screen_img)


## Paint a packed (idx | pal<<4 in one byte) buffer, matching the exported
## screen.idx format's per-pixel encoding used elsewhere in this project.
func _paint_packed(buf: PackedByteArray, w: int, h: int, src: PackedByteArray,
		sw: int, sh: int, dx: int, dy: int, opaque: bool) -> void:
	for y in range(sh):
		var oy := dy + y
		if oy < 0 or oy >= h:
			continue
		for x in range(sw):
			var ox := dx + x
			if ox < 0 or ox >= w:
				continue
			var packed: int = src[y * sw + x]
			var idxv := packed & 0xF
			var pal := (packed >> 4) & 0xF
			var r: int; var g: int; var b: int; var a: int
			if idxv == 0:
				if not opaque:
					continue
				var c0: Array = _palettes[0][0]
				r = int(c0[0]); g = int(c0[1]); b = int(c0[2]); a = 255
			else:
				var c: Array = _palettes[pal][idxv]
				r = int(c[0]); g = int(c[1]); b = int(c[2]); a = 255
			var o := (oy * w + ox) * 4
			buf[o] = r; buf[o + 1] = g; buf[o + 2] = b; buf[o + 3] = a


## Paint a flat 1-byte-per-pixel index array (from load_idx_indices) using a
## single fixed palette line, index 0 = transparent (overlay sprites/strikes/bats).
func _paint_indices(buf: PackedByteArray, w: int, h: int, src: PackedByteArray,
		sw: int, sh: int, dx: int, dy: int, pal_line: int, opaque: bool) -> void:
	for y in range(sh):
		var oy := dy + y
		if oy < 0 or oy >= h:
			continue
		for x in range(sw):
			var ox := dx + x
			if ox < 0 or ox >= w:
				continue
			var idxv: int = src[y * sw + x]
			if idxv == 0 and not opaque:
				continue
			var c: Array = _palettes[pal_line][idxv]
			var o := (oy * w + ox) * 4
			buf[o] = int(c[0]); buf[o + 1] = int(c[1]); buf[o + 2] = int(c[2]); buf[o + 3] = 255


func _dup_pal(pal: Array) -> Array:
	var out := []
	for c in pal:
		out.append((c as Array).duplicate())
	return out


func _read_idx_packed(path: String) -> PackedByteArray:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("pre_menu_anim: missing " + path)
		return PackedByteArray()
	var raw := f.get_buffer(f.get_length())
	f.close()
	var w: int = raw[0] | (raw[1] << 8)
	var h: int = raw[2] | (raw[3] << 8)
	var out := PackedByteArray()
	out.resize(w * h)
	for i in range(w * h):
		var idxv: int = raw[6 + i * 2]
		var pal: int = raw[6 + i * 2 + 1]
		out[i] = (idxv & 0xF) | ((pal & 0xF) << 4)
	return out


static func _load_json(path: String) -> Variant:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("pre_menu_anim: missing " + path)
		return {}
	var d: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	return d

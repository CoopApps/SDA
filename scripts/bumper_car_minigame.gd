extends CanvasLayer
class_name BumperCarMinigame

## Carnival Bumper Cars duel. Faithful reimplementation of the ROM minigame at
## 0x003142 (VM op-0C subop 50), reached from the Bumper Car object 0x1B49FE.
## Derived by execution (D:/scoobydoo/work/bumpercar_minigame_spec.md):
##   * player drives the RED car (sprites/source_34, 8 direction frames);
##   * a homing-AI BLUE car (the villain, source_35) chases and rams;
##   * bump = both cars lose health (head-on ram = more), knocked apart;
##   * health starts 63, negative = spin out -> round ends;
##   * BLUE knocked out = WIN (ROM $FF120C=1 -> villain to room 7, advances the
##     carnival puzzle); RED knocked out = LOSE.
## Movement geometry (8 compass dirs, cardinal 7px/diagonal 5px per step) and the
## constants come from assets/data/global/bumper_car.json. Arena walls are the
## bounded box (the ROM's exact per-scene $FFE000 collision tilemap is a later
## refinement; a bounded arena is the faithful functional equivalent).

signal finished(won: bool)

const TICK := 1.0 / 60.0
const VW := 320
const VH := 200

var cfg: Dictionary = {}
var _red_frames: Array[Texture2D] = []
var _blue_frames: Array[Texture2D] = []
var _red: Sprite2D
var _blue: Sprite2D
var _hud: Control
var _bg: ColorRect
var _accum := 0.0
var _over := false
var _won := false
var _end_timer := 0.0
var _result_label: Label

# arena bounds (inside the box border), in viewport px
var _arena := Rect2(28, 40, 264, 140)

# per-car live state
var _cars := {}

func _init() -> void:
	layer = 50                              # above gameplay + HUD

func start() -> void:
	cfg = Game.load_json("res://assets/data/global/bumper_car.json")
	if not (cfg is Dictionary):
		cfg = {}
	_slice("res://assets/minigame/bumpercar_red.png", _red_frames)
	_slice("res://assets/minigame/bumpercar_blue.png", _blue_frames)

	# Backdrop = carnival ROOM 5's real background (the bumper-car pavilion the
	# ride lives in; the ROM snapshots the room state for this overlay -- there is
	# no separate arena-floor tile set, 0x1900C is the racer HUD portraits). The
	# cars drive on the room floor. Falls back to a dark box if the asset is absent.
	_bg = ColorRect.new()
	_bg.color = Color(0.02, 0.02, 0.05)
	_bg.size = Vector2(VW, VH)
	add_child(_bg)
	var bgpath := "res://assets/data/%s/room_05/background.png" % Game.cluster
	var bgtex: Texture2D = Game.load_texture(bgpath)
	if bgtex != null:
		var room_bg := Sprite2D.new()
		room_bg.centered = false
		room_bg.texture = bgtex
		var tw := float(bgtex.get_width())
		var th := float(bgtex.get_height())
		var s := VW / tw
		room_bg.scale = Vector2(s, s)
		room_bg.position = Vector2(0, VH - th * s)   # sit the floor at the bottom
		_bg.add_child(room_bg)
		# keep the movement arena within the visible floor band
		_arena = Rect2(20, VH - th * s + 8, VW - 40, th * s - 24)
	else:
		var fl := ColorRect.new()
		fl.color = Color(0.12, 0.10, 0.16)
		fl.position = _arena.position
		fl.size = _arena.size
		_bg.add_child(fl)

	_red = _make_car(_red_frames)
	_blue = _make_car(_blue_frames)

	var h: int = int(cfg.get("start_health", 63))
	_cars["red"] = {"sprite": _red, "frames": _red_frames,
		"pos": Vector2(_arena.position.x + 50, _arena.position.y + _arena.size.y * 0.5),
		"facing": 2, "prev": 2, "speed": 0.0, "hp": h, "turn_cd": 0, "spin": 0.0}
	_cars["blue"] = {"sprite": _blue, "frames": _blue_frames,
		"pos": Vector2(_arena.end.x - 50, _arena.position.y + _arena.size.y * 0.5),
		"facing": 6, "prev": 6, "speed": 0.0, "hp": h, "turn_cd": 0, "spin": 0.0}
	_apply_frame("red"); _apply_frame("blue")

	_build_hud()
	_bg.draw.connect(_on_bg_draw)

func _slice(path: String, out: Array) -> void:
	var tex: Texture2D = Game.load_texture(path)
	if tex == null:
		return
	var img := tex.get_image()
	var fp: int = int(cfg.get("frame_px", 82))
	var n: int = int(cfg.get("n_dirs", 8))
	for i in range(n):
		var sub := img.get_region(Rect2i(i * fp, 0, fp, fp))
		out.append(ImageTexture.create_from_image(sub))

func _make_car(frames: Array) -> Sprite2D:
	var s := Sprite2D.new()
	s.centered = true
	if not frames.is_empty():
		s.texture = frames[0]
	_bg.add_child(s) if _bg != null else add_child(_new_layer(s))
	return s

func _new_layer(n: Node) -> Node:
	return n

func _apply_frame(who: String) -> void:
	var c: Dictionary = _cars[who]
	var frames: Array = c["frames"]
	var fi: int = clampi(int(c["facing"]), 0, frames.size() - 1)
	c["sprite"].texture = frames[fi]
	c["sprite"].position = c["pos"]

func _build_hud() -> void:
	_hud = Control.new()
	_bg.add_child(_hud)
	_result_label = Label.new()
	_result_label.position = Vector2(0, VH * 0.5 - 12)
	_result_label.size = Vector2(VW, 24)
	_result_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_result_label.add_theme_font_size_override("font_size", 20)
	_result_label.visible = false
	_hud.add_child(_result_label)

func _process(delta: float) -> void:
	_accum += delta
	while _accum >= TICK:
		_accum -= TICK
		_step()
	_bg.queue_redraw()

func _step() -> void:
	if _over:
		_end_timer -= TICK
		if _end_timer <= 0.0:
			_finish()
		return
	_drive_player()
	_drive_cpu()
	_move("red")
	_move("blue")
	_resolve_bump()
	_check_dead()

func _dir_vec(facing: int) -> Vector2:
	var v: Array = cfg.get("dir_vectors", [])
	if facing >= 0 and facing < v.size():
		return Vector2(float(v[facing][0]), float(v[facing][1]))
	return Vector2.ZERO

func _drive_player() -> void:
	var c: Dictionary = _cars["red"]
	var acc: float = float(cfg.get("player_accel", 0.12))
	var fr: float = float(cfg.get("player_friction", 0.04))
	var mx: float = float(cfg.get("player_max_speed", 2.2))
	if Input.is_action_pressed("ui_up"):
		c["speed"] = minf(float(c["speed"]) + acc, mx)
	elif Input.is_action_pressed("ui_down"):
		c["speed"] = maxf(float(c["speed"]) - acc, -mx * 0.5)
	else:
		c["speed"] = move_toward(float(c["speed"]), 0.0, fr)
	if int(c["turn_cd"]) > 0:
		c["turn_cd"] = int(c["turn_cd"]) - 1
	else:
		var t := 0
		if Input.is_action_pressed("ui_right"): t = 1
		elif Input.is_action_pressed("ui_left"): t = -1
		if t != 0:
			c["facing"] = (int(c["facing"]) + t + 8) % 8
			c["turn_cd"] = int(cfg.get("turn_frames", 7))

func _drive_cpu() -> void:
	var c: Dictionary = _cars["blue"]
	var target: Vector2 = _cars["red"]["pos"]
	var want := _octant(target - c["pos"])
	if int(c["turn_cd"]) > 0:
		c["turn_cd"] = int(c["turn_cd"]) - 1
	elif want != int(c["facing"]):
		var diff := ((want - int(c["facing"]) + 8) % 8)
		c["facing"] = (int(c["facing"]) + (1 if diff <= 4 else -1) + 8) % 8
		c["turn_cd"] = int(cfg.get("cpu_turn_frames", 9))
	c["speed"] = float(cfg.get("cpu_speed", 1.7))

func _octant(v: Vector2) -> int:
	if v.length() < 0.01:
		return 2
	var ang := atan2(v.y, v.x)                  # 0=+x(right)
	# map to ROM dir order: 0=up,1=ur,2=right,3=dr,4=down,5=dl,6=left,7=ul
	var oct := int(round(ang / (PI / 4.0))) % 8
	# oct: 0=right,1=dr,2=down,3=dl,4=left,5=ul,6=up,7=ur (screen y down)
	const MAP := [2, 3, 4, 5, 6, 7, 0, 1]
	return MAP[(oct + 8) % 8]

func _move(who: String) -> void:
	var c: Dictionary = _cars[who]
	if int(c["facing"]) != int(c["prev"]):
		c["prev"] = int(c["facing"])
	var step := _dir_vec(int(c["facing"])) * float(c["speed"])
	var np: Vector2 = c["pos"] + step
	# wall collision: clamp to arena, kill speed on the blocked axis (bounce-lite)
	var r := 20.0
	if np.x < _arena.position.x + r or np.x > _arena.end.x - r:
		c["speed"] = float(c["speed"]) * 0.3
	if np.y < _arena.position.y + r or np.y > _arena.end.y - r:
		c["speed"] = float(c["speed"]) * 0.3
	np.x = clampf(np.x, _arena.position.x + r, _arena.end.x - r)
	np.y = clampf(np.y, _arena.position.y + r, _arena.end.y - r)
	c["pos"] = np
	_apply_frame(who)

func _resolve_bump() -> void:
	var a: Dictionary = _cars["red"]
	var b: Dictionary = _cars["blue"]
	var d: Vector2 = b["pos"] - a["pos"]
	var hit_r := 34.0
	if d.length() >= hit_r:
		return
	# bump: damage by head-on alignment (spec 0x3AF0). Impact octant = dir b->a.
	var impact := _octant(a["pos"] - b["pos"])
	var base: int = int(cfg.get("bump_base_damage", 9))
	var bonus: int = int(cfg.get("bump_headon_bonus", 9))
	# a car facing INTO the impact rams harder; facing away takes more.
	var a_align := _align(int(a["facing"]), impact)
	var b_align := _align(int(b["facing"]), (impact + 4) % 8)
	a["hp"] = int(a["hp"]) - (base + int(bonus * (1.0 - a_align)))
	b["hp"] = int(b["hp"]) - (base + int(bonus * (1.0 - b_align)))
	# knock apart
	var push: float = float(cfg.get("knockback_px", 18))
	var n := d.normalized() if d.length() > 0.01 else Vector2.RIGHT
	a["pos"] -= n * push * 0.5
	b["pos"] += n * push * 0.5
	a["speed"] = float(a["speed"]) * 0.2
	b["speed"] = float(b["speed"]) * 0.2
	_clamp_pos(a); _clamp_pos(b)
	_apply_frame("red"); _apply_frame("blue")
	if Game.has_method("play_sfx"):
		Game.play_sfx("bump")

func _align(facing: int, dir: int) -> float:
	# 1.0 = same heading (rammer), 0.0 = opposite (rammed head-on)
	var diff: int = mini((facing - dir + 8) % 8, (dir - facing + 8) % 8)
	return 1.0 - float(diff) / 4.0

func _clamp_pos(c: Dictionary) -> void:
	var r := 20.0
	c["pos"] = Vector2(
		clampf(c["pos"].x, _arena.position.x + r, _arena.end.x - r),
		clampf(c["pos"].y, _arena.position.y + r, _arena.end.y - r))

func _check_dead() -> void:
	if int(_cars["blue"]["hp"]) < 0:
		_end(true)
	elif int(_cars["red"]["hp"]) < 0:
		_end(false)

func _end(won: bool) -> void:
	_over = true
	_won = won
	_end_timer = 1.8
	_result_label.text = "YOU WIN!" if won else "YOU LOSE"
	_result_label.add_theme_color_override("font_color", Color(1, 0.9, 0.3) if won else Color(1, 0.4, 0.4))
	_result_label.visible = true

func _finish() -> void:
	finished.emit(_won)
	queue_free()

func _on_bg_draw() -> void:
	if not _cars.has("red"):
		return
	var maxh: float = float(cfg.get("start_health", 63))
	_bar(Vector2(_arena.position.x, 24), maxf(0.0, float(_cars["red"]["hp"])) / maxh, Color(0.9, 0.25, 0.25), "YOU")
	_bar(Vector2(_arena.end.x - 100, 24), maxf(0.0, float(_cars["blue"]["hp"])) / maxh, Color(0.35, 0.5, 0.95), "RIVAL")

func _bar(at: Vector2, frac: float, col: Color, label: String) -> void:
	var w := 100.0
	_bg.draw_rect(Rect2(at, Vector2(w, 8)), Color(0, 0, 0, 0.6))
	_bg.draw_rect(Rect2(at, Vector2(w * clampf(frac, 0, 1), 8)), col)
	var f := ThemeDB.fallback_font
	_bg.draw_string(f, at + Vector2(0, -2), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 8, Color.WHITE)

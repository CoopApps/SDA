extends Node2D

## Shared player for the three finalized intro scenes (room9 Hallway, room10
## Outside the Hotel, room16 Lobby) — a direct GDScript port of the proven
## logic already validated across work/room9_mockup.html, room10_mockup.html
## and room16_mockup.html this session: real ROM-decoded backgrounds/actors,
## floating dialogue (anchor frozen once per line, real per-line flag_word
## color, only the current speaker's talk-anim cycles), walk-on/off actors
## (never "beam"), data-driven timeline (move/anim/text/sound/wait/leave).
##
## Each scene supplies its own data JSON (assets/intros/room9_data.json etc,
## a straight copy of the already-validated work/room*_data.json) plus a
## small per-scene config for the handful of things that differ per room
## (front-plane z-order, starting actor poses, extra static overlays like
## room16's fireplace or room9's door cel).

signal finished

const GLYPH := 8
## ONE unit: the VBLANK frame. An animation step's `dur` ($FF0618, decremented
## by 0xAFD0) and op-21 wait_n_frames ($FF08AE, decremented at 0xA6FC) are both
## decremented inside gameplay_per_frame 0xA65C on the same VBLANK, so both are
## 1/60s. The earlier "anim durations are 30fps ticks" note was a cached
## conclusion with no derivation behind it, contradicted by 0xAFD0.
const TICK_MS := 1000.0 / 60.0
const FRAME_MS := 1000.0 / 60.0

@export var data_path: String = ""
@export var front_over_actors: bool = false   # room16: real priority tiles draw OVER actors
@export var next_scene_path: String = ""      # "" = emit `finished` only, caller decides
# The real ROM mechanism for actor depth-scaling (if any) is unresolved --
# see memory/actor-depth-scaling-investigation.md: the OAM-emit routine was
# fully traced and ruled out as the source, and no per-room flag or layer
# count was found in the shared scene-activation routine (0x00758A) either.
# User confirmed (ground truth, has played the original) it should only
# apply in the lobby -- an explicit per-scene port setting, not a citation.
@export var depth_scale_enabled: bool = false

var DATA: Dictionary = {}

var _bg_back: Sprite2D
var _bg_front: Sprite2D
var _font_img: Image
var _font_meta: Dictionary
var _tint_cache: Dictionary = {}   # color name -> Image (tinted glyph atlas)

var _scroll_x: float = 0.0
var _room_y: float = 0.0

# actor runtime state, keyed by str(sel)
var _actors: Dictionary = {}
# per-actor loaded frame data: sel -> {seq(String) -> {loop,loop_to,frames:[{dur,hx,hy,flip,tex}]}}
var _actor_frames: Dictionary = {}
var _actor_nodes: Dictionary = {}   # sel -> Sprite2D

var _timeline: Array = []
var _ti := 0
var _wait_ms := 0.0
var _await_text := false
var _speaking_sel := ""
var _mouth_accum := 0.0
const MOUTH_MS := 110.0

var _float_lines: Array = []
var _float_color: Color = Color.WHITE
var _float_x := 0.0
var _float_y := 0.0
var _float_node: Sprite2D
var _dlg_advance_ms := 0.0

var _done := false


func _ready() -> void:
	DATA = _load_json(data_path)
	_scroll_x = float(DATA.get("scroll_x", 0))
	_room_y = float(DATA.get("room_y", 0))
	_bg_back = _make_sprite(_b64_tex(DATA.get("bg_back", {}).get("png", "")), -20)
	_bg_front = _make_sprite(_b64_tex(DATA.get("bg_front", {}).get("png", "")),
		1000 if front_over_actors else -10)
	_bg_back.position = Vector2(_scroll_x, _room_y)
	_bg_front.position = Vector2(_scroll_x, _room_y)

	var fm: Dictionary = DATA.get("font", {})
	if fm.has("png"):
		_font_meta = fm
		_font_img = _b64_image(str(fm["png"]))

	_load_actor_defs()
	_apply_home_positions()   # actors seeded by the chapter actor-init template, not the script (e.g. room10's Blake)
	_extra_ready()   # per-scene hook (room16 fireplace, room9 door)

	_timeline = DATA.get("timeline", [])
	if _timeline.is_empty():
		_timeline = _build_timeline()   # per-scene hook for data without a "timeline" field

	set_process(true)
	_setup_fade()
	_fade_in()


## ------------------------------------------------------------ scene fade ---
const FADE_MS := 450.0

var _fade_layer: CanvasLayer
var _fade_rect: ColorRect

func _setup_fade() -> void:
	_fade_layer = CanvasLayer.new()
	_fade_layer.layer = 128   # above everything this scene draws
	add_child(_fade_layer)
	_fade_rect = ColorRect.new()
	_fade_rect.color = Color.BLACK
	_fade_rect.size = Vector2(320, 200)
	_fade_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fade_layer.add_child(_fade_rect)


func _fade_in() -> void:
	_fade_rect.modulate.a = 1.0
	var tw := create_tween()
	tw.tween_property(_fade_rect, "modulate:a", 0.0, FADE_MS / 1000.0)


func _fade_out() -> void:
	_fade_rect.modulate.a = 0.0
	var tw := create_tween()
	tw.tween_property(_fade_rect, "modulate:a", 1.0, FADE_MS / 1000.0)
	await tw.finished


## Some actors (e.g. room10's Blake, cited to cluster_init_entities 0x7F66)
## are already standing in the room when the script starts -- their position
## comes from the chapter's actor-init template, not a move_actor_to_xy call,
## so they never get an explicit "move" timeline step. DATA carries these as
## "<lowercase actor name>_home": [x, y]. Without this, such an actor stays
## permanently invisible (_ensure_actor() defaults visible=false, and only
## _do_move() ever flips it true).
func _apply_home_positions() -> void:
	var actors_data: Dictionary = DATA.get("actors", {})
	for key in DATA.keys():
		var key_str := str(key)
		if not key_str.ends_with("_home"):
			continue
		var pos: Array = DATA[key]
		if pos.size() < 2:
			continue
		var prefix := key_str.substr(0, key_str.length() - 5).to_lower()
		for sel in actors_data.keys():
			if str((actors_data[sel] as Dictionary).get("name", "")).to_lower() != prefix:
				continue
			var a := _ensure_actor(str(sel))
			a["x"] = float(pos[0])
			a["y"] = float(pos[1])
			a["visible"] = true
			break


## Override point: extra static setup (fireplace, door cel) beyond bg/actors.
func _extra_ready() -> void:
	pass


## Override point: scenes whose data JSON has no "timeline" (room9) build one here.
func _build_timeline() -> Array:
	return []


func _process(delta: float) -> void:
	if _done:
		return
	var ms := delta * 1000.0
	_tick_actors(ms)
	_tick_mouth(ms)
	_tick_extra(ms)   # per-scene hook (flame flicker, bulb cycle)
	if _wait_ms > 0.0:
		_wait_ms -= ms
		return
	if _await_text:
		return
	if _awaiting_anim_sel != "":
		if not _actors.has(_awaiting_anim_sel) or not bool((_actors[_awaiting_anim_sel] as Dictionary).get("_wait_anim_done", false)):
			return
		_awaiting_anim_sel = ""
	if _awaiting_move_sel != "":
		if _actors.has(_awaiting_move_sel) and (_actors[_awaiting_move_sel] as Dictionary).has("walk_to"):
			return
		_awaiting_move_sel = ""
	if _ti >= _timeline.size():
		_finish()
		return
	_run_step(_timeline[_ti])
	_ti += 1


func _extra_tick(_ms: float) -> void:
	pass


func _tick_extra(ms: float) -> void:
	_extra_tick(ms)


## JSON has no int type -- Godot's JSON parser decodes every number as
## float, so a bare str() on a parsed "sel": 5 gives "5.0", not "5",
## silently breaking every dictionary keyed by str(step["sel"]) against
## _actor_frames (whose keys come from JSON OBJECT keys, already real
## strings with no ".0"). Route every actor-id stringification through
## this so the two key spaces always agree.
static func _num_key(v: Variant) -> String:
	if typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT:
		return str(int(v))
	return str(v)

## Timeline text steps carry the speaker's display NAME ("Fred"); _actors is
## keyed by script sel ("13"). Without this mapping no speaker ever matched, so
## talk animations never played (Shaggy's 20-frame head-scratch sat unused) and
## the head anchor fell back. Sels per room10-outside-hotel memory.
const SPEAKER_SELS := {"Shaggy": "1", "Scooby": "2", "Fred": "13",
	"Velma": "14", "Daphne": "15", "Blake": "26"}

func _speaker_sel(name: String) -> String:
	if _actors.has(name):
		return name                      # already a sel (numeric or direct key)
	return str(SPEAKER_SELS.get(name, name))


## ------------------------------------------------------------- timeline ---
func _run_step(step: Dictionary) -> void:
	if _handle_custom_step(step):
		return
	match str(step.get("t", "")):
		"move":
			_do_move(step)
		"anim":
			_set_anim(_num_key(step["sel"]), int(step["seq"]))
		"text":
			_show_text(_num_key(step.get("speaker", "")), str(step.get("color", "#ffffff")),
				str(step.get("text", "")))
		"sound":
			pass   # SFX not wired yet (matches the mockups: sound events are logged, not played)
		"wait":
			# op-21 wait_n_frames counts VBLANK display frames (60Hz): the
			# operand goes into $FF08AE, decremented once per frame at 0xA6FC.
			# Anim step `dur` is the SAME unit -- both are decremented inside
			# gameplay_per_frame 0xA65C on the same VBLANK (dur at 0xAFD0), so
			# TICK_MS and FRAME_MS are now both 1/60. The earlier note here
			# claiming anim durations were 30fps ticks was wrong.
			_wait_ms = float(step.get("frames", 0)) * FRAME_MS
		"wait_anim":
			var sel := _num_key(step["sel"])
			if _actors.has(sel):
				(_actors[sel] as Dictionary)["_wait_anim_done"] = false
				_awaiting_anim_sel = sel
		"wait_move":
			# Blocks until this actor's current walk_to arrives -- matches the
			# room9 artifact's own `await tweenActor(...)`, where every walk
			## is sequential unless the data explicitly omits this step (room10's
			# concurrent gang walk-in has no wait_move between its moves).
			_awaiting_move_sel = _num_key(step["sel"])
		"leave":
			_leave(_num_key(step["sel"]))
		"hide":
			if _actors.has(_num_key(step["sel"])):
				(_actors[_num_key(step["sel"])] as Dictionary)["visible"] = false


## Override point: per-scene step kinds (room9's "door"). Return true if handled.
func _handle_custom_step(_step: Dictionary) -> bool:
	return false


var _awaiting_anim_sel := ""
var _awaiting_move_sel := ""


func _ensure_actor(sel: String) -> Dictionary:
	if not _actors.has(sel):
		_actors[sel] = {"x": 0.0, "y": 0.0, "anim": "", "frame": 0, "accum": 0.0,
			"visible": false, "face_left": false}
		var spr := Sprite2D.new()
		spr.centered = false
		add_child(spr)
		_actor_nodes[sel] = spr
	return _actors[sel]


## Actors WALK to their target over real time (never teleport/"beam") unless
## explicitly snapped (their very first placement in a scene). Matches the
## user's explicit correction earlier this session: "NO BEAM IN AND BEAM OUT
## ... THEY SHOULD WALK ON AND OFF."
const WALK_PXMS := 0.09

func _do_move(step: Dictionary) -> void:
	var sel := _num_key(step["sel"])
	var a := _ensure_actor(sel)
	a["visible"] = true
	if step.get("anim") != null:
		_set_anim(sel, int(step["anim"]))
	if bool(step.get("snap", false)):
		a["x"] = float(step["x"]); a["y"] = float(step["y"])
		_face_toward(sel, float(step["x"]))
	else:
		a["walk_to"] = Vector2(float(step["x"]), float(step["y"]))
		if not is_equal_approx(float(step["x"]), float(a["x"])):
			a["face_left"] = float(step["x"]) < a["x"]
			a["facing_known"] = true


## Face an actor toward target_x. A ZERO-distance call (e.g. a snap placement,
## which sets x BEFORE calling this) carries NO direction information -- claiming
## facing intent there would override the frame's authored orientation. The
## room-9 maid is the case in point: her per-actor `native_left` is calibrated
## for her FLEE frames, so forcing "face right" on the snap mirrored her
## sweeping art the wrong way round. No movement -> no intent -> the drawn frame
## keeps its own descriptor flip.
func _face_toward(sel: String, target_x: float) -> void:
	var a: Dictionary = _actors[sel]
	if is_equal_approx(target_x, float(a["x"])):
		return
	a["face_left"] = target_x < a["x"]
	a["facing_known"] = true


func _set_anim(sel: String, seq: int) -> void:
	var a := _ensure_actor(sel)
	var key := str(seq)
	if _actor_frames.has(sel) and (_actor_frames[sel] as Dictionary).has(key):
		a["anim"] = key
		a["frame"] = 0
		a["accum"] = 0.0
		a["_wait_anim_done"] = false


func _leave(sel: String) -> void:
	if _actors.has(sel):
		(_actors[sel] as Dictionary)["walk_leave"] = true


func _finish() -> void:
	if _done:
		return
	_done = true
	emit_signal("finished")
	if next_scene_path != "":
		await _fade_out()
		get_tree().change_scene_to_file(next_scene_path)


func _unhandled_input(event: InputEvent) -> void:
	var pressed: bool = (event is InputEventKey and event.pressed) \
		or (event is InputEventMouseButton and event.pressed) \
		or (event is InputEventJoypadButton and event.pressed)
	if not pressed:
		return
	if _await_text:
		_await_text = false
		_clear_float_line()
		if _speaking_sel != "" and _actors.has(_speaking_sel):
			var idle_map: Dictionary = DATA.get("idle", {})
			if idle_map.has(_speaking_sel):
				_set_anim(_speaking_sel, int(idle_map[_speaking_sel]))
				(_actors[_speaking_sel] as Dictionary)["_talk_loop"] = false
		_speaking_sel = ""


## --------------------------------------------------------------- actors ---
# Most sprite banks are drawn facing right (mirror to face left). A few
# (room9's maid, confirmed against her flee frames) are natively drawn
# facing LEFT -- flipping her on a leftward move was cancelling out the
# turn instead of showing it. DATA.actors[sel].native_left marks these.
var _actor_native_left: Dictionary = {}

func _load_actor_defs() -> void:
	var actors_data: Dictionary = DATA.get("actors", {})
	for sel in actors_data.keys():
		var ad: Dictionary = actors_data[sel]
		_actor_native_left[sel] = bool(ad.get("native_left", false))
		var anims_out: Dictionary = {}
		var anims_in: Dictionary = ad.get("anims", {})
		for seq in anims_in.keys():
			var def: Dictionary = anims_in[seq]
			var frames_out: Array = []
			for f in (def.get("frames", []) as Array):
				var fd: Dictionary = f
				frames_out.append({
					"dur": int(fd.get("dur", 2)),
					"hx": int(fd.get("hx", 0)), "hy": int(fd.get("hy", 0)),
					"flip": bool(fd.get("flip", false)),
					"tex": _b64_tex(str(fd.get("png", ""))),
				})
			anims_out[str(seq)] = {"loop": bool(def.get("loop", true)),
				"loop_to": int(def.get("loop_to", 0)), "frames": frames_out}
		_actor_frames[sel] = anims_out


func _tick_actors(ms: float) -> void:
	for sel in _actors.keys():
		var a: Dictionary = _actors[sel]
		if not a.get("visible", false):
			continue
		# walk toward a queued target (never teleport mid-scene)
		if a.has("walk_to"):
			var target: Vector2 = a["walk_to"]
			var pos := Vector2(a["x"], a["y"])
			var step: float = WALK_PXMS * ms
			var to_target := target - pos
			if to_target.length() <= step:
				a["x"] = target.x; a["y"] = target.y
				a.erase("walk_to")
				# DATA's "idle" map (sel -> idle anim index) is the ROM's own
				# per-actor standing pose; without switching to it on arrival,
				# an actor keeps looping its last walk cycle forever.
				var idle_map: Dictionary = DATA.get("idle", {})
				if idle_map.has(sel):
					_set_anim(sel, int(idle_map[sel]))
			else:
				var d := to_target.normalized() * step
				a["x"] += d.x; a["y"] += d.y
		elif a.get("walk_leave", false):
			# walk off in the current facing direction until off-screen, then hide
			var dir := -1.0 if a.get("face_left", false) else 1.0
			a["x"] += dir * WALK_PXMS * ms
			if a["x"] < _scroll_x - 40 or a["x"] > _scroll_x + 360:
				a["visible"] = false
				a.erase("walk_leave")
		# advance the current animation
		var seq := str(a.get("anim", ""))
		if seq != "" and _actor_frames.has(sel) and (_actor_frames[sel] as Dictionary).has(seq):
			var def: Dictionary = _actor_frames[sel][seq]
			var frames: Array = def["frames"]
			if frames.size() > 0:
				var fr: Dictionary = frames[a["frame"]]
				a["accum"] = float(a["accum"]) + ms
				var hold: float = float(fr["dur"]) * TICK_MS
				if a["accum"] >= hold:
					a["accum"] = 0.0
					var nxt: int = int(a["frame"]) + 1
					if nxt >= frames.size():
						# force-loop while talking (DATA.talk anim, see
						# _sync_speaker_anims) even if the anim isn't natively
						# looping, so the mouth keeps moving for the whole line
						if bool(def["loop"]) or bool(a.get("_talk_loop", false)):
							nxt = int(def["loop_to"])
						else:
							nxt = frames.size() - 1
							a["_wait_anim_done"] = true
					a["frame"] = nxt
		_draw_actor(sel, a)


func _draw_actor(sel: String, a: Dictionary) -> void:
	var spr: Sprite2D = _actor_nodes[sel]
	spr.visible = bool(a.get("visible", false))
	if not spr.visible:
		return
	var seq := str(a.get("anim", ""))
	if seq == "" or not _actor_frames.has(sel):
		return
	var def: Dictionary = _actor_frames[sel][seq]
	var frames: Array = def["frames"]
	if frames.is_empty():
		return
	var fr: Dictionary = frames[int(a["frame"])]
	var tex: Texture2D = fr["tex"]
	if tex == null:
		return
	spr.texture = tex
	var w := float(tex.get_width())
	# Display facing: when the scene has EXPLICITLY faced this actor (walk
	# direction, face_ref_x idle facing, speaker-faces-Blake), that intent wins
	# outright -- the seq's own descriptor flip must not XOR against it (Fred's
	# talk seqs are all flip-variants; XOR made him face AWAY while talking).
	# With no explicit intent, fall back to the frame's descriptor flip (the
	# previously validated behaviour for direction-encoded mirrored seqs).
	# fr.flip always still normalises the hotspot to raw-art space.
	var native_left: bool = bool(_actor_native_left.get(sel, false))
	var mirror: bool
	if bool(a.get("facing_known", false)):
		mirror = bool(a.get("face_left", false)) != native_left
	else:
		mirror = bool(fr["flip"])
	var raw_hx: float = (w - float(fr["hx"])) if bool(fr["flip"]) else float(fr["hx"])
	spr.flip_h = mirror
	# Hotspot position in the DRAWN sprite's own local space (mirrored art puts
	# it on the other side), and the depth scale applied at this y.
	var local_hx: float = (w - raw_hx) if mirror else raw_hx
	var local_hy: float = float(fr["hy"])
	var s := 1.0
	if depth_scale_enabled:
		# Depth-scale curve mirroring gameplay's actor.gd update_depth() -- only
		# the lobby (room16) uses it, per user confirmation; see
		# depth_scale_enabled's own comment for why it's not ROM-cited.
		var room_h: float = float(DATA.get("bg_back", {}).get("h", 152))
		var horizon: float = room_h * 0.35
		var tt: float = clampf((float(a["y"]) - horizon) / (room_h - horizon), 0.0, 1.0)
		s = lerpf(0.55, 1.0, tt)
	spr.scale = Vector2.ONE * s
	# A Sprite2D with centered=false scales about its POSITION (its top-left),
	# NOT about the hotspot -- so scaling shrank the art toward the top-left and
	# lifted the feet off the floor (Blake floated ~29px above the lobby rug at
	# s=0.6). Anchor the SCALED hotspot on the actor's world point instead.
	spr.position = Vector2(_scroll_x + float(a["x"]) - local_hx * s,
		_room_y + float(a["y"]) - local_hy * s)
	# z-sort by y like the mockups (`sort((p,q)=>actors[p].y-actors[q].y)`)
	spr.z_index = int(a["y"])
	spr.z_as_relative = false


func _tick_mouth(ms: float) -> void:
	if _speaking_sel == "" or not _actors.has(_speaking_sel):
		return
	# talk anim is just whatever "anim" step set for the speaker (matches the
	# mockups: driven off the timeline's own speaker field, NOT a separate
	# per-frame talk-cycle flag) — nothing to do here beyond normal _tick_actors.
	pass


## ------------------------------------------------------------- dialogue ---
func _tint_glyph_atlas(color: Color) -> Image:
	var key := color.to_html()
	if _tint_cache.has(key):
		return _tint_cache[key]
	var img: Image = _font_img.duplicate()
	img.convert(Image.FORMAT_RGBA8)
	for y in range(img.get_height()):
		for x in range(img.get_width()):
			var p := img.get_pixel(x, y)
			if p.a > 0.0:
				img.set_pixel(x, y, Color(color.r, color.g, color.b, p.a))
	_tint_cache[key] = img
	return img


func _wrap_text(text: String, max_w: int, scale: float) -> Array:
	var gw := int(_font_meta.get("gw", GLYPH)) * scale
	var words := text.split(" ")
	var lines: Array = []
	var cur := ""
	for w in words:
		var t: String = (cur + " " + w) if cur != "" else w
		if t.length() * gw <= max_w:
			cur = t
		else:
			if cur != "":
				lines.append(cur)
			cur = w
	if cur != "":
		lines.append(cur)
	return lines


func _actor_head_anchor(sel: String) -> Vector2:
	if _actor_nodes.has(sel) and _actors.has(sel):
		var a: Dictionary = _actors[sel]
		var spr: Sprite2D = _actor_nodes[sel]
		var top: float = spr.position.y
		return Vector2(_scroll_x + float(a["x"]), top)
	return Vector2(128, 40)


## Cross-referenced against the room10 artifact's own JS: the ROM script's raw
## "anim" ops don't correspond 1:1 to who's actually speaking (e.g. Blake's
## channel gets set right before a Shaggy line), which made the wrong actor
## animate. The artifact's own fix -- confirmed working -- ignores those raw
## ops entirely and drives talk/idle purely off each line's speaker: only the
## speaker plays DATA.talk[sel] (looped), everyone else (visible, not
## mid-walk) holds DATA.idle[sel]. Idle actors also face the scene's
## "face_ref_x" (Blake, when present) the same way the artifact's playIdle/
## playTalk do.
func _sync_speaker_anims(speaking_sel: String) -> void:
	var talk_map: Dictionary = DATA.get("talk", {})
	var idle_map: Dictionary = DATA.get("idle", {})
	var ref_x: Variant = DATA.get("face_ref_x", null)
	for sel in _actors.keys():
		var a: Dictionary = _actors[sel]
		if not bool(a.get("visible", false)) or a.has("walk_to"):
			continue
		if sel == speaking_sel and talk_map.has(sel):
			_set_anim(sel, int(talk_map[sel]))
			a["_talk_loop"] = true
		else:
			if idle_map.has(sel):
				_set_anim(sel, int(idle_map[sel]))
			a["_talk_loop"] = false
			if ref_x != null:
				a["face_left"] = float(a["x"]) > float(ref_x)
				a["facing_known"] = true


func _show_text(speaker: String, color_hex: String, text: String) -> void:
	speaker = _speaker_sel(speaker)      # display name -> actor sel
	_speaking_sel = speaker
	_sync_speaker_anims(speaker)
	var anchor_ref: Variant = DATA.get("face_ref_x", null)
	if speaker != "" and anchor_ref != null and _actors.has(speaker):
		# The speaker faces the reference (Blake) too: LEFT iff standing to
		# his RIGHT. (Was inverted -- Fred talked facing away from Blake.)
		var sa: Dictionary = _actors[speaker]
		sa["face_left"] = float(sa["x"]) > float(anchor_ref)
		sa["facing_known"] = true
	var scale := 2.0    # was 0.85 (< native 8px glyph, hard to read); 2x for legibility
	var anchor := _actor_head_anchor(speaker)
	_float_color = Color(color_hex)
	_float_lines = _wrap_text(text, 288, scale)   # < 320 screen width so lines fit; clamp keeps the box on-screen
	_float_x = anchor.x
	_float_y = anchor.y
	_render_float_line(scale)
	_await_text = true


func _render_float_line(scale: float) -> void:
	if _font_img == null or _float_lines.is_empty():
		return
	var gw := int(_font_meta.get("gw", GLYPH))
	var gh := int(_font_meta.get("gh", GLYPH))
	var cols := int(_font_meta.get("cols", 16))
	var first := int(_font_meta.get("first", 32))
	var max_len := 0
	for l in _float_lines:
		max_len = max(max_len, str(l).length())
	var pad := 2   # room for the black outline
	var img_w := int(max_len * gw * scale) + pad * 2
	var img_h := int(_float_lines.size() * (gh * scale + 2)) + pad * 2
	var out := Image.create(img_w, img_h, false, Image.FORMAT_RGBA8)
	var tinted := _tint_glyph_atlas(_float_color)
	var black := _tint_glyph_atlas(Color.BLACK)
	var offs := [Vector2i(-1, -1), Vector2i(0, -1), Vector2i(1, -1), Vector2i(-1, 0),
		Vector2i(1, 0), Vector2i(-1, 1), Vector2i(0, 1), Vector2i(1, 1)]
	var ty := pad
	for l in _float_lines:
		var line := str(l)
		var w := line.length() * gw * scale
		var lx := int(pad + (img_w - pad * 2 - w) / 2.0)
		for off in offs:
			_blit_line(out, black, line, lx + off.x, ty + off.y, gw, gh, cols, first, scale)
		_blit_line(out, tinted, line, lx, ty, gw, gh, cols, first, scale)
		ty += int(gh * scale) + 2
	if _float_node == null:
		_float_node = Sprite2D.new()
		_float_node.centered = false
		_float_node.z_index = 2000
		add_child(_float_node)
	_float_node.texture = ImageTexture.create_from_image(out)
	# Keep the whole box on-screen (320x200 here, no root scale). Centre on the
	# speaker's head, then clamp to the edges so the 2x dialogue can't stick off
	# the side when a speaker stands near the left/right of the room.
	var px := clampf(_float_x - img_w / 2.0, 2.0, maxf(2.0, 320.0 - img_w - 2.0))
	var py := clampf(_float_y - img_h - 3.0, 1.0, maxf(1.0, 200.0 - img_h - 1.0))
	_float_node.position = Vector2(px, py)
	_float_node.visible = true


func _blit_line(out: Image, atlas: Image, line: String, x: int, y: int, gw: int, gh: int,
		cols: int, first: int, scale: float) -> void:
	var gx := x
	for i in range(line.length()):
		var ch := line.unicode_at(i)
		if ch != 32 and ch >= first and ch < first + 96:
			var gi := ch - first
			var sx := (gi % cols) * gw
			var sy := int(gi / cols) * gw
			var src := Rect2i(sx, sy, gw, gh)
			if scale == 1.0:
				out.blit_rect(atlas, src, Vector2i(gx, y))
			else:
				var scaled := atlas.get_region(src)
				scaled.resize(int(gw * scale), int(gh * scale), Image.INTERPOLATE_NEAREST)
				out.blend_rect(scaled, Rect2i(Vector2i.ZERO, scaled.get_size()), Vector2i(gx, y))
		gx += int(gw * scale)


func _clear_float_line() -> void:
	_float_lines = []
	if _float_node != null:
		_float_node.visible = false


## ---------------------------------------------------------------- utils ---
func _make_sprite(tex: Texture2D, z: int) -> Sprite2D:
	var s := Sprite2D.new()
	s.centered = false
	s.texture = tex
	s.z_index = z
	add_child(s)
	return s


func _b64_image(b64: String) -> Image:
	if b64 == "":
		return null
	var img := Image.new()
	img.load_png_from_buffer(Marshalls.base64_to_raw(b64))
	return img


func _b64_tex(b64: String) -> ImageTexture:
	var img := _b64_image(b64)
	if img == null:
		return null
	return ImageTexture.create_from_image(img)


static func _load_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	var d: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	return d if d is Dictionary else {}

extends "res://scripts/vm_presenter.gd"

## Episode-intro presenter — ported from D:\scoobydoo\godot\scripts\intro_vm.gd
## (823 lines, extensively ROM-cited, confirmed working by direct play-through
## for the titlecard/van-drive/room-3-interior-chat portion). That file walked
## its OWN flat event array against the OLD pre-canonical schema; this port
## drives identical presentation logic from script_vm.gd's signals instead,
## consuming the NEW canonical schema (scooby_script_decode.py) -- needed
## because the old flat walker has no way to execute the nested condition/
## "then" trees decode_actions() emits for 0x03/0x04, which script_vm.gd
## already handles correctly via recursion.
##
## Hotel sequence (ROM-confirmed room names):
##   The Mystery Machine (3) -> [STOP HERE, see ROOM_STOP_AT] ->
##   The Hallway (9, maid/ghost) -> Outside the Hotel (10, Blake) ->
##   The Lobby (16) -> PlayRoom.
## Room 9 (maid/ghost) is explicitly excluded for now (known coordinate/
## layering bugs from the predecessor project, needs its own rework) --
## the presenter stops cleanly the moment the VM tries to transition there.

signal titlecard_done
signal stopped_before_excluded_scene(room_id: int)
signal _never   # deliberately never emitted -- see _handle_blocking's room-stop path

const FPS := 60.0
const SCENES_DIR := "res://assets/intros/scenes/"
const FONT_PATH := "res://assets/hud_font.png"
const GLYPH := 8
const FONT_COLS := 16
const FIRST_CHAR := 0x20

# Rooms not yet ported (see class doc) -- the presenter halts (does not call
# vm.resume()) the moment a scene-transition targets one of these, holding on
# the last good frame instead of rendering a known-wrong scene.
const ROOM_STOP_AT := {9: true}

var chapter := "hotel"

var _bg: Sprite2D
var _front_bg: Sprite2D
var _scene_w := 0
const Z_BACK := -20
const Z_FACE_B := -15
const Z_FRONT := 1000   # see intro_vm.gd's class doc for why this isn't -10
const Z_FACE_A := 1005   # BUG FIX: was -5 -- comment said "over the front layer"
# (Z_FRONT=1000) but the value was nowhere near above it, so Velma/Daphne/
# Fred's plane-A faces silently rendered BEHIND the van's front dashboard/
# window layer -- talk-anim textures were updating correctly, just fully
# hidden. This exact bug was inherited verbatim from the predecessor
# project's intro_vm.gd. Shaggy/Scooby (plane B, meant to sit BEHIND the
# front layer) happened to render correctly since their intended z-order
# matched the actual one.
var _actors: Dictionary = {}
var _actor_layer: Node2D
var _font_img: Image
var _line_colors: Dictionary = {}   # flag_word (String) -> hex color, scene-3 only
var _cur_scene := -1
var _actor_roomed: Dictionary = {}
var _actor_anim_done: Dictionary = {}

const FACES_DIR := "res://assets/intros/scenes/faces/"
const FACE_FRAME_HOLD := 6
var _faces: Dictionary = {}

const ACTORS_DIR := "res://assets/intros/actors/"
const ACTOR_FRAME_HOLD := 6
const SCENE_SCROLL := {9: -140}
var _actor_defs: Dictionary = {}
var _actor_anim: Dictionary = {}
var _face: Sprite2D
var _face_talk: Array = []
var _face_i := 0
var _face_accum := 0
var _face_active := false

var _interior_scene := -1
var _scene_base := Vector2.ZERO
var _face_base := Vector2.ZERO
var _bob_y := 0.0
var _bob_vel := 0.0
var _bob_timer := 0
var _bob_rng := RandomNumberGenerator.new()

const TITLECARD_HOLD := 150
var _phase := "titlecard"
var _tc_frames := 0
var _van: Sprite2D
var _van_x := -158.0
var _van_end := 256.0
var _van_origin := Vector2(4, 143)
var _px_layers: Array = []
var _px_frame := 0.0
var _van_delta: Array = [0, 1, 1, 1, 2, 2, 2, 1, 1, 1, 0]
var _van_frames: Array = []
var _van_x_speed := 0.5
var _van_bob := 0

const CELART_DIR := "res://assets/intros/celart/"
const Z_CELART := -8
var _celart: Dictionary = {}
var _entity_size: Dictionary = {}
var _cels: Dictionary = {}

var _stopped := false


func setup(chapter_: String, events: Array) -> void:
	# Native Genesis art (256x224) scaled to fill the PC port's 320x200 canvas.
	# One root-level scale rather than touching every sprite this presenter
	# creates (backdrop, van, room3 background, faces, floating dialogue).
	scale = Vector2(320.0 / 256.0, 200.0 / 224.0)
	chapter = chapter_
	_actor_layer = Node2D.new()
	add_child(_actor_layer)
	_build_dialogue()
	_faces = _load_json(FACES_DIR + "faces.json")
	_actor_defs = _load_json(ACTORS_DIR + "actors.json")
	_line_colors = _load_json("res://assets/intros/room3_line_colors.json").get("colors", {})
	_load_celart()
	for e in events:
		if String(e.get("op", "")) in ["load_room_at_entry_with_facing", "change_scene_with_palette_fadeout"]:
			_interior_scene = int(e.get("to_room", -1)); break
	_bob_rng.randomize()
	_start_titlecard()


func _process(_delta: float) -> void:
	if _phase == "titlecard":
		_tick_titlecard()
	_tick_bob()
	_face_cycle()
	_actor_cycle()


## --------------------------------------------------------------- title card
func _start_titlecard() -> void:
	var mani := _load_json("res://assets/intros/scenes/titlecard.json")
	var chapters: Dictionary = mani.get("chapters", {})
	var px: Dictionary = chapters.get(chapter, {})
	var a_rate := _rate_tex(px.get("planeA_row_rate", []))
	var b_rate := _rate_tex(px.get("planeB_row_rate", []))
	var backdrop := ColorRect.new()
	backdrop.size = Vector2(256, 224)
	backdrop.color = Color(0, 0, 0)
	backdrop.z_index = -40
	add_child(backdrop)
	_px_layers.append(backdrop)
	var built := false
	for spec in [["Blo", b_rate, -30], ["Alo", a_rate, -28],
				 ["Bhi", b_rate, -20], ["Ahi", a_rate, -18]]:
		var lyr := _make_px_layer("titlecard_%s_px%s" % [chapter, spec[0]], spec[1], int(spec[2]))
		if lyr != null:
			_px_layers.append(lyr); built = true
	if not built:
		var tex := _scene_texture("titlecard_" + chapter)
		if tex == null:
			_phase = "intro"
			# Deferred: this fires synchronously inside setup(), which the
			# caller invokes BEFORE it has a chance to await titlecard_done --
			# an immediate emit() here would be lost with nothing listening
			# yet (same class of race as the Acclaim scroll bug earlier this
			# session: resume-before-await). Deferring guarantees the awaiter
			# is registered first.
			titlecard_done.emit.call_deferred()
			return
		_bg = Sprite2D.new(); _bg.centered = false; _bg.z_index = -10
		add_child(_bg); _bg.texture = tex; _bg.position = Vector2.ZERO
	_phase = "titlecard"
	_tc_frames = 0
	_px_frame = 0.0
	_setup_van()


func _make_px_layer(stem: String, rate_tex: Texture2D, z: int) -> ColorRect:
	var tex := _scene_texture(stem)
	if tex == null or rate_tex == null:
		return null
	var mat := ShaderMaterial.new()
	mat.shader = preload("res://shaders/titlecard_parallax.gdshader")
	mat.set_shader_parameter("layer_tex", tex)
	mat.set_shader_parameter("row_rate", rate_tex)
	mat.set_shader_parameter("tex_w", float(tex.get_width()))
	mat.set_shader_parameter("frame_count", 0.0)
	var cr := ColorRect.new()
	cr.size = Vector2(256, 224)
	cr.position = Vector2.ZERO
	cr.material = mat
	cr.z_index = z
	cr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	add_child(cr)
	return cr


func _rate_tex(rates: Array) -> Texture2D:
	if rates.is_empty():
		return null
	var img := Image.create(1, rates.size(), false, Image.FORMAT_RF)
	for y in range(rates.size()):
		img.set_pixel(0, y, Color(float(rates[y]) / 8.0, 0, 0))
	return ImageTexture.create_from_image(img)


func _setup_van() -> void:
	var mani := _load_json("res://assets/intros/scenes/titlecard.json")
	var van: Dictionary = mani.get("van", {})
	if van.has("start_x"): _van_x = float(van["start_x"])
	if van.has("end_x"): _van_end = float(van["end_x"])
	if van.has("origin"): _van_origin = Vector2(float(van["origin"][0]), float(van["origin"][1]))
	if van.has("delta_table") and (van["delta_table"] as Array).size() > 0:
		_van_delta = van["delta_table"]
	if van.has("x_speed"): _van_x_speed = float(van["x_speed"])
	_van_frames = []
	for fn in van.get("frames", []):
		var t := _load_tex("res://assets/intros/scenes/" + String(fn))
		if t != null:
			_van_frames.append(t)
	if _van_frames.is_empty():
		var t := _load_tex("res://assets/intros/scenes/titlecard_van.png")
		if t != null:
			_van_frames.append(t)
	if _van_frames.is_empty():
		return
	_van = Sprite2D.new()
	_van.centered = false
	_van.texture = _van_frames[0]
	_van.z_index = -24
	add_child(_van)
	_place_van()


func _place_van() -> void:
	if _van != null:
		_van.position = Vector2(_van_origin.x + _van_x, _van_origin.y + _van_bob)


func _tick_titlecard() -> void:
	_tc_frames += 1
	_px_frame += 1.0
	for lyr in _px_layers:
		if lyr.material is ShaderMaterial:
			(lyr.material as ShaderMaterial).set_shader_parameter("frame_count", _px_frame)
	if _van != null and _van_x < _van_end:
		_van_x += _van_x_speed
		_van_bob = int(_van_delta[_tc_frames % _van_delta.size()])
		if _van_bob < _van_frames.size():
			_van.texture = _van_frames[_van_bob]
		_place_van()
	if _van_x >= _van_end or (_van == null and _tc_frames >= TITLECARD_HOLD):
		_end_titlecard()


func _end_titlecard() -> void:
	if _phase != "titlecard":
		return
	_phase = "intro"
	if _van != null:
		_van.queue_free()
		_van = null
	for lyr in _px_layers:
		lyr.queue_free()
	_px_layers.clear()
	titlecard_done.emit()


func _tick_bob() -> void:
	if _phase == "titlecard" or _cur_scene != _interior_scene or _bg == null:
		return
	_bob_timer -= 1
	if _bob_timer <= 0:
		var d: float = float(_bob_rng.randi_range(4, 8))
		if _bob_rng.randf() < 0.5:
			d = -d
		_bob_vel += d
		_bob_timer = _bob_rng.randi_range(24, 72)
	_bob_vel += -_bob_y * 0.3
	_bob_vel *= 0.72
	_bob_y += _bob_vel
	var oy: float = round(_bob_y)
	_bg.position.y = _scene_base.y + oy
	if _front_bg != null and _front_bg.visible:
		_front_bg.position.y = _scene_base.y + oy
	if _face != null and _face.visible:
		_face.position.y = _face_base.y + oy


## ---------------------------------------------------------------- op dispatch
## Non-blocking ops (fire and forget -- stepping already moved on).
func _on_op_fired(op_name: String, data: Dictionary) -> void:
	match op_name:
		"move_actor_to_room":
			_set_actor_room(int(data.get("entity", 0)), int(data.get("room", 0)))
		"actor_set_word0_and_raise_pending_flag":
			var a0 := int(data.get("actor", 0))
			var v0 := int(data.get("value", 0))
			if _is_background_object(a0):
				_swap_cel(a0, v0)
			else:
				_play_actor_anim(a0, v0)
		"set_actor_shape_index", "set_actor_asset_id":
			var a1 := int(data.get("actor", 0))
			if _is_background_object(a1):
				_swap_cel(a1, int(data.get("value", 0)))
		"queue_sound_driver_id":
			pass   # TODO: drive the sound engine
		_:
			pass   # assign / subcommand / unmodeled: state-only


## Blocking ops -- must call resume() (via the base class wrapper) once done.
func _handle_blocking(op_name: String, data: Dictionary) -> void:
	match op_name:
		"load_room_at_entry_with_facing", "change_scene_with_palette_fadeout":
			var room_id := int(data.get("to_room", -1))
			if ROOM_STOP_AT.has(room_id):
				# Room 9 onward is now handled by the dedicated, ROM-accurate
				# scenes built this session (intro_scene_player.gd chain:
				# Room9Intro -> Room10Intro -> Room16Intro -> PlayRoom), not
				# this generic script_vm.gd-driven presenter — hand off
				# cleanly instead of halting forever.
				_stopped = true
				stopped_before_excluded_scene.emit(room_id)
				get_tree().change_scene_to_file("res://Room9Intro.tscn")
				await _never
			_load_scene(room_id)
		"draw_text_message_and_wait":
			await _show_text_and_wait(int(data.get("flag_word", 0)), String(data.get("text", "")))
		"move_actor_to_xy":
			await _move_actor(int(data.get("actor", 0)), int(data.get("x", 0)), int(data.get("y", 0)),
				int(data.get("walk_anim", 0xFFFF)))
		"wait_n_frames":
			var n := int(data.get("frames", 0))
			for i in range(n):
				await get_tree().process_frame
		"wait_until_anim_channel_signalled":
			var aid := int(data.get("channel", 0))
			while not bool(_actor_anim_done.get(aid, false)):
				await get_tree().process_frame
		"start_anim_sequence_and_wait":
			_play_actor_anim(int(data.get("channel", 0)), int(data.get("seq", 0)))
			# ROM-cited from the predecessor: this signals via the SAME per-actor
			# anim-done flag wait_until_anim_channel_signalled checks -- but the
			# op itself doesn't block on it (only op17 does); fire and continue.
		_:
			pass   # move_actor_to_waypoint / resume_anim_channel_wait_drawn /
			       # wait_while_channel_busy: not yet exercised by this chapter's
			       # room-3 span, left as instant no-ops rather than guessed.


## ------------------------------------------------- background-art cel swap
func _load_celart() -> void:
	var doc := _load_json(CELART_DIR + "index.json")
	_celart = doc.get("rooms", {})
	var path := "D:/scoobydoo/%s/entities/entities.json" % chapter
	if FileAccess.file_exists(path):
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
		if parsed is Array:
			for i in range((parsed as Array).size()):
				_entity_size[i + 3] = int((parsed as Array)[i].get("size", 18))


func _is_background_object(actor_id: int) -> bool:
	return int(_entity_size.get(actor_id, 18)) == 14


func _swap_cel(actor_id: int, shape: int) -> void:
	var room: Dictionary = _celart.get(str(_cur_scene), {})
	var rec: Dictionary = room.get(str(shape), {})
	if rec.is_empty():
		if _cels.has(actor_id):
			(_cels[actor_id] as Sprite2D).visible = false
		return
	var tex := _load_tex(CELART_DIR + String(rec["png"]))
	if tex == null:
		return
	var s: Sprite2D
	if _cels.has(actor_id):
		s = _cels[actor_id]
	else:
		s = Sprite2D.new()
		s.centered = false
		_actor_layer.add_child(s)
		_cels[actor_id] = s
	s.texture = tex
	s.visible = true
	var bx := (_bg.position.x if _bg != null else 0.0)
	var by := (_bg.position.y if _bg != null else 0.0)
	s.position = Vector2(bx + float(rec["x"]), by + float(rec["y"]))
	s.z_index = Z_CELART


## ------------------------------------------------------------------- rendering
func _load_scene(scene_id: int) -> void:
	var stem := "%s_%d" % [chapter, scene_id]
	var back_tex := _scene_texture(stem + "_back")
	var front_tex := _scene_texture(stem + "_front")
	var split := back_tex != null and front_tex != null
	var tex := back_tex if split else _scene_texture(stem)
	if tex == null:
		return
	if _bg == null:
		_bg = Sprite2D.new()
		_bg.centered = false
		add_child(_bg)
	_bg.texture = tex
	_bg.z_index = Z_BACK if split else -10
	_scene_w = tex.get_width()
	_cur_scene = scene_id
	_stop_face()
	var scroll_x: float = float(SCENE_SCROLL.get(scene_id, 0))
	var pos := Vector2(scroll_x, 0.0)
	_bg.position = pos
	_scene_base = pos
	if scene_id == _interior_scene:
		_bob_y = 0.0; _bob_vel = 0.0
		_bob_timer = _bob_rng.randi_range(20, 50)
	if split:
		if _front_bg == null:
			_front_bg = Sprite2D.new()
			_front_bg.centered = false
			_front_bg.z_index = Z_FRONT
			add_child(_front_bg)
		_front_bg.texture = front_tex
		_front_bg.position = pos
		_front_bg.visible = true
	elif _front_bg != null:
		_front_bg.visible = false
	for id in _actors.keys():
		_actors[id].queue_free()
	_actors.clear()
	_actor_anim.clear()
	for id in _cels.keys():
		_cels[id].queue_free()
	_cels.clear()


func _scene_texture(stem: String) -> Texture2D:
	var path := SCENES_DIR + stem + ".idx"
	if not FileAccess.file_exists(path):
		return null
	var f := FileAccess.open(path, FileAccess.READ)
	var w := f.get_16(); var h := f.get_16(); f.get_16()
	var raw := f.get_buffer(w * h * 2)
	f.close()
	var pal := _load_json_arr(SCENES_DIR + stem + "_pal.json")
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	for y in range(h):
		for x in range(w):
			var o := (y * w + x) * 2
			var ci := raw[o]; var pl := raw[o + 1]
			if ci == 0 or pl >= pal.size() or ci >= (pal[pl] as Array).size():
				img.set_pixel(x, y, Color(0, 0, 0, 0))
			else:
				var c: Array = pal[pl][ci]
				img.set_pixel(x, y, Color8(c[0], c[1], c[2]))
	return ImageTexture.create_from_image(img)


## ----------------------------------------------------------- actors
func _actor_marker(id: int) -> Node2D:
	if _actors.has(id):
		return _actors[id]
	if _actor_defs.has(str(id)):
		var s := Sprite2D.new()
		s.centered = false
		_actor_layer.add_child(s)
		_actors[id] = s
		var anims: Dictionary = _actor_defs[str(id)].get("anims", {})
		if not anims.is_empty():
			_play_actor_anim(id, int(String(anims.keys()[0])))
		return s
	var m := Node2D.new()
	var r := ColorRect.new()
	r.size = Vector2(14, 22)
	r.position = Vector2(-7, -22)
	r.color = Color.from_hsv(fmod(float(id) * 0.16, 1.0), 0.7, 0.9)
	m.add_child(r)
	var l := Label.new()
	l.text = str(id)
	l.position = Vector2(-7, -22)
	l.add_theme_font_size_override("font_size", 8)
	m.add_child(l)
	_actor_layer.add_child(m)
	_actors[id] = m
	return m


func _play_actor_anim(id: int, anim: int) -> void:
	if not _actor_defs.has(str(id)):
		return
	var anims: Dictionary = _actor_defs[str(id)].get("anims", {})
	if not anims.has(str(anim)):
		return
	var def: Dictionary = anims[str(anim)]
	var texs: Array = []
	for fr in def.get("frames", []):
		var t := _load_tex(ACTORS_DIR + String(fr["file"]))
		if t != null:
			texs.append(t)
	if texs.is_empty():
		return
	var loop: bool = def.has("loop_to_step") if not def.has("loop") else bool(def["loop"])
	var loop_to: int = int(def.get("loop_to_step", 0))
	_actor_anim[id] = {"frames": texs, "i": 0, "accum": 0, "loop": loop, "loop_to": loop_to}
	_actor_anim_done[id] = false
	if _actors.has(id) and _actors[id] is Sprite2D:
		(_actors[id] as Sprite2D).texture = texs[0]


func _actor_cycle() -> void:
	for id in _actor_anim.keys():
		var a: Dictionary = _actor_anim[id]
		var frames: Array = a["frames"]
		var last: int = frames.size() - 1
		if not bool(a["loop"]) and int(a["i"]) >= last:
			_actor_anim_done[id] = true
			continue
		a["accum"] += 1
		if a["accum"] >= ACTOR_FRAME_HOLD:
			a["accum"] = 0
			var nxt: int = int(a["i"]) + 1
			if nxt > last:
				nxt = int(a["loop_to"]) if bool(a["loop"]) else last
			a["i"] = nxt
			if not bool(a["loop"]) and nxt >= last:
				_actor_anim_done[id] = true
			if _actors.has(id) and _actors[id] is Sprite2D:
				(_actors[id] as Sprite2D).texture = frames[nxt]


func _move_actor(id: int, x: int, y: int, walk_anim: int = 0xFFFF) -> void:
	var m := _actor_marker(id)
	var bx := (_bg.position.x if _bg != null else 0.0)
	var by := (_bg.position.y if _bg != null else 0.0)
	var pos := Vector2(bx + x, by + y)
	if not bool(_actor_roomed.get(id, false)):
		m.position = pos
		m.z_index = int(pos.y)
		return
	if m is Sprite2D and pos.x != m.position.x:
		(m as Sprite2D).flip_h = pos.x < m.position.x
	if walk_anim != 0xFFFF:
		_play_actor_anim(id, walk_anim)
	var dist := m.position.distance_to(pos)
	var secs: float = clampf(dist / 90.0, 0.25, 2.0)
	var tw := create_tween()
	tw.tween_property(m, "position", pos, secs)
	tw.parallel().tween_property(m, "z_index", int(pos.y), secs).set_ease(Tween.EASE_IN)
	await tw.finished


func _set_actor_room(id: int, room: int) -> void:
	if room == 0:
		if _actors.has(id):
			_actors[id].queue_free(); _actors.erase(id)
		_actor_roomed.erase(id)
	else:
		_actor_marker(id)
		_actor_roomed[id] = true


## ---------------------------------------------------------- floating dialogue
## Finalized PC-port style (locked in this session): text floats above the
## speaker's own head instead of a bottom text-box, black-outlined, real
## per-line color decoded from the scene's own flag_word/CRAM palette
## (room3_line_colors.json), anchor frozen once per line (recomputing every
## frame from a live talk-anim causes visible bobbing — found and fixed
## earlier this session), only the current speaker's portrait animates.
# Dialogue glyph scale. Was 0.85 (SMALLER than the native 8px ROM glyph -> ~6.8px,
# hard to read). Bumped to a clean 2x (16px) for legibility; NEAREST keeps it crisp.
# Wrap width widened to match so lines don't over-wrap in the 320px screen.
const FLOAT_SCALE := 2.0
const FLOAT_MAX_W := 260

var _float_node: Sprite2D
var _tint_cache: Dictionary = {}


func _build_dialogue() -> void:
	var f := FileAccess.open(FONT_PATH, FileAccess.READ)
	if f != null:
		_font_img = Image.new()
		_font_img.load_png_from_buffer(f.get_buffer(f.get_length()))
		f.close()
	_float_node = Sprite2D.new()
	_float_node.centered = false
	_float_node.z_index = 2000
	_float_node.visible = false
	add_child(_float_node)


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


func _wrap_text(text: String, max_w: int) -> Array:
	var gw := GLYPH * FLOAT_SCALE
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


func _blit_line(out: Image, atlas: Image, line: String, x: int, y: int) -> void:
	var gx := x
	for i in range(line.length()):
		var ch := line.unicode_at(i)
		if ch != 32 and ch >= FIRST_CHAR and ch < FIRST_CHAR + 96:
			var gi := ch - FIRST_CHAR
			var src := Rect2i((gi % FONT_COLS) * GLYPH, (gi / FONT_COLS) * GLYPH, GLYPH, GLYPH)
			if FLOAT_SCALE == 1.0:
				out.blit_rect(atlas, src, Vector2i(gx, y))
			else:
				var scaled := atlas.get_region(src)
				scaled.resize(int(GLYPH * FLOAT_SCALE), int(GLYPH * FLOAT_SCALE), Image.INTERPOLATE_NEAREST)
				out.blend_rect(scaled, Rect2i(Vector2i.ZERO, scaled.get_size()), Vector2i(gx, y))
		gx += int(GLYPH * FLOAT_SCALE)


func _face_anchor(speaker: int) -> Vector2:
	var key := str(speaker)
	if _faces.has(key):
		var fd: Dictionary = _faces[key]
		return _scene_base + Vector2(int(fd["x"]) * 8 + 20, int(fd["y"]) * 8)
	return Vector2(128, 40)


func _render_float_line(text: String, color: Color, anchor: Vector2) -> void:
	if _font_img == null:
		return
	var lines := _wrap_text(text, FLOAT_MAX_W)
	if lines.is_empty():
		return
	var gw := GLYPH * FLOAT_SCALE
	var gh := GLYPH * FLOAT_SCALE
	var max_len := 0
	for l in lines:
		max_len = maxi(max_len, String(l).length())
	var pad := 2
	var img_w := int(max_len * gw) + pad * 2
	var img_h := int(lines.size() * (gh + 2)) + pad * 2
	var out := Image.create(img_w, img_h, false, Image.FORMAT_RGBA8)
	var tinted := _tint_glyph_atlas(color)
	var black := _tint_glyph_atlas(Color.BLACK)
	var offs := [Vector2i(-1, -1), Vector2i(0, -1), Vector2i(1, -1), Vector2i(-1, 0),
		Vector2i(1, 0), Vector2i(-1, 1), Vector2i(0, 1), Vector2i(1, 1)]
	var ty := pad
	for l in lines:
		var line := String(l)
		var w := line.length() * gw
		var lx := int(pad + (img_w - pad * 2 - w) / 2.0)
		for off in offs:
			_blit_line(out, black, line, lx + off.x, ty + off.y)
		_blit_line(out, tinted, line, lx, ty)
		ty += int(gh) + 2
	_float_node.texture = ImageTexture.create_from_image(out)
	_float_node.position = Vector2(anchor.x - img_w / 2.0, maxf(1.0, anchor.y - img_h - 3.0))
	_float_node.visible = true


signal _dialogue_advance
var _await_text := false

func _show_text_and_wait(speaker: int, text: String) -> void:
	var color := Color(String(_line_colors.get(str(speaker), "#ffffff")))
	_render_float_line(text, color, _face_anchor(speaker))
	_start_face(speaker)
	_await_text = true
	await _dialogue_advance
	_float_node.visible = false
	_stop_face()


func _unhandled_input(event: InputEvent) -> void:
	if not _await_text:
		return
	var pressed: bool = (event is InputEventKey and event.pressed) \
		or (event is InputEventMouseButton and event.pressed) \
		or (event is InputEventJoypadButton and event.pressed)
	if pressed:
		_await_text = false
		_dialogue_advance.emit()


## ------------------------------------------------------------ face animation
func _start_face(speaker: int) -> void:
	_stop_face()
	if _cur_scene != 3 or _bg == null:
		return
	var key := str(speaker)
	if not _faces.has(key):
		return
	var fd: Dictionary = _faces[key]
	_face_talk = []
	for fn in fd.get("talking", []):
		var t := _load_tex(FACES_DIR + String(fn))
		if t != null:
			_face_talk.append(t)
	if _face_talk.is_empty():
		return
	if _face == null:
		_face = Sprite2D.new()
		_face.centered = false
		add_child(_face)
	_face.z_index = Z_FACE_A if String(fd.get("plane", "A")) == "A" else Z_FACE_B
	_face_base = _scene_base + Vector2(int(fd["x"]) * 8, int(fd["y"]) * 8)
	_face.position = _face_base + Vector2(0, round(_bob_y))
	_face.texture = _face_talk[0]
	_face.visible = true
	_face_i = 0
	_face_accum = 0
	_face_active = true


func _face_cycle() -> void:
	if not _face_active or _face == null or _face_talk.is_empty():
		return
	_face_accum += 1
	if _face_accum >= FACE_FRAME_HOLD:
		_face_accum = 0
		_face_i = (_face_i + 1) % _face_talk.size()
		_face.texture = _face_talk[_face_i]


func _stop_face() -> void:
	_face_active = false
	if _face != null:
		_face.visible = false


func _load_tex(path: String) -> Texture2D:
	if not FileAccess.file_exists(path):
		return null
	return ImageTexture.create_from_image(Image.load_from_file(path))


static func _load_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	var d: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	return d if d is Dictionary else {}


static func _load_json_arr(path: String) -> Array:
	if not FileAccess.file_exists(path):
		return []
	var f := FileAccess.open(path, FileAccess.READ)
	var d: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	return d if d is Array else []

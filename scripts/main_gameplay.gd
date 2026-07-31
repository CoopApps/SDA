extends Node2D

## Interactive-gameplay bootstrap: loads a room, spawns Shaggy/Scooby, the
## verb/inventory UI (ui.gd) and a scrolling camera. This is scoobygodot's
## port of the predecessor project's main.gd, adapted to Game's
## scene_manifest-centric data (Game.scene_for()/item_icon_id()/
## item_for_entity() replace main.gd's own local bundle-shaped lookups —
## same behavior, one less duplicate copy of the data).
##
## PlayRoom.tscn attaches this after the intro chain hands off
## (Room16Intro -> PlayRoom); Game.pending_cluster/pending_start_room are
## already set by then (default: hotel room 16, the lobby).

const RoomScript := preload("res://scripts/room.gd")
const CharScript := preload("res://scripts/controllable.gd")
const UIScript := preload("res://scripts/ui.gd")
const HotspotOverlayScript := preload("res://scripts/hotspot_overlay.gd")
const RunnerScript := preload("res://scripts/room_behavior_runner.gd")
const FloatingTextScript := preload("res://scripts/floating_text.gd")
const NpcActorScript := preload("res://scripts/actor.gd")

# Per-character floating-dialogue color. Shaggy's is cited (sampled from his
# own sprite's shirt pixels, see the verb/inventory artifact's own note).
# Scooby has no equivalent citation yet -- off-white placeholder, not an
# invented "Scooby orange".
const CHAR_TEXT_COLOR := {0: Color(109.0 / 255, 182.0 / 255, 73.0 / 255), 1: Color(0.9, 0.9, 0.85)}

# State -> ANIMATION INDEX in the bank's lifted anims.json (cited to
# sprite_port_data.json animation_index_table). Grounded against live
# behavior: anim 0 = horizontal walk (faces right unflipped, h-flipped for
# left), anim 2 = away (up), anim 3 = toward camera (down).
# Anims 0-3 are the 8-frame WALK cycles; anims 4-7 are the dedicated single-frame
# STANDING/REST poses (4=right side, 5=left side native, 6=UP/back view, 7=DOWN/
# front view -- confirmed by rendering the frames) -- same layout for both
# source_00 (Shaggy) and source_01 (Scooby). Idle must use the rest poses, NOT
# walk-anim frame 0 (a mid-stride, one-leg-up pose). a5 is a native-left rest so
# idle_left needs no flip.
const SHAGGY_ANIMS := {
	"walk_right": 0, "walk_left": 0, "walk_up": 2, "walk_down": 3,
	"idle": 7, "idle_left": 5, "idle_right": 4, "idle_up": 6, "idle_down": 7,
}
const SCOOBY_ANIMS := {
	"walk_right": 0, "walk_left": 0, "walk_up": 2, "walk_down": 3,
	"idle": 7, "idle_left": 5, "idle_right": 4, "idle_up": 6, "idle_down": 7,
}
const HERO_FLIP := {"walk_left": true}

var room: Node2D
var chars: Array[Node2D] = []      # [shaggy, scooby]
var active_index := 0
var ui: CanvasLayer
var camera: Camera2D
var room_index: int = 0
var hotspot_overlay: Node2D
var floating_text: Sprite2D

func active_char() -> Node2D:
	return chars[active_index]


## Matches Room4Intro's own fade-out (intro_scene_player.gd) so gameplay
## doesn't pop in abruptly right after the intro chain fades to black.
const FADE_MS := 450.0
var _fade_layer: CanvasLayer
var _fade_rect: ColorRect

func _setup_fade() -> void:
	_fade_layer = CanvasLayer.new()
	_fade_layer.layer = 128
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

func _ready() -> void:
	room = RoomScript.new()
	add_child(room)

	var shaggy: Node2D = CharScript.new()
	add_child(shaggy)
	shaggy.room = room
	shaggy.setup("D:/scoobydoo/sprites/source_00", SHAGGY_ANIMS, HERO_FLIP)

	var scooby: Node2D = CharScript.new()
	add_child(scooby)
	scooby.room = room
	scooby.setup("D:/scoobydoo/sprites/source_01", SCOOBY_ANIMS, HERO_FLIP)

	chars = [shaggy, scooby]
	_set_active(0)

	# Camera: follows the active character horizontally; vertically pinned
	# so the room sits at the TOP of the screen (bottom band is the UI).
	camera = Camera2D.new()
	camera.zoom = Vector2.ONE
	add_child(camera)
	camera.make_current()

	hotspot_overlay = HotspotOverlayScript.new()
	hotspot_overlay.room = room
	hotspot_overlay.z_index = 4000
	add_child(hotspot_overlay)

	floating_text = FloatingTextScript.new()
	add_child(floating_text)

	_setup_fade()
	_fade_in()

	ui = UIScript.new()
	add_child(ui)
	ui.verb_selected.connect(_on_verb)
	ui.actor_selected.connect(_on_actor)
	ui.item_selected.connect(_on_item)

	# Chapter routing: Game.pending_cluster/pending_start_room are set by the
	# menu (default: hotel, room 16 — the lobby the intro hands off into).
	if Game.pending_cluster != Game.cluster:
		Game.set_cluster(Game.pending_cluster)
	var start_room: int = Game.pending_start_room if Game.pending_cluster == "hotel" \
			else int(Game.rooms[0]["room_id"])
	for i in range(Game.rooms.size()):
		if int(Game.rooms[i]["room_id"]) == start_room:
			room_index = i
			break
	_enter_room(Game.rooms[room_index])

	# Dev aid (like the F-key overlays): SCOOBY_SHOT=<path> captures a real
	# screenshot after the room settles, then quits. Headless-safe validation
	# of the true composite (planes + camera crop + NPCs + HUD + fonts).
	if OS.get_environment("SCOOBY_SHOT") != "":
		_dev_screenshot(OS.get_environment("SCOOBY_SHOT"))

func _dev_screenshot(out_path: String) -> void:
	var shot_room := OS.get_environment("SCOOBY_SHOT_ROOM")
	if shot_room != "" and int(shot_room) != room.room_id:
		for i in range(Game.rooms.size()):
			if int(Game.rooms[i]["room_id"]) == int(shot_room):
				room_index = i
				_enter_room(Game.rooms[i])
				break
	if OS.get_environment("SCOOBY_SHOT_TEXT") != "":
		ui.show_message(OS.get_environment("SCOOBY_SHOT_TEXT"))
	if OS.get_environment("SCOOBY_SHOT_ITEM") != "":
		for it in OS.get_environment("SCOOBY_SHOT_ITEM").split(","):
			ui.add_item(it.strip_edges())
	if OS.get_environment("SCOOBY_SHOT_OVERLAY") != "":
		hotspot_overlay.mode = int(OS.get_environment("SCOOBY_SHOT_OVERLAY")) % 4
		hotspot_overlay.queue_redraw()
	for i in range(14):
		await get_tree().process_frame
	var img: Image = get_viewport().get_texture().get_image()
	img.save_png(out_path)
	print("[dev_screenshot] room %d -> %s (%dx%d)" %
		[room.room_id, out_path, img.get_width(), img.get_height()])
	get_tree().quit()

func _set_active(idx: int) -> void:
	active_index = idx
	for i in range(chars.size()):
		chars[i].active = (i == idx)

func _on_actor(player_def: Dictionary) -> void:
	# Actor buttons (Shaggy/Scooby) switch which character you control.
	var pid := int(player_def.get("id", 0))
	if pid == 0:
		_set_active(0)
	elif pid == 1:
		_set_active(1)

## room16's own intro hand-off positions (Room16Intro's timeline: sel 1
## Shaggy snaps to (248,80), sel 2 Scooby to (248,81), neither moves again
## before the scene ends) -- so PlayRoom's very first room16 entry starts
## them exactly where the cutscene left them, instead of the generic
## floor-spawn search picking an unrelated spot.
const ROOM16_HANDOFF_POS := [Vector2(248, 80), Vector2(248, 81)]
var _first_entry := true
## Entry-point index for the NEXT room load (ROM $FF069E, set by op-24's
## `(4,A5)` operand). 0 unless the transition that sent us named one.
var _pending_entry_index := 0

func _enter_room(desc: Dictionary) -> void:
	if not room.load_room(desc):
		return
	var size: Vector2 = room.pixel_size()
	if _first_entry and room.room_id == 16:
		# Start exactly where the lobby cutscene left them...
		for i in range(chars.size()):
			chars[i].position = ROOM16_HANDOFF_POS[i]
		# ...but those two points are 1px apart (the cutscene stacked them), so
		# the companion is invisible behind the lead. He walks off to his own
		# spot as gameplay begins, which is what the hand-off looks like in the
		# original. Deferred so the room's reachable map is built first.
		_separate_companion.call_deferred()
	else:
		# The ROM places the leads at the room's ENTRY POINT, not an arbitrary
		# floor tile: scene_load (0x78DA/row 308) reads the entry index $FF069E
		# into the entry table $FF0696 and writes entry.x<<3 / entry.y<<3 to
		# BOTH leads ($FF04DC/$FF04E0, $FF04F4/$FF04F8). That table is the same
		# one op-$0E waypoints use, already extracted per room. So arriving in a
		# room puts you AT the door you came through, not mid-floor.
		var pl := active_char()
		var entry := Game.waypoint_px(room.room_id, _pending_entry_index)
		if entry.x >= 0 and not room.is_blocked(entry.x, entry.y):
			pl.position = entry
		else:
			pl.position = _find_spawn(size)
		_pending_entry_index = 0
		var near := _spawn_near(pl.position)
		for c in chars:
			if c != pl:
				c.position = near
	room.compute_reachable(active_char().position)
	for c in chars:
		c.update_depth()
	_first_entry = false
	if hotspot_overlay:
		hotspot_overlay.queue_redraw()
	_spawn_npcs()
	ui.show_message("")     # sentence line stays blank until a real command
	# Run the scene's ENTRY(+0xC)/SECONDARY(+0x10) scripts (ROM 0x221A/0x2278,
	# run_initial_scene_scripts 0x000CD0 / row 40 -- the ROM runs these every scene
	# load). They set initial flags, place/motion arrival actors, and play once-only
	# on-arrival cutscenes (self-gated by their own op-03 flag guards, so replay is
	# not an issue). Deferred so the room + NPCs finish building first; the run is
	# its own coroutine so it doesn't block room setup.
	_run_entry_scripts.call_deferred(room.room_id)

## Run the room's scene entry/secondary scripts on arrival, once per entry, in
## address order (entry then secondary), through the same behaviour runner that
## drives object scripts. Data: assets/data/<cluster>/room_NN/entry_script.json
## (exporters/gen_scene_entry_scripts.py; ROM +0xC/+0x10 scripts the port used to
## drop). op-1A cycle anims are already stripped from that file (cycle.json owns
## them). Guarded so a mid-cutscene room change aborts the leftover run.
func _run_entry_scripts(rid: int) -> void:
	var path := "res://assets/data/%s/room_%02d/entry_script.json" % [Game.cluster, rid]
	if not FileAccess.file_exists(path):
		return
	var data: Variant = Game.load_json(path)
	if not (data is Dictionary):
		return
	var runner := _ensure_runner()
	for block in ["entry", "secondary"]:
		var actions: Variant = data.get(block)
		if actions is Array and not actions.is_empty():
			if room == null or room.room_id != rid:
				return                      # player already left -- abandon the run
			await runner.run(_entry_safe(actions))

## Arrival scripts do STATE/actor/anim/text setup -- they must never change the
## room. Strip any scene-transition op (defence in depth: a mis-decode or an
## unverified ROM special case, e.g. carnival room 31's unguarded
## load_room_at_entry_with_facing, would otherwise teleport the player on entry).
const _ENTRY_BANNED := ["load_room_at_entry_with_facing", "change_scene_with_palette_fadeout"]
func _entry_safe(actions: Array) -> Array:
	var out: Array = []
	for a in actions:
		if not (a is Dictionary):
			continue
		if String(a.get("op", "")) in _ENTRY_BANNED:
			push_warning("entry_script: dropped scene-change op %s (arrival scripts don't change rooms)" % a.get("op"))
			continue
		var b: Dictionary = a.duplicate(true)
		for k in ["then", "actions"]:
			if b.get(k) is Array:
				b[k] = _entry_safe(b[k])
		out.append(b)
	return out

## --- Companion behaviour (Scooby) ------------------------------------------
## ROM-derived: there is NO wander AI. The per-frame routine at 0x6D24 gates on
## $FF09EB bit6 and, when set, drives the companion straight off the LEAD's
## state -- `MOVE.W $FF04DC,$FF04E0` / `$FF04F4,$FF04F8` (copy position),
## `MOVE.W D1,$FF048A` (copy facing/anim from $FF05B8) and `BSET #1,$FF0AB5`
## (raise his pending-move flag). Outside that mode the companion is moved only
## by script ops (0x4A86) or by scene_load placing BOTH leads at the room's
## entry point (0x78C0) -- which is why he "comes with you" between rooms.
##
## Port interpretation: a mirror-exactly-on-top copy reads wrong at 320x200, so
## the companion PATH-FOLLOWS the lead to a nearby free tile once the lead has
## moved beyond FOLLOW_NEAR, using the same walk/anim code as a player walk.
## Everything except that spacing is the ROM's own model.
const FOLLOW_NEAR := 34.0        # start following once this far from the lead
const FOLLOW_STOP := 22.0        # settle this close behind

## Walk the companion off the lead's exact pixel (see the room-16 hand-off).
func _separate_companion() -> void:
	if chars.size() < 2:
		return
	var lead := active_char()
	var mate: Node2D = chars[1 - active_index]
	if mate == null or lead == null:
		return
	if mate.position.distance_to(lead.position) > FOLLOW_STOP:
		return
	var spot := _spawn_near(lead.position)
	if mate.has_method("walk_to"):
		mate.walk_to(spot)

func _companion_tick() -> void:
	if chars.size() < 2:
		return
	var lead := active_char()
	var mate: Node2D = chars[1 - active_index]
	if mate == null or lead == null:
		return
	if mate.walk_target != null:
		return                                   # already on its way
	var d := mate.position.distance_to(lead.position)
	if d <= FOLLOW_NEAR:
		return
	# aim for a free spot just behind the lead, never his exact pixel
	var back := (mate.position - lead.position).normalized() * FOLLOW_STOP
	var goal := lead.position + back
	if room != null and room.is_blocked(goal.x, goal.y):
		goal = _spawn_near(lead.position)
	if mate.has_method("walk_to"):
		mate.walk_to(goal)

func _spawn_near(origin: Vector2) -> Vector2:
	# Stand the companion a clear sprite-width away so the two don't overlap.
	for dist in range(52, 120, 8):
		for offset: Vector2 in [Vector2(dist, 0), Vector2(-dist, 0),
				Vector2(dist, 8), Vector2(-dist, 8)]:
			var p: Vector2 = origin + offset
			if not room.is_blocked(p.x, p.y):
				return p
	return origin + Vector2(52, 0)

func _find_spawn(size: Vector2) -> Vector2:
	# Stand just above the floor markers (57 = floor line, 1-6 = stair
	# edges): take the median-x marker on the lowest row that has any, so
	# the spawn lands mid-floor rather than at a room edge.
	for y in range(room.height_tiles - 1, 0, -1):
		var xs: Array[int] = []
		for x in range(1, room.width_tiles - 1):
			var v: int = room.collision[y * room.width_tiles + x]
			if v == 57 or (v >= 1 and v <= 6):
				xs.append(x)
		if not xs.is_empty():
			var mx: int = xs[xs.size() / 2]
			return Vector2(mx * 8 + 4, y * 8 - 2)
	# Fallback: center-outward search for any open cell
	var center := size / 2.0
	for radius in range(0, int(size.x / 2), 8):
		for angle in range(0, 360, 30):
			var p := center + Vector2.from_angle(deg_to_rad(angle)) * radius
			if not room.is_blocked(p.x, p.y):
				return p
	return center

## ------------------------------------------------------- resident NPCs ------
## Spawn the room's resident NPC/actor sprites and make them clickable. These
## are entities that carry dialogue (manifest behaviors) but have NO clickable
## hotspot bounds -- so their dialogue was unreachable ("dead data"). The sprite
## itself becomes their click target, routing to the SAME _interact() path as
## bounded hotspots. Presence is the static signal (record placed a sprite in
## this scene); the ROM's runtime activation timer (+0xA -> +0x18 bit2, ROM
## 0x7C1C-0x7C2C) is not modelled, so a story-gated NPC could appear early --
## acceptable vs. leaving dialogue dead.
var _npcs: Array = []            # [{eid:int, node:Actor, name:String}]

func _spawn_npcs() -> void:
	for e in _npcs:
		var n = e.get("node")
		if is_instance_valid(n):
			n.queue_free()
	_npcs = []
	if room == null:
		return
	for def in Game.talkable_npcs(room.room_id):
		var a := NpcActorScript.new()
		a.room = room
		room.add_child(a)
		# Static idle pose: show the validated frame and place it with its REAL
		# per-frame hotspot (top-left = pos-hotspot, the SEGA rule). We do NOT
		# play an animation -- the Actor's animated path would overwrite the
		# offset with its (-w/2,-h) approximation, and the lift's frame-offset
		# alignment isn't reliable enough to animate without jitter.
		var tex := Game.load_texture("%s/%s" % [Game.kit_path(str(def["dir"])), str(def["frame"])])
		if tex != null:
			a.sprite.texture = tex
			a.sprite.offset = Vector2(-float(def["hx"]), -float(def["hy"]))
		a.position = Vector2(float(def["x"]), float(def["y"]))
		# Depth-sort only (walk in front of / behind by y); no perspective scale
		# -- the ROM's per-slot depth scaling (opcode 12/sub 21) isn't confirmed
		# for these residents, and the placement was verified at full size.
		a.z_index = int(a.position.y)
		_npcs.append({"eid": int(def["entity_id"]), "node": a,
			"name": str(def.get("name", "")),
			"clickable": bool(def.get("clickable", true))})

## Synthesize an _interact() hotspot for a click that landed on a resident NPC
## sprite (feet-centered at position, offset -w/2,-h). {} if none hit.
func _npc_hotspot_at(world: Vector2) -> Dictionary:
	for e in _npcs:
		if not bool(e.get("clickable", true)) and str(e.get("name", "")) == "":
			continue                # unnamed scenery actor: let the click fall through
		var a = e.get("node")
		if not is_instance_valid(a) or a.sprite == null or a.sprite.texture == null:
			continue
		var w := float(a.sprite.texture.get_width())
		var h := float(a.sprite.texture.get_height())
		var left: float = a.position.x + a.sprite.offset.x
		var top: float = a.position.y + a.sprite.offset.y
		if world.x >= left and world.x <= left + w and world.y >= top and world.y <= top + h:
			return {"entity_id": int(e["eid"]), "name": e["name"],
				"bounds": {"x": left, "y": top, "w": w, "h": h}}
	return {}

## The room-16 fireplace flame is a RESIDENT SPRITE ACTOR (entity 40, sprite
## bank 14 anim 0: 2 frames, 8 VBLANK each, infinite loop) -- NOT a palette
## cycle. Room 16 has no op-$1A site; the earlier "cluster-14 ring $3E-$3F"
## attribution was wrong (that ring is room 14's Television). It was double-drawn
## (a static npc sprite + a capture overlay), which read as "an animated layer
## over a frozen wrong one". Now: entity 40 is excluded from the static npc spawn
## and its real 2-frame ROM art runs through room.gd's CycleAnim path
## (assets/data/hotel/room_16/cycle.json). Genuine op-$1A palette cyclers are
## only the Television (room 14, ring $3E-$3F) and Engine (room 18, ring $22-$25).


## --- Gamepad (S13) ----------------------------------------------------------
## The pad drives the SAME cursor+click pipeline as the mouse: the left stick /
## d-pad moves the real cursor (viewport warp) and A synthesizes a left click at
## its position -- so walking, hotspots, NPCs, verbs, inventory and the choice
## bar all work through the existing mouse paths with no duplicated logic.
## (The choice bar additionally supports direct ui_up/down/accept natively.)
##   left stick / d-pad  move cursor (accelerating)
##   A (bottom)          click / confirm
##   B (right)           cancel the pending verb/item ("clear the sentence")
## Master switch: Game.gamepad_enabled (future menu option or toggle button).
const PAD_DEADZONE := 0.25
const PAD_SPEED := 160.0        # px/s at full deflection
const PAD_ACCEL_MAX := 2.2      # speed multiplier after holding a direction
var _pad_accel := 1.0
var _pad_btn_prev: Dictionary = {}   # JoyButton -> was-pressed

func _gamepad_tick(delta: float) -> void:
	if not Game.gamepad_enabled or Input.get_connected_joypads().is_empty():
		return
	var dev: int = Input.get_connected_joypads()[0]
	# --- cursor motion: analog stick + d-pad ---
	var v := Vector2(Input.get_joy_axis(dev, JOY_AXIS_LEFT_X),
		Input.get_joy_axis(dev, JOY_AXIS_LEFT_Y))
	if v.length() < PAD_DEADZONE:
		v = Vector2.ZERO
	if Input.is_joy_button_pressed(dev, JOY_BUTTON_DPAD_LEFT):
		v.x = -1.0
	if Input.is_joy_button_pressed(dev, JOY_BUTTON_DPAD_RIGHT):
		v.x = 1.0
	if Input.is_joy_button_pressed(dev, JOY_BUTTON_DPAD_UP):
		v.y = -1.0
	if Input.is_joy_button_pressed(dev, JOY_BUTTON_DPAD_DOWN):
		v.y = 1.0
	if v != Vector2.ZERO:
		_pad_accel = minf(_pad_accel + delta * 1.5, PAD_ACCEL_MAX)
		var pos := get_viewport().get_mouse_position()
		pos += v.limit_length(1.0) * PAD_SPEED * _pad_accel * delta
		pos.x = clampf(pos.x, 0.0, 319.0)
		pos.y = clampf(pos.y, 0.0, 199.0)
		get_viewport().warp_mouse(pos)
	else:
		_pad_accel = 1.0
	# --- buttons (edge-triggered) ---
	if _pad_pressed(dev, JOY_BUTTON_A):
		# When the choice bar is up it owns confirm via ui_accept (which maps
		# to the same physical button) -- don't also click through it.
		if _choice_bar == null or not _choice_bar.visible:
			_pad_click(get_viewport().get_mouse_position())
	if _pad_pressed(dev, JOY_BUTTON_B):
		_pending_verb = {}
		_pending_item = ""
		ui.show_message("")

func _pad_pressed(dev: int, btn: int) -> bool:
	var now := Input.is_joy_button_pressed(dev, btn)
	var was: bool = _pad_btn_prev.get(btn, false)
	_pad_btn_prev[btn] = now
	return now and not was

## Synthesize a left press+release at `pos`, routed through the normal input
## pipeline (Control gui_input for the panel, _unhandled_input for the room).
func _pad_click(pos: Vector2) -> void:
	for pressed in [true, false]:
		var ev := InputEventMouseButton.new()
		ev.button_index = MOUSE_BUTTON_LEFT
		ev.pressed = pressed
		ev.position = pos
		ev.global_position = pos
		Input.parse_input_event(ev)

func _process(delta: float) -> void:
	if room == null or chars.is_empty():
		return
	_gamepad_tick(delta)
	_companion_tick()
	var size: Vector2 = room.pixel_size()
	var pl := active_char()
	# Horizontal: track active char, clamped so the view stays inside the room.
	var half_w := 160.0
	var cam_x: float = clampf(pl.position.x, half_w, maxf(size.x - half_w, half_w))
	# Vertical composition (320x200 layout):
	#   0..136  play area (room, 1:1 -- NOT scaled)
	#   136..200 status bar (64px, reduced from the Genesis 72px HUD)
	# The Genesis draws speech text in a 16px band at the TOP of the screen,
	# OVERLAID on the room background. The port moved that text to the bottom
	# status bar, so that top 16px of background -- the strip the player only
	# ever saw with text over it -- is deliberately scrolled OFF the top rather
	# than shown bare: the visible room starts at world y = HW_TOP_CROP. A
	# standard 152-tall room maps y[16..152] onto the 136px play area (152-16=136),
	# floor visible. Camera centred at Cy shows world [Cy-100, Cy-100+136]; clamp
	# so the crop line never lifts (top strip never shows) and taller rooms
	# (hotel 8=448, carnival 6/13) scroll instead of hiding their lower half.
	# NOTE: this is an intentional presentation choice, not a ROM-fidelity bug --
	# do not "correct" it to show the top strip.
	var cy_min: float = 100.0 + HW_TOP_CROP                 # world crop line at screen 0
	var cy_max: float = maxf(cy_min, size.y - PLAY_AREA_H + 100.0)
	var cam_y: float = clampf(pl.position.y - PLAY_AREA_H * 0.5 + 100.0, cy_min, cy_max)
	camera.position = Vector2(cam_x, cam_y)

var _pending_verb: Dictionary = {}
var _pending_item := ""                 # armed inventory item name, or "" if none
const EVENT_VERB_CODE := 11             # verb 11 = EVENT: the ROM's ARRIVAL trigger
                                        # (exits + scripted door reactions live here)
const TAKE_VERB_CODE := 2               # gameplay_spec.json verb_names["2"] == TAKE, high confidence
const USE_VERB_CODE := 5                # gameplay_spec.json verb_names["5"] == USE, med confidence
const GIVE_VERB_CODE := 6               # dropped from the verb bar (ui.gd) -- exactly 1 behavior
                                         # chapter-wide (room 15 "Beads"); USE falls back to it below
var _runner: RoomBehaviorRunner

## The object's decoded behaviour for the current room + verb (+ optional item
## context), or {} if none. `item_icon` is the armed inventory item's icon_id
## (sel2 in the decoded data), e.g. room 12's Shovel has 3 distinct USE
## behaviors keyed by which item is used on it. -1 means no item armed:
## prefer a sel2==0 (generic) behavior for that verb.
## Every behaviour list for an entity: its manifest object(s) (current room
## first, then anywhere) plus the global puzzle behaviours.
func _behaviors_of(ent_id: int) -> Array:
	var out: Array = []
	for o in Game.scene_for(room.room_id).get("objects", []):
		if int(o.get("entity_id", -1)) == ent_id:
			out.append_array(o.get("behaviors", []))
	if out.is_empty():
		for sc in Game.manifest.get("scenes", {}).values():
			for o in sc.get("objects", []):
				if int(o.get("entity_id", -1)) == ent_id and o.get("behaviors"):
					out.append_array(o.get("behaviors", []))
	out.append_array(Game.puzzle_behaviors_for(ent_id))
	return out

const OPEN_VERB_CODE := 3

## The cel an OPEN handler swaps this object's graphic to (its open pose), or 0
## if the object is not an openable door/cupboard. Searches nested behaviours
## (where the REAL gated OPEN handler lives) as well as manifest/puzzle.
func _open_cel_of(ent_id: int) -> int:
	var lists: Array = [Game.nested_behaviors_for(ent_id)]
	lists.append(_behaviors_of(ent_id))
	for blist in lists:
		for b in blist:
			if int(b.get("verb_code", -1)) == OPEN_VERB_CODE:
				var c := _first_cel_value(b.get("actions"))
				if c > 0:
					return c
	return 0

## First op-0x0B cel value an action tree applies (recurses into then/actions).
func _first_cel_value(actions) -> int:
	if not (actions is Array):
		return 0
	for a in actions:
		if String(a.get("op", "")) == "actor_set_word0_and_raise_pending_flag":
			var v := int(a.get("value", 0))
			if v > 0:
				return v
		for k in ["then", "actions", "else"]:
			var r := _first_cel_value(a.get(k))
			if r > 0:
				return r
	return 0

## A door is SHUT if it has an OPEN handler with an open cel AND that open cel is
## not currently applied. "Open" is the ROM's own signal: the OPEN handler runs
## op-0x0B to swap the door graphic, which the runner records as
## Game.flags["cel_<ent>"]. cel 0 / absent = shut. Generic across every door.
func _is_shut_door(ent_id: int) -> bool:
	return _open_cel_of(ent_id) > 0 and int(Game.flags.get("cel_%d" % ent_id, 0)) <= 0

## Behaviour lookup. `item_ent` is the ARMED item's ENTITY id (-1 = none).
## A USE/GIVE pairing is stored on EITHER participant, keyed by the OTHER one's
## entity id in sel2 -- e.g. room 12's "Shovel" carries sel2=71 (the Snowman)
## and room 14's "Poison Oak" carries sel2=177 (the Bear), while the Light Bulb
## carries sel2=135 (the Battery). So we search the clicked object for
## sel2==item_ent AND the armed item for sel2==ent_id.
func _behavior_for(ent_id: int, verb_code: int, item_ent: int = -1) -> Dictionary:
	var scene: Dictionary = Game.scene_for(room.room_id)
	var generic := {}
	var first := {}
	if item_ent >= 0:
		# pairing stored on the ARMED ITEM, keyed by the clicked object
		for b in _behaviors_of(item_ent):
			if int(b.get("verb_code", -1)) == verb_code \
					and int(b.get("sel2", 0)) == ent_id:
				return b
	# The entity's behavior list. Usually under the current room's scene, but
	# some resident actors STAND in a different room than the manifest keys
	# their dialogue under (executed presence vs. manifest attribution -- e.g.
	# carnival's Inky stands in scene 18, dialogue keyed under room 24). Fall
	# back to the entity's objects anywhere in the manifest.
	var objs: Array = []
	for o in scene.get("objects", []):
		if int(o.get("entity_id", -1)) == ent_id:
			objs.append(o)
	if objs.is_empty():
		for sc in Game.manifest.get("scenes", {}).values():
			for o in sc.get("objects", []):
				if int(o.get("entity_id", -1)) == ent_id and o.get("behaviors"):
					objs.append(o)
	# Behavior lists to search: the manifest object(s) PLUS the global puzzle
	# behaviors (USE-combinations / gated grants the manifest bake skipped --
	# the 'unlinked' scripts, e.g. USE Battery on Light Bulb -> Bulb and
	# Battery). Puzzle behaviors are room-independent, keyed by target entity.
	var behavior_lists: Array = []
	# NESTED guards first: they are the REAL state-gated handler (e.g. a door's
	# actual "open it" block). The manifest's top-level entry for the same verb
	# is only the fallback line, so it must lose the race.
	behavior_lists.append(Game.nested_behaviors_for(ent_id))
	for o in objs:
		behavior_lists.append(o.get("behaviors", []))
	behavior_lists.append(Game.puzzle_behaviors_for(ent_id))
	for blist in behavior_lists:
		for b in blist:
			if int(b.get("verb_code", -1)) != verb_code:
				continue
			if first.is_empty():
				first = b
			var sel2 := int(b.get("sel2", 0))
			if item_ent >= 0 and sel2 == item_ent:
				return b                        # exact pairing wins
			if sel2 == 0 and generic.is_empty():
				generic = b
	if not generic.is_empty():
		return generic       # covers both "no item armed" and "wrong item armed"
	if item_ent < 0:
		return first          # no item context at all (LOOK/TALK/PULL...): any match is fine
	# A specific (wrong) item was armed, no exact match, and no generic exists:
	# do NOT show some OTHER item's specific response -- empty falls through
	# to just the verb's already-shown default catalog response.
	return {}

var _float_token := 0

## Floats `text` above the active character's head, matching the cutscene
## dialogue style (same FloatingTextScript, same outline/wrap/scale).
## Auto-hides after a read-time pause -- gameplay can't block on a click the
## way cutscene dialogue does, since the player is free to keep moving.
func _float_response(text: String) -> void:
	_float_token += 1
	var token := _float_token
	if text == "":
		floating_text.hide_line()
		return
	var pl := active_char()
	var h := 60.0
	if "sprite" in pl and pl.sprite != null and pl.sprite.texture != null:
		h = float(pl.sprite.texture.get_height())
	var anchor: Vector2 = pl.position + Vector2(0, -h)
	var color: Color = CHAR_TEXT_COLOR.get(active_index, Color.WHITE)
	floating_text.show_line(text, color, anchor)
	var dur: float = 1.1 + text.length() * 0.045
	await get_tree().create_timer(dur).timeout
	if token == _float_token:
		floating_text.hide_line()


## Float an NPC's reply at the hotspot, same FloatingTextScript presentation as
## _float_response (dialogue display unchanged — only the anchor/colour differ).
func _float_reply(text: String, anchor: Vector2) -> void:
	_float_token += 1
	var token := _float_token
	if text == "":
		floating_text.hide_line()
		return
	floating_text.show_line(text, Color(0.85, 0.9, 1.0), anchor)
	var dur: float = 1.1 + text.length() * 0.045
	await get_tree().create_timer(dur).timeout
	if token == _float_token:
		floating_text.hide_line()


## --- Dialogue choices (script op $02, lifted by tools/gen_choices.py) --------
const TALK_VERB_CODE := 8              # verb_dispatch.json: code 8 = TALK

var _choice_bar: ChoiceBar = null
var _choices_doc: Dictionary = {}      # entity_id (String) -> Array of choices

func _load_choices() -> void:
	_choices_doc = {}
	var doc: Variant = Game.load_json(
		"res://assets/data/global/choices_%s.json" % Game.cluster)
	if doc is Dictionary:
		_choices_doc = doc.get("choices", {})

func _choices_for(ent_id: int) -> Array:
	if _choices_doc.is_empty():
		_load_choices()
	return _choices_doc.get(str(ent_id), [])

## TALK at an entity with lifted choices: open the selector; picking a line
## says it (player colour/anchor), then floats the NPC's reply at the hotspot,
## then re-opens the remaining conversation until dismissed (ui_cancel / ESC).
func _run_choice_dialogue(choices: Array, hs: Dictionary) -> void:
	if _choice_bar == null:
		_choice_bar = ChoiceBar.new()
		add_child(_choice_bar)
	var b: Variant = hs.get("bounds")
	var reply_anchor := Vector2(160, 60)
	if b != null:
		reply_anchor = Vector2(float(b["x"]) + float(b["w"]) * 0.5, float(b["y"]) - 4.0)
	var remaining := choices.duplicate()
	while not remaining.is_empty():
		_choice_bar.open(remaining)
		var picked: Variant = await _await_choice()
		if picked == null:
			return                        # dismissed
		var c: Dictionary = picked[1]
		await _float_response(str(c.get("label", "")))
		await _float_reply(str(c.get("reply", "")), reply_anchor)
		# Run the choice's decoded consequence script (gen_choices.py `actions`):
		# sets flags, animates, reveals items, changes scene, etc. A choice WITH
		# a consequence ends the conversation (matches the ROM's op_0C return /
		# scene change that terminates these bodies); a plain label+reply choice
		# just drops out of the menu and the rest stay available.
		var actions: Array = c.get("actions", [])
		if not actions.is_empty():
			await _ensure_runner().run(actions)
			return
		remaining.remove_at(int(picked[0]))

func _await_choice() -> Variant:
	## Resolves to [index, choice] on selection or null on dismissal.
	## NOTE: GDScript lambdas capture locals by COPY — reassignment inside a
	## lambda never reaches the outer variable. State must be MUTATED (array
	## append / dict store), which is why `state` is a Dictionary here.
	var state := {"done": false, "picked": null}
	var on_sel := func(i: int, c: Dictionary) -> void:
		state["picked"] = [i, c]
		state["done"] = true
	var on_dis := func() -> void:
		state["done"] = true
	_choice_bar.choice_selected.connect(on_sel, CONNECT_ONE_SHOT)
	_choice_bar.dismissed.connect(on_dis, CONNECT_ONE_SHOT)
	while not state["done"]:
		await get_tree().process_frame
	if _choice_bar.choice_selected.is_connected(on_sel):
		_choice_bar.choice_selected.disconnect(on_sel)
	if _choice_bar.dismissed.is_connected(on_dis):
		_choice_bar.dismissed.disconnect(on_dis)
	return state["picked"]


func _on_verb(verb: Dictionary) -> void:
	# Arm this verb; the next hotspot click completes the sentence. Starting a
	# fresh verb clears any previously-armed item (classic adventure-UX reset).
	_pending_verb = verb
	_pending_item = ""
	ui.show_message(str(verb.get("label", "")) + " ...")

func _on_item(item_name: String) -> void:
	# Arm this item as context for the pending verb (e.g. "USE ..." ->
	# "USE KEY ..."); the next hotspot click completes "verb item on hotspot".
	if _pending_verb.is_empty():
		return
	_pending_item = item_name

## Walk the active character to `target` and wait until it arrives (walk_target
## clears) or the timeout elapses. Unreachable targets return immediately (the
## pathfinder snaps to nearest-walkable and clears when boxed in), so the caller
## still resolves the interaction — never a soft-lock.
## Returns true if the character actually ENDED UP at `target` (within
## ARRIVE_TOL). False means no route exists -- the caller must not treat the
## interaction as "reached", or clicking an exit would fire it from across the
## room without ever walking there.
const ARRIVE_TOL := 24.0

func _walk_to_and_wait(target: Vector2, timeout := 5.0) -> bool:
	var ch := active_char()
	if ch == null or not ch.has_method("walk_to"):
		return false
	ch.walk_to(target)
	var elapsed := 0.0
	while ch.walk_target != null and elapsed < timeout:
		await get_tree().process_frame
		elapsed += get_process_delta_time()
	return ch.position.distance_to(target) <= ARRIVE_TOL

var _interact_gen := 0

func _interact(hs: Dictionary) -> void:
	# SCUMM: walk to the object before acting on it. A generation counter lets a
	# fresh click during the walk supersede this one cleanly (no double-resolve).
	_interact_gen += 1
	var gen := _interact_gen
	var arrived := true
	var b: Variant = hs.get("bounds")
	if b != null and room != null:
		var ax := float(b["x"]) + float(b["w"]) * 0.5
		var ay := float(b["y"]) + float(b["h"])     # stand at the object's foot
		arrived = await _walk_to_and_wait(Vector2(ax, ay))
		if gen != _interact_gen:
			return                                   # superseded by a newer click
		var ch := active_char()                       # then look at the object
		if ch != null and ch.has_method("face_toward"):
			ch.face_toward(Vector2(ax, float(b["y"]) + float(b["h"]) * 0.5))

	var noun: String = str(hs.get("name", "that"))
	# EXITS ARE ARRIVAL-TRIGGERED, NOT CLICK-TRIGGERED. In the ROM every exit
	# is a verb-11 EVENT behavior on the object, fired when the character
	# ARRIVES at it -- and that behavior carries the ROM's own gating, e.g.
	# room 11's Double Doors:
	#     EVENT: branch_if_compare_false(flag15 == 0) -> [skip]
	#            change_scene_with_palette_fadeout -> room 2
	# so a shut door simply skips the transition (and says "No way!..."), while
	# OPEN's own behavior flips flag15 and swaps the door cel (op 0x0B).
	# The old code teleported the player on click, bypassing doors entirely.
	# We have already walked to the object above; now run its EVENT block.
	if _pending_verb.is_empty():
		var ent_here := int(hs.get("entity_id", -1))
		# ROM-DERIVED DOOR GATE: a shut door must be OPENED before you can pass.
		# The Outside Door's exit EVENT has NO flag gate in the ROM (it is just
		# move + change_scene), so the gate lives here: if this object is a door
		# whose open cel is not yet applied, a bare click OPENS it (runs the
		# OPEN handler, which renders the open-door cel and clears its shut flag)
		# and does NOT change scene. Only a click on an already-open door exits.
		# This is what makes "you can't walk through a closed door" hold for every
		# door, not only the few whose ROM EVENT happens to carry its own gate.
		if _is_shut_door(ent_here):
			var op := _behavior_for(ent_here, OPEN_VERB_CODE, -1)
			ui.show_message("")
			if not op.is_empty() and op.has("actions"):
				await _ensure_runner().run(op["actions"])
			elif not op.is_empty() and op.has("say") and op["say"] != null:
				_float_response(str(op["say"]))
			return
		var ev := _behavior_for(ent_here, EVENT_VERB_CODE, -1)
		if not ev.is_empty() and not arrived:
			# An exit is ARRIVAL-triggered. No route to it (blocked by a shut
			# door, or the click was double-fired before the walk began) means
			# the character never got there -- do not fire the transition.
			return
		if not ev.is_empty():
			ui.show_message("")
			if ev.has("say") and ev["say"] != null and str(ev["say"]) != "":
				_float_response(str(ev["say"]))
			if ev.has("actions"):
				await _ensure_runner().run(ev["actions"])
			return
		_float_response(noun)  # look/identify
		return
	# Real object + verb (+ optional armed item): echo the sentence in the
	# status bar, same as the artifact's own `sentence = said`, then resolve
	# the actual behavior and float ITS text -- matching the artifact's
	# control flow exactly (command echo -> resolved response, not the
	# generic verb catalog default sitting in for whatever specific line the
	# object actually has).
	var verb_label := str(_pending_verb.get("label", ""))
	var item_name := _pending_item
	var sentence := ("%s %s on %s" % [verb_label, item_name, noun]) if item_name != "" \
		else ("%s %s" % [verb_label, noun])
	ui.show_message(sentence)
	var ent_id := int(hs.get("entity_id", -1))
	var verb_code := int(_pending_verb.get("code", -1))
	# The armed item's ENTITY id -- a USE/GIVE pairing's sel2 is an entity id,
	# not an icon id (see _behavior_for).
	var item_ent := Game.entity_for_item(item_name) if item_name != "" else -1
	var pending_verb := _pending_verb
	_pending_verb = {}
	_pending_item = ""
	if ent_id < 0 or verb_code < 0:
		return
	if verb_code == TALK_VERB_CODE:
		var ch_list := _choices_for(ent_id)
		if not ch_list.is_empty():
			ui.show_message("")
			await _run_choice_dialogue(ch_list, hs)
			return
	var beh := _behavior_for(ent_id, verb_code, item_ent)
	if beh.is_empty() and verb_code == USE_VERB_CODE:
		# GIVE has no dedicated button (see ui.gd) -- USE covers it.
		beh = _behavior_for(ent_id, GIVE_VERB_CODE, item_ent)
	var took_something := false
	if verb_code == TAKE_VERB_CODE:
		# Give the player the item regardless of whether a scripted action
		# list exists for this TAKE -- icon_items.json is the source of
		# truth for "does picking this up give an inventory item".
		var item := Game.item_for_entity(ent_id)
		if not item.is_empty():
			var flag_key := "taken_%d" % ent_id
			if int(Game.flags.get(flag_key, 0)) == 0:
				Game.flags[flag_key] = 1
				ui.add_item(str(item.get("item", "")))
				took_something = true
				# the item's cel leaves the room with it
				if room != null and room.has_method("remove_item_entity"):
					room.remove_item_entity(ent_id)
	# Resolved-response text: the object's own specific line if one exists,
	# else (for non-TAKE) the verb's catalog default -- matches the
	# artifact's `b.say` / `else if (b && !b.say)` / default_responses chain.
	# `say` is a CONVENIENCE copy of one draw_text inside the behaviour's own
	# actions -- and for a stateful object it is usually the FALLBACK branch
	# ("It's already open."). Printing it unconditionally showed the wrong
	# branch and pre-empted the real one, so only use it when the behaviour has
	# no actions to run; otherwise the runner executes the conditional text.
	var has_actions: bool = beh.has("actions") and not (beh["actions"] as Array).is_empty()
	if beh.has("say") and beh["say"] != null and not has_actions:
		_float_response(str(beh["say"]))
	elif has_actions:
		pass                                  # the runner will speak the right line
	elif verb_code != TAKE_VERB_CODE or not took_something:
		if verb_code != TAKE_VERB_CODE:
			_float_response(str(pending_verb.get("default_response", "")).replace(char(1), noun))
	ui.show_message("")
	if beh.is_empty() or not beh.has("actions"):
		return
	await _ensure_runner().run(beh["actions"])


## The shared behavior runner, created on first use with everything wired:
## room, spawn layer, UI, the two player nodes (script ids 1/2), and the
## script-driven room-change entry (ops 17/24).
func _ensure_runner() -> RoomBehaviorRunner:
	if _runner == null:
		_runner = RunnerScript.new()
		add_child(_runner)
	# refresh per-call: room changes between runs, chars persist
	_runner.room = room
	_runner.actor_layer = self
	_runner.ui = ui
	_runner.chars = chars
	_runner.change_room = _script_change_room
	_runner.say_line = _float_response
	return _runner


## Script-driven room change (op 17 change_scene / op 24 load_room): same path
## as walking through an exit -- find the room desc and enter it.
func _script_change_room(target: int) -> void:
	if not Game.room_by_id.has(target):
		return
	_pending_entry_index = int(Game.flags.get("pending_entry", 0))
	Game.flags.erase("pending_entry")
	for i in range(Game.rooms.size()):
		if int(Game.rooms[i]["room_id"]) == target:
			room_index = i
			break
	_enter_room(Game.room_by_id[target])

const PLAY_AREA_H := 136  # top band; bottom 64px (8 sentence + 56 verb/inv) is the command panel
const HW_TOP_CROP := 16   # Genesis top status band (2 tiles), removed in the 320x200 redesign:
                          # crop it off the top of every room plane (152-16 = 136 play area, 1:1)

func _unhandled_input(event: InputEvent) -> void:
	# Left-click in the play area walks the player to that spot.
	if event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT:
		if event.position.y < PLAY_AREA_H:
			var world: Vector2 = get_global_mouse_position()
			# Hotspot bounds are pixel-accurate; with no verb armed,
			# _interact() falls through to a plain LOOK/identify, and an
			# exit object triggers the room change directly (walking onto a
			# door doesn't require arming a verb first, same as the original).
			var hs: Variant = room.hotspot_at(world.x, world.y)
			if hs != null:
				_interact(hs)
				return
			var npc := _npc_hotspot_at(world)
			if not npc.is_empty():
				_interact(npc)
				return
			if not room.is_blocked(world.x, world.y):
				active_char().walk_to(world)
				ui.show_message("Walking...")
			return

	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_BRACKETRIGHT:
				room_index = (room_index + 1) % Game.rooms.size()
				_enter_room(Game.rooms[room_index])
			KEY_BRACKETLEFT:
				room_index = (room_index - 1 + Game.rooms.size()) % Game.rooms.size()
				_enter_room(Game.rooms[room_index])
			KEY_O:
				# Toggle the hotspot debug overlay.
				hotspot_overlay.toggle()
			KEY_F5:
				_save_game(0)
			KEY_F9:
				_load_game(0)


## --- Save / load (real, replaces the Sega password) -------------------------
## Captures the whole recoverable state (cluster, room, flags, inventory,
## companion, verb, score) via SaveSystem to user://saves/. The redesigned UI
## can call _save_game/_load_game per slot; F5/F9 are the dev bindings.
func _capture_state() -> Dictionary:
	return {
		"cluster": Game.cluster,
		"room": room.room_id if room != null else Game.current_room,
		"flags": Game.flags.duplicate(true),
		"inventory": (ui.held_items.duplicate() if ui != null else []),
		"companion": Game.companion,
		"active": active_index,
		"verb": Game.current_verb_code,
		"score": Game.score,
	}

func _save_game(slot: int) -> void:
	if SaveSystem.save_slot(slot, _capture_state()):
		ui.show_message("Saved.")
	else:
		ui.show_message("Save failed.")

func _load_game(slot: int) -> void:
	var d := SaveSystem.load_slot(slot)
	if d.is_empty():
		ui.show_message("No save in slot %d." % slot)
		return
	# Chapter first — set_cluster rebuilds room_by_id/rooms.
	var want_cluster := str(d.get("cluster", Game.cluster))
	if want_cluster != Game.cluster:
		Game.set_cluster(want_cluster)
	# Restore flat state.
	var fl: Dictionary = d.get("flags", {})
	Game.flags = fl.duplicate(true) if fl is Dictionary else {}
	Game.companion = int(d.get("companion", 0))
	Game.score = int(d.get("score", 0))
	Game.current_verb_code = int(d.get("verb", 10))
	# Inventory (ui.held_items is the live truth).
	if ui != null:
		var inv: Array = d.get("inventory", [])
		ui.held_items.clear()
		for it in inv:
			ui.held_items.append(str(it))
		ui.queue_redraw()
	# Active character.
	_set_active(int(d.get("active", 0)))
	# Re-enter the saved room via the normal loader.
	var rid := int(d.get("room", Game.current_room))
	_first_entry = false
	if Game.room_by_id.has(rid):
		for i in range(Game.rooms.size()):
			if int(Game.rooms[i]["room_id"]) == rid:
				room_index = i
				break
		_enter_room(Game.room_by_id[rid])
	ui.show_message("Loaded.")

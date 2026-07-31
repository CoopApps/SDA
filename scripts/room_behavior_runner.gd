extends Node
class_name RoomBehaviorRunner

## Executes a room object's decoded `actions` list (scooby_scene_manifest.py,
## fixed to emit real opcode names + operands from analysis/gameplay_spec.json
## instead of placeholder strings). Same 34-opcode VM as the intro cutscene
## (dispatcher 0x2406 / table 0x2354) -- the move/anim primitives here mirror
## the ones proven in intro_vm.gd: an actor's move is an INSTANT placement
## until that actor has been "room-bound" (ROM 0x2934/0x4B24 -- see
## intro_vm.gd's own note), after which it's a real timed walk, and a move's
## third operand is a live animation-index override (ROM 0x4B7A/0x4B86), not
## a raw speed.
##
## Scope (deliberately not all 34 opcodes' visual effects -- see the plan):
## real sprite-bank actors (registered table 0x32670, e.g. the chieftain
## ghost) get full move/shape/anim playback. Background-art objects (doors,
## etc. -- shape values that aren't in the registered table, like room 9's
## doors at shape 54-59) get their STATE tracked (Game.flags) and timing
## respected, but no visual cel-swap yet -- that needs the room's own
## background-art cel system, not yet decoded (see plan Phase A note).

const FPS := 60.0

# id -> ROM base address, the SAME registered sprite-bank table (0x32670)
# walked by disassemblers/genesis_actor_anim.py this session. Small, static,
# and cited -- not re-derived at runtime (no ROM access from Godot).
const REGISTERED_BANK_BY_ID := {
	1: "0x032700", 2: "0x0642D0", 3: "0x07E91C", 4: "0x082D78", 5: "0x085306",
	6: "0x087368", 7: "0x08B540", 8: "0x09ACF8", 9: "0x09E682", 10: "0x09F7D4",
	11: "0x0A701C", 12: "0x0A94A2", 13: "0x0AAACE", 14: "0x0B1BE2", 15: "0x0B302E",
	16: "0x0B5D02", 17: "0x0C76D2", 18: "0x0C9BDE", 19: "0x0CDD00", 20: "0x0D1084",
	21: "0x0D138E", 22: "0x0D17E8", 23: "0x0D31AA", 24: "0x0D4076", 26: "0x0D4520",
	27: "0x0D826A", 28: "0x0D87E6", 29: "0x0DC6BC", 30: "0x0DDB5E", 31: "0x0E12F8",
	32: "0x0E19C8", 33: "0x0E3BFA", 34: "0x0EEBD6", 35: "0x0F04F0", 36: "0x0F88DC",
	37: "0x0FA77A",
}

const ActorScript := preload("res://scripts/actor.gd")

# op-30 turn-anim transition tables, lifted from ROM (this session):
# TURN_TABLE[slot][prev_facing][new_facing] -> animation index.
# slot 0 = Shaggy ($FC740), slot 1 = Scooby ($FC700). Facings 0-3.
const TURN_TABLE := [
	[[4, 53, 58, 56], [52, 5, 59, 57], [62, 63, 6, 55], [60, 61, 54, 7]],
	[[4, 51, 56, 54], [50, 5, 57, 55], [60, 61, 6, 53], [58, 59, 52, 7]],
]

var room: Node2D                        # for is_blocked()/pixel_size(), may be null
var actor_layer: Node2D                 # parent for spawned Actor nodes
var ui: CanvasLayer                     # for draw_text_message_and_wait, may be null
var chars: Array = []                   # the two lead player nodes (script ids 1/2), may be empty
var change_room: Callable               # main_gameplay's room-change entry (op 17/24), may be invalid
var say_line: Callable                  # main_gameplay's floating-text presenter, may be invalid
var actors: Dictionary = {}             # actor id -> Actor node
var _roomed: Dictionary = {}            # actor id -> bool (room-bound, see class doc)
var _suspended: Dictionary = {}         # channel/actor id -> true (op 22; released by op 25)
var _stopped := false                   # op 32 stop_script_slot: abandon the rest of the list
var _log: Array = []                    # decoded but not-yet-visual ops, for inspection
var _entities: Array = []               # cluster's entities.json records, cached per cluster
var _entities_cluster := ""

func _ready() -> void:
	set_process(false)                  # we drive frame waits via await, not _process

func _load_entities() -> void:
	if _entities_cluster == Game.cluster and not _entities.is_empty():
		return
	var path := "D:/scoobydoo/%s/entities/entities.json" % Game.cluster
	if FileAccess.file_exists(path):
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
		_entities = parsed if parsed is Array else []
	_entities_cluster = Game.cluster

## An actor's DEFAULT shape (registered-bank id), from its entity record --
## the (script actor id - 3) convention proven against the scene-9 intro
## (entity index 2's default shape 7 = the chieftain ghost's bank, matching
## its script actor id 5). A script that never explicitly set_actor_shape_
## index's an actor still needs this to become visible at all.
func _default_shape(actor_id: int) -> int:
	_load_entities()
	var idx := actor_id - 3
	if idx < 0 or idx >= _entities.size():
		return -1
	var long0 := String(_entities[idx].get("long0", "0x00000000"))
	return long0.hex_to_int() & 0xFFFF

func _actor(id: int):
	if actors.has(id):
		return actors[id]
	var a := ActorScript.new()
	a.room = room                       # for update_depth()'s scale/z-sort, same as controllable.gd
	if actor_layer:
		actor_layer.add_child(a)
	else:
		add_child(a)
	actors[id] = a
	var dir := _bank_for_shape(_default_shape(id))
	if dir != "":
		a.load_bank(dir)
	return a

func _bank_for_shape(value: int) -> String:
	if not REGISTERED_BANK_BY_ID.has(value):
		return ""                       # background-art object, not a sprite bank
	for s in Game.sprite_sheets.get("sources", []):
		if str(s.get("base", "")) == REGISTERED_BANK_BY_ID[value]:
			return Game.kit_path(str(s.get("dir", "")))
	return ""

## Run a decoded actions list to completion. Call with `await`.
func run(actions: Array) -> void:
	_stopped = false
	for act in actions:
		if _stopped:
			break                       # op 32 stop_script_slot fired
		await _run_one(act)

## The scene node a script id refers to: 1/2 = the two lead player characters
## (actor slots 0/1, $FF04DC/$FF04E0 family), >=3 = the actor array (op-15
## handler 0x4C20 resolves ids exactly this way). Null if not present.
func _node_for(id: int):
	if id == 1 or id == 2:
		return chars[id - 1] if chars.size() >= id else null
	return actors.get(id)

## World position of any entity: a live node (lead char / script actor) if one
## exists, else the room's static hotspot rect for that entity (foot-centre) --
## so op-15 anchors work against items and scenery, not just actors.
func _entity_pos(id: int) -> Variant:
	var n = _node_for(id)
	if n != null:
		return n.position
	if room != null and room.has_method("hotspot_rect_for_entity"):
		var r: Variant = room.hotspot_rect_for_entity(id)
		if r != null:
			return Vector2(r.position.x + r.size.x / 2.0, r.position.y + r.size.y)
	return null

func _wait_frames(n: int) -> void:
	for i in range(n):
		await get_tree().process_frame

## op-12 sub 4 (input_wait_button 0x4568): block the script until the player
## presses confirm -- click, ui_accept (keyboard/pad), or pad A all count.
## Guarded by a generous timeout so a lost focus can't stall a script forever.
func _wait_for_player_press(timeout := 30.0) -> void:
	var t := 0.0
	while t < timeout:
		await get_tree().process_frame
		t += get_process_delta_time()
		if Input.is_action_just_pressed("ui_accept") \
				or Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
			return

## Set/clear one bit of a recorded engine state byte ($FF09E8 etc.), kept as an
## int bitmask in Game.flags -- scripts and future systems read them uniformly.
func _hw_bit(key: String, bit: int, on: bool) -> void:
	var v: int = int(Game.flags.get(key, 0))
	Game.flags[key] = (v | (1 << bit)) if on else (v & ~(1 << bit))

## The left/right operand value for a 0x03/0x04 condition (ROM 0x2796
## cond_predicate_compare, decoded this session). "flag"/"actor_field" read
## from the SAME Game.flags keys the assign ops (0x08/0x09) write --
## unset/unwritten state defaults to 0, matching the ROM's own zero-
## initialized RAM.
func _operand_value(o: Dictionary) -> int:
	match String(o.get("source", "immediate")):
		"flag":
			var byte: int = int(Game.flags.get("fb%d" % int(o["index"]), 0))
			return (byte >> int(o["selector"])) & 1
		"actor_field":
			return int(Game.flags.get("af%d_%d" % [int(o["selector"]), int(o["index"])], 0))
		_:
			return int(o.get("index", 0))

func _eval_condition(cond: Dictionary) -> bool:
	var l := _operand_value(cond["left"])
	var r := _operand_value(cond["right"])
	match String(cond.get("comparator", "ne")):
		"eq": return l == r
		"gt": return l > r
		"lt": return l < r
		_: return l != r

func _run_one(act: Dictionary) -> void:
	match String(act.get("op", "")):
		"nop_advance_pc":
			pass                        # op 0x00: advances the script PC only
		"match_event_selectors_else_skip_block":
			# op 0x01 (ROM 0x246A): an inline EVENT GUARD reached inside an
			# already verb-matched response -- its guarded block is the
			# continuation of that response, so run it. (Top-level guards are
			# lifted into behaviour headers by the bake; only inline continuations
			# arrive here. Degenerate guards, disp<=1, decode to an empty `then`.)
			await run(act.get("then", []))
		"register_choice_option":
			# op 0x02 (ROM 0x25AC): registers a dialogue-choice entry. The choice
			# MENU is presented via choices_<cluster>.json / _run_choice_dialogue,
			# so this does NOT auto-run the consequence (that fires when the player
			# picks it) -- acknowledged here so it is not an unhandled op.
			pass
		"attach_inline_position_track_to_slot":
			# op 0x21 (ROM 0x49AC): attaches an inline per-frame position track
			# (signed x/y deltas) to an actor slot -- drives the Mine Car, the
			# bouncing Bed Spring, the Christmas Lights, and the maid's run-off.
			# The track PAYLOAD (not modelled yet) would move the actor over
			# frames; explicitly acknowledged so it is never silently dropped.
			# TODO: play the position track (shared mechanism with the intro's
			# sequence-57 run-off). Until then the actor holds position.
			pass
		"branch_if_compare_false", "if_compare_then_block":
			if _eval_condition(act["condition"]):
				await run(act.get("then", []))
		"move_actor_to_xy":
			await _move(int(act["actor"]), int(act["x"]), int(act["y"]), int(act.get("walk_anim", 0xFFFF)))
		"move_actor_to_waypoint":
			# op $0E (ROM 0x49BA/0x4B24, ROM_MAP rows 208/284): the target is a
			# SLOT into the room's entry-point table ($FF0696), resolved to pixels
			# (tile<<3). Table extracted per-scene by executing scene_load
			# (waypoints_<cluster>.json). Two decoder shapes are accepted: the
			# scene-manifest one (selector/waypoint_index/anim_id) and the inline
			# consequence-body one (actor/waypoint/anim).
			var wid: int = int(act.get("actor", int(act.get("selector", 0)) & 0x7FFF))
			var slot: int = int(act.get("waypoint", act.get("waypoint_index", 0)))
			var wanim: int = int(act.get("anim", act.get("anim_id", 0xFFFF)))
			var rid: int = room.room_id if (room != null and "room_id" in room) else Game.current_room
			var wp: Vector2 = Game.waypoint_px(rid, slot)
			if wp.x >= 0:
				await _move(wid, int(wp.x), int(wp.y), wanim)
			else:
				_log.append(act)        # no table entry for this slot -- don't teleport to (0,0)
		"move_actor_to_room":
			# field name differs by decoder: manifest emits "entity", the
			# choice/puzzle body decoder emits "actor" -- accept both.
			var id: int = int(act.get("entity", act.get("actor", -1)))
			var to_room: int = int(act["room"])
			if to_room == 1:
				# ROM op5 (0x28A0): "destination room 1 is the player inventory".
				# This is how scripts GRANT items (dialogue rewards, USE-combo
				# outputs, puzzle payoffs) -- the entity moves into the roster.
				# Without this most hotel items are unobtainable (only the ~15
				# room `items_here` pickups worked). Resolve the entity to its
				# inventory item and add it.
				var item: Dictionary = Game.item_for_entity(id)
				if not item.is_empty() and ui != null and ui.has_method("add_item"):
					var nm := str(item.get("item", ""))
					if nm != "" and not ui.held_items.has(nm.to_upper()):
						ui.add_item(nm)
				if actors.has(id):
					actors[id].visible = false     # left the room, now carried
				_roomed.erase(id)
			elif to_room == 0:
				# Leaving the world -- if it's a held inventory item, this is a
				# USE-combination CONSUMING it (e.g. Battery + Light Bulb spent
				# to make Bulb-and-Battery). Remove it from inventory.
				var citem: Dictionary = Game.item_for_entity(id)
				if not citem.is_empty() and ui != null and ui.has_method("remove_item"):
					ui.remove_item(str(citem.get("item", "")))
				_roomed.erase(id)
				if actors.has(id):
					actors[id].visible = false
			else:
				_actor(id).visible = true
				_roomed[id] = true      # ROM 0x2934: room-entry binds the actor
		"set_actor_shape_index", "set_actor_asset_id":
			var id2: int = int(act["actor"])
			var dir := _bank_for_shape(int(act["value"]))
			if dir != "":
				_actor(id2).load_bank(dir)
			else:
				_log.append(act)        # background-art object -- no visual yet
		"actor_set_word0_and_raise_pending_flag":
			# op 0x0B writes actor field +0. For a SPRITE actor that selects an
			# animation; for a CEL object (doors, cupboards -- the common case)
			# field +0 IS the object's picture (0x7C4A reads it), so this is
			# "swap the graphic": the open-door / open-cupboard pose.
			var id3: int = int(act.get("actor", act.get("entity", -1)))
			var val3: int = int(act.get("value", 0))
			var a3 = actors.get(id3)
			if a3 != null and not a3.animations.is_empty():
				a3.play_anim_index(val3)
			elif room != null and room.has_method("set_entity_cel"):
				room.set_entity_cel(id3, val3)
				Game.flags["cel_%d" % id3] = val3
			else:
				_log.append(act)
		"start_anim_sequence_and_wait":
			var id4: int = int(act["channel"])
			var a4 = actors.get(id4)
			if a4 != null:
				a4.play_anim_index(int(act["seq"]))
		"wait_until_anim_channel_signalled", "wait_while_channel_busy":
			var id5: int = int(act.get("channel", -1))
			var a5 = actors.get(id5)
			if a5 != null:
				var guard := 0
				while not a5.anim_done() and guard < int(FPS) * 5:
					a5.advance_anim(1.0 / FPS)
					await get_tree().process_frame
					guard += 1
		"draw_text_message_and_wait":
			# ROM 0x4D80 (gameplay_spec.json): shows the message and blocks
			# until dismissed (polls a sequencer-busy bit). We don't yet have
			# real input-driven dismissal wired for room-object dialogue (the
			# intro VM has its own _await_text mechanism, not shared with
			# this runner) -- show it and hold for a fixed, generous read
			# time instead of forever, so a missing "click to continue" input
			# doesn't stall the whole action sequence.
			# Route through the caller's floating-dialogue presenter when it
			# supplied one, so a behaviour's conditional line (e.g. the door's
			# real "It's locked" / "It's already open" branch) appears the same
			# way a normal response does, instead of only in the status line.
			var msg := String(act.get("text", ""))
			if say_line.is_valid():
				say_line.call(msg)
			elif ui != null:
				ui.show_message(msg)
			await _wait_frames(int(FPS) * 2)
		"wait_n_frames":
			await _wait_frames(int(act.get("frames", 0)))
		"queue_sound_driver_id":
			pass                        # sound engine not wired yet (matches intro_vm.gd)
		"assign_flagbit_or_actor_field":
			# Decompiled ROM 0x2C56..0x2D58 this session (see conversation --
			# not re-derived here). dest=="flag": a global bit at $FF2A00,
			# persisted as Game.flags["fb<index>"] (an int bitmask standing
			# in for that byte). dest=="actor_field": a word field in the
			# actor's own record, persisted as Game.flags["af<actor>_<off>"].
			if String(act.get("dest", "")) == "flag":
				var fb_key := "fb%d" % int(act["dest_index"])
				var byte: int = int(Game.flags.get(fb_key, 0))
				var bit: int = int(act["dest_bit_or_actor"])
				var src: int = int(act["src_value"])
				match String(act.get("operation", "")):
					"set_clear":
						byte = (byte | (1 << bit)) if src != 0 else (byte & ~(1 << bit))
					"toggle_if_nonzero":
						if src != 0:
							byte ^= (1 << bit)
				Game.flags[fb_key] = byte
			else:
				var af_key := "af%d_%d" % [int(act["dest_bit_or_actor"]), int(act["dest_index"])]
				var cur: int = int(Game.flags.get(af_key, 0))
				var src2: int = int(act["src_value"])
				match String(act.get("operation", "")):
					"assign": cur = src2
					"sub": cur -= src2
					"or": cur |= src2
					"add": cur += src2
				Game.flags[af_key] = cur
		"actor_set_byte_field_and_refresh":
			# Decompiled ROM 0x2D5E..0x2DBE this session. Same actor-record-
			# field addressing as the assign op above's actor_field path, at
			# a fixed +22-relative offset -- persisted under the same key
			# scheme so both ops agree on one actor's field state.
			var af_key2 := "af%d_%d" % [int(act["actor"]), int(act["field_offset"])]
			Game.flags[af_key2] = int(act["value"])
		"set_palette_cycle_channel":
			# op $1A (ROM_MAP row 116/409): [ch, cram_lo, cram_hi, period].
			# Toggle the room's matching CycleAnim overlay (period $FFFF = off).
			# Faithful to the ROM: rotating those CRAM entries at that rate.
			var ops: Array = act.get("operands", [])
			if ops.size() >= 4 and room != null and room.has_method("set_cycle_channel"):
				room.set_cycle_channel(int(ops[1]), int(ops[2]), int(ops[3]))
		"move_entity_to_anchor_of_reference":
			# op 15 (ROM 0x4C20, disasm re-read this session): target X =
			# reference X + operand(+8) -- the baked `x_addend` (typically
			# 8-12px, "stand beside it") -- and target Y = reference Y. The
			# further per-frame anchor lookup ($197E, cel-mode references only)
			# is not modelled; the addend is the dominant, always-applied term.
			var subj: int = int(act.get("subject", 0)) & 0x7FFF
			var ref_pos: Variant = _entity_pos(int(act.get("reference", 0)))
			if ref_pos != null:
				var p: Vector2 = ref_pos
				p.x += float(int(act.get("x_addend", 0)))
				await _move(subj, int(p.x), int(p.y), 0xFFFF)
			else:
				_log.append(act)        # reference not on stage -- nothing to anchor to
		"set_channel_suspend_bit":
			# op 22 (ROM 0x2AD0): mask an anim channel out of the scheduler.
			_suspended[int(act.get("channel", -1))] = true
		"resume_anim_channel_wait_drawn":
			# op 25 (ROM 0x2B0E): release the channel suspended by op 22, then
			# BLOCK until its sprite work is drawn -- i.e. resume + await anim.
			var rid5: int = int(act.get("channel", -1))
			_suspended.erase(rid5)
			var rn = _node_for(rid5)
			if rn != null and rn.has_method("anim_done"):
				var guard5 := 0
				while not rn.anim_done() and guard5 < int(FPS) * 5:
					rn.advance_anim(1.0 / FPS)
					await get_tree().process_frame
					guard5 += 1
		"set_actor_turn_anim_from_transition_table":
			# op 30 (ROM 0x268E): anim := table[prev_facing][new_facing] for a
			# LEAD character slot (writes $FF0488/$FF048A), then optionally
			# blocks until the anim completes. Tables lifted from ROM this
			# session: slot 0 (Shaggy) $FC740, slot 1 (Scooby) $FC700; the
			# diagonal is the per-facing idle (4/5/6/7 -- matches the verified
			# room-10 idle data), off-diagonal are the turn anims.
			var slot30: int = 0 if int(act.get("slot", act.get("channel", 1))) == 1 else 1
			var new30: int = int(act.get("state", act.get("facing", 0))) & 3
			var prev30: int = int(Game.flags.get("turn_state_%d" % slot30, 0)) & 3
			Game.flags["turn_state_%d" % slot30] = new30
			var anim30: int = TURN_TABLE[slot30][prev30][new30]
			if slot30 < chars.size() and chars[slot30] != null:
				var ch30 = chars[slot30]
				ch30.play_anim_index(anim30)
				if bool(act.get("wait", false)):
					var guard30 := 0
					while not ch30.anim_done() and guard30 < int(FPS):
						ch30.advance_anim(1.0 / FPS)
						await get_tree().process_frame
						guard30 += 1
		"call_subcommand_from_table":
			# op 12 (ROM 0x2E9E): parameterless engine action from a 62-entry
			# table -- mostly engine flag bits. Record which one ran (visible
			# state for conditions/debug); no visual effect modelled yet.
			# op 12 (ROM 0x2E9E): sub-id indexes the jump table at 0x2EB4.
			# Every sub used by either chapter was identified from its handler
			# (carve ask, this session); the port maps each to its faithful
			# equivalent. Categories:
			#   state bits  -> recorded as Game.flags["hw_<byte>"] bitmasks
			#                  ($FF09E8/$FF09E9/$FF09EB engine bytes)
			#   repaint/VDP -> no-op (the port redraws every frame): subs
			#                  3 (display refresh), 5/12 (room repaint 0x45A4),
			#                  15 (camera edge push), 28 (VRAM upload),
			#                  29 (coproc handshake), 2 (transition snapshot),
			#                  6 (flag test), 16 (raster scroll effect)
			#   footsteps   -> subs 19/20 (0x4374/0x4390 randomised footstep
			#                  cue): queued for the audio pass
			#   input wait  -> sub 4 (0x4568): block until the player presses
			#   depth scale -> sub 21 (0x432C): per-slot perspective enable --
			#                  recorded; visual scaling deliberately not applied
			var sub: Array = act.get("operands", [])
			var sid: int = int(sub[0]) if not sub.is_empty() else int(act.get("subcommand", -1))
			Game.flags["subcmd_%d" % sid] = 1
			match sid:
				4:
					await _wait_for_player_press()
				19, 20:
					Game.flags["pending_sfx_footstep"] = int(Game.flags.get("pending_sfx_footstep", 0)) + 1
				21:
					Game.flags["depth_scale_armed"] = 1
				9:
					_hw_bit("hw_09DE", 7, true)
					_hw_bit("hw_0ABF", 1, true)
				11:
					_hw_bit("hw_09EB", 2, true)
				13: _hw_bit("hw_09E8", 1, true)
				14: _hw_bit("hw_09E8", 1, false)
				17: _hw_bit("hw_09E8", 2, true)
				22: _hw_bit("hw_09E8", 3, false)
				32: _hw_bit("hw_09E9", 0, false)
				35: _hw_bit("hw_09E9", 1, true)
				36: _hw_bit("hw_09E9", 1, false)
				42: _hw_bit("hw_09E9", 3, false)
				45: _hw_bit("hw_09E9", 6, true)
				51: _hw_bit("hw_09EB", 0, true)
				52: _hw_bit("hw_09EB", 0, false)
				53: _hw_bit("hw_09EB", 2, true)   # scene cmd 0x45 sequencer arm
				58: _hw_bit("hw_09EB", 5, true)
				61: _hw_bit("hw_09EB", 6, false)
				_:
					_log.append(act)    # repaint/VDP no-ops and anything new
		"mark_object_present_or_scroll_inventory":
			# op 7: flag the object as present (readable by conditions).
			Game.flags["present_%d" % int(act.get("object", -1))] = 1
		"set_actor_icon_id_and_refresh_inventory":
			# op 10 (ROM 0x2DC0): write actor record +4 (icon id); if the actor
			# is in the roster (scene==1) rebuild the inventory strip (0x5CF6).
			# Port: record the override and re-resolve the drawn icons -- this
			# is how items visually transform (e.g. a container emptying).
			Game.set_entity_icon(int(act.get("actor", act.get("entity", -1))),
				int(act.get("value", act.get("icon", 0))))
			if ui != null and ui.has_method("refresh_inventory"):
				ui.refresh_inventory()
		"copy_slot_bit_ff0ab7_into_flagbyte0_bit2":
			# op 28 (ROM 0x255E): VM flag byte0 bit2 := "selected slot still has
			# a pending walk/task" ($FF0AB7 bit). Read by op3/4 conditions as
			# flag fb0 selector 2. Port approximation: runner moves are awaited
			# to completion before the next op, so the pending bit is CLEAR.
			Game.flags["fb0"] = int(Game.flags.get("fb0", 0)) & ~(1 << 2)
		"set_flag_bit3_if_anim_channel_done":
			# op 29 (ROM 0x2510): VM flag byte0 bit3 := "selected anim channel
			# hit its stop/hold". Port: consult the selected actor's anim state
			# (done when not mid one-shot); selectors 1/2 (lead channels) and
			# unknown actors count as done -- their anims are frame-synchronous
			# here.
			var sel29: int = int(act.get("channel", act.get("actor", -1)))
			var a29 = actors.get(sel29)
			var done29: bool = a29 == null or a29.anim_done()
			var fb0: int = int(Game.flags.get("fb0", 0)) & ~(1 << 3)
			Game.flags["fb0"] = fb0 | ((1 << 3) if done29 else 0)
		"stop_script_slot":
			_stopped = true             # op 32: abandon the rest of this list
		"change_scene_with_palette_fadeout", "load_room_at_entry_with_facing":
			# ops 17/24: script-driven room change. Routed through
			# main_gameplay's _enter_room (spawn placement handled there).
			var target: int = int(act.get("to_room", -1))
			if target >= 0 and change_room.is_valid():
				# op-24 carries the arrival ENTRY index ($FF069E = (4,A5)<<2);
				# pass it so the room places you at the door you came through.
				Game.flags["pending_entry"] = int(act.get("entry", 0))
				change_room.call(target)
			else:
				_log.append(act)
		_:
			_log.append(act)            # control-flow / not-yet-executed op; kept, not dropped

func _move(id: int, x: int, y: int, walk_anim: int) -> void:
	var pos := Vector2(x, y)
	# ids 1/2 are the LEAD PLAYER characters (actor slots 0/1) -- move the real
	# player node, never a runner-spawned stand-in.
	if id == 1 or id == 2:
		var ch = _node_for(id)
		if ch != null:
			if ch.has_method("walk_to"):
				ch.walk_to(pos)
				var guard := 0
				while ch.walk_target != null and guard < int(FPS) * 6:
					await get_tree().process_frame
					guard += 1
			else:
				ch.position = pos
			if ch.has_method("update_depth"):
				ch.update_depth()
		return
	var a = _actor(id)
	if not bool(_roomed.get(id, false)):
		a.position = pos                # pre-room: instant placement (see class doc)
		a.update_depth()
		return
	if a.position.x != pos.x:
		a.sprite.flip_h = pos.x < a.position.x
	if walk_anim != 0xFFFF and not a.animations.is_empty():
		a.play_anim_index(walk_anim)
	var dist: float = a.position.distance_to(pos)
	var secs: float = clampf(dist / 90.0, 0.1, 2.0)
	var tw: Tween = a.create_tween()
	tw.tween_property(a, "position", pos, secs)
	tw.tween_callback(a.update_depth)
	await tw.finished

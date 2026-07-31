extends RefCounted
class_name ScriptVM

## Pure interpreter for Scooby-Doo Mystery's script VM (ROM dispatcher
## 0x2406, dispatch table 0x2354, 34 opcodes cited in
## D:\scoobydoo\analysis\gameplay_spec.json). Consumes the canonical
## decoded event list produced by
## D:\scoobydoo\exporters\scooby_script_decode.py::decode_actions() --
## both scooby_scene_manifest.py (per-room object behaviour) and
## scooby_intro_script_export.py (cutscenes) emit this same schema, so
## this one stepper drives both.
##
## Owns ONLY: program-counter stepping through the event list, condition
## evaluation (0x03 branch_if_compare_false / 0x04 if_compare_then_block),
## and state mutation (0x08 assign_flagbit_or_actor_field / 0x09
## actor_set_byte_field_and_refresh). Everything else is either fired
## (non-blocking, presenter reacts and stepping continues immediately) or
## blocked (stepping pauses until the presenter calls resume() -- these are
## the ops whose ROM handlers don't return to the script dispatcher until
## their own wait-loop is satisfied: text-wait, frame-wait, channel-wait,
## scene loads, anim-and-wait, moves). No Sprite2D/Tween/scene code here --
## see vm_presenter.gd (base) + intro_presenter.gd (concrete) for that half.

signal op_fired(op_name: String, data: Dictionary)
signal op_blocking(op_name: String, data: Dictionary)
signal finished
signal resumed

const ScriptVMStateScript = preload("res://scripts/script_vm_state.gd")

var events: Array
var state
var _running := false

## Ops whose ROM handler blocks the script dispatcher until its own
## wait-loop resolves (gameplay_spec.json handler addresses in parens):
##   0x06 start_anim_sequence_and_wait   (0x2B5A)
##   0x0E move_actor_to_waypoint         (0x49BA)
##   0x10 draw_text_message_and_wait     (0x4D80)
##   0x11 change_scene_with_palette_fadeout (0x4F0E)
##   0x15 wait_n_frames                  (0x48D8)
##   0x17 wait_until_anim_channel_signalled (0x4FBE)
##   0x18 load_room_at_entry_with_facing (0x4EE4)
##   0x19 resume_anim_channel_wait_drawn (0x2B0E) -- name says "wait_drawn"
##   0x1B move_actor_to_xy               (0x49BA, same handler as 0x0E)
##   0x1F wait_while_channel_busy        (0x4F70)
const BLOCKING_OPS := {
	"start_anim_sequence_and_wait": true,
	"move_actor_to_waypoint": true,
	"draw_text_message_and_wait": true,
	"change_scene_with_palette_fadeout": true,
	"wait_n_frames": true,
	"wait_until_anim_channel_signalled": true,
	"load_room_at_entry_with_facing": true,
	"resume_anim_channel_wait_drawn": true,
	"move_actor_to_xy": true,
	"wait_while_channel_busy": true,
}


func _init(events_: Array, state_ = null) -> void:
	events = events_
	state = state_ if state_ else ScriptVMStateScript.new()


func run() -> void:
	if _running:
		return
	_running = true
	await _run_block(events)
	_running = false
	finished.emit()


## Presenter calls this once a blocking op it received via op_blocking has
## actually completed (text dismissed, N frames elapsed, channel signalled,
## move/anim tween finished) so stepping can continue.
##
## Deferred emit is load-bearing: op_blocking.emit() below calls connected
## handlers SYNCHRONOUSLY, so a handler that resumes immediately (as a
## stub/instant presenter does) would fire `resumed` before `await resumed`
## even starts listening for it -- an immediate emit() here is silently
## lost and the stepper deadlocks forever. Deferring guarantees the await
## is already registered by the time this actually emits.
func resume() -> void:
	resumed.emit.call_deferred()


func _run_block(block: Array) -> void:
	for ev in block:
		await _step(ev)


func _step(ev: Dictionary) -> void:
	var op: String = ev.get("op", "")
	match op:
		"branch_if_compare_false", "if_compare_then_block":
			if _eval_condition(ev.get("condition", {})):
				await _run_block(ev.get("then", []))
		"assign_flagbit_or_actor_field":
			_do_assign_flag_or_field(ev)
			op_fired.emit(op, ev)
		"actor_set_byte_field_and_refresh":
			_do_assign_byte_field(ev)
			op_fired.emit(op, ev)
		_:
			if BLOCKING_OPS.has(op):
				op_blocking.emit(op, ev)
				await resumed
			else:
				op_fired.emit(op, ev)


## ROM 0x2796/0x27B2/0x27D0 (left) mirrored at 0x2820/0x283E (right),
## comparator at 0x285E/0x2870/0x2882 -- see compare_mode() in
## scooby_script_decode.py for the bit layout this "condition" dict was
## already decoded from.
func _eval_condition(cond: Dictionary) -> bool:
	var l := _resolve_operand(cond.get("left", {}))
	var r := _resolve_operand(cond.get("right", {}))
	match String(cond.get("comparator", "eq")):
		"eq": return l == r
		"gt": return l > r
		"lt": return l < r
		_: return l != r  # "ne"


func _resolve_operand(o: Dictionary) -> int:
	match String(o.get("source", "immediate")):
		"flag":
			return 1 if state.get_flag(int(o.get("index", 0)), int(o.get("selector", 0))) else 0
		"actor_field":
			return state.get_actor_field(int(o.get("selector", 0)), int(o.get("index", 0)))
		_:
			# INFERRED: for the immediate case only the first decoded word
			# ("index") has ever been observed carrying a value in this
			# pass -- the second ("selector") is unused/reserved. Not yet
			# independently bit-verified against a live MAME capture.
			return int(o.get("index", 0))


## ROM 0x2C56 assign_flagbit_or_actor_field. dest=="flag" -> $FF2A00 bit
## array (dest_index=byte, dest_bit_or_actor=bit); dest=="actor_field" ->
## actor-record word field (dest_index=field offset, dest_bit_or_actor=
## actor id). operation was pre-classified from the mode bits by
## scooby_script_decode.py's decode_actions().
func _do_assign_flag_or_field(ev: Dictionary) -> void:
	var dest_index: int = ev.get("dest_index", 0)
	var dest_ba: int = ev.get("dest_bit_or_actor", 0)
	var src: int = ev.get("src_value", 0)
	var op: String = ev.get("operation", "assign")
	if ev.get("dest") == "flag":
		var cur: bool = state.get_flag(dest_index, dest_ba)
		if op == "set_clear":
			state.set_flag(dest_index, dest_ba, src != 0)
		elif src != 0:  # "toggle_if_nonzero"
			state.set_flag(dest_index, dest_ba, not cur)
	else:
		var cur_v: int = state.get_actor_field(dest_ba, dest_index)
		var new_v: int = cur_v
		match op:
			"assign": new_v = src
			"add": new_v = cur_v + src
			"sub": new_v = cur_v - src
			"or": new_v = cur_v | src
		state.set_actor_field(dest_ba, dest_index, new_v)


## ROM 0x2D5E actor_set_byte_field_and_refresh -- always a direct byte
## assign (no add/sub/or variants observed at this opcode).
func _do_assign_byte_field(ev: Dictionary) -> void:
	var actor: int = ev.get("actor", 0)
	var field_offset: int = ev.get("field_offset", 0)
	var value: int = ev.get("value", 0)
	state.set_actor_field(actor, field_offset, value)

extends SceneTree

## Phase 1 gate (see d:\claudetemp\plans\starry-tumbling-boot.md): run
## script_vm.gd over one small, well-understood REAL script -- room 9's
## Door OPEN behaviour (Blake's Hotel, entity_id 74) -- and assert the flag
## transitions it's known to perform, before any presenter/rendering code
## exists to consume its signals.
##
## No presenter yet: this script itself stubs the presenter role, logging
## every op_fired/op_blocking and immediately resume()-ing blocking ops so
## the VM runs the whole script to completion in one headless pass.
##
## Run:  D:\godot\Godot_v4.7.1-stable_win64_console.exe --headless \
##         --path D:\scoobygodot -s tools/validate/vm_core.gd

const ScriptVMScript = preload("res://scripts/script_vm.gd")
const ScriptVMStateScript = preload("res://scripts/script_vm_state.gd")

const MANIFEST_PATH := "res://assets/data/global/scene_manifest_hotel.json"
const ROOM_ID := "9"
const OBJECT_ENTITY_ID := 74
const BEHAVIOR_VERB := "OPEN"

var fired_count := 0
var blocked_count := 0


func _initialize() -> void:
	var f := FileAccess.open(MANIFEST_PATH, FileAccess.READ)
	if f == null:
		printerr("FAIL: could not open %s" % MANIFEST_PATH)
		quit(1)
		return
	var manifest: Dictionary = JSON.parse_string(f.get_as_text())
	f.close()

	var room: Dictionary = manifest.get("scenes", {}).get(ROOM_ID, {})
	var obj: Dictionary = {}
	for o in room.get("objects", []):
		if int(o.get("entity_id", -1)) == OBJECT_ENTITY_ID:
			obj = o
			break
	if obj.is_empty():
		printerr("FAIL: entity_id %d not found in room %s" % [OBJECT_ENTITY_ID, ROOM_ID])
		quit(1)
		return

	var behavior: Dictionary = {}
	for b in obj.get("behaviors", []):
		if String(b.get("verb", "")) == BEHAVIOR_VERB and int(b.get("sel2", -1)) == 0:
			behavior = b
			break
	if behavior.is_empty():
		printerr("FAIL: no %s/sel2=0 behavior on entity %d" % [BEHAVIOR_VERB, OBJECT_ENTITY_ID])
		quit(1)
		return

	print("running room %s entity %d verb %s -- %d top-level actions" %
		[ROOM_ID, OBJECT_ENTITY_ID, BEHAVIOR_VERB, behavior["actions"].size()])

	var state = ScriptVMStateScript.new()
	var vm = ScriptVMScript.new(behavior["actions"], state)
	vm.op_fired.connect(_on_fired)
	vm.op_blocking.connect(_on_blocking.bind(vm))
	vm.finished.connect(_on_finished.bind(state))
	await vm.run()


func _on_fired(op_name: String, _data: Dictionary) -> void:
	fired_count += 1


func _on_blocking(op_name: String, _data: Dictionary, vm) -> void:
	blocked_count += 1
	vm.resume()  # no presenter yet -- stub: treat every wait as instant


func _on_finished(state) -> void:
	print("finished: %d fired, %d blocking-resumed" % [fired_count, blocked_count])

	# Known-correct assertions, hand-verified against the decoded action
	# list read directly from scene_manifest_hotel.json (see this session's
	# transcript): the script unconditionally sets flag byte0/bit4 (the
	# "door open" flag written twice: set at the top of the open sequence,
	# cleared again at the very end once the gang is safely past) and flag
	# byte11/bit4 ("door fully open" latch, gated behind the actor_field==63
	# check that only fires once the door's actor field 12 has reached 63).
	var ok := true
	if state.get_flag(0, 4) != false:
		printerr("FAIL: flag(0,4) expected false (cleared at script end), got true")
		ok = false
	if state.get_actor_field(81, 12) != 1:
		printerr("FAIL: actor_field(81,12) expected 1 (OR'd with 1 near script start), got %d" %
			state.get_actor_field(81, 12))
		ok = false

	if ok:
		print("OK: flag/actor-field transitions match expected values")
		quit()
	else:
		quit(1)

extends RefCounted
class_name SaveSystem

## Real save/load — replaces the Sega password. The password encoded a compact
## game-state block (roadmap §E); this persists that same field set as JSON under
## user://saves/, so a load just restores the fields and re-enters the room.
##
## Captured (the whole recoverable state): chapter/cluster, current room, the
## $FF2A00-equivalent flag dict, inventory, active character/companion, verb,
## score. Everything else (backgrounds, sprites, walkmaps) is static content
## rebuilt from the room id on load.

const DIR := "user://saves"
const SLOTS := 6
const VERSION := 1


static func _slot_path(slot: int) -> String:
	return "%s/slot_%02d.json" % [DIR, slot]


static func _ensure_dir() -> void:
	if not DirAccess.dir_exists_absolute(DIR):
		DirAccess.make_dir_recursive_absolute(DIR)


static func save_slot(slot: int, state: Dictionary) -> bool:
	_ensure_dir()
	var f := FileAccess.open(_slot_path(slot), FileAccess.WRITE)
	if f == null:
		push_error("save_slot: cannot open " + _slot_path(slot))
		return false
	var out := state.duplicate(true)
	out["_version"] = VERSION
	out["_saved_unix"] = int(Time.get_unix_time_from_system())
	f.store_string(JSON.stringify(out, "  "))
	f.close()
	return true


static func load_slot(slot: int) -> Dictionary:
	var p := _slot_path(slot)
	if not FileAccess.file_exists(p):
		return {}
	var f := FileAccess.open(p, FileAccess.READ)
	if f == null:
		return {}
	var txt := f.get_as_text()
	f.close()
	var v: Variant = JSON.parse_string(txt)
	if not (v is Dictionary):
		push_warning("load_slot: corrupt save at " + p)
		return {}
	return v


static func has_slot(slot: int) -> bool:
	return FileAccess.file_exists(_slot_path(slot))


## Slot summaries for a save/load menu — one entry per slot (empty dict if free).
static func list_slots() -> Array:
	var out: Array = []
	for s in range(SLOTS):
		var d := load_slot(s)
		if d.is_empty():
			out.append({"slot": s, "empty": true})
		else:
			out.append({"slot": s, "empty": false,
				"cluster": d.get("cluster", ""), "room": int(d.get("room", 0)),
				"score": int(d.get("score", 0)),
				"saved_unix": int(d.get("_saved_unix", 0))})
	return out

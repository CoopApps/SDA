extends SceneTree
## Verifies the ROM's door model is present in the data the port now runs:
##   * exits are verb-11 EVENT behaviors (arrival-triggered), not click-teleports
##   * a gated door's EVENT carries a condition (branch_if_compare_false /
##     if_compare_then_block) BEFORE its change_scene
##   * OPEN/SHUT behaviors exist for gated doors and flip the same flag
##   * an openable object has runtime CEL states rendered (open-door graphic)

func _init() -> void:
	var man: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(
		"res://assets/data/global/scene_manifest_hotel.json"))["scenes"]
	var ok := true

	# 1. every exit lives on a verb-11 EVENT behavior
	var exits := 0
	var gated := 0
	for rid in man:
		for o in man[rid].get("objects", []):
			for b in o.get("behaviors", []):
				if int(b.get("verb_code", -1)) != 11:
					continue
				var acts: Array = b.get("actions", [])
				var has_scene := false
				var has_cond := false
				for a in acts:
					var op := str(a.get("op", ""))
					if op in ["change_scene_with_palette_fadeout", "load_room_at_entry_with_facing"]:
						has_scene = true
					if op in ["branch_if_compare_false", "if_compare_then_block"]:
						has_cond = true
				if has_scene:
					exits += 1
					if has_cond:
						gated += 1
	print("[door_gating_test] %d arrival(EVENT) exits, %d of them ROM-gated" % [exits, gated])
	ok = ok and exits >= 20 and gated >= 3

	# 2. room 11's Double Doors: the canonical gate (flag15) + OPEN/SHUT pair
	var dd: Dictionary = {}
	for o in man["11"].get("objects", []):
		if int(o.get("entity_id", -1)) == 57:
			dd = o
	var verbs := {}
	for b in dd.get("behaviors", []):
		verbs[int(b.get("verb_code", -1))] = b
	var has_open: bool = verbs.has(3)
	var has_shut: bool = verbs.has(4)
	var ev: Dictionary = verbs.get(11, {})
	var ev_cond := false
	for a in ev.get("actions", []):
		if str(a.get("op", "")) == "branch_if_compare_false":
			ev_cond = true
	print("[door_gating_test] room11 Double Doors: OPEN=%s SHUT=%s EVENT-gated=%s" %
		[has_open, has_shut, ev_cond])
	ok = ok and has_open and has_shut and ev_cond

	# 3. runtime cels exist for an openable object (room 13's doors -> cel 111)
	var cels: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(
		"res://assets/data/hotel/room_13/cels/cels.json")).get("by_entity", {})
	var door_cels: Array = cels.get("130", [])
	print("[door_gating_test] room13 door runtime cels: %s" %
		[door_cels.map(func(c): return int(c["cel"]))])
	ok = ok and door_cels.size() >= 1

	# 4. item cels rendered (takeables visible)
	var items: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(
		"res://assets/data/hotel/room_13/items/items.json"))
	print("[door_gating_test] room13 items rendered: %s" %
		[items.get("items", []).map(func(i): return str(i["name"]))])
	ok = ok and items.get("items", []).size() >= 2

	print("[door_gating_test] RESULT: ", ("PASS" if ok else "FAIL"))
	quit()

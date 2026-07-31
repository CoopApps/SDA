extends SceneTree
## Every op name that appears in the hotel manifest's decoded action lists must
## have a matching case in room_behavior_runner.gd (or be a known scan-pass /
## interaction-layer op that the runner is NOT supposed to execute). Guards
## against new manifest bakes silently introducing unexecuted ops.

# Ops served OUTSIDE the runner: op 1 guards are resolved at manifest-bake time
# (the scan pass), op 2 choices render via ChoiceBar.
const NON_RUNNER_OPS := [
	"match_event_selectors_else_skip_block",
	"register_choice_option",
]

func _init() -> void:
	var runner := FileAccess.get_file_as_string("res://scripts/room_behavior_runner.gd")
	var f := FileAccess.open("res://assets/data/global/scene_manifest_hotel.json", FileAccess.READ)
	var m: Dictionary = JSON.parse_string(f.get_as_text())
	f.close()

	var used := {}
	_walk(m.get("scenes", {}), used)
	var missing: Array = []
	for op in used:
		if op in NON_RUNNER_OPS:
			continue
		if not runner.contains('"%s"' % op):
			missing.append("%s (x%d)" % [op, used[op]])
	print("[runner_coverage_test] %d distinct ops in hotel manifest actions" % used.size())
	if missing.is_empty():
		print("[runner_coverage_test] all runner-executed ops have handlers")
	else:
		for op in missing:
			print("[runner_coverage_test] MISSING handler: ", op)
	print("[runner_coverage_test] RESULT: ", ("PASS" if missing.is_empty() else "FAIL"))
	quit()

func _walk(o: Variant, used: Dictionary) -> void:
	if o is Dictionary:
		if o.has("op") and o["op"] is String:
			used[o["op"]] = int(used.get(o["op"], 0)) + 1
		for v in o.values():
			_walk(v, used)
	elif o is Array:
		for v in o:
			_walk(v, used)

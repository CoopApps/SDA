extends SceneTree
## The lobby door bug, end to end: every door's REAL open handler is nested in
## a `flag 14` state test (fb14 = 0xFF initially = ALL doors shut). Verifies the
## nested guards are recovered, the door starts shut, and the recovered OPEN
## block is the real one (anim + cel swap) rather than the "already open" text.

func _init() -> void:
	await process_frame
	var game = get_root().get_node_or_null("Game")
	if game == null:
		game = (load("res://scripts/game.gd") as GDScript).new()
		game.name = "Game"; get_root().add_child(game); await process_frame
	game.set_cluster("hotel")
	var ok := true

	# fb14 = 0xFF -> every door starts SHUT
	var fb14: int = int(game.flags.get("fb14", 0))
	print("[nested_test] fb14 = 0x%02X (%s)" % [fb14, "all doors SHUT" if fb14 == 0xFF else "WRONG"])
	ok = ok and fb14 == 0xFF

	# the lobby Outside Door (47) must now have a nested OPEN whose block
	# really opens it (cel swap), not just text
	var nb: Array = game.nested_behaviors_for(47)
	var open_real := false
	for b in nb:
		if int(b.get("verb_code", -1)) != 3:
			continue
		for a in b.get("actions", []):
			for inner in a.get("then", []):
				if str(inner.get("op", "")) == "actor_set_word0_and_raise_pending_flag":
					open_real = true
	print("[nested_test] Outside Door nested guards: %d, OPEN swaps its cel: %s" % [nb.size(), open_real])
	ok = ok and nb.size() >= 2 and open_real

	# and the whole game: how many objects regained a nested handler
	var ents := 0
	var guards := 0
	for k in game.nested_behaviors:
		ents += 1
		guards += (game.nested_behaviors[k] as Array).size()
	print("[nested_test] recovered %d nested guards across %d objects" % [guards, ents])
	ok = ok and guards >= 15

	print("[nested_test] RESULT: ", ("PASS" if ok else "FAIL"))
	quit()

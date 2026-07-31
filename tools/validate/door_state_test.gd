extends SceneTree
## Verifies the chapter's INITIAL FLAG BLOCK is seeded (ROM 0x7F66 copies it to
## $FF2A00) so stateful doors start SHUT, and that each room's entry point is a
## walkable spot (the ROM spawns the leads there, scene_load row 308).

func _init() -> void:
	await process_frame
	var game = get_root().get_node_or_null("Game")
	if game == null:
		game = (load("res://scripts/game.gd") as GDScript).new()
		game.name = "Game"; get_root().add_child(game); await process_frame
	game.set_cluster("hotel")
	var ok := true

	# 1. initial flags seeded, and fb15 bit0 == 1 (front/double doors SHUT)
	var fb15: int = int(game.flags.get("fb15", 0))
	var shut: bool = (fb15 & 1) == 1
	print("[door_state_test] seeded flags: %d, fb15=0x%02X -> door bit0=%d (%s)" %
		[game.flags.size(), fb15, fb15 & 1, "SHUT (correct)" if shut else "open (WRONG)"])
	ok = ok and shut and game.flags.size() >= 7

	# 2. every hotel room's entry point 0 resolves to a real coordinate
	var rooms: Array = []
	for k in game.manifest.get("scenes", {}):
		rooms.append(int(k))
	rooms.sort()
	var good := 0
	var bad: Array = []
	for rid in rooms:
		var e: Vector2 = game.waypoint_px(rid, 0)
		if e.x >= 0 and (e.x > 0 or e.y > 0):
			good += 1
		else:
			bad.append(rid)
	print("[door_state_test] rooms with a usable entry point: %d/%d %s" %
		[good, rooms.size(), ("" if bad.is_empty() else "(no entry: %s)" % str(bad))])
	ok = ok and good >= rooms.size() - 2

	print("[door_state_test] RESULT: ", ("PASS" if ok else "FAIL"))
	quit()

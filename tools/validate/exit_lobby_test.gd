extends SceneTree
## End-to-end: leaving the lobby by the front door must land the player AT the
## room-11 entry point (beside the door), on walkable ground, in a region big
## enough to walk out of -- not in a sealed pocket.
func _init() -> void:
	await process_frame
	var game = get_root().get_node_or_null("Game")
	if game == null:
		game = (load("res://scripts/game.gd") as GDScript).new()
		game.name = "Game"; get_root().add_child(game); await process_frame
	game.set_cluster("hotel")
	var RoomScript: GDScript = load("res://scripts/room.gd")
	var by_id := {}
	for d in game.rooms:
		by_id[int(d["room_id"])] = d
	var room = RoomScript.new()
	get_root().add_child(room)
	# 1. be in the lobby, fully flood-filled (this is what poisoned the check)
	room.load_room(by_id[16])
	room.compute_reachable(Vector2(248, 80))
	# 2. walk out the front door -> room 11, entry 0
	room.load_room(by_id[11])
	var wp = game.load_json("res://assets/data/global/waypoints_hotel.json")["rooms"]["11"]
	var e: Array = wp["entries_px"][0]
	var entry := Vector2(float(e[0]), float(e[1]))
	var blocked_before_fill: bool = room.is_blocked(entry.x, entry.y)
	room.compute_reachable(entry)
	var open := 0
	for c in room.reachable:
		if c != 0: open += 1
	print("[exit_lobby_test] r11 entry0 = (%d,%d)  blocked=%s  region=%d tiles"
		% [int(entry.x), int(entry.y), blocked_before_fill, open])
	var ok: bool = (not blocked_before_fill) and open >= 100
	print("[exit_lobby_test] %s" % ("PASS" if ok else "FAIL"))
	quit(0 if ok else 1)

extends SceneTree
## Every room's entry points must land on WALKABLE ground inside a real floor
## region. The ROM spawns the leads at the entry point (scene_load row 308), so
## an entry that is solid -- or sits in a sealed one-tile pocket -- beams the
## player somewhere he cannot walk out of.

func _init() -> void:
	await process_frame
	var game = get_root().get_node_or_null("Game")
	if game == null:
		game = (load("res://scripts/game.gd") as GDScript).new()
		game.name = "Game"; get_root().add_child(game); await process_frame
	game.set_cluster("hotel")
	var RoomScript: GDScript = load("res://scripts/room.gd")
	var wp: Dictionary = game.load_json(
		"res://assets/data/global/waypoints_%s.json" % game.cluster).get("rooms", {})
	var bad := 0
	for desc in game.rooms:
		var rid := int(desc["room_id"])
		var room = RoomScript.new()
		get_root().add_child(room)
		if not room.load_room(desc):
			room.queue_free()
			continue
		var r: Dictionary = wp.get(str(rid), {})
		var n := int(r.get("count", 0))
		var pts: Array = r.get("entries_px", [])
		for i in range(min(n, pts.size())):
			var p: Array = pts[i]
			var v := Vector2(float(p[0]), float(p[1]))
			room.reachable = PackedByteArray()
			var solid: bool = room._pixel_blocked(int(v.x), int(v.y))
			room.compute_reachable(v)
			var open := 0
			for c in room.reachable:
				if c != 0:
					open += 1
			if solid or open < 12:
				print("  r%-3d entry%d (%d,%d)  solid=%s reachable_tiles=%d"
					% [rid, i, int(v.x), int(v.y), solid, open])
				bad += 1
		room.queue_free()
	print("[entry_walkable_test] entry points in an unusable spot: %d" % bad)

	# Regression: a room TRANSITION must not consult the previous room's flood
	# fill. `reachable` is indexed by the current width, so a stale array from a
	# differently-sized room answers from a garbage cell -- which reported the
	# arrival entry as blocked and dumped the player in a sealed pocket.
	var t_room = RoomScript.new()
	get_root().add_child(t_room)
	var by_id: Dictionary = {}
	for d in game.rooms:
		by_id[int(d["room_id"])] = d
	var stale_bad := 0
	for pair in [[16, 11], [11, 16], [16, 9], [9, 16], [16, 13]]:
		if not (by_id.has(pair[0]) and by_id.has(pair[1])):
			continue
		t_room.load_room(by_id[pair[0]])
		t_room.compute_reachable(Vector2(160, 100))     # fill the FIRST room
		t_room.load_room(by_id[pair[1]])                # ...then walk into the second
		var e: Array = wp.get(str(pair[1]), {}).get("entries_px", [[0, 0]])[0]
		var ev := Vector2(float(e[0]), float(e[1]))
		if t_room.is_blocked(ev.x, ev.y):
			print("  STALE: r%d -> r%d entry0 (%d,%d) reported blocked"
				% [pair[0], pair[1], int(ev.x), int(ev.y)])
			stale_bad += 1
	t_room.queue_free()
	print("[entry_walkable_test] transitions with a stale-reachable failure: %d" % stale_bad)
	quit(0 if (bad <= 1 and stale_bad == 0) else 1)

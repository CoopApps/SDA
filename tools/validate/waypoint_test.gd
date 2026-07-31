extends SceneTree
## Verifies the per-room waypoint (entry-point) table extracted by executing
## scene_load_activate (waypoints_<cluster>.json) resolves op-$0E slots to the
## expected pixel coords (tile<<3). Known values are the executed ROM results
## for hotel scenes 9/16 (ROM_MAP rows 208/307/391).

func _init() -> void:
	var path := "res://assets/data/global/waypoints_hotel.json"
	var f := FileAccess.open(path, FileAccess.READ)
	var data: Dictionary = JSON.parse_string(f.get_as_text())
	f.close()
	var rooms: Dictionary = data.get("rooms", {})

	# resolver mirror of Game.waypoint_px
	var resolve := func(rid: int, slot: int) -> Vector2:
		var r: Dictionary = rooms.get(str(rid), {})
		var px: Array = r.get("entries_px", [])
		if slot < 0 or slot >= px.size():
			return Vector2(-1, -1)
		return Vector2(int(px[slot][0]), int(px[slot][1]))

	var checks := [
		[16, 0, Vector2(112, 104)],
		[16, 1, Vector2(288, 64)],
		[9, 1, Vector2(272, 72)],
		[9, 0, Vector2(96, 112)],
		[4, 2, Vector2(120, 104)],
	]
	var ok := true
	for c in checks:
		var got: Vector2 = resolve.call(c[0], c[1])
		var pass_one: bool = got == c[2]
		ok = ok and pass_one
		print("[waypoint_test] room ", c[0], " slot ", c[1], " -> ", got,
			" expected ", c[2], "  ", ("ok" if pass_one else "MISMATCH"))
	# out-of-range slot must return sentinel, never (0,0)
	var oob: Vector2 = resolve.call(9, 99)
	ok = ok and oob == Vector2(-1, -1)
	print("[waypoint_test] oob slot -> ", oob, " (sentinel expected)")
	print("[waypoint_test] RESULT: ", ("PASS" if ok else "FAIL"))
	quit()

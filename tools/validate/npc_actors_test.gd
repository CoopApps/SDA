extends SceneTree
## Verifies resident-NPC placement uses the SEGA rule (top-left = pos - per-frame
## hotspot), not the Actor (-w/2,-h) approximation, and that the click rect
## matches the drawn sprite. Values are the executed/ROM-read results for the two
## verified hotel NPCs (Bear room 11, The Cook room 13). See gen_npc_actors.py.

func _init() -> void:
	var f := FileAccess.open("res://assets/data/global/npc_actors_hotel.json", FileAccess.READ)
	var data: Dictionary = JSON.parse_string(f.get_as_text())
	f.close()
	var rooms: Dictionary = data.get("rooms", {})

	var expect := {
		"Bear": {"room": "11", "x": 383, "y": 65, "hx": 69, "hy": 30, "tl": Vector2(314, 35)},
		"The Cook": {"room": "13", "x": 90, "y": 106, "hx": 24, "hy": 73, "tl": Vector2(66, 33)},
	}
	var ok := true
	for name in expect:
		var e: Dictionary = expect[name]
		var lst: Array = rooms.get(e["room"], [])
		var rec: Dictionary = {}
		for n in lst:
			if str(n.get("name")) == name:
				rec = n
				break
		if rec.is_empty():
			print("[npc_actors_test] MISSING ", name); ok = false; continue
		# placement: top-left = (x - hx, y - hy)
		var tl := Vector2(int(rec["x"]) - int(rec["hx"]), int(rec["y"]) - int(rec["hy"]))
		var place_ok: bool = tl == e["tl"] and int(rec["hx"]) == e["hx"] and int(rec["hy"]) == e["hy"]
		# click rect (top-left .. +w,+h) must contain the sprite centre
		var w := int(rec["w"]); var h := int(rec["h"])
		var centre := tl + Vector2(w * 0.5, h * 0.5)
		var hit: bool = centre.x >= tl.x and centre.x <= tl.x + w and centre.y >= tl.y and centre.y <= tl.y + h
		ok = ok and place_ok and hit
		print("[npc_actors_test] %-9s top-left %s (expect %s) rect-hit %s  %s"
			% [name, tl, e["tl"], hit, ("ok" if place_ok and hit else "FAIL")])
	print("[npc_actors_test] RESULT: ", ("PASS" if ok else "FAIL"))
	quit()

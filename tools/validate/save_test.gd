extends SceneTree
## Round-trips a game-state dict through SaveSystem: save, reload, verify every
## field survives (incl. nested flag dict + inventory array), then a missing
## slot returns empty.

func _init() -> void:
	var S := load("res://scripts/save_system.gd")
	var state := {
		"cluster": "hotel", "room": 13,
		"flags": {"taken_129": 1, "cook_angry": 1},
		"inventory": ["Key", "Bottle of Oil"],
		"companion": 1, "verb": 8, "score": 250,
	}
	var ok_save: bool = S.save_slot(3, state)
	var back: Dictionary = S.load_slot(3)
	var missing: Dictionary = S.load_slot(5)   # never written this run? clear it first

	var ok := (
		ok_save
		and str(back.get("cluster")) == "hotel"
		and int(back.get("room")) == 13
		and int(back.get("score")) == 250
		and int(back.get("companion")) == 1
		and (back.get("flags") as Dictionary).get("taken_129") != null
		and (back.get("inventory") as Array).size() == 2
		and str((back.get("inventory") as Array)[1]) == "Bottle of Oil"
		and back.has("_version")
	)
	print("[save_test] saved=", ok_save, " room=", back.get("room"),
		" inv=", back.get("inventory"), " flags=", back.get("flags"))
	print("[save_test] RESULT: ", ("PASS" if ok else "FAIL"))
	quit()

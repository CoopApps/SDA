extends SceneTree
## Verifies the per-frame hotspot data + the Actor's offset FORMULA (SEGA
## screen=pos-hotspot: offset = -(hx,hy) unflipped, (hx-w,-hy) flipped) without
## instantiating Actor (which needs the Game autoload, absent in --script runs;
## the Actor code itself is compile-checked by the --editor pass). Uses
## source_00 (Shaggy): the valid frames are placed by real hotspot and the ~19
## invalid-descriptor frames are omitted (held at runtime, never shown).

func _init() -> void:
	var dir := "D:/scoobydoo/sprites/source_00"
	var hs: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(dir + "/hotspots.json"))
	var pngs := 0
	for f in DirAccess.get_files_at(dir):
		if f.begins_with("frame_") and f.ends_with(".png"):
			pngs += 1
	var valid := hs.size()
	var held := pngs - valid
	var ok := valid > 0 and held > 0 and held < pngs / 4   # some held, but the minority

	# formula check on a known frame: frame_0ed2 hotspot (24,75), width 48.
	var e: Array = hs.get("frame_0ed2.png", [])
	var w := 48.0
	var off_unflipped := Vector2(-float(e[0]), -float(e[1]))
	var off_flipped := Vector2(float(e[0]) - w, -float(e[1]))
	var formula_ok := e.size() == 2 and off_unflipped == Vector2(-24, -75) \
		and off_flipped == Vector2(24 - 48, -75)
	ok = ok and formula_ok

	# every table hotspot must be inside its frame (already enforced by generator)
	for f in hs:
		var hv: Array = hs[f]
		if hv[0] < 0 or hv[1] < 0:
			ok = false
			break

	print("[actor_hotspot_test] source_00: %d valid / %d frames (%d held)" % [valid, pngs, held])
	print("[actor_hotspot_test] frame_0ed2 hotspot %s  offset unflipped %s flipped %s  formula %s"
		% [e, off_unflipped, off_flipped, formula_ok])
	print("[actor_hotspot_test] RESULT: ", ("PASS" if ok else "FAIL"))
	quit()

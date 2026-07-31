extends SceneTree

## Headless (no GPU needed) state-only check: boots Intros.tscn, confirms it
## reaches PreMenuAnim.tscn, and confirms the pre-menu -> menu phase
## transition actually happens within the expected frame budget.
##
## Run:  D:\godot\Godot_v4.7.1-stable_win64_console.exe --headless --path . \
##         -s tools/validate/pre_menu_headless.gd

func _initialize() -> void:
	var scene: Node = load("res://Intros.tscn").instantiate()
	get_root().add_child(scene)
	current_scene = scene

	var frame := 0
	var reached_pre_menu := false
	var last_path := ""
	while frame < 12000:
		await process_frame
		frame += 1
		var cur: Node = current_scene
		var path := cur.scene_file_path if cur != null else ""
		if path != last_path:
			print("SCENE,%d,%s" % [frame, path])
			last_path = path
		if not reached_pre_menu and path.ends_with("PreMenuAnim.tscn"):
			reached_pre_menu = true
		if reached_pre_menu and cur.get("_phase") != null and String(cur.get("_phase")) == "menu":
			print("ENTERED menu phase at frame %d (_frame=%s)" % [frame, cur.get("_frame")])
			quit()
			return

	if not reached_pre_menu:
		printerr("FAIL: never reached PreMenuAnim.tscn")
	else:
		printerr("FAIL: reached PreMenuAnim but never entered menu phase within 1200 frames")
	quit(1)

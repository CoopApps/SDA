extends SceneTree

## Boots the real Intros.tscn all the way through the 5 logos into
## PreMenuAnim.tscn (the new pre-menu/main-menu port), then screenshots at
## two points: mid pre-menu dissolve, and after the menu phase has kicked in.
##
## Run (NOT headless -- needs a real viewport texture):
##   D:\godot\Godot_v4.7.1-stable_win64_console.exe --path D:\scoobygodot \
##     -s tools/validate/pre_menu_smoke.gd

const OUT_DIR := "res://tools/validate/out"

func _initialize() -> void:
	var scene: Node = load("res://Intros.tscn").instantiate()
	get_root().add_child(scene)
	current_scene = scene

	var frame := 0
	var reached_pre_menu := false
	var shot_mid := false
	var shot_menu := false
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))

	while frame < 900:
		await process_frame
		frame += 1
		var cur: Node = current_scene
		var path := cur.scene_file_path if cur != null else ""
		if not reached_pre_menu and path.ends_with("PreMenuAnim.tscn"):
			reached_pre_menu = true
			print("REACHED PreMenuAnim at frame %d" % frame)
		if reached_pre_menu and not shot_mid and cur.get("_frame") != null and int(cur.get("_frame")) >= 30:
			_shot("pre_menu_mid.png")
			shot_mid = true
		if reached_pre_menu and not shot_menu and cur.get("_phase") != null and String(cur.get("_phase")) == "menu":
			_shot("pre_menu_menu_phase.png")
			shot_menu = true
			print("ENTERED menu phase at frame %d" % frame)
			break

	if not reached_pre_menu:
		printerr("FAIL: never reached PreMenuAnim.tscn (stuck at %s)" % (current_scene.scene_file_path if current_scene else "null"))
		quit(1)
		return
	if not shot_menu:
		printerr("FAIL: never entered menu phase within 900 frames")
		quit(1)
		return
	print("OK")
	quit()

func _shot(name: String) -> void:
	var img: Image = get_root().get_texture().get_image()
	img.save_png(ProjectSettings.globalize_path(OUT_DIR + "/" + name))
	print("saved " + name)

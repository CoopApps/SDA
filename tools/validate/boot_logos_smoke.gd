extends SceneTree

## Phase 2 gate, step 1 (boot logos): load the real Intros.tscn (now the
## project's actual run/main_scene), let it play into the SEGA logo's held
## frame (fade-in is 7 frames, then a 51-frame hold -- 40 frames in is
## safely inside the hold), and screenshot it.
##
## Must run WITHOUT --headless (get_viewport().get_texture() is null under
## the dummy backend, see smoke_render.gd).
##
## Run:  D:\godot\Godot_v4.7.1-stable_win64_console.exe --path D:\scoobygodot \
##         -s tools/validate/boot_logos_smoke.gd
## Output: tools/validate/out/boot_logos_smoke.png -- READ THIS IMAGE.

const OUT_DIR := "res://tools/validate/out"
const OUT_PNG := OUT_DIR + "/boot_logos_smoke.png"


func _initialize() -> void:
	var scene: Node = load("res://Intros.tscn").instantiate()
	get_root().add_child(scene)
	current_scene = scene

	for i in range(40):
		await process_frame

	var img: Image = get_root().get_texture().get_image()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	var err := img.save_png(ProjectSettings.globalize_path(OUT_PNG))
	if err != OK:
		printerr("FAIL: save_png returned %d" % err)
		quit(1)
		return
	print("OK: saved %s" % OUT_PNG)
	quit()

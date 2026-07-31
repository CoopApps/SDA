extends SceneTree

## Phase 3 gate: run the hotel intro (titlecard -> van drive -> room 3
## interior chat) through script_vm.gd + intro_presenter.gd, screenshot key
## moments, and confirm it halts cleanly the instant it would transition into
## Room 9 (the excluded maid/ghost scene) rather than rendering it wrong.
##
## Must run WITHOUT --headless (get_viewport().get_texture() is null under
## the dummy backend, see smoke_render.gd).
##
## Run:  D:\godot\Godot_v4.7.1-stable_win64_console.exe --path D:\scoobygodot \
##         -s tools/validate/intro_smoke.gd

const IntroVMSceneScript = preload("res://scripts/intro_vm_scene.gd")
const OUT_DIR := "res://tools/validate/out"

var scene
var stopped_at_room := -1


func _initialize() -> void:
	scene = IntroVMSceneScript.new()
	get_root().add_child(scene)
	scene.start("hotel")

	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))

	# frame 0: sega/van driving, mid-titlecard
	for i in range(60):
		await process_frame
	_shot("intro_smoke_01_titlecard.png")
	print("titlecard frame captured")

	# let the van finish driving + enter room 3
	for i in range(300):
		await process_frame
	_shot("intro_smoke_02_room3.png")
	print("room3 frame captured, cur_scene=", scene.presenter._cur_scene)

	# advance through room 3's dialogue by synthesizing input presses on a
	# steady cadence, watching for the room-9 stop signal
	scene.presenter.stopped_before_excluded_scene.connect(func(room_id):
		stopped_at_room = room_id
	)
	var advanced_frames := 0
	while stopped_at_room < 0 and advanced_frames < 3000:
		# synthesize an accept press every ~40 frames to advance dialogue
		if advanced_frames % 40 == 0:
			var ev := InputEventKey.new()
			ev.keycode = KEY_ENTER
			ev.pressed = true
			Input.parse_input_event(ev)
			await process_frame
			var ev2 := InputEventKey.new()
			ev2.keycode = KEY_ENTER
			ev2.pressed = false
			Input.parse_input_event(ev2)
		await process_frame
		advanced_frames += 1

	_shot("intro_smoke_03_final.png")
	if stopped_at_room == 9:
		print("OK: halted cleanly before room 9 after ", advanced_frames, " frames")
	else:
		printerr("FAIL: did not halt before room 9 (stopped_at_room=", stopped_at_room,
			", advanced_frames=", advanced_frames, ")")
		quit(1)
		return
	quit()


func _shot(name: String) -> void:
	var img: Image = get_root().get_texture().get_image()
	img.save_png(ProjectSettings.globalize_path(OUT_DIR + "/" + name))

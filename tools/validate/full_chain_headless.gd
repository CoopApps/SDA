extends SceneTree

## Full headless chain check: Intros -> PreMenuAnim -> (select "PLAY BLAKE'S
## HOTEL") -> IntroChapterHotel (titlecard/van/room3 chat) -> Room9Intro ->
## Room10Intro -> Room16Intro -> PlayRoom. No GPU needed (state-only, no
## screenshots). Confirms the whole chain this session built completes
## without a dead end or script error.
##
## Run:  D:\godot\Godot_v4.7.1-stable_win64_console.exe --headless --path . \
##         -s tools/validate/full_chain_headless.gd

const MAX_FRAMES := 40000

func _initialize() -> void:
	var scene: Node = load("res://Intros.tscn").instantiate()
	get_root().add_child(scene)
	current_scene = scene

	var frame := 0
	var last_path := ""
	var entered_menu_phase := false
	var selected := false

	while frame < MAX_FRAMES:
		await process_frame
		frame += 1
		var cur: Node = current_scene
		var path := cur.scene_file_path if cur != null else ""
		if path != last_path:
			print("SCENE,%d,%s" % [frame, path])
			last_path = path
			if path.ends_with("PlayRoom.tscn"):
				print("OK: reached PlayRoom.tscn at frame %d" % frame)
				quit()
				return

		if cur == null:
			continue

		# PreMenuAnim: wait for menu phase, then press Enter once to select item 0.
		if path.ends_with("PreMenuAnim.tscn"):
			if not entered_menu_phase and cur.get("_phase") != null and String(cur.get("_phase")) == "menu":
				entered_menu_phase = true
			if entered_menu_phase and not selected:
				selected = true
				_press_enter(cur)

		# Any scene exposing "_await_text" (intro_scene_player.gd subclasses,
		# checked directly): press Enter periodically while blocked on a line.
		if cur.get("_await_text") != null and bool(cur.get("_await_text")):
			if frame % 30 == 0:
				_press_enter(cur)

		# IntroChapterHotel wraps intro_vm_scene.gd (child 0), whose
		# `.presenter` (intro_presenter.gd) holds the real `_await_text` --
		# not exposed on current_scene itself.
		if path.ends_with("IntroChapterHotel.tscn") and cur.get_child_count() > 0:
			var vm_scene: Node = cur.get_child(0)
			var presenter = vm_scene.get("presenter") if vm_scene != null else null
			if presenter != null and presenter.get("_await_text") != null and bool(presenter.get("_await_text")):
				if frame % 30 == 0:
					_press_enter(presenter)

	printerr("FAIL: did not reach PlayRoom.tscn within %d frames (stuck at %s)" % [MAX_FRAMES, last_path])
	quit(1)


func _press_enter(target: Node) -> void:
	var ev := InputEventKey.new()
	ev.keycode = KEY_ENTER
	ev.pressed = true
	if target.has_method("_unhandled_input"):
		target.call("_unhandled_input", ev)

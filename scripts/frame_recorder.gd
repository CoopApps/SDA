extends Node
## Dev frame recorder for the intro/front-end audit (env-gated, inert in
## normal play). SCOOBY_RECORD=<dir> captures the viewport every
## SCOOBY_RECORD_EVERY frames (default 6 = 10fps at 60Hz) as
## <dir>/<counter>_<scene>.png through the WHOLE scene chain (logos -> pre-menu
## -> menu -> chapter intro -> room intros -> gameplay), so every card, fade
## and intro screen can be audited offline.
##
## SCOOBY_AUTOPLAY=1 additionally advances the flow without faking input into
## the skippable cards: it only synthesizes ui_accept while the PRE-MENU scene
## has been active > 45 s (i.e. the interactive main menu, after its own
## animation), which starts the chapter intro. Everything else runs at its
## natural pace.

var dir := ""
var every := 6
var autoplay := false
var _frame := 0
var _shot := 0
var _scene_started_at := 0.0
var _last_scene := ""

func _ready() -> void:
	dir = OS.get_environment("SCOOBY_RECORD")
	if dir == "":
		set_process(false)
		return
	every = maxi(1, int(OS.get_environment("SCOOBY_RECORD_EVERY"))
		if OS.get_environment("SCOOBY_RECORD_EVERY") != "" else 6)
	autoplay = OS.get_environment("SCOOBY_AUTOPLAY") != ""
	DirAccess.make_dir_recursive_absolute(dir)

func _process(_delta: float) -> void:
	_frame += 1
	var cs: Node = get_tree().current_scene
	var scene: String = "none"
	if cs != null:
		scene = cs.scene_file_path.get_file().get_basename() if cs.scene_file_path != "" else str(cs.name)
	if scene != _last_scene:
		_last_scene = scene
		_scene_started_at = Time.get_ticks_msec() / 1000.0
	if _frame % every == 0:
		var img := get_viewport().get_texture().get_image()
		if img != null:
			img.save_png("%s/%06d_%s.png" % [dir, _shot, scene])
			_shot += 1
	if autoplay:
		var t := Time.get_ticks_msec() / 1000.0 - _scene_started_at
		# menu: start the hotel chapter once the pre-menu animation is done
		if scene == "PreMenuAnim" and t > 45.0 and _frame % 90 == 0:
			_press_enter()
		# every intro scene's dialogue is press-to-advance -- advance a line
		# every ~2.5 s (natural reading pace) so the whole flow plays through
		elif scene != "PreMenuAnim" and t > 4.0 and _frame % 150 == 0:
			_press_enter()

func _press_enter() -> void:
	var ev := InputEventKey.new()
	ev.keycode = KEY_ENTER
	ev.physical_keycode = KEY_ENTER
	ev.pressed = true
	Input.parse_input_event(ev)
	var up := InputEventKey.new()
	up.keycode = KEY_ENTER
	up.physical_keycode = KEY_ENTER
	up.pressed = false
	Input.parse_input_event(up)

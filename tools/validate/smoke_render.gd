extends SceneTree

## Phase 0 gate (see d:\claudetemp\plans\starry-tumbling-boot.md): prove the
## asset pipeline + screenshot harness work BEFORE any VM code is written.
## Loads one already-validated room background, renders it, and saves a real
## screenshot PNG -- the previous project's entire validation apparatus never
## produced a single pixel anyone looked at; this is the fix for that.
##
## Uses the proven `await process_frame` pattern (NOT a manual _process()
## loop, which was found this session to silently starve Tweens/timers).
##
## Run:  D:\godot\Godot_v4.7.1-stable_win64_console.exe --headless \
##         --path D:\scoobygodot -s tools/validate/smoke_render.gd
## Output: tools/validate/out/smoke_render.png -- READ THIS IMAGE, don't just
## trust the console log.

const OUT_DIR := "res://tools/validate/out"
const OUT_PNG := OUT_DIR + "/smoke_render.png"
const BG_PATH := "res://assets/data/hotel/room_09/background.png"

func _initialize() -> void:
	# `load()` needs the editor's resource-import step, which never runs in
	# pure `--script` mode (confirmed: "No loader found for resource").
	# Read raw image bytes directly instead -- same technique the old
	# project's intro_vm.gd::_load_tex() used for this exact reason.
	var img_path := ProjectSettings.globalize_path(BG_PATH)
	var raw_img := Image.new()
	var load_err := raw_img.load(img_path)
	if load_err != OK:
		printerr("FAIL: could not load %s (err %d)" % [img_path, load_err])
		quit(1)
		return
	var tex: Texture2D = ImageTexture.create_from_image(raw_img)
	var sp := Sprite2D.new()
	sp.centered = false
	sp.texture = tex
	get_root().add_child(sp)
	# a couple of real frames so the render actually completes before capture
	await process_frame
	await process_frame
	var img: Image = get_root().get_texture().get_image()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	var err := img.save_png(ProjectSettings.globalize_path(OUT_PNG))
	if err != OK:
		printerr("FAIL: save_png returned %d" % err)
		quit(1)
		return
	print("OK: saved %s (%dx%d source texture)" % [OUT_PNG, tex.get_width(), tex.get_height()])
	quit()

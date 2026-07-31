extends SceneTree
## Verifies CycleAnim rotates on the ROM's own schedule and wraps.
## animate_cycle_tiles 0x00A7CE runs once per VBLANK (0xA68C, inside
## gameplay_per_frame 0xA65C) = 60Hz, and 0xA7E4 `subq.w #1` / 0xA7E8 `bpl`
## fires only when the timer goes NEGATIVE -- so period P rotates every P+1
## VBLANK frames, not P.

func _init() -> void:
	var Cyc := load("res://scripts/cycle_anim.gd")
	var c = Cyc.new()
	var frames: Array = []
	for i in range(3):
		var img := Image.create(4, 4, false, Image.FORMAT_RGBA8)
		frames.append(ImageTexture.create_from_image(img))
	c.setup(frames, 2, Vector2.ZERO)          # period 2 -> a step every 3 frames
	var step := 3.0 / 60.0

	var f0: int = c.current_frame()           # 0
	c.step(step)
	var f1: int = c.current_frame()           # 1
	c.step(step)
	var f2: int = c.current_frame()           # 2
	c.step(step)
	var f3: int = c.current_frame()           # 0 (wrap)
	c.step(1.0 / 60.0)                        # partial period, no advance
	var f3b: int = c.current_frame()          # still 0

	var ok := f0 == 0 and f1 == 1 and f2 == 2 and f3 == 0 and f3b == 0
	print("[cycle_anim_test] seq=", [f0, f1, f2, f3, f3b], " RESULT: ", ("PASS" if ok else "FAIL"))
	c.free()
	quit()

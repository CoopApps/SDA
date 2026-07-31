extends Sprite2D
class_name CycleAnim

## A background CYCLE animation — the port equivalent of the verified ROM
## off-table cycle-animation system:
##   * op $1A  install_cycle_anim_channel  (ROM 0x2626, ROM_MAP row 117):
##       operand = channel, ring start, ring end, PERIOD (in game ticks)
##   * animate_cycle_tiles                 (ROM 0x00A7CE, ROM_MAP row 409):
##       every frame, decrements the slot timer; on expiry advances the ring
##       and re-uploads.
## The effect is PALETTE cycling (verified: $9B10 DMAs the $FF06F8 palette buffer
## to CRAM, CD=%100011). The ROM rotates a run of CRAM colour entries in place
## (Television = entries 62-63, Engine = 34-37); on a flat-RGB-background port we
## instead overlay the pre-rendered frames of that region and swap them on the
## same schedule. The (period, run, position) come straight from the op-$1A
## operand; frames are produced offline by tools/gen_cycle_frames.py (rotate the
## palette run, recolour the matching background pixels).
##
## Verified in-game users (ROM_MAP): Television (hotel cluster 14, ring $3E-$3F,
## period 1) and Engine (hotel cluster 18, ring $22-$25, period 4).

## animate_cycle_tiles 0x00A7CE runs from 0xA68C inside gameplay_per_frame
## 0xA65C -- once per VBLANK, 60Hz.
const TICKS_PER_SEC := 60.0
## 0xA7E4 `subq.w #1,10(A1,D3.w)` then 0xA7E8 `bpl` -- the rotation fires only
## when the timer goes NEGATIVE, so reloading period P gives P+1 frames per
## step, not P.
const PERIOD_BIAS := 1

var frames: Array = []          # Array[Texture2D], one per ring position
var period_ticks := 1           # ticks between advances (op-$1A operand)
var cram_run: Array = []        # [lo, hi] CRAM entries this channel cycles
var _frame := 0
var _accum := 0.0

func setup(frames_: Array, period_ticks_: int, pos: Vector2, z := 3, run := []) -> void:
	frames = frames_
	period_ticks = maxi(1, period_ticks_)
	cram_run = run
	centered = false
	position = pos
	z_index = z
	_frame = 0
	_accum = 0.0
	if not frames.is_empty():
		texture = frames[0]

## Apply a runtime op-$1A trigger: period $FFFF (65535) disables the channel
## (freeze on frame 0, hidden); any other period turns it on at that rate.
func apply_period(period: int) -> void:
	if period == 0xFFFF:
		visible = false
		_frame = 0
		_accum = 0.0
		if not frames.is_empty():
			texture = frames[0]
	else:
		visible = true
		period_ticks = maxi(1, period)

## Manually advance the animation by `delta` seconds. Called from _process at
## runtime; exposed so headless tests can step it deterministically.
func step(delta: float) -> void:
	if frames.size() < 2:
		return
	_accum += delta * TICKS_PER_SEC
	var step_frames := float(period_ticks + PERIOD_BIAS)
	while _accum >= step_frames:
		_accum -= step_frames
		_frame = (_frame + 1) % frames.size()
	if _frame < frames.size():
		texture = frames[_frame]

func current_frame() -> int:
	return _frame

func _process(delta: float) -> void:
	step(delta)

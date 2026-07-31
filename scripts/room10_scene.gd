extends "res://scripts/intro_scene_player.gd"

## Room 10 "Outside the Hotel" -- adds the blinking garland/lights over the
## door. Unlike bg_back/bg_front elsewhere (flat PNGs), this front layer is
## SPARSE indexed pixel data (DATA.bg_front.px, each [x, y, pal_line,
## pal_idx]) rebuilt every ~180ms with palette line 3's bulb range
## (DATA.bulb: indices lo..hi) rotated -- the artifact's own citation:
## "the game's CRAM cycle, 0xA7CE". The base class only knows how to load a
## flat "png" bg_front; since this room's data has no "png" key at all,
## _bg_front.texture was silently staying null -- no lights layer rendered.

var _bulb_off := 0
var _bulb_ms := 0.0
const BULB_STEP_MS := 180.0


func _extra_ready() -> void:
	_rebuild_front()


func _extra_tick(ms: float) -> void:
	var bulb: Dictionary = DATA.get("bulb", {})
	if bulb.is_empty():
		return
	var nb: int = int(bulb.get("hi", 0)) - int(bulb.get("lo", 0)) + 1
	if nb <= 0:
		return
	_bulb_ms += ms
	if _bulb_ms >= BULB_STEP_MS:
		_bulb_ms = 0.0
		_bulb_off = (_bulb_off + 1) % nb
		_rebuild_front()


func _rebuild_front() -> void:
	var bf: Dictionary = DATA.get("bg_front", {})
	var px: Array = bf.get("px", [])
	if px.is_empty():
		return
	var w := int(bf.get("w", 0))
	var h := int(bf.get("h", 0))
	var pal: Array = DATA.get("pal10", [])
	var bulb: Dictionary = DATA.get("bulb", {})
	var bline := int(bulb.get("line", -1))
	var blo := int(bulb.get("lo", 0))
	var bhi := int(bulb.get("hi", 0))
	var nb := bhi - blo + 1
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	for entry in px:
		var x := int(entry[0])
		var y := int(entry[1])
		var line := int(entry[2])
		var idx := int(entry[3])
		if line < 0 or line >= pal.size():
			continue
		var eff_idx := idx
		if line == bline and idx >= blo and idx <= bhi and nb > 0:
			eff_idx = blo + ((idx - blo + _bulb_off) % nb)
		var line_colors: Array = pal[line]
		if eff_idx < 0 or eff_idx >= line_colors.size():
			continue
		var c: Array = line_colors[eff_idx]
		img.set_pixel(x, y, Color(float(c[0]) / 255.0, float(c[1]) / 255.0, float(c[2]) / 255.0, 1.0))
	if _bg_front != null:
		_bg_front.texture = ImageTexture.create_from_image(img)

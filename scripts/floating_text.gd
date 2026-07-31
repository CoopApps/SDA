extends Sprite2D

## Reusable floating-dialogue renderer for gameplay verb responses -- same
## technique as intro_scene_player.gd's cutscene dialogue (thin 8x8 font,
## 8-direction black outline, wrapped + centered, anchor frozen once per
## line), so gameplay responses read identically to the cutscenes instead
## of falling back to the old plain status-bar sentence line.

const GLYPH := 8
const FONT_PATH := "res://assets/hud_font.png"
const FONT_GW := 8
const FONT_GH := 8
const FONT_FIRST := 0x20
const FONT_COLS := 16

var _font_img: Image
var _tint_cache: Dictionary = {}

func _ready() -> void:
	centered = false
	z_index = 4050   # above actors/room art/foreground (4000); max allowed is 4096
	visible = false
	_font_img = Image.load_from_file(ProjectSettings.globalize_path(FONT_PATH))


func _tint_glyph_atlas(color: Color) -> Image:
	var key := color.to_html()
	if _tint_cache.has(key):
		return _tint_cache[key]
	var img: Image = _font_img.duplicate()
	img.convert(Image.FORMAT_RGBA8)
	for y in range(img.get_height()):
		for x in range(img.get_width()):
			var p := img.get_pixel(x, y)
			if p.a > 0.0:
				img.set_pixel(x, y, Color(color.r, color.g, color.b, p.a))
	_tint_cache[key] = img
	return img


func _wrap_text(text: String, max_w: int, scale: float) -> Array:
	var gw := FONT_GW * scale
	var words := text.split(" ")
	var lines: Array = []
	var cur := ""
	for w in words:
		var t: String = (cur + " " + w) if cur != "" else w
		if t.length() * gw <= max_w:
			cur = t
		else:
			if cur != "":
				lines.append(cur)
			cur = w
	if cur != "":
		lines.append(cur)
	return lines


func _blit_line(out: Image, atlas: Image, line: String, x: int, y: int, scale: float) -> void:
	var gx := x
	for i in range(line.length()):
		var ch := line.unicode_at(i)
		if ch != 32 and ch >= FONT_FIRST and ch < FONT_FIRST + 96:
			var gi := ch - FONT_FIRST
			var sx := (gi % FONT_COLS) * FONT_GW
			var sy := int(gi / FONT_COLS) * FONT_GH
			var src := Rect2i(sx, sy, FONT_GW, FONT_GH)
			if scale == 1.0:
				out.blit_rect(atlas, src, Vector2i(gx, y))
			else:
				var scaled := atlas.get_region(src)
				scaled.resize(int(FONT_GW * scale), int(FONT_GH * scale), Image.INTERPOLATE_NEAREST)
				out.blend_rect(scaled, Rect2i(Vector2i.ZERO, scaled.get_size()), Vector2i(gx, y))
		gx += int(FONT_GW * scale)


## Shows `text` (wrapped, outlined, tinted `color`) anchored so its BOTTOM
## sits at `anchor` (world position, typically just above a character's head).
func show_line(text: String, color: Color, anchor: Vector2, max_w: int = 150, scale: float = 0.85) -> void:
	var lines := _wrap_text(text, max_w, scale)
	if lines.is_empty():
		hide_line()
		return
	var gw := FONT_GW
	var gh := FONT_GH
	var max_len := 0
	for l in lines:
		max_len = max(max_len, str(l).length())
	var pad := 2
	var img_w := int(max_len * gw * scale) + pad * 2
	var img_h := int(lines.size() * (gh * scale + 2)) + pad * 2
	var out := Image.create(img_w, img_h, false, Image.FORMAT_RGBA8)
	var tinted := _tint_glyph_atlas(color)
	var black := _tint_glyph_atlas(Color.BLACK)
	var offs := [Vector2i(-1, -1), Vector2i(0, -1), Vector2i(1, -1), Vector2i(-1, 0),
		Vector2i(1, 0), Vector2i(-1, 1), Vector2i(0, 1), Vector2i(1, 1)]
	var ty := pad
	for l in lines:
		var line := str(l)
		var w := line.length() * gw * scale
		var lx := int(pad + (img_w - pad * 2 - w) / 2.0)
		for off in offs:
			_blit_line(out, black, line, lx + off.x, ty + off.y, scale)
		_blit_line(out, tinted, line, lx, ty, scale)
		ty += int(gh * scale) + 2
	texture = ImageTexture.create_from_image(out)
	position = Vector2(anchor.x - img_w / 2.0, anchor.y - img_h)
	visible = true


func hide_line() -> void:
	visible = false

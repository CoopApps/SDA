extends RefCounted

const _Self := preload("res://scripts/hud_font.gd")

## Game bitmap fonts extracted from VRAM. Two available:
##  - HudFont.thin(): thin ASCII font (VRAM tiles 1696+, ASCII 0x20-based).
##    Single 96-glyph atlas (assets/hud_font.png). Full character set.
##  - HudFont.bold(): the BOLD verb-bar font (8x16 glyphs). This is not a
##    full ASCII font — the game only stores the 14 letters used by the
##    10 verbs: L O K T A E U S P H N G I V. Any other character renders
##    as nothing. Cited: gameplay.state plane A rows 22-25 nametable, see
##    D:/scoobydoo/hud/atlas.json (produced by scooby_hud.py).
##
## Glyphs render white-on-transparent so the caller tints them.

var _thin_atlas: Texture2D
var _thin_glyphs: Array[AtlasTexture] = []
var _thin_first: int = 0
var _thin_cols: int = 0
var _bold_glyphs: Dictionary = {}   # int(char code) -> Texture2D

const _THIN_GLYPH := 8
const _BOLD_W := 8
const _BOLD_H := 16
const _BOLD_LETTERS := ["A", "E", "G", "H", "I", "K", "L", "N", "O", "P", "S", "T", "U", "V"]

static func thin():
	return _Self.new()._setup_thin("res://assets/hud_font.png", 0x20, 96, 16)

static func bold():
	return _Self.new()._setup_bold("res://assets/hud/letters/")

func _setup_thin(path: String, first: int, n: int, columns: int):
	_thin_atlas = load(path)
	_thin_first = first
	_thin_cols = columns
	if _thin_atlas == null:
		push_error("HudFont: missing " + path)
		return self
	for i in range(n):
		var a := AtlasTexture.new()
		a.atlas = _thin_atlas
		a.region = Rect2((i % columns) * _THIN_GLYPH, (i / columns) * _THIN_GLYPH,
				_THIN_GLYPH, _THIN_GLYPH)
		_thin_glyphs.append(a)
	return self

func _setup_bold(dir_path: String):
	for ch in _BOLD_LETTERS:
		var tex: Texture2D = load(dir_path + ch + ".png")
		if tex == null:
			push_error("HudFont.bold: missing " + dir_path + ch + ".png")
			continue
		_bold_glyphs[ch.unicode_at(0)] = tex
	return self

func is_bold() -> bool:
	return not _bold_glyphs.is_empty()

func glyph_size() -> Vector2:
	return Vector2(_BOLD_W, _BOLD_H) if is_bold() else Vector2(_THIN_GLYPH, _THIN_GLYPH)

func text_width(s: String) -> int:
	return s.length() * int(glyph_size().x)

## Draw bold text scaled by `scale` (each glyph drawn at _BOLD_W*scale x
## _BOLD_H*scale, advancing by the scaled width). Returns the drawn pixel width.
func draw_text_scaled(ci: CanvasItem, s: String, pos: Vector2, color: Color, scale: float) -> float:
	var gw := _BOLD_W * scale
	var gh := _BOLD_H * scale
	var x := pos.x
	for i in range(s.length()):
		var tex: Texture2D = _bold_glyphs.get(s.unicode_at(i))
		if tex != null:
			ci.draw_texture_rect(tex, Rect2(x, pos.y, gw, gh), false, color)
		x += gw
	return x - pos.x

func bold_scaled_width(s: String, scale: float) -> float:
	return s.length() * _BOLD_W * scale

func draw_text(ci: CanvasItem, s: String, pos: Vector2, color: Color) -> void:
	var x := pos.x
	if is_bold():
		for i in range(s.length()):
			var code := s.unicode_at(i)
			var tex: Texture2D = _bold_glyphs.get(code)
			if tex != null:
				ci.draw_texture_rect(tex, Rect2(x, pos.y, _BOLD_W, _BOLD_H),
						false, color)
			x += _BOLD_W
	else:
		for i in range(s.length()):
			var idx := s.unicode_at(i) - _thin_first
			if idx >= 0 and idx < _thin_glyphs.size():
				ci.draw_texture_rect(_thin_glyphs[idx],
						Rect2(x, pos.y, _THIN_GLYPH, _THIN_GLYPH), false, color)
			x += _THIN_GLYPH

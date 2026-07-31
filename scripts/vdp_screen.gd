extends RefCounted
class_name VDPScreen

## A Genesis screen rendered the Godot-native way: the picture is an INDEX
## image (each texel = colour index 0..15 in R, palette number 0..3 in G)
## drawn ONCE, and a palette shader colours it live on the GPU.
##
## Why: palette animation (the SEGA streak, the menu's lightning/title
## glow) is just a palette change on real hardware. Re-compositing pixels
## in GDScript every frame is far too slow; swapping a small palette
## texture is free. So animation = `rotate_palette()` / `set_palette()`
## then `apply_palette()`.
##
## Assets (from exporters/scooby_screens.py):
##   screen.idx        composed 256x224 index image (planes B+A, VDP rules)
##   palettes.json     4 palettes x 16 RGB
##   sprites.json      on-screen sprites — MOVING ones become Godot nodes
##   sprite_tiles.idx  index atlas of sprite tiles
##
## Usage:
##   var s := VDPScreen.new("res://assets/screens/menu/")
##   add_child(s.make_sprite())        # the static picture
##   s.rotate_palette(0, 2, 10); s.apply_palette()   # animate

const PALETTE_SHADER := preload("res://shaders/palette.gdshader")

var width: int
var height: int
var palettes: Array                 # [4][16] of [r,g,b]
var sprites: Array                  # OAM entries (for moving elements)
var sprite_tiles_index: Dictionary  # vram tile id (String) -> atlas cell
var _index_tex: ImageTexture
var _palette_tex: ImageTexture
var _mat: ShaderMaterial
var _sprite_mat: ShaderMaterial
var _sprite_atlas: PackedByteArray
var _sprite_atlas_w: int
var _sprite_atlas_cols: int
var _dir: String

func _init(dir_path: String) -> void:
	_dir = dir_path
	# --- index image ---
	_index_tex = _pack_index_file(dir_path + "screen.idx")

	palettes = _load_json(dir_path + "palettes.json")
	var sp: Dictionary = _load_json(dir_path + "sprites.json")
	sprites = sp.get("sprites", [])
	sprite_tiles_index = sp.get("tiles_index", {})

	var sf := FileAccess.open(dir_path + "sprite_tiles.idx", FileAccess.READ)
	if sf:
		var sraw := sf.get_buffer(sf.get_length())
		sf.close()
		_sprite_atlas_w = sraw[0] | (sraw[1] << 8)
		_sprite_atlas_cols = sraw[4]
		_sprite_atlas = sraw.slice(6)

	_mat = ShaderMaterial.new()
	_mat.shader = PALETTE_SHADER
	_mat.set_shader_parameter("opaque_backdrop", true)    # background planes
	_sprite_mat = ShaderMaterial.new()
	_sprite_mat.shader = PALETTE_SHADER
	_sprite_mat.set_shader_parameter("opaque_backdrop", false)
	_build_palette_texture()

## Build an index texture (index in R, palette-number in G) from a .idx file.
## Sets width/height from the file header. Returns null on failure.
func _pack_index_file(path: String) -> ImageTexture:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("VDPScreen: missing " + path)
		return null
	var raw := f.get_buffer(f.get_length())
	f.close()
	width = raw[0] | (raw[1] << 8)
	height = raw[2] | (raw[3] << 8)
	var body := raw.slice(6)
	var img := Image.create(width, height, false, Image.FORMAT_RGBA8)
	for y in range(height):
		for x in range(width):
			var o := (y * width + x) * 2
			img.set_pixel(x, y, Color8(body[o], body[o + 1], 0, 255))
	return ImageTexture.create_from_image(img)

## Load an index texture from a kit-relative .idx (e.g. "anim/cel_00.idx"),
## for picture animation (illusions filmstrip). Same palette shader applies.
func load_index_texture(rel: String) -> ImageTexture:
	return _pack_index_file(_dir + rel)

## Load an index texture from an absolute res:// path (e.g. a shared asset in
## another screen dir). Same packing as load_index_texture.
func load_index_abs(path: String) -> ImageTexture:
	return _pack_index_file(path)

## The static picture as a ready-to-add Sprite2D (shader-coloured).
func make_sprite() -> Sprite2D:
	var s := Sprite2D.new()
	s.texture = _index_tex
	s.centered = false
	s.position = Vector2.ZERO
	s.material = _mat
	s.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	return s

## Build a plain layer sprite for a given index texture, sharing this screen's
## palette. `opaque` picks the material: true = background plane (index 0 shows
## the backdrop colour); false = overlay (index 0 transparent, lets layers below
## show through). Used by the acclaim two-layer hscroll (plane B behind, A front).
func make_layer(tex: Texture2D, opaque: bool) -> Sprite2D:
	var s := Sprite2D.new()
	s.texture = tex
	s.centered = false
	s.material = _mat if opaque else _sprite_mat
	s.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	return s

## Material for a transparent overlay layer (index 0 = transparent).
func front_material() -> ShaderMaterial:
	return _sprite_mat

func set_palette(index: int, colors: Array) -> void:
	palettes[index] = colors

## Rotate a palette range by one slot, wrapping first->last. Ports the
## ROM's palette-rotation idiom (SEGA streak: 0x9C6 `MOVE.W -(A1),2(A1)`
## / DBF over the palette buffer, then wrap).
func rotate_palette(index: int, lo: int, hi: int) -> void:
	var pal: Array = palettes[index]
	var first: Variant = pal[lo]
	for i in range(lo, hi):
		pal[i] = pal[i + 1]
	pal[hi] = first

## Push the current palettes to the GPU. Cheap — call after any change.
func apply_palette() -> void:
	_build_palette_texture()

# --- palette animation (menu lightning / title glow) -----------------
# palette_frames.json is a per-frame record of the game's own palette
# (48 bytes/frame). Cycling it through the shader reproduces the effect;
# the picture itself is the static index image.
var palette_frames: Array = []
var _pf_i := 0
var _pf_t := 0.0

func has_palette_animation() -> bool:
	return not palette_frames.is_empty()

func load_palette_animation() -> void:
	var path := _dir + "palette_frames.json"
	if FileAccess.file_exists(path):
		palette_frames = _load_json(path)

## Advance the palette animation. `fps` defaults to the Genesis 60Hz.
func tick_palette(delta: float, fps: float = 60.0) -> void:
	if palette_frames.is_empty():
		return
	_pf_t += delta
	var step := 1.0 / fps
	var changed := false
	while _pf_t >= step:
		_pf_t -= step
		_pf_i = (_pf_i + 1) % palette_frames.size()
		changed = true
	if changed:
		palettes = palette_frames[_pf_i]
		_build_palette_texture()

func _build_palette_texture() -> void:
	var img := Image.create(16, 4, false, Image.FORMAT_RGBA8)
	for p in range(4):
		var pal: Array = palettes[p]
		for i in range(16):
			var c: Array = pal[i]
			img.set_pixel(i, p, Color8(int(c[0]), int(c[1]), int(c[2]), 255))
	_palette_tex = ImageTexture.create_from_image(img)
	_mat.set_shader_parameter("palette_tex", _palette_tex)
	_sprite_mat.set_shader_parameter("palette_tex", _palette_tex)

## Build the texture for one OAM entry, optionally overriding its base
## tile — used to step a sprite through its animation cycle (wheels
## turning, characters) with the game's own tile graphics.
func make_sprite_texture(oam_index: int, base_tile_override: int = -1) -> ImageTexture:
	for sp in sprites:
		if int(sp["i"]) != oam_index:
			continue
		var sw: int = int(sp["w"])
		var sh: int = int(sp["h"])
		var pal_num: int = int(sp["pal"])
		var base_tile: int = base_tile_override if base_tile_override >= 0 else int(sp["tile"])
		var img := Image.create(sw * 8, sh * 8, false, Image.FORMAT_RGBA8)
		for col in range(sw):
			for r in range(sh):
				var key := str((base_tile + col * sh + r) & 0x7FF)
				if not sprite_tiles_index.has(key):
					continue
				var cell: int = int(sprite_tiles_index[key])
				var ax := (cell % _sprite_atlas_cols) * 8
				var ay := (cell / _sprite_atlas_cols) * 8
				for py in range(8):
					for px in range(8):
						var idx := _sprite_atlas[(ay + py) * _sprite_atlas_w + (ax + px)]
						img.set_pixel(col * 8 + px, r * 8 + py,
							Color8(idx, pal_num, 0, 255) if idx != 0 else Color8(0, 0, 0, 255))
		return ImageTexture.create_from_image(img)
	return null

## Build a Sprite2D for one OAM entry (for elements the port animates,
## e.g. the cursor arm, the Mystery Machine). Uses the real sprite tiles.
func make_sprite_node(oam_index: int) -> Sprite2D:
	for sp in sprites:
		if int(sp["i"]) != oam_index:
			continue
		var sw: int = int(sp["w"])
		var sh: int = int(sp["h"])
		var img := Image.create(sw * 8, sh * 8, false, Image.FORMAT_RGBA8)
		var base_tile: int = int(sp["tile"])
		var pal_num: int = int(sp["pal"])
		for col in range(sw):
			for r in range(sh):
				var key := str((base_tile + col * sh + r) & 0x7FF)
				if not sprite_tiles_index.has(key):
					continue
				var cell: int = int(sprite_tiles_index[key])
				var ax := (cell % _sprite_atlas_cols) * 8
				var ay := (cell / _sprite_atlas_cols) * 8
				for py in range(8):
					for px in range(8):
						var idx := _sprite_atlas[(ay + py) * _sprite_atlas_w + (ax + px)]
						img.set_pixel(col * 8 + px, r * 8 + py,
							Color8(idx, pal_num, 0, 255) if idx != 0 else Color8(0, 0, 0, 255))
		var node := Sprite2D.new()
		node.texture = ImageTexture.create_from_image(img)
		node.centered = false
		node.position = Vector2(int(sp["x"]), int(sp["y"]))
		node.material = _sprite_mat     # index 0 transparent
		node.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		return node
	return null

static func _load_json(path: String) -> Variant:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("VDPScreen: missing " + path)
		return {}
	var d: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	return d

extends RefCounted

## Exact port of the ROM's logo-dissolve bit-unpacker (routines 0xF272 DOO /
## 0xE40C SCOOBY-), verified against a from-scratch JS reimplementation this
## session (see the "pre-menu / main menu" mockup artifact) which itself
## found and fixed a real bug: the wave-table read-offset (gated by bit4 of
## $FF09EB, set once at 0x8234 and NEVER cleared anywhere in the ROM) must
## always be applied — a flat/clean logo render is wrong; the real ROM logo
## is permanently rippled.
##
## Data (assets/screens/menu/dissolve.json): mask_steps (256 x 16-byte rows,
## monotonic 128->min), wave (39 words), dst_doo/dst_sco (tile-offset tables),
## doo_tile_pos/sco_tile_pos (tile index -> atlas (x,y)).

var mask_steps: Array
var wave: Array
var dst_doo: Array
var dst_sco: Array
var doo_tile_pos: Dictionary
var sco_tile_pos: Dictionary

func _init(json_path: String) -> void:
	var d: Dictionary = _load_json(json_path)
	mask_steps = d.get("mask_steps", [])
	wave = d.get("wave", [])
	dst_doo = d.get("dst_doo", [])
	dst_sco = d.get("dst_sco", [])
	doo_tile_pos = d.get("doo_tile_pos", {})
	sco_tile_pos = d.get("sco_tile_pos", {})

func _mask_words(step: int) -> Array:
	var row: Array = mask_steps[clampi(step, 0, mask_steps.size() - 1)]
	var w := []
	for i in range(8):
		w.append((int(row[i * 2]) << 8) | int(row[i * 2 + 1]))
	return w

func _mask_bytes(step: int) -> Array:
	return mask_steps[clampi(step, 0, mask_steps.size() - 1)]

func _blit_long(buf: PackedByteArray, tmap: Dictionary, off: int, d7: int) -> void:
	var tile := off / 32
	var row := (off % 32) / 4
	if not tmap.has(str(tile)):
		return
	var pos: Array = tmap[str(tile)]
	var x0: int = int(pos[0])
	var y0: int = int(pos[1]) + row
	for i in range(8):
		var pix := (d7 >> ((7 - i) * 4)) & 0xF
		var x := x0 + i
		if x < 256 and y0 < 120:
			buf[y0 * 256 + x] = pix

## piece: "doo" or "sco". source: flat 1-byte-per-pixel raster (index only).
## Writes into (or creates) a 256x120 index buffer.
func render(piece: String, source: PackedByteArray, i626: int, i624: int,
		ff000c: int, bit4: bool, into_buf: PackedByteArray = PackedByteArray()) -> PackedByteArray:
	var doo := piece == "doo"
	var width := 64 if doo else 120
	var dst_t: Array = dst_doo if doo else dst_sco
	var tmap: Dictionary = doo_tile_pos if doo else sco_tile_pos
	var buf := into_buf
	if buf.is_empty():
		buf.resize(256 * 120)
		buf.fill(0)
	var tgtw := _mask_words(i624)
	var a1 := 0
	var a6 := ff000c / 2
	var a4 := 0
	var d7 := 0
	var groups := 2 if doo else 5
	var rows_per := 16 if doo else 8
	var curw := _mask_words(i626)
	var curb := _mask_bytes(i626)
	for g in range(groups):
		var d1: int = int(curw[g]) if doo else ((int(curb[g]) << 8) & 0xFFFF)
		for r in range(rows_per):
			var d3w: int = int(wave[a6 % 39])
			a6 += 1
			var carry: bool = (d1 & 0x8000) != 0
			d1 = (d1 << 1) & 0xFFFF
			if carry:
				var d4 := 7
				var d5 := width - 1
				var a5 := a1 + (( (d3w if doo else -d3w) ) if bit4 else 0)
				var reads := 0
				for w in range(8):
					if reads >= width:
						break
					var d3: int = int(tgtw[w])
					for j in range(16):
						if reads >= width:
							break
						reads += 1
						var d6 := 0
						if a5 >= 0 and a5 < source.size():
							d6 = source[a5]
						a5 += 1
						var tc: bool = (d3 & 0x8000) != 0
						d3 = (d3 << 1) & 0xFFFF
						if tc:
							d7 = ((d7 << 4) | (d6 & 0xF)) & 0xFFFFFFFF
							d5 -= 1
							d4 -= 1
							if d4 < 0:
								d4 = 7
								_blit_long(buf, tmap, int(dst_t[a4]) if a4 < dst_t.size() else 0, d7)
								a4 += 1
				d5 += 1
				if d5 != 0:
					var fpad := d5 & 7
					if fpad != 0:
						d7 = (d7 << (4 * fpad)) & 0xFFFFFFFF
						_blit_long(buf, tmap, int(dst_t[a4]) if a4 < dst_t.size() else 0, d7)
						a4 += 1
					var rem := (d5 >> 3) - 1
					var k := 0
					while k <= rem:
						_blit_long(buf, tmap, int(dst_t[a4]) if a4 < dst_t.size() else 0, 0)
						a4 += 1
						k += 1
			a1 += width
	return buf

static func _load_json(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("MenuDissolve: missing " + path)
		return {}
	var d: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	return d if d is Dictionary else {}

## Load a .idx file's index bytes ONLY (drop the interleaved palette byte —
## the dissolve source rasters are always palette line 0), as a flat
## 1-byte-per-pixel array matching this algorithm's `source[a5]` addressing.
static func load_idx_indices(path: String) -> PackedByteArray:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("MenuDissolve: missing " + path)
		return PackedByteArray()
	var raw := f.get_buffer(f.get_length())
	f.close()
	var w: int = raw[0] | (raw[1] << 8)
	var h: int = raw[2] | (raw[3] << 8)
	var out := PackedByteArray()
	out.resize(w * h)
	for i in range(w * h):
		out[i] = raw[6 + i * 2]
	return out

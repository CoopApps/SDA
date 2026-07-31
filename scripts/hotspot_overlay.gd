extends Node2D

## Debug overlay (S14) -- O key cycles modes:
##   0 off
##   1 hotspots        dashed amber rects + names (cited ROM cel rects)
##   2 + walkmask      blocked cells tinted red (the SAME is_blocked() the
##                     pathfinder uses -- validated 0-mismatch vs ROM 0x73D6)
##   3 + zones/exits   collision zone ids per tile (green) + exit objects
##                     highlighted cyan
## Style for hotspots matches the verb/inventory artifact exactly: dashed
## amber outline, no fill (rgba(255,180,84,0.85), 2px dash).

const HOTSPOT_COLOR := Color(255.0 / 255.0, 180.0 / 255.0, 84.0 / 255.0, 0.85)
const BLOCK_COLOR := Color(1.0, 0.15, 0.15, 0.30)
const ZONE_COLOR := Color(0.3, 1.0, 0.4, 0.9)
const EXIT_COLOR := Color(0.3, 0.9, 1.0, 0.95)
const DASH_LEN := 4.0
const TILE := 8

var room: Node2D
var mode := 0                 # 0 off / 1 hotspots / 2 +walkmask / 3 +zones/exits

func _draw() -> void:
	if mode == 0 or room == null:
		return
	var font := ThemeDB.fallback_font
	if mode >= 2:
		_draw_walkmask()
	if mode >= 3:
		_draw_zones(font)
	for h in room.hotspots:
		var name: String = str(h.get("name", ""))
		if name == "":
			continue
		var b: Variant = h.get("bounds")
		if b == null:
			continue
		var rect := Rect2(float(b["x"]), float(b["y"]),
						float(b["w"]), float(b["h"]))
		var is_exit: bool = mode >= 3 and room.exit_target(name) >= 0
		_draw_dashed_rect(rect, EXIT_COLOR if is_exit else HOTSPOT_COLOR)
		draw_string(font, rect.position + Vector2(1, -2), name,
					HORIZONTAL_ALIGNMENT_LEFT, -1, 8,
					EXIT_COLOR if is_exit else HOTSPOT_COLOR)

## Blocked cells at 4px resolution -- fine enough to show the sub-tile nibble
## shapes without a per-pixel redraw every frame.
func _draw_walkmask() -> void:
	var size: Vector2 = room.pixel_size()
	for y in range(0, int(size.y), 4):
		for x in range(0, int(size.x), 4):
			if room.is_blocked(float(x), float(y)):
				draw_rect(Rect2(x, y, 4, 4), BLOCK_COLOR)

## Per-tile collision zone ids (low 15 bits of the $FFE000 cell), skipping 0.
func _draw_zones(font: Font) -> void:
	if not ("collision" in room) or room.collision.is_empty():
		return
	for cy in range(room.height_tiles):
		for cx in range(room.width_tiles):
			var cell: int = room.collision[cy * room.width_tiles + cx]
			var zone := cell & 0x7FFF
			if zone == 0:
				continue
			draw_string(font, Vector2(cx * TILE, cy * TILE + 7), str(zone),
						HORIZONTAL_ALIGNMENT_LEFT, -1, 6, ZONE_COLOR)

func _draw_dashed_rect(rect: Rect2, col: Color = HOTSPOT_COLOR) -> void:
	var tl := rect.position
	var tr := rect.position + Vector2(rect.size.x, 0)
	var br := rect.position + rect.size
	var bl := rect.position + Vector2(0, rect.size.y)
	draw_dashed_line(tl, tr, col, 1.0, DASH_LEN)
	draw_dashed_line(tr, br, col, 1.0, DASH_LEN)
	draw_dashed_line(br, bl, col, 1.0, DASH_LEN)
	draw_dashed_line(bl, tl, col, 1.0, DASH_LEN)

func toggle() -> void:
	mode = (mode + 1) % 4
	queue_redraw()

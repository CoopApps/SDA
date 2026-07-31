extends CanvasLayer
class_name GameUI

## DOTT-style HUD. Verb grid on the LEFT, inventory on the RIGHT.
## Verb labels use the AUTHENTIC bold 8x16 font extracted from VRAM (14
## letters L O K T A E U S P H N G I V — enough for all 10 verbs).
## Layout diverges from the Genesis original (which used a 5x2 verb row);
## this arrangement mirrors LucasArts adventures — three columns of related
## verbs, inventory to the right.
##
## GIVE dropped from the grid: real chapter data (scene_manifest_hotel.json)
## has exactly ONE give-verb behavior in the whole hotel chapter (room 15
## "Beads", and even that has no dialogue), and the original catalog already
## flagged it low-confidence. main.gd's USE handling falls back to GIVE's
## verb_code when USE finds nothing, so that one interaction still works --
## it's just not worth a dedicated button. That leaves exactly 9 real verbs,
## a clean 3x3 grid with no invented filler words needed.
##
##   TAKE  USE   EAT                inv[0]  inv[1]  inv[2]  inv[3]
##   OPEN  LOOK  PUSH               inv[4]  inv[5]  inv[6]  inv[7]
##   SHUT  TALK  PULL

signal verb_selected(verb: Dictionary)
signal actor_selected(player_def: Dictionary)
signal item_selected(item_name: String)

const HudFontScript := preload("res://scripts/hud_font.gd")
const SCREEN_W := 320
const PANEL_TOP := 136                  # 136px play area (hardware-exact visible band, room_y=0)
const PANEL_H := 200 - PANEL_TOP        # 64 px: 8 sentence + 56 verb/inventory
const BLUE := Color(0.45, 0.5, 1.0)
const WHITE := Color(0.9, 0.9, 1.0)

# DOTT-style verb layout — 3 columns x 3 rows, all 9 real verbs (GIVE
# dropped, see class comment above). Order pairs related actions per column
# (take/use/eat, open/look/push, shut/talk/pull).
const VERB_GRID := [
	["TAKE", "USE",  "EAT"],
	["OPEN", "LOOK", "PUSH"],
	["SHUT", "TALK", "PULL"],
]

# Sentence line — its own strip at the panel top (never shares space with
# the verb/inventory rows below it, unlike the old bottom-overlapping draw).
const SENT_H := 8

# Verb cell geometry (px within the panel, below the sentence strip).
# Enlarged cells (48x16 pitch, slabs 46x14) starting near the left edge; the
# inventory is pushed near-flush right (ends x=318) with a 14px gutter kept
# between them for the up/down scroll arrows.
const VERB_X := 5                                   # slab x0 = VERB_X-3 = 2
const VERB_Y := SENT_H + 3
const VERB_CELL_W := 48
const VERB_CELL_H := 16
const VERBS_RIGHT_EDGE := VERB_X - 3 + 3 * VERB_CELL_W  # 146

# Inventory geometry — near-flush right: 160 + 4*40 = 320.
const INV_X := VERBS_RIGHT_EDGE + 14                # 160
const INV_Y := SENT_H + 3
const INV_COLS := 4
const INV_ROWS := 2
const INV_CELL_W := 40
const INV_CELL_H := 26
const INV_ICON_W := 28
const INV_ICON_H := 21
const INV_SCROLL_STEP := INV_COLS * INV_ROWS        # 8 items per page

var thin_font                 # thin ASCII font, for the sentence line + item labels without art
var bold_font                 # 8x16 verb-bar font
var arrow_tex: Texture2D      # 24x32 icon, used for inventory paging
var panel: Control
var sentence := ""
var _item_icon_cache: Dictionary = {}   # item name -> ImageTexture (or false if none)
var selected_verb: Dictionary = {}
var verb_by_label: Dictionary = {}
var held_items: Array[String] = []
var inv_offset := 0
var _hit: Array = []          # [{rect: Rect2, kind: "verb"|"item"|"scroll", data: ...}]

func _ready() -> void:
	thin_font = HudFontScript.thin()
	bold_font = HudFontScript.bold()
	arrow_tex = load("res://assets/hud/arrow.png")
	for v in Game.verb_list():
		verb_by_label[str(v.get("label", "")).split(" ")[0].to_upper()] = v
	panel = Control.new()
	panel.position = Vector2(0, PANEL_TOP)
	panel.size = Vector2(SCREEN_W, PANEL_H)
	panel.draw.connect(_draw_panel)
	panel.gui_input.connect(_on_gui_input)
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(panel)
	panel.queue_redraw()

func _draw_panel() -> void:
	_hit = []
	panel.draw_rect(Rect2(0, 0, SCREEN_W, PANEL_H), Color(0, 0, 0))

	if sentence != "":
		# Centred in the status/sentence strip.
		var sw: int = thin_font.text_width(sentence)
		thin_font.draw_text(panel, sentence, Vector2((SCREEN_W - sw) / 2.0, 0), WHITE)

	_draw_verbs()
	_draw_inventory()

## Panel styling (Sam&Max/DOTT-style, per reference): every verb and inventory
## slot sits on its own dark tinted square, and verb text carries a 1px drop
## shadow so the lettering reads as raised, not flat.
const CELL_BG := Color(0.035, 0.013, 0.018)    # slab: barely above black, very subtle
const TEXT_SHADOW := Color(0, 0, 0)            # deep bevel shadow, offset +2,+2

func _draw_verbs() -> void:
	# Verb grid, sized so the bottom of the LOWEST row is flush with the bottom
	# of the inventory slabs, with the lettering SCALED UP to fill the taller
	# cells. Cell pitch = (inventory bottom - VERB_Y) / rows; glyph scale fills
	# the cell (height-bound; width has slack in the 48px cells). Slabs first,
	# then all text, so a slab never covers a neighbour's drop shadow.
	var rows_n := VERB_GRID.size()
	var inv_bottom := float(INV_Y + INV_ROWS * INV_CELL_H)      # 63
	var cell_h := (inv_bottom - float(VERB_Y - 1)) / float(rows_n)
	# Glyph scale: fill the taller cell with the INK band (rows ~2..14 of the
	# 8x16 glyph = 12px): 1.25x -> 10x20 glyphs, ~15px ink in the ~15.7px slab.
	# 1.25 keeps integer target rects (8->10, 16->20) so nearest-neighbour
	# scaling stays crisp.
	var gscale := 1.25
	for r in range(rows_n):
		for c in range(VERB_GRID[r].size()):
			if VERB_GRID[r][c] == "":
				continue
			panel.draw_rect(Rect2(VERB_X - 3 + c * VERB_CELL_W,
				VERB_Y - 1 + r * cell_h,
				VERB_CELL_W - 2, cell_h - 2), CELL_BG)
	for r in range(rows_n):
		var row: Array = VERB_GRID[r]
		for c in range(row.size()):
			var lbl: String = row[c]
			if lbl == "":
				continue
			var v: Dictionary = verb_by_label.get(lbl, {})
			var col := WHITE if v == selected_verb and not v.is_empty() else BLUE
			var w: float = bold_font.bold_scaled_width(lbl, gscale)
			var cell_x := float(VERB_X - 3 + c * VERB_CELL_W)
			var x: float = cell_x + (VERB_CELL_W - 2 - w) / 2.0
			# centre the scaled glyph band vertically in the cell
			var gh := 16.0 * gscale
			var y := float(VERB_Y - 1 + r * cell_h) + (cell_h - gh) / 2.0
			bold_font.draw_text_scaled(panel, lbl, Vector2(x + 2, y + 2), TEXT_SHADOW, gscale)
			bold_font.draw_text_scaled(panel, lbl, Vector2(x + 1, y + 2), TEXT_SHADOW, gscale)
			bold_font.draw_text_scaled(panel, lbl, Vector2(x + 2, y + 1), TEXT_SHADOW, gscale)
			bold_font.draw_text_scaled(panel, lbl, Vector2(x, y), col, gscale)
			_hit.append({"rect": Rect2(x, y, w, gh), "kind": "verb", "data": v})

func _draw_inventory() -> void:
	# Every slot gets a dark tinted square (reference style), filled or empty;
	# icons and the armed-item highlight draw on top.
	for r in range(INV_ROWS):
		for c in range(INV_COLS):
			var rect := Rect2(
				INV_X + c * INV_CELL_W,
				INV_Y + r * INV_CELL_H,
				INV_CELL_W - 1, INV_CELL_H - 1)
			panel.draw_rect(rect, CELL_BG)
			var idx := inv_offset + r * INV_COLS + c
			if idx < held_items.size():
				var name: String = held_items[idx]
				var icon := _icon_for(name)
				if icon != null:
					# Real icon_items.json art is 32x24; drawn at 28x21 (near-
					# native, a light downscale, not cropped) -- matches the
					# artifact's own INV_ICON_W/H exactly.
					panel.draw_texture_rect(icon, Rect2(
						rect.position.x + (rect.size.x - INV_ICON_W) / 2,
						rect.position.y + (rect.size.y - INV_ICON_H) / 2,
						INV_ICON_W, INV_ICON_H), false)
				else:
					# No icon_items.json art for this item — fall back to a
					# short text label so it's still legible, not blank.
					var text_w: int = thin_font.text_width(name.substr(0, 5))
					thin_font.draw_text(panel, name.substr(0, 5),
						Vector2(rect.position.x + (rect.size.x - text_w) / 2,
							rect.position.y + (rect.size.y - 8) / 2),
						WHITE)
				_hit.append({"rect": rect, "kind": "item", "data": name})
	_draw_inv_scroll()

## Up/down inventory scroll arrows, in the gutter BETWEEN the verb grid and the
## inventory (the original places them at the strip's right edge; the redesign
## moves them here, resized to the gutter). Visible ONLY when the inventory
## holds more items than the 8 visible slots. Each press scrolls one grid row.
## ART: the game's own arrow -- VRAM tiles 0x3E9-0x3EC from the gameplay
## capture; the down arrow is the vertical flip of the up (the original renders
## it once and flips). See assets/hud/arrow_updown.provenance.json.
var _arrow_up_tex: Texture2D
var _arrow_dn_tex: Texture2D

func _draw_inv_scroll() -> void:
	if held_items.size() <= INV_SCROLL_STEP:
		return
	if _arrow_up_tex == null:
		# Game.load_texture reads the PNG directly (no editor import needed).
		_arrow_up_tex = Game.load_texture("res://assets/hud/arrow_up.png")
		_arrow_dn_tex = Game.load_texture("res://assets/hud/arrow_down.png")
	var gw := 12.0                                 # arrow width in the 14px gutter
	var gx := float(VERBS_RIGHT_EDGE) + (float(INV_X - VERBS_RIGHT_EDGE) - gw) / 2.0
	var top := float(INV_Y)
	var band := float(INV_ROWS * INV_CELL_H - 2)
	var ah := gw * 1.5                             # art is 16x24 (2x3 tiles): keep aspect
	var can_prev := inv_offset > 0
	var can_next := inv_offset + INV_SCROLL_STEP < held_items.size()
	var up_rect := Rect2(gx, top + 1.0, gw, ah)
	if can_prev and _arrow_up_tex != null:
		_draw_arrow(_arrow_up_tex, up_rect)
		_hit.append({"rect": up_rect, "kind": "scroll", "data": -INV_COLS})
	var dn_rect := Rect2(gx, top + band - ah - 1.0, gw, ah)
	if can_next and _arrow_dn_tex != null:
		_draw_arrow(_arrow_dn_tex, dn_rect)
		_hit.append({"rect": dn_rect, "kind": "scroll", "data": +INV_COLS})

## Same treatment as the verbs: a subtle slab behind the arrow, and a deep
## black bevel (the arrow art re-drawn in black at the diagonal offsets) so it
## stands off the slab like the lettering does.
func _draw_arrow(tex: Texture2D, rect: Rect2) -> void:
	panel.draw_rect(rect.grow(1.0), CELL_BG)
	for off in [Vector2(2, 2), Vector2(1, 2), Vector2(2, 1)]:
		panel.draw_texture_rect(tex, Rect2(rect.position + off, rect.size),
			false, TEXT_SHADOW)
	panel.draw_texture_rect(tex, rect, false)

## Item name -> icon_items.json's own icon art, cached per name for the
## session (icons don't change once the chapter's icon_items.json is loaded).
func _icon_for(item_name: String) -> Texture2D:
	if _item_icon_cache.has(item_name):
		var cached: Variant = _item_icon_cache[item_name]
		return cached if cached != false else null
	var path := Game.icon_png_for_item(item_name)
	var tex: Texture2D = Game.load_texture(path) if path != "" else null
	_item_icon_cache[item_name] = tex if tex != null else false
	return tex

func _on_gui_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton and event.pressed
			and event.button_index == MOUSE_BUTTON_LEFT):
		return
	for h in _hit:
		if not h["rect"].has_point(event.position):
			continue
		match h["kind"]:
			"verb":
				var v: Dictionary = h["data"]
				if not v.is_empty():
					selected_verb = v
					sentence = str(v.get("label", "")).split(" ")[0].to_upper() + " ..."
					verb_selected.emit(v)
					panel.queue_redraw()
			"item":
				# Selecting an item arms it as context for the current verb
				# (e.g. "USE ... " -> "USE KEY ..."); main.gd listens on
				# item_selected to remember which item, for the next hotspot
				# click to complete "verb item on hotspot".
				sentence = str(sentence).replace("...", str(h["data"]) + " ...") \
					if sentence.ends_with("...") else (str(h["data"]) + " ...")
				item_selected.emit(str(h["data"]))
				panel.queue_redraw()
			"scroll":
				# data = signed item delta (one grid ROW per press, like the
				# original's up/down arrows). Clamp so the last page stays full.
				var max_off: int = max(0, held_items.size() - INV_SCROLL_STEP)
				inv_offset = clampi(inv_offset + int(h["data"]), 0, max_off)
				panel.queue_redraw()
		return

func show_message(text: String) -> void:
	sentence = text
	if panel:
		panel.queue_redraw()

func show_default_response(verb: Dictionary, noun := "that") -> void:
	show_message(str(verb.get("default_response", "")).replace(char(1), noun))

func add_item(name: String) -> void:
	held_items.append(name.to_upper())
	if panel:
		panel.queue_redraw()

## Remove an item from inventory (consumed by a USE-combination). Returns true
## if it was held. Keeps the scroll offset valid.
func remove_item(name: String) -> bool:
	var i := held_items.find(name.to_upper())
	if i < 0:
		return false
	held_items.remove_at(i)
	inv_offset = clampi(inv_offset, 0, max(0, held_items.size() - INV_SCROLL_STEP))
	if panel:
		panel.queue_redraw()
	return true

## Re-resolve icons and redraw (op 10 changed an entity's icon id at runtime).
func refresh_inventory() -> void:
	_item_icon_cache.clear()
	if panel:
		panel.queue_redraw()

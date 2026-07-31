extends Node
## Global game-data singleton (autoload "Game").
##
## Reads scoobygodot's own imported room backgrounds/foregrounds
## (res://assets/data/<cluster>/room_NN/) plus scene_manifest_<cluster>.json
## (res://assets/data/global/ — already carries per-room objects, hotspot
## bounds, behaviors and exits in one place, so no separate room_map.json/
## hotspots.json/exits.json is needed here). Collision grids and a couple of
## global lookup tables (collision_tables.json, icon_items.json) aren't
## copied into the project yet, so those are read directly from the raw
## carve kit on disk (D:/scoobydoo/...) by absolute path — same convention
## the predecessor project's game.gd used for its own kit-relative assets.

const KIT_ROOT := "D:/scoobydoo"

var manifest: Dictionary = {}          # scene_manifest_<cluster>.json
var waypoints: Dictionary = {}         # waypoints_<cluster>.json (per-room $FF0696 entry table)
var collision_tables: Dictionary = {}  # zone_entries + shapes (ROM 0x2AF8E/0x2B0BA)
var icon_items: Dictionary = {}        # icon <-> item binding
var verb_dispatch: Dictionary = {}     # analysis/verb_dispatch.json — per-object verb responses + catalog
var sprite_sheets: Dictionary = {}     # {"sources": [{base, dir}, ...]} — one dir per registered sprite bank

var rooms: Array = []                  # Array[Dictionary] {room_id,width,height,background,collision,foreground?}
var room_by_id: Dictionary = {}

## Gamepad master switch. The redesigned menu (or a toggle button -- undecided)
## will flip this; the input layer itself is always wired and only acts when
## this is true AND a pad is connected. Default on: harmless without a pad.
var gamepad_enabled := true

var cluster: String = "hotel"
var pending_cluster: String = "hotel"
var pending_start_room: int = 16
var current_room: int = 16
var current_verb_code: int = 10        # default LOOK
var flags: Dictionary = {}
var inventory: Array = []
var companion: int = 0
var score: int = 0

const ROOM_TILE := 8

func _ready() -> void:
	collision_tables = load_json(kit_path("global/collision_tables.json"))
	icon_items = load_json(kit_path("analysis/icon_items.json"))
	verb_dispatch = load_json(kit_path("analysis/verb_dispatch.json"))
	sprite_sheets = _scan_sprite_sheets()
	_load_manifest()
	_build_rooms()


## room_behavior_runner.gd's registered-bank ids only need base+dir (not the
## per-animation frame data itself — Actor.load_bank() reads each source's own
## anims.json directly). Scanning D:/scoobydoo/sprites/ rather than depending
## on the predecessor's bundle keeps this pointed at the FULL re-lifted kit
## (relift_all_sprites.py output), not the older 32-sample bundle copy.
func _scan_sprite_sheets() -> Dictionary:
	var sources: Array = []
	var da := DirAccess.open(kit_path("sprites"))
	if da == null:
		return {"sources": sources}
	da.list_dir_begin()
	var entry := da.get_next()
	while entry != "":
		if da.current_is_dir() and entry.begins_with("source_"):
			var anims_path := kit_path("sprites/%s/anims.json" % entry)
			var d: Dictionary = load_json(anims_path)
			var base: Variant = d.get("source_base")
			if base != null:
				sources.append({"base": String(base), "dir": "sprites/" + entry})
		entry = da.get_next()
	da.list_dir_end()
	return {"sources": sources}


## verb_code -> name (LOOK=10, TAKE=2, ...), from verb_dispatch's catalog.
func verb_name(code: int) -> String:
	var cat: Dictionary = verb_dispatch.get("catalog", {})
	var e: Dictionary = cat.get(str(code), {})
	return e.get("verb", "verb%d" % code) if e else "verb%d" % code


## Verb button list for the HUD (ui.gd): [{code, label}].
func verb_list() -> Array:
	var cat: Dictionary = verb_dispatch.get("catalog", {})
	var out: Array = []
	var codes: Array = cat.keys()
	codes.sort_custom(func(a, b): return int(a) < int(b))
	for k in codes:
		out.append({"code": int(k), "label": verb_name(int(k))})
	return out


var puzzle_behaviors: Dictionary = {}    # entity_id(str) -> [behavior] (global USE-combos)
## Behaviours nested inside a state conditional -- the REAL open/shut handlers.
## The manifest bake only walks top-level guards, so without these an object
## kept only its fallback line ("It's already open.") and its gate never ran.
## Their actions arrive pre-wrapped in the enclosing condition.
var nested_behaviors: Dictionary = {}

func _load_manifest() -> void:
	manifest = load_json("res://assets/data/global/scene_manifest_%s.json" % cluster)
	waypoints = load_json("res://assets/data/global/waypoints_%s.json" % cluster)
	puzzle_behaviors = load_json(
		"res://assets/data/global/puzzle_behaviors_%s.json" % cluster).get("behaviors", {})
	nested_behaviors = load_json(
		"res://assets/data/global/nested_behaviors_%s.json" % cluster).get("behaviors", {})
	_seed_initial_flags()


## The script flags do NOT start at zero: cluster_init_entities (ROM 0x7F66)
## copies a per-chapter block over $FF2A00. Hotel byte 15 = 0x01, and fb15.0 is
## the front/double-door gate -- without seeding, every such door read as
## already open ("It's already open") and its exit was passable immediately.
## Only seeds flags not already set, so a loaded save wins.
func _seed_initial_flags() -> void:
	var doc: Dictionary = load_json("res://assets/data/global/initial_flags_%s.json" % cluster)
	for k in doc.get("flags", {}):
		if not flags.has(k):
			flags[k] = int(doc["flags"][k])


## Global (room-independent) puzzle behaviors for an entity -- the USE-combination
## and gated-grant logic the manifest bake skipped (the 'unlinked' script bucket).
## See tools/gen_puzzle_behaviors.py. Returns [] if none.
func puzzle_behaviors_for(ent_id: int) -> Array:
	var b: Variant = puzzle_behaviors.get(str(ent_id), [])
	return b if b is Array else []


func nested_behaviors_for(ent_id: int) -> Array:
	var b: Variant = nested_behaviors.get(str(ent_id), [])
	return b if b is Array else []


## The op-$0E move_actor_to_waypoint target for `idx` in `room_id`, in pixels.
## The ROM resolves waypoint (slot) -> $FF0696[slot] (tile x,y) <<3 (ROM_MAP
## rows 208/307/391); waypoints_<cluster>.json is that table, extracted by
## executing scene_load_activate. Returns a sentinel (-1,-1) if unavailable so
## the caller can fall back rather than teleport an actor to (0,0).
func waypoint_px(room_id: int, idx: int) -> Vector2:
	var r: Dictionary = waypoints.get("rooms", {}).get(str(room_id), {})
	var px: Array = r.get("entries_px", [])
	if idx < 0 or idx >= px.size():
		return Vector2(-1, -1)
	var e: Array = px[idx]
	return Vector2(int(e[0]), int(e[1]))


func set_cluster(name: String) -> void:
	cluster = name
	_load_manifest()
	_build_rooms()


## Builds `rooms`/`room_by_id` from scene_manifest_<cluster>.json's own room
## list plus scoobygodot's own imported per-room background/foreground art.
## width/height come from the background PNG's own pixel size (/8), same
## convention as the predecessor project, so it can never drift from the art.
func _build_rooms() -> void:
	rooms = []
	room_by_id = {}
	var scenes: Dictionary = manifest.get("scenes", {})
	var ids: Array = scenes.keys()
	ids.sort_custom(func(a, b): return int(a) < int(b))
	for rid_str in ids:
		var rid := int(rid_str)
		var dir := "res://assets/data/%s/room_%02d" % [cluster, rid]
		var bg_path := dir + "/background.png"
		if not FileAccess.file_exists(bg_path):
			continue
		var img := Image.load_from_file(ProjectSettings.globalize_path(bg_path))
		if img == null:
			continue
		var fg_path := dir + "/foreground.png"
		var desc := {
			"room_id": rid,
			"width": img.get_width() / ROOM_TILE,
			"height": img.get_height() / ROOM_TILE,
			"background": bg_path,
			"collision": kit_path("%s/scenes/room_%02d/ffe000.bin" % [cluster, rid]),
		}
		if FileAccess.file_exists(fg_path):
			desc["foreground"] = fg_path
		rooms.append(desc)
		room_by_id[rid] = desc


## The full scene_manifest record for a room (objects + their behaviors +
## exits), or {} if this room has no manifest entry.
func scene_for(room_id: int) -> Dictionary:
	return manifest.get("scenes", {}).get(str(room_id), {})


func room_display_name(room_id: int) -> String:
	var name: Variant = scene_for(room_id).get("name")
	return String(name) if name != null else "Room %d" % room_id


## Runtime icon overrides (script op 10 set_actor_icon_id_and_refresh_inventory:
## writes actor record +4; the inventory rebuild at 0x5D90 then draws icon
## (value-1) from the chapter icon table). Keyed by entity_id.
var icon_override: Dictionary = {}     # entity_id -> icon_id

func set_entity_icon(ent_id: int, icon_id: int) -> void:
	icon_override[ent_id] = icon_id


## icon_items.json's item name -> icon_id.
func item_icon_id(item_name: String) -> int:
	for it in icon_items.get("chapters", {}).get(cluster, []):
		if str(it.get("item", "")).to_upper() == item_name.to_upper():
			return int(it.get("icon_id", -1))
	return -1


## Item name -> its ENTITY id. A USE behaviour's sel2 is the ENTITY id of the
## other participant (verified: room 12 Shovel sel2=71 = the Snowman, room 13
## Key sel2=70 = the Lock, room 14 Poison Oak sel2=177 = the Bear), NOT an icon
## id -- so item matching must go through this.
func entity_for_item(item_name: String) -> int:
	for it in icon_items.get("chapters", {}).get(cluster, []):
		if str(it.get("item", "")).to_upper() == item_name.to_upper():
			return int(it.get("entity_id", -1))
	return -1


## icon_items.json's entity_id -> {item, icon_id}.
func item_for_entity(ent_id: int) -> Dictionary:
	for it in icon_items.get("chapters", {}).get(cluster, []):
		if int(it.get("entity_id", -1)) == ent_id:
			return it
	return {}


## Item name -> its icon_items.json icon art, as an absolute kit path
## (ui.gd loads it directly via Game.load_texture — no res:// import step).
func icon_png_for_item(item_name: String) -> String:
	var entries: Array = icon_items.get("chapters", {}).get(cluster, [])
	for it in entries:
		if str(it.get("item", "")).to_upper() == item_name.to_upper():
			# op-10 runtime override: this entity's icon id was reassigned
			# (e.g. a container emptying) -- serve the overridden icon's art.
			var ov: Variant = icon_override.get(int(it.get("entity_id", -1)))
			if ov != null:
				for it2 in entries:
					if int(it2.get("icon_id", -1)) == int(ov):
						return kit_path(str(it2.get("icon_png", "")))
			return kit_path(str(it.get("icon_png", "")))
	return ""


## --- Resident NPC actors -----------------------------------------------------
## shape (entity record +2) -> registered sprite-bank ROM base. Mirrors
## room_behavior_runner.gd's REGISTERED_BANK_BY_ID (the table walked at ROM
## 0x32670); kept here so room entry can resolve an NPC's sprite without the
## runner. Shape values outside this set are non-sprite entities (hotspots /
## inventory / dialogue-only descriptors), never spawned.
const NPC_BANK_BY_SHAPE := {
	1: "0x032700", 2: "0x0642D0", 3: "0x07E91C", 4: "0x082D78", 5: "0x085306",
	6: "0x087368", 7: "0x08B540", 8: "0x09ACF8", 9: "0x09E682", 10: "0x09F7D4",
	11: "0x0A701C", 12: "0x0A94A2", 13: "0x0AAACE", 14: "0x0B1BE2", 15: "0x0B302E",
	16: "0x0B5D02", 17: "0x0C76D2", 18: "0x0C9BDE", 19: "0x0CDD00", 20: "0x0D1084",
	21: "0x0D138E", 22: "0x0D17E8", 23: "0x0D31AA", 24: "0x0D4076", 26: "0x0D4520",
	27: "0x0D826A", 28: "0x0D87E6", 29: "0x0DC6BC", 30: "0x0DDB5E", 31: "0x0E12F8",
	32: "0x0E19C8", 33: "0x0E3BFA", 34: "0x0EEBD6", 35: "0x0F04F0", 36: "0x0F88DC",
	37: "0x0FA77A",
}

var _entities_cache: Dictionary = {}   # cluster -> Array of raw entity records

func _entity_records() -> Array:
	if _entities_cache.has(cluster):
		return _entities_cache[cluster]
	var path := kit_path("%s/entities/entities.json" % cluster)
	var arr: Array = []
	if FileAccess.file_exists(path):
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
		if parsed is Array:
			arr = parsed
	_entities_cache[cluster] = arr
	return arr


func sprite_dir_for_shape(shape: int) -> String:
	if not NPC_BANK_BY_SHAPE.has(shape):
		return ""
	var base: String = NPC_BANK_BY_SHAPE[shape]
	for s in sprite_sheets.get("sources", []):
		if int(str(s.get("base", "0")).hex_to_int()) == int(base.hex_to_int()):
			return kit_path(str(s.get("dir", "")))
	return ""


var _npc_actors: Dictionary = {}       # cluster -> npc_actors_<cluster>.json

## Resident NPC/actor sprites to spawn on entering `room_id`: the manifest
## objects that HAVE verb behaviors (dialogue) but NO clickable bounds -- their
## dialogue is otherwise unreachable -- whose entity record carries a registered
## sprite shape, a placed position, AND a record scene matching the manifest
## room (so the record's X/Y is trustworthy here). Precomputed offline by
## work/gen_npc_actors.py, which also picks a validated idle frame and reads its
## REAL per-frame hotspot (hx,hy) from ROM -- the SEGA rule places the sprite at
## top-left = (x-hx, y-hy), not the Actor's (-w/2,-h) approximation. Returns
## [{entity_id, x, y, name, dir, frame, hx, hy}].
func talkable_npcs(room_id: int) -> Array:
	if not _npc_actors.has(cluster):
		_npc_actors[cluster] = load_json(
			"res://assets/data/global/npc_actors_%s.json" % cluster)
	var doc: Dictionary = _npc_actors[cluster]
	var lst: Variant = doc.get("rooms", {}).get(str(room_id), [])
	return lst if lst is Array else []


func kit_path(rel: String) -> String:
	if rel == "":
		return ""
	return KIT_ROOT + "/" + rel


static func load_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		push_warning("Game: missing " + path)
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	return parsed if typeof(parsed) == TYPE_DICTIONARY else {}


static func load_texture(path: String) -> ImageTexture:
	if path == "" or not FileAccess.file_exists(path):
		return null
	var img := Image.load_from_file(ProjectSettings.globalize_path(path) if path.begins_with("res://") else path)
	if img == null:
		return null
	return ImageTexture.create_from_image(img)

extends Node2D
class_name Room

## A game room: background from the extracted scene render plus the
## per-tile collision grid decoded from the room's ffe000 word grid.

const TILE := 8

var room_id: int = 0
var width_tiles: int = 0
var height_tiles: int = 0
var collision: PackedInt32Array = PackedInt32Array()

var background: Sprite2D
var foreground: Sprite2D
var reachable: PackedByteArray = PackedByteArray()
var hotspots: Array = []      # from rooms/<cluster>_room_NN.json (cited)
var overlays: Array = []
var _astar: AStarGrid2D = null   # built lazily from `reachable` for walk pathfinding

func _init() -> void:
	background = Sprite2D.new()
	background.centered = false
	background.z_index = -10
	add_child(background)
	# Priority tiles (Genesis nametable bit15) draw in front of sprites.
	foreground = Sprite2D.new()
	foreground.centered = false
	foreground.z_index = 4000
	add_child(foreground)

func load_room(desc: Dictionary) -> bool:
	room_id = int(desc["room_id"])
	width_tiles = int(desc["width"])
	height_tiles = int(desc["height"])
	# Drop the PREVIOUS room's flood fill. is_blocked() indexes `reachable` by
	# the CURRENT width, so a stale array from a differently-sized room answers
	# from a garbage cell -- which made the arrival entry point look blocked and
	# dumped the player in whatever pocket _find_spawn happened to pick.
	reachable = PackedByteArray()

	var tex := Game.load_texture(str(desc["background"]))
	if tex == null:
		return false
	background.texture = tex

	# Occlusion overlay may be absent for rooms with no priority tiles
	foreground.texture = null
	if desc.has("foreground"):
		foreground.texture = Game.load_texture(str(desc["foreground"]))

	_load_collision(str(desc["collision"]))
	_load_interactions()
	_load_items()        # after hotspots: appends the item cels' own hit rects
	_load_cel_defs()     # runtime cel states (open door/cupboard) for op 0x0B
	_load_cycle_anims()
	return true

var _cycle_nodes: Array = []

## Spawn the room's op-$1A palette-cycle animations (Television, Engine, ...) as
## CycleAnim overlays, from assets/data/<cluster>/room_NN/cycle.json produced by
## tools/gen_cycle_frames.py. Absent config -> nothing (rooms without cyclers).
func _load_cycle_anims() -> void:
	for n in _cycle_nodes:
		if is_instance_valid(n):
			n.queue_free()
	_cycle_nodes = []
	var base := "res://assets/data/%s/room_%02d/" % [Game.cluster, room_id]
	var path := base + "cycle.json"
	if not FileAccess.file_exists(path):
		return
	var cfg: Variant = Game.load_json(path)
	var list: Array = cfg if cfg is Array else [cfg]
	for a in list:
		if not (a is Dictionary):
			continue
		var count := int(a.get("frames", 0))
		var frames: Array = []
		for k in range(count):
			var t := Game.load_texture(base + "cycle_%02d.png" % k)
			if t != null:
				frames.append(t)
		if frames.size() < 2:
			continue
		var pos: Array = a.get("pos", [0, 0])
		var node := CycleAnim.new()
		# z defaults to 3 (background-plane cyclers like TV/Engine); the room-16
		# fireplace flame is a SPRITE that draws ABOVE the front plane (z 4000) --
		# its lower half is otherwise clipped by the mantel's priority tiles
		# (verified in the room16 mockup the user confirmed).
		node.setup(frames, int(a.get("period_ticks", 1)),
			Vector2(float(pos[0]), float(pos[1])), int(a.get("z", 3)), a.get("cram_run", []))
		add_child(node)
		_cycle_nodes.append(node)

## Runtime op-$1A trigger (script set_palette_cycle_channel): enable/disable the
## overlay whose CRAM run matches [lo,hi], or set its rate. No matching overlay
## (frames not extracted for this room) -> no-op, so scripts never error.
func set_cycle_channel(lo: int, hi: int, period: int) -> void:
	for n in _cycle_nodes:
		if not is_instance_valid(n):
			continue
		var run: Array = n.cram_run
		if run.size() == 2 and int(run[0]) == lo and int(run[1]) == hi:
			n.apply_period(period)

var exits_by_object: Dictionary = {}   # object name -> target room (cited: D4)

## Takeable room items, drawn from their CEL art (tools/gen_room_items.py).
## Items are cel objects, NOT sprites (verified: every items_here entity has
## actor +0x18 bit1 clear = cel mode, and record pos (0,0) -- the position IS
## the cel rect). The ROM stamps these cels into the room nametable at runtime,
## which is why they are absent from the exported background planes: without
## this the items were invisible AND unclickable.
var _item_nodes: Array = []

func _load_items() -> void:
	for n in _item_nodes:
		if is_instance_valid(n):
			n.queue_free()
	_item_nodes = []
	var base := "res://assets/data/%s/room_%02d/items/" % [Game.cluster, room_id]
	var doc: Dictionary = Game.load_json(base + "items.json")
	for it in doc.get("items", []):
		var eid := int(it.get("entity_id", -1))
		if int(Game.flags.get("taken_%d" % eid, 0)) != 0:
			continue                       # already in the inventory
		var tex := Game.load_texture(base + str(it.get("png", "")))
		if tex == null:
			continue
		var s := Sprite2D.new()
		s.texture = tex
		s.centered = false
		s.position = Vector2(float(it["x"]), float(it["y"]))
		# cel words carry the priority bit -> draw over the background, and
		# above actors' feet band, but below the room's front plane (z 4000).
		s.z_index = int(it["y"]) + int(it["h"])
		add_child(s)
		_item_nodes.append(s)
		# clickable: the cel rect IS the ROM's own hit rect for a cel object
		# (hit-test 0x1018 reads the same descriptor).
		hotspots.append({"name": it.get("name", ""), "entity_id": eid,
			"bounds": {"x": it["x"], "y": it["y"], "w": it["w"], "h": it["h"]}})

## Runtime CEL state per object (open door, open cupboard, ...). Script op 0x0B
## writes actor field +0 = the object's picture (CLAUDE.md render facts), so
## `set_entity_cel(ent, cel)` IS the ROM's own "change this object's graphic".
## Pre-rendered by tools/gen_room_cels.py. cel 0 clears back to the base art.
var _cel_defs: Dictionary = {}      # entity(str) -> [{cel,x,y,w,h,png}]
var _cel_nodes: Dictionary = {}     # entity(int) -> Sprite2D

func _load_cel_defs() -> void:
	for n in _cel_nodes.values():
		if is_instance_valid(n):
			n.queue_free()
	_cel_nodes = {}
	_cel_defs = Game.load_json("res://assets/data/%s/room_%02d/cels/cels.json"
		% [Game.cluster, room_id]).get("by_entity", {})
	# Re-apply cel state persisted by op 0x0B. A door's OPEN handler swaps BOTH
	# sides (the lobby's sets actor 47 -> 164 and actor 61 -> 83), but only the
	# side in the current room has a node; without this the other side snapped
	# back to its shut base art on arrival.
	for k in _cel_defs.keys():
		var ent := int(k)
		var cel := int(Game.flags.get("cel_%d" % ent, 0))
		if cel > 0:
			set_entity_cel(ent, cel)

func set_entity_cel(ent_id: int, cel_id: int) -> void:
	var node: Sprite2D = _cel_nodes.get(ent_id)
	if cel_id <= 0:
		if is_instance_valid(node):
			node.visible = false          # back to the room's base art
		return
	for d in _cel_defs.get(str(ent_id), []):
		if int(d.get("cel", -1)) != cel_id:
			continue
		var tex := Game.load_texture("res://assets/data/%s/room_%02d/cels/%s"
			% [Game.cluster, room_id, str(d.get("png", ""))])
		if tex == null:
			return
		if not is_instance_valid(node):
			node = Sprite2D.new()
			node.centered = false
			add_child(node)
			_cel_nodes[ent_id] = node
		node.texture = tex
		node.position = Vector2(float(d["x"]), float(d["y"]))
		node.z_index = int(d["y"]) + int(d["h"])
		node.visible = true
		return

## Remove a taken item's cel + its hit rect (called after a successful TAKE).
func remove_item_entity(ent_id: int) -> void:
	for i in range(hotspots.size() - 1, -1, -1):
		if int(hotspots[i].get("entity_id", -1)) == ent_id and hotspots[i].has("bounds"):
			hotspots.remove_at(i)
	_load_items()        # rebuild the cels, now skipping the taken one

func _load_interactions() -> void:
	hotspots = []
	overlays = []
	exits_by_object = {}
	var path := "D:/scoobydoo/rooms/%s_room_%02d.json" % [Game.cluster, room_id]
	if FileAccess.file_exists(path):
		var doc: Variant = Game.load_json(path)
		if doc is Dictionary:
			hotspots = doc.get("hotspots", [])
			overlays = doc.get("overlays", [])
	# Exits lifted from the context scripts (scooby_scripts.py / D4). The
	# hotel_exits.json lift and the scene-manifest per-object transitions are
	# COMPLEMENTARY (each carries exits the other misses -- e.g. room 2's Mine
	# Car is manifest-only, rooms 4/6's Passage are exits-json-only), so MERGE
	# both. Without the merge only 10/21 hotel rooms were reachable; together
	# with the manifest transitions it is 15/21 (the rest are travel-map /
	# cutscene rooms). Verified by work/playthrough_hotel.py.
	var epath := "D:/scoobydoo/rooms/%s_exits.json" % Game.cluster
	if FileAccess.file_exists(epath):
		var edoc: Variant = Game.load_json(epath)
		if edoc is Dictionary:
			for obj in edoc.get(str(room_id), []):
				var exits: Array = obj.get("exits", [])
				if not exits.is_empty():
					exits_by_object[str(obj.get("object", ""))] = int(exits[0]["target_room"])
	# Merge manifest per-object transitions (source of truth for object->room).
	for o in Game.scene_for(room_id).get("objects", []):
		var trans: Array = o.get("transitions", [])
		var nm := str(o.get("name", ""))
		if not trans.is_empty() and nm != "" and not exits_by_object.has(nm):
			var to: Variant = trans[0].get("to")
			if to != null:
				exits_by_object[nm] = int(to)

func exit_target(object_name: String) -> int:
	return int(exits_by_object.get(object_name, -1))

func hotspot_at(px: float, py: float):
	## Return the named hotspot whose layout bounds contain (px,py), or null.
	## Bounds are already in PIXELS (rooms/*.json self-documents "units":
	## "pixels"/"layout-raw", and matches global/hotspots.json's independently
	## rebuilt values 1:1, e.g. hotel room 16 "Archway" x=288 y=144 w=80 h=8 in
	## both). An earlier ×TILE(8) multiply here inflated every hotspot 8x per
	## axis (that 80x8 archway became 640x64) -- removed.
	for h in hotspots:
		if str(h.get("name", "")) == "":
			continue
		var b: Variant = h.get("bounds")
		if b == null:
			continue
		var bx: float = float(b["x"])
		var by: float = float(b["y"])
		var bw: float = float(b["w"])
		var bh: float = float(b["h"])
		if px >= bx and px < bx + bw and py >= by and py < by + bh:
			return h
	return null

## The static hotspot rect for an entity in this room (ROM cel rect, see
## work/fix_hotspot_bounds.py), or null. Used by op-15 anchors to resolve a
## reference entity that has no live node (items, scenery).
func hotspot_rect_for_entity(ent_id: int) -> Variant:
	for h in hotspots:
		if int(h.get("entity_id", -1)) != ent_id:
			continue
		var b: Variant = h.get("bounds")
		if b != null:
			return Rect2(float(b["x"]), float(b["y"]), float(b["w"]), float(b["h"]))
	return null

func compute_reachable(from: Vector2) -> void:
	## 4-connected flood fill over non-wall cells from a known-good point;
	## everything outside the region (e.g. void behind walls) becomes blocked.
	reachable = PackedByteArray()
	reachable.resize(width_tiles * height_tiles)
	var sx := int(from.x) / TILE
	var sy := int(from.y) / TILE
	if sx < 0 or sx >= width_tiles or sy < 0 or sy >= height_tiles:
		return
	var stack: Array[int] = [sy * width_tiles + sx]
	while not stack.is_empty():
		var i: int = stack.pop_back()
		if reachable[i] == 1 or _tile_impassable(i):
			continue
		reachable[i] = 1
		var cx := i % width_tiles
		var cy := i / width_tiles
		if cx > 0: stack.append(i - 1)
		if cx < width_tiles - 1: stack.append(i + 1)
		if cy > 0: stack.append(i - width_tiles)
		if cy < height_tiles - 1: stack.append(i + width_tiles)

func _load_collision(path: String) -> void:
	collision = PackedInt32Array()
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_warning("No collision grid: " + path)
		return
	var data := f.get_buffer(f.get_length())
	f.close()
	var cells := width_tiles * height_tiles
	collision.resize(cells)
	for i in range(mini(cells, data.size() / 2)):
		collision[i] = (data[i * 2] << 8) | data[i * 2 + 1]

func cell_at(px: float, py: float) -> int:
	var cx := int(px) / TILE
	var cy := int(py) / TILE
	if cx < 0 or cx >= width_tiles or cy < 0 or cy >= height_tiles:
		return 30  # out of bounds = wall
	return collision[cy * width_tiles + cx]

func _tile_impassable(i: int) -> bool:
	## A tile blocks the flood fill only if no sampled pixel in it is walkable.
	var cx := (i % width_tiles) * TILE
	var cy := (i / width_tiles) * TILE
	for oy in [1, 4, 6]:
		for ox in [1, 4, 6]:
			if not _pixel_blocked(cx + ox, cy + oy):
				return false
	return true

func is_blocked(px: float, py: float) -> bool:
	if _pixel_blocked(int(px), int(py)):
		return true
	if not reachable.is_empty():
		var ci := (int(py) / TILE) * width_tiles + int(px) / TILE
		if ci >= 0 and ci < reachable.size() and reachable[ci] == 0:
			return true
	return false

func _pixel_blocked(x: int, y: int) -> bool:
	## Lifted from the game's walkability routine (ROM 0x740C):
	## cell bit15 = solid; low bits = zone id -> shape entry -> 8x8 nibble
	## mask; nonzero nibble at the sub-tile pixel = blocked.
	var cx := x / TILE
	var cy := y / TILE
	if cx < 0 or cx >= width_tiles or cy < 0 or cy >= height_tiles:
		return true
	var i := cy * width_tiles + cx
	if i >= collision.size():
		return false          # collision grid missing/short for this room -- don't crash
	var cell := collision[i]
	# ROM 0x7416 masks bit15 OFF (ANDI #$7FFF) and uses the low 15 bits as the
	# tile index; index 0 = walkable. Treating bit15 as "solid" over-blocks cells
	# that are 0x8000 (bit15 set, index 0) -- verified walkable by the executed
	# oracle (work/diff_walkmask.py caught 21 such cells on room 2's floor).
	var zone := cell & 0x7FFF
	if zone == 0:
		return false
	var entries: Array = Game.collision_tables.get("zone_entries", [])
	var shapes: Array = Game.collision_tables.get("shapes", [])
	if zone >= entries.size():
		return false
	var entry: int = int(entries[zone])
	var shape_idx: int = entry & 0x7FF
	if shape_idx >= shapes.size():
		return false
	var sx := x & 7
	var sy := y & 7
	# Original: EOR #7 on x when bit11 CLEAR; EOR #7 on y when bit12 SET.
	if (entry & 0x800) == 0:
		sx ^= 7
	if entry & 0x1000:
		sy ^= 7
	return int(shapes[shape_idx][sy][sx]) != 0

func pixel_size() -> Vector2:
	return Vector2(width_tiles * TILE, height_tiles * TILE)


## --- Walk pathfinding -------------------------------------------------------
## The ROM routes a walk with a line-of-sight test then corner / 2-segment
## detours (walkbox pathfinder, ROM 0x5002-0x519C, route cases). We reach the
## same result — a path that never crosses an unwalkable cell — with A* over the
## SAME walkability grid the collision test already computes (`reachable`, which
## is the flood-fill of the ROM sub-cell mask at 0x740C). Cells are TILE(8)px.

func _build_astar() -> void:
	_astar = AStarGrid2D.new()
	_astar.region = Rect2i(0, 0, width_tiles, height_tiles)
	_astar.cell_size = Vector2(TILE, TILE)
	_astar.offset = Vector2(TILE, TILE) * 0.5     # points land on cell centres
	_astar.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	_astar.default_compute_heuristic = AStarGrid2D.HEURISTIC_EUCLIDEAN
	_astar.default_estimate_heuristic = AStarGrid2D.HEURISTIC_EUCLIDEAN
	_astar.update()
	for cy in range(height_tiles):
		for cx in range(width_tiles):
			var i := cy * width_tiles + cx
			var walkable := (not reachable.is_empty()
				and i < reachable.size() and reachable[i] == 1)
			_astar.set_point_solid(Vector2i(cx, cy), not walkable)

func _cell_of(px: float, py: float) -> Vector2i:
	return Vector2i(clampi(int(px) / TILE, 0, width_tiles - 1),
		clampi(int(py) / TILE, 0, height_tiles - 1))

## Nearest walkable cell to `c` (a click may land on a wall) — expanding ring.
func _nearest_walkable(c: Vector2i) -> Vector2i:
	if not _astar.is_point_solid(c):
		return c
	for r in range(1, maxi(width_tiles, height_tiles)):
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if absi(dx) != r and absi(dy) != r:
					continue    # ring only
				var n := Vector2i(c.x + dx, c.y + dy)
				if n.x >= 0 and n.x < width_tiles and n.y >= 0 and n.y < height_tiles \
						and not _astar.is_point_solid(n):
					return n
	return c

## Returns pixel waypoints from `from_px` to `to_px` that stay on walkable
## cells. Empty when already there / unreachable (caller keeps current pos).
func find_path(from_px: Vector2, to_px: Vector2) -> PackedVector2Array:
	if width_tiles == 0 or reachable.is_empty():
		return PackedVector2Array([to_px])   # no grid -> straight (loader fallback)
	if _astar == null:
		_build_astar()
	var fc := _nearest_walkable(_cell_of(from_px.x, from_px.y))
	var tc := _nearest_walkable(_cell_of(to_px.x, to_px.y))
	if fc == tc:
		return PackedVector2Array([to_px])
	var pts := _astar.get_point_path(fc, tc)   # already cell-centre pixel coords
	if pts.is_empty():
		return PackedVector2Array()
	# Drop the first point (we're already standing there) and make the last
	# waypoint the exact click target when that pixel is itself walkable, so the
	# actor arrives where the player clicked, not just the cell centre.
	var out := PackedVector2Array()
	for k in range(1, pts.size()):
		out.append(pts[k])
	if not out.is_empty() and not is_blocked(to_px.x, to_px.y):
		out[out.size() - 1] = to_px
	return out

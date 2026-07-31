extends SceneTree
## Validates the exact AStarGrid2D configuration room.gd::_build_astar uses
## (region, cell_size, offset, diagonal mode, set_point_solid, get_point_path)
## produces a path that routes AROUND a wall — no Game/autoload dependency.

func _init() -> void:
	var W := 10
	var H := 10
	var TILE := 8
	var a := AStarGrid2D.new()
	a.region = Rect2i(0, 0, W, H)
	a.cell_size = Vector2(TILE, TILE)
	a.offset = Vector2(TILE, TILE) * 0.5
	a.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	a.default_compute_heuristic = AStarGrid2D.HEURISTIC_EUCLIDEAN
	a.default_estimate_heuristic = AStarGrid2D.HEURISTIC_EUCLIDEAN
	a.update()
	# wall column cx=5 rows 0..7 (gap at 8,9)
	for cy in range(0, 8):
		a.set_point_solid(Vector2i(5, cy), true)

	var pts := a.get_point_path(Vector2i(2, 3), Vector2i(8, 3))
	var reaches := not pts.is_empty() and pts[pts.size() - 1].distance_to(Vector2(8 * 8 + 4, 3 * 8 + 4)) < 12.0
	var crosses := false
	var went_down := false
	for p in pts:
		var cx := int(p.x) / TILE
		var cy := int(p.y) / TILE
		if cx == 5 and cy < 8:
			crosses = true
		if cy >= 8:
			went_down = true
	print("[astar_test] waypoints=", pts.size(), " first=", pts[0] if pts.size() > 0 else "none",
		" last=", pts[pts.size() - 1] if pts.size() > 0 else "none")
	print("[astar_test] reaches=", reaches, " avoids_wall=", not crosses, " through_gap=", went_down)
	print("[astar_test] RESULT: ", ("PASS" if (reaches and not crosses and went_down) else "FAIL"))
	quit()

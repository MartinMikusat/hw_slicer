package features

import "base:runtime"
import "core:slice"

import contracts "../contracts"
import geometry "../geometry"
import polygon "../polygon"
import profiles "../profiles"

Unified_Path_Source_Kind :: enum u8 {
	Invalid,
	Adhesion,
	Perimeter,
	Bridge,
	Gap_Centerline,
	Solid,
	Sparse_Infill,
	Support,
}

Seam_Strategy :: enum u8 {
	Rear,
	Aligned,
	Sharpest_Corner,
	Nearest,
}

Unified_Path_Source :: struct {
	stable_id:    contracts.Stable_ID,
	layer_id:     contracts.Stable_ID,
	layer_index:  u32,
	role:         profiles.Printable_Role,
	source_kind:  Unified_Path_Source_Kind,
	source_index: u32,
	source_order: u64,
	closed:       bool,
	points:       []polygon.Polygon_Point,
	line_widths:  []contracts.Micrometres,
}

Unified_Path_Plan_Config :: struct {
	start:           polygon.Polygon_Point,
	seam:            profiles.Seam_Policy,
	seam_visibility: profiles.Seam_Visibility_Policy,
	seam_strategy:   Seam_Strategy,
}

Unified_Planned_Layer :: struct {
	path_offset: u64,
	path_count:  u32,
	move_offset: u64,
	move_count:  u32,
}

Unified_Planned_Path :: struct {
	stable_id:    contracts.Stable_ID,
	path_set_id:  contracts.Stable_ID,
	source_id:    contracts.Stable_ID,
	source_kind:  Unified_Path_Source_Kind,
	source_index: u32,
	source_order: u64,
	layer_id:     contracts.Stable_ID,
	layer_index:  u32,
	role:         profiles.Printable_Role,
	priority:     u8,
	start_index:  u32,
	reversed:     bool,
	closed:       bool,
	move_offset:  u64,
	move_count:   u32,
}

Unified_Planned_Move :: struct {
	stable_id:         contracts.Stable_ID,
	path_id:           contracts.Stable_ID,
	kind:              Planned_Move_Kind,
	role:              profiles.Printable_Role,
	source_edge_index: u32,
	point_a:           polygon.Polygon_Point,
	point_b:           polygon.Polygon_Point,
	line_width_a:      contracts.Micrometres,
	line_width_b:      contracts.Micrometres,
}

Unified_Path_Plan_Result :: struct {
	config:             Unified_Path_Plan_Config,
	layers:             []Unified_Planned_Layer,
	paths:              []Unified_Planned_Path,
	moves:              []Unified_Planned_Move,
	travel_move_count:  u64,
	extrude_move_count: u64,
}

Unified_Path_Plan_Limits :: struct {
	max_paths: u64,
	max_moves: u64,
}

DEFAULT_UNIFIED_PATH_PLAN_LIMITS :: Unified_Path_Plan_Limits{
	max_paths = 1_000_000_000,
	max_moves = 4_000_000_000,
}

Unified_Path_Plan_Error :: enum u8 {
	None,
	Invalid_Config,
	Invalid_Input,
	Path_Limit,
	Move_Limit,
	Allocation_Failed,
	Arithmetic,
}

Unified_Path_Order :: struct {
	source_slice_index: u32,
	layer_index:       u32,
	priority:          u8,
	source_order:      u64,
	stable_id:         contracts.Stable_ID,
}

Unified_Seam_Score :: struct {
	turn_score:      u32,
	rear_coordinate: i64,
	travel_distance: u128,
	point_index:     u32,
}

unified_path_plan_build :: proc(
	layer_ids: []contracts.Stable_ID,
	sources: []Unified_Path_Source,
	config: Unified_Path_Plan_Config,
	limits := DEFAULT_UNIFIED_PATH_PLAN_LIMITS,
	allocator := context.allocator,
) -> (Unified_Path_Plan_Result, Unified_Path_Plan_Error) {
	if geometry.point_2_validate({
		config.start.x,
		config.start.y,
	}) != .None ||
	   config.seam != .Deterministic_Cost ||
	   config.seam_visibility != .Rear_Maximum_Y {
		return {}, .Invalid_Config
	}
	if u64(len(layer_ids)) > u64(max(u32)) ||
	   u64(len(sources)) > u64(max(u32)) {
		return {}, .Arithmetic
	}
	if u64(len(sources)) > limits.max_paths {
		return {}, .Path_Limit
	}
	orders := make([]Unified_Path_Order, len(sources), allocator)
	identities := make([]contracts.Stable_ID, len(sources), allocator)
	if len(sources) > 0 &&
	   (orders == nil || identities == nil) {
		delete(orders, allocator)
		delete(identities, allocator)
		return {}, .Allocation_Failed
	}
	defer {
		delete(orders, allocator)
		delete(identities, allocator)
	}
	extrude_move_count: u64
	if len(sources) > 0 {
		chunk_count := 1
		if get_worker_threads() > 1 && len(sources) >= 256 {
			chunk_count = min(get_worker_threads()*2, (len(sources)+127)/128)
		}
		if chunk_count == 1 {
			for source, source_slice_index in sources {
				priority, source_ok := unified_path_source_validate(source, layer_ids)
				if !source_ok {return {}, .Invalid_Input}
				edge_count := len(source.points)-1
				if source.closed {edge_count = len(source.points)}
				if extrude_move_count > limits.max_moves ||
				   u64(edge_count) > limits.max_moves-extrude_move_count {
					return {}, .Move_Limit
				}
				extrude_move_count += u64(edge_count)
				orders[source_slice_index] = {
					source_slice_index = u32(source_slice_index),
					layer_index        = source.layer_index,
					priority           = priority,
					source_order       = source.source_order,
					stable_id          = source.stable_id,
				}
				identities[source_slice_index] = source.stable_id
			}
		} else {
			chunk_size := (len(sources)+chunk_count-1)/chunk_count
			chunk_counts := make([]u64, chunk_count, allocator)
			chunk_ok := make([]bool, chunk_count, allocator)
			if chunk_counts == nil || chunk_ok == nil {
				delete(chunk_counts, allocator)
				delete(chunk_ok, allocator)
				return {}, .Allocation_Failed
			}
			defer {
				delete(chunk_counts, allocator)
				delete(chunk_ok, allocator)
			}
			val_ctx := Plan_Validate_Context{
				layer_ids    = layer_ids,
				sources      = sources,
				orders       = orders,
				identities   = identities,
				chunk_counts = chunk_counts,
				chunk_ok     = chunk_ok,
				chunk_size   = chunk_size,
			}
			parallel_for(chunk_count, &val_ctx, unified_path_validate_chunk, min_count = 2)
			for c in 0..<chunk_count {
				if !chunk_ok[c] {return {}, .Invalid_Input}
				if extrude_move_count > limits.max_moves ||
				   chunk_counts[c] > limits.max_moves-extrude_move_count {
					return {}, .Move_Limit
				}
				extrude_move_count += chunk_counts[c]
			}
		}
	}
	slice.sort_by(orders, unified_path_order_less)
	slice.sort_by(identities, unified_path_stable_id_less)
	for stable_id, stable_id_index in identities {
		if stable_id_index > 0 &&
		   stable_id == identities[stable_id_index-1] {
			return {}, .Invalid_Input
		}
	}
	maximum_move_count :=
		extrude_move_count+u64(len(sources))
	if maximum_move_count < extrude_move_count ||
	   maximum_move_count > limits.max_moves {
		return {}, .Move_Limit
	}
	if maximum_move_count > u64(max(int)) {
		return {}, .Arithmetic
	}

	emit_items := make([]Plan_Emit_Item, len(sources), allocator)
	if len(sources) > 0 && emit_items == nil {
		return {}, .Allocation_Failed
	}
	defer delete(emit_items, allocator)

	result := Unified_Path_Plan_Result{config = config}
	result.layers = make(
		[]Unified_Planned_Layer,
		len(layer_ids),
		allocator,
	)
	result.paths = make(
		[]Unified_Planned_Path,
		len(sources),
		allocator,
	)
	if len(layer_ids) > 0 && result.layers == nil ||
	   len(sources) > 0 && result.paths == nil {
		unified_path_plan_result_destroy(&result, allocator)
		return {}, .Allocation_Failed
	}

	// Pass 1 (serial): chain open-path runs, resolve per-path seam/direction and exact move offsets.
	current := config.start
	has_last_seam := false
	last_seam: polygon.Polygon_Point
	order_cursor := 0
	path_write := 0
	move_write := 0
	for _, layer_index in layer_ids {
		layer_path_start := path_write
		layer_move_start := move_write
		for order_cursor < len(orders) &&
		    orders[order_cursor].layer_index == u32(layer_index) {
			// A run of open paths with one priority is chained greedily by nearest endpoint from
			// the current position; closed paths (perimeters) keep their order.
			if order_cursor == 0 ||
			   orders[order_cursor - 1].layer_index != orders[order_cursor].layer_index ||
			   orders[order_cursor - 1].priority != orders[order_cursor].priority {
				run_end := order_cursor
				all_open := true
				for run_end < len(orders) &&
				    orders[run_end].layer_index == orders[order_cursor].layer_index &&
				    orders[run_end].priority == orders[order_cursor].priority {
					if sources[orders[run_end].source_slice_index].closed {all_open = false}
					run_end += 1
				}
				if all_open && run_end - order_cursor > 2 {
					unified_path_plan_chain_nearest(orders[order_cursor:run_end], sources, current)
				}
			}
			order := orders[order_cursor]
			source := sources[order.source_slice_index]
			start_index := 0
			reversed := false
			if source.closed {
				start_index = unified_path_plan_seam_index(
					source.points,
					current,
					config.seam_strategy,
					has_last_seam,
					last_seam,
				)
				if source.source_kind == .Perimeter {
					has_last_seam = true
					last_seam = source.points[start_index]
				}
			} else if path_plan_distance_2(
				current,
				source.points[len(source.points)-1],
			) < path_plan_distance_2(current, source.points[0]) {
				start_index = len(source.points)-1
				reversed = true
			}
			start_point := source.points[start_index]
			has_travel := current != start_point
			edge_count := len(source.points)-1
			if source.closed {edge_count = len(source.points)}
			path_move_count := edge_count+(1 if has_travel else 0)
			if path_move_count <= 0 || path_move_count > int(max(u32)) {
				unified_path_plan_result_destroy(&result, allocator)
				return {}, .Arithmetic
			}
			emit_items[path_write] = {
				order       = order,
				start_index = u32(start_index),
				reversed    = reversed,
				has_travel  = has_travel,
				travel_from = current,
				move_offset = u64(move_write),
				move_count  = u32(path_move_count),
			}
			if has_travel {result.travel_move_count += 1}
			result.extrude_move_count += u64(edge_count)
			move_write += path_move_count
			path_write += 1
			if source.closed {
				current = start_point
			} else if reversed {
				current = source.points[0]
			} else {
				current = source.points[len(source.points)-1]
			}
			order_cursor += 1
		}
		layer_path_count := path_write-layer_path_start
		layer_move_count := move_write-layer_move_start
		if layer_path_count > int(max(u32)) ||
		   layer_move_count > int(max(u32)) {
			unified_path_plan_result_destroy(&result, allocator)
			return {}, .Arithmetic
		}
		result.layers[layer_index] = {
			path_offset = u64(layer_path_start),
			path_count  = u32(layer_path_count),
			move_offset = u64(layer_move_start),
			move_count  = u32(layer_move_count),
		}
	}
	if order_cursor != len(orders) ||
	   path_write != len(result.paths) ||
	   u64(move_write) > maximum_move_count {
		unified_path_plan_result_destroy(&result, allocator)
		return {}, .Arithmetic
	}

	result.moves = make([]Unified_Planned_Move, move_write, allocator)
	if move_write > 0 && result.moves == nil {
		unified_path_plan_result_destroy(&result, allocator)
		return {}, .Allocation_Failed
	}

	// Pass 2 (parallel per layer): emit planned paths and moves (including per-move stable IDs).
	layer_ok := make([]bool, len(layer_ids), allocator)
	if len(layer_ids) > 0 && layer_ok == nil {
		unified_path_plan_result_destroy(&result, allocator)
		return {}, .Allocation_Failed
	}
	defer delete(layer_ok, allocator)

	emit_ctx := Plan_Emit_Context{
		sources    = sources,
		emit_items = emit_items,
		layers     = result.layers,
		paths      = result.paths,
		moves      = result.moves,
		layer_ok   = layer_ok,
	}
	parallel_for(len(layer_ids), &emit_ctx, unified_path_emit_layer)
	for ok in layer_ok {
		if !ok {
			unified_path_plan_result_destroy(&result, allocator)
			return {}, .Arithmetic
		}
	}
	return result, .None
}

@(private = "file")
Plan_Validate_Context :: struct {
	layer_ids:    []contracts.Stable_ID,
	sources:      []Unified_Path_Source,
	orders:       []Unified_Path_Order,
	identities:   []contracts.Stable_ID,
	chunk_counts: []u64,
	chunk_ok:     []bool,
	chunk_size:   int,
}

@(private = "file")
unified_path_validate_chunk :: proc(ctx: ^Plan_Validate_Context, chunk_index: int) {
	start := chunk_index*ctx.chunk_size
	end := min(start+ctx.chunk_size, len(ctx.sources))
	total: u64
	for source_slice_index in start..<end {
		source := ctx.sources[source_slice_index]
		priority, source_ok := unified_path_source_validate(source, ctx.layer_ids)
		if !source_ok {
			ctx.chunk_ok[chunk_index] = false
			return
		}
		edge_count := len(source.points)-1
		if source.closed {edge_count = len(source.points)}
		total += u64(edge_count)
		ctx.orders[source_slice_index] = {
			source_slice_index = u32(source_slice_index),
			layer_index        = source.layer_index,
			priority           = priority,
			source_order       = source.source_order,
			stable_id          = source.stable_id,
		}
		ctx.identities[source_slice_index] = source.stable_id
	}
	ctx.chunk_counts[chunk_index] = total
	ctx.chunk_ok[chunk_index] = true
}

@(private = "file")
Plan_Emit_Item :: struct {
	order:       Unified_Path_Order,
	start_index: u32,
	reversed:    bool,
	has_travel:  bool,
	travel_from: polygon.Polygon_Point,
	move_offset: u64,
	move_count:  u32,
}

@(private = "file")
Plan_Emit_Context :: struct {
	sources:    []Unified_Path_Source,
	emit_items: []Plan_Emit_Item,
	layers:     []Unified_Planned_Layer,
	paths:      []Unified_Planned_Path,
	moves:      []Unified_Planned_Move,
	layer_ok:   []bool,
}

@(private = "file")
unified_path_emit_layer :: proc(ctx: ^Plan_Emit_Context, layer_index: int) {
	layer := ctx.layers[layer_index]
	path_start := int(layer.path_offset)
	path_end := path_start+int(layer.path_count)
	for path_index in path_start..<path_end {
		item := ctx.emit_items[path_index]
		source := ctx.sources[item.order.source_slice_index]
		path_set_id := contracts.stable_id_child(source.stable_id, .Feature, 0)
		path_id := contracts.stable_id_child(path_set_id, .Path, 0)
		move_write := int(item.move_offset)
		start_index := int(item.start_index)
		if item.has_travel {
			ctx.moves[move_write] = {
				stable_id         = contracts.stable_id_child(path_id, .Path, u64(1)<<63),
				path_id           = path_id,
				kind              = .Travel,
				source_edge_index = max(u32),
				point_a           = item.travel_from,
				point_b           = source.points[start_index],
			}
			move_write += 1
		}
		edge_count := len(source.points)-1
		if source.closed {edge_count = len(source.points)}
		for local_edge_index in 0..<edge_count {
			point_a_index := local_edge_index
			point_b_index := local_edge_index+1
			source_edge_index := local_edge_index
			if source.closed {
				point_a_index = (start_index+local_edge_index)%len(source.points)
				point_b_index = (point_a_index+1)%len(source.points)
				source_edge_index = point_a_index
			} else if item.reversed {
				point_a_index = len(source.points)-1-local_edge_index
				point_b_index = point_a_index-1
				source_edge_index = point_b_index
			}
			a := source.points[point_a_index]
			b := source.points[point_b_index]
			if a == b {
				ctx.layer_ok[layer_index] = false
				return
			}
			ctx.moves[move_write] = {
				stable_id         = contracts.stable_id_child(path_id, .Path, u64(source_edge_index)),
				path_id           = path_id,
				kind              = .Extrude,
				role              = source.role,
				source_edge_index = u32(source_edge_index),
				point_a           = a,
				point_b           = b,
				line_width_a      = source.line_widths[point_a_index],
				line_width_b      = source.line_widths[point_b_index],
			}
			move_write += 1
		}
		ctx.paths[path_index] = {
			stable_id    = path_id,
			path_set_id  = path_set_id,
			source_id    = source.stable_id,
			source_kind  = source.source_kind,
			source_index = source.source_index,
			source_order = source.source_order,
			layer_id     = source.layer_id,
			layer_index  = source.layer_index,
			role         = source.role,
			priority     = item.order.priority,
			start_index  = item.start_index,
			reversed     = item.reversed,
			closed       = source.closed,
			move_offset  = item.move_offset,
			move_count   = item.move_count,
		}
	}
	ctx.layer_ok[layer_index] = true
}

unified_path_plan_seam_index :: proc(
	points: []polygon.Polygon_Point,
	current: polygon.Polygon_Point,
	strategy: Seam_Strategy = .Rear,
	has_last_seam := false,
	last_seam := polygon.Polygon_Point{},
) -> int {
	best_index := 0
	switch strategy {
	case .Rear:
		best_y := i64(points[0].y)
		best_computed := false
		best: Unified_Seam_Score
		for point_index in 1..<len(points) {
			y := i64(points[point_index].y)
			if y < best_y {continue}
			if y > best_y {
				best_index = point_index
				best_y = y
				best_computed = false
				continue
			}
			if !best_computed {
				best = unified_path_plan_seam_score(points, best_index, current)
				best_computed = true
			}
			candidate := unified_path_plan_seam_score(points, point_index, current)
			if unified_path_plan_seam_score_less(candidate, best) {
				best_index = point_index
				best = candidate
			}
		}
		return best_index
	case .Nearest:
		best_d := path_plan_distance_2(current, points[0])
		best_computed := false
		best: Unified_Seam_Score
		for point_index in 1..<len(points) {
			d := path_plan_distance_2(current, points[point_index])
			if d > best_d {continue}
			if d < best_d {
				best_index = point_index
				best_d = d
				best_computed = false
				continue
			}
			if !best_computed {
				best = unified_path_plan_seam_score(points, best_index, current)
				best_computed = true
			}
			candidate := unified_path_plan_seam_score(points, point_index, current)
			if unified_path_plan_seam_score_less(candidate, best) {
				best_index = point_index
				best = candidate
			}
		}
		return best_index
	case .Aligned:
		if has_last_seam {
			best_align := path_plan_distance_2(last_seam, points[0])
			best_computed := false
			best: Unified_Seam_Score
			for point_index in 1..<len(points) {
				cand_align := path_plan_distance_2(last_seam, points[point_index])
				if cand_align > best_align {continue}
				if cand_align < best_align {
					best_index = point_index
					best_align = cand_align
					best_computed = false
					continue
				}
				if !best_computed {
					best = unified_path_plan_seam_score(points, best_index, current)
					best_computed = true
				}
				candidate := unified_path_plan_seam_score(points, point_index, current)
				if unified_path_plan_seam_score_less(candidate, best) {
					best_index = point_index
					best = candidate
				}
			}
			return best_index
		}
		fallthrough
	case .Sharpest_Corner:
		best := unified_path_plan_seam_score(points, 0, current)
		for point_index in 1..<len(points) {
			candidate := unified_path_plan_seam_score(points, point_index, current)
			if unified_path_plan_seam_score_less(candidate, best) {
				best_index = point_index
				best = candidate
			}
		}
		return best_index
	}
	return best_index
}

unified_path_plan_seam_score :: proc(
	points: []polygon.Polygon_Point,
	point_index: int,
	current: polygon.Polygon_Point,
) -> Unified_Seam_Score {
	previous := points[(point_index+len(points)-1)%len(points)]
	point := points[point_index]
	next := points[(point_index+1)%len(points)]
	incoming_x := i128(i64(point.x))-i128(i64(previous.x))
	incoming_y := i128(i64(point.y))-i128(i64(previous.y))
	outgoing_x := i128(i64(next.x))-i128(i64(point.x))
	outgoing_y := i128(i64(next.y))-i128(i64(point.y))
	cross :=
		incoming_x*outgoing_y-incoming_y*outgoing_x
	if cross < 0 {cross = -cross}
	dot :=
		incoming_x*outgoing_x+incoming_y*outgoing_y
	if dot < 0 {dot = -dot}
	turn_denominator := u128(cross)+u128(dot)
	turn_score: u32
	if turn_denominator > 0 {
		turn_score = u32(
			(u128(cross)*u128(profiles.RATIO_SCALE))/
			turn_denominator,
		)
	}
	return {
		turn_score = turn_score,
		rear_coordinate = i64(point.y),
		travel_distance = path_plan_distance_2(current, point),
		point_index = u32(point_index),
	}
}

unified_path_plan_seam_score_less :: proc(
	candidate, current: Unified_Seam_Score,
) -> bool {
	if candidate.turn_score != current.turn_score {
		return candidate.turn_score > current.turn_score
	}
	if candidate.rear_coordinate != current.rear_coordinate {
		return candidate.rear_coordinate > current.rear_coordinate
	}
	if candidate.travel_distance != current.travel_distance {
		return candidate.travel_distance < current.travel_distance
	}
	return candidate.point_index < current.point_index
}

// Reorders `run` (open paths) greedily: each next path is the one with the endpoint nearest to
// the current position, which then moves to that path's other end. Ties go to the earlier order,
// so the result is deterministic.
unified_path_plan_chain_nearest :: proc(
	run: []Unified_Path_Order,
	sources: []Unified_Path_Source,
	start: polygon.Polygon_Point,
) {
	CELL :: i64(4000)
	cell_of :: proc(p: polygon.Polygon_Point) -> [2]i64 {
		x, y := i64(p.x), i64(p.y)
		return {x / CELL - (1 if x < 0 && x % CELL != 0 else 0), y / CELL - (1 if y < 0 && y % CELL != 0 else 0)}
	}
	n := len(run)
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	original := make([]Unified_Path_Order, n, context.temp_allocator)
	copy(original, run)
	used := make([]bool, n, context.temp_allocator)
	grid := make(map[[2]i64][dynamic]int, n, context.temp_allocator)
	min_c, max_c := [2]i64{max(i64), max(i64)}, [2]i64{min(i64), min(i64)}
	for o, i in original {
		pts := sources[o.source_slice_index].points
		for p in ([2]polygon.Polygon_Point{pts[0], pts[len(pts) - 1]}) {
			c := cell_of(p)
			bucket, found := grid[c]
			if !found {bucket = make([dynamic]int, 0, 4, context.temp_allocator)}
			append(&bucket, i)
			grid[c] = bucket
			min_c = {min(min_c[0], c[0]), min(min_c[1], c[1])}
			max_c = {max(max_c[0], c[0]), max(max_c[1], c[1])}
		}
	}
	current := start
	for k in 0..<n {
		center := cell_of(current)
		best := -1
		best_d: u128
		max_ring := max(abs(center[0] - min_c[0]), abs(center[0] - max_c[0]), abs(center[1] - min_c[1]), abs(center[1] - max_c[1]))
		for ring := i64(0); ring <= max_ring; ring += 1 {
			// Once a candidate exists, a ring whose nearest possible point is farther stops the search.
			if best >= 0 && ring > 0 {
				reach := u128((ring - 1) * CELL)
				if reach * reach > best_d {break}
			}
			for dy := -ring; dy <= ring; dy += 1 {
				for dx := -ring; dx <= ring; dx += 1 {
					if max(abs(dx), abs(dy)) != ring {continue}
					bucket, found := grid[{center[0] + dx, center[1] + dy}]
					if !found {continue}
					for i in bucket {
						if used[i] {continue}
						pts := sources[original[i].source_slice_index].points
						d := min(path_plan_distance_2(current, pts[0]), path_plan_distance_2(current, pts[len(pts) - 1]))
						if best < 0 || d < best_d || (d == best_d && i < best) {
							best = i
							best_d = d
						}
					}
				}
			}
		}
		used[best] = true
		run[k] = original[best]
		pts := sources[original[best].source_slice_index].points
		if path_plan_distance_2(current, pts[len(pts) - 1]) < path_plan_distance_2(current, pts[0]) {
			current = pts[0]
		} else {
			current = pts[len(pts) - 1]
		}
	}
}

unified_path_order_less :: proc(
	a, b: Unified_Path_Order,
) -> bool {
	if a.layer_index != b.layer_index {
		return a.layer_index < b.layer_index
	}
	if a.priority != b.priority {return a.priority < b.priority}
	if a.source_order != b.source_order {
		return a.source_order < b.source_order
	}
	if a.stable_id != b.stable_id {return a.stable_id < b.stable_id}
	return a.source_slice_index < b.source_slice_index
}

unified_path_stable_id_less :: proc(
	a, b: contracts.Stable_ID,
) -> bool {
	return a < b
}

unified_path_source_kind_valid :: proc(
	kind: Unified_Path_Source_Kind,
	role: profiles.Printable_Role,
) -> bool {
	switch kind {
	case .Adhesion:
		return role == .Perimeter
	case .Perimeter:
		return role == .Perimeter
	case .Bridge:
		return role == .Bridge
	case .Gap_Centerline:
		return role == .Gap || role == .Thin_Wall
	case .Solid:
		return solid_path_role_is_skin(role)
	case .Sparse_Infill:
		return role == .Sparse_Infill
	case .Support:
		return role == .Support || role == .Support_Interface
	case .Invalid:
		return false
	}
	return false
}

unified_path_source_validate :: proc(
	source: Unified_Path_Source,
	layer_ids: []contracts.Stable_ID,
) -> (u8, bool) {
	priority, priority_ok :=
		profiles.printable_role_priority(source.role)
	if source.source_kind == .Adhesion {
		priority = 0
		priority_ok = true
	}
	if !priority_ok ||
	   !unified_path_source_kind_valid(
			source.source_kind,
			source.role,
	   ) ||
	   source.stable_id == contracts.INVALID_STABLE_ID ||
	   source.layer_id == contracts.INVALID_STABLE_ID ||
	   u64(source.layer_index) >= u64(len(layer_ids)) ||
	   source.layer_id != layer_ids[source.layer_index] ||
	   len(source.points) != len(source.line_widths) ||
	   source.closed && len(source.points) < 3 ||
	   !source.closed && len(source.points) < 2 ||
	   u64(len(source.points)) > u64(max(u32)) {
		return 0, false
	}
	previous := source.points[len(source.points)-1]
	for point, point_index in source.points {
		if geometry.point_2_validate({
			point.x,
			point.y,
		}) != .None ||
		   i64(source.line_widths[point_index]) <= 0 ||
		   i64(source.line_widths[point_index]) >
			geometry.MAX_PLANAR_COORDINATE_UM ||
		   point == previous {
			return 0, false
		}
		previous = point
	}
	return priority, true
}

unified_path_plan_result_destroy :: proc(
	result: ^Unified_Path_Plan_Result,
	allocator := context.allocator,
) {
	delete(result.layers, allocator)
	delete(result.paths, allocator)
	delete(result.moves, allocator)
	result^ = {}
}

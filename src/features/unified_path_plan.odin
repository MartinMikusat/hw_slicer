package features

import "core:slice"

import contracts "../contracts"
import geometry "../geometry"
import polygon "../polygon"
import profiles "../profiles"

Unified_Path_Source_Kind :: enum u8 {
	Invalid,
	Perimeter,
	Bridge,
	Gap_Centerline,
	Solid,
	Sparse_Infill,
	Support,
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
	for source, source_slice_index in sources {
		priority, source_ok :=
			unified_path_source_validate(source, layer_ids)
		if !source_ok {return {}, .Invalid_Input}
		edge_count := len(source.points)-1
		if source.closed {edge_count = len(source.points)}
		if extrude_move_count > limits.max_moves ||
		   u64(edge_count) >
			limits.max_moves-extrude_move_count {
			return {}, .Move_Limit
		}
		extrude_move_count += u64(edge_count)
		orders[source_slice_index] = {
			source_slice_index = u32(source_slice_index),
			layer_index = source.layer_index,
			priority = priority,
			source_order = source.source_order,
			stable_id = source.stable_id,
		}
		identities[source_slice_index] = source.stable_id
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
	result.moves = make(
		[]Unified_Planned_Move,
		int(maximum_move_count),
		allocator,
	)
	if len(layer_ids) > 0 && result.layers == nil ||
	   len(sources) > 0 && result.paths == nil ||
	   maximum_move_count > 0 && result.moves == nil {
		unified_path_plan_result_destroy(&result, allocator)
		return {}, .Allocation_Failed
	}

	current := config.start
	order_cursor := 0
	path_write := 0
	move_write := 0
	for layer_id, layer_index in layer_ids {
		layer_path_start := path_write
		layer_move_start := move_write
		for order_cursor < len(orders) &&
		    orders[order_cursor].layer_index == u32(layer_index) {
			order := orders[order_cursor]
			source := sources[order.source_slice_index]
			emit_ok := unified_path_plan_emit_source(
				source,
				order.priority,
				&current,
				result.paths,
				result.moves,
				&path_write,
				&move_write,
				&result,
			)
			if !emit_ok {
				unified_path_plan_result_destroy(&result, allocator)
				return {}, .Arithmetic
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
		_ = layer_id
		result.layers[layer_index] = {
			path_offset = u64(layer_path_start),
			path_count = u32(layer_path_count),
			move_offset = u64(layer_move_start),
			move_count = u32(layer_move_count),
		}
	}
	if order_cursor != len(orders) ||
	   path_write != len(result.paths) {
		unified_path_plan_result_destroy(&result, allocator)
		return {}, .Arithmetic
	}
	result.moves = result.moves[:move_write]
	return result, .None
}

unified_path_plan_emit_source :: proc(
	source: Unified_Path_Source,
	priority: u8,
	current: ^polygon.Polygon_Point,
	paths: []Unified_Planned_Path,
	moves: []Unified_Planned_Move,
	path_write, move_write: ^int,
	result: ^Unified_Path_Plan_Result,
) -> bool {
	if path_write^ >= len(paths) {return false}
	start_index := 0
	reversed := false
	if source.closed {
		start_index = unified_path_plan_seam_index(
			source.points,
			current^,
		)
	} else if path_plan_distance_2(
		current^,
		source.points[len(source.points)-1],
	) < path_plan_distance_2(current^, source.points[0]) {
		start_index = len(source.points)-1
		reversed = true
	}
	path_set_id := contracts.stable_id_child(
		source.stable_id,
		.Feature,
		0,
	)
	path_id := contracts.stable_id_child(path_set_id, .Path, 0)
	path_move_start := move_write^
	start_point := source.points[start_index]
	if !unified_path_plan_emit_travel(
		current^,
		start_point,
		path_id,
		moves,
		move_write,
		result,
	) {
		return false
	}
	edge_count := len(source.points)-1
	if source.closed {edge_count = len(source.points)}
	for local_edge_index in 0..<edge_count {
		point_a_index := local_edge_index
		point_b_index := local_edge_index+1
		source_edge_index := local_edge_index
		if source.closed {
			point_a_index =
				(start_index+local_edge_index)%len(source.points)
			point_b_index = (point_a_index+1)%len(source.points)
			source_edge_index = point_a_index
		} else if reversed {
			point_a_index =
				len(source.points)-1-local_edge_index
			point_b_index = point_a_index-1
			source_edge_index = point_b_index
		}
		if !unified_path_plan_emit_extrude(
			source.points[point_a_index],
			source.points[point_b_index],
			source.line_widths[point_a_index],
			source.line_widths[point_b_index],
			source.role,
			path_id,
			u32(source_edge_index),
			moves,
			move_write,
			result,
		) {
			return false
		}
	}
	if source.closed {
		current^ = start_point
	} else if reversed {
		current^ = source.points[0]
	} else {
		current^ = source.points[len(source.points)-1]
	}
	path_move_count := move_write^-path_move_start
	if path_move_count <= 0 || path_move_count > int(max(u32)) {
		return false
	}
	paths[path_write^] = {
		stable_id = path_id,
		path_set_id = path_set_id,
		source_id = source.stable_id,
		source_kind = source.source_kind,
		source_index = source.source_index,
		source_order = source.source_order,
		layer_id = source.layer_id,
		layer_index = source.layer_index,
		role = source.role,
		priority = priority,
		start_index = u32(start_index),
		reversed = reversed,
		closed = source.closed,
		move_offset = u64(path_move_start),
		move_count = u32(path_move_count),
	}
	path_write^ += 1
	return true
}

unified_path_plan_seam_index :: proc(
	points: []polygon.Polygon_Point,
	current: polygon.Polygon_Point,
) -> int {
	best_index := 0
	best := unified_path_plan_seam_score(points, 0, current)
	for point_index in 1..<len(points) {
		candidate :=
			unified_path_plan_seam_score(points, point_index, current)
		if unified_path_plan_seam_score_less(candidate, best) {
			best_index = point_index
			best = candidate
		}
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

unified_path_plan_emit_travel :: proc(
	a, b: polygon.Polygon_Point,
	path_id: contracts.Stable_ID,
	moves: []Unified_Planned_Move,
	move_write: ^int,
	result: ^Unified_Path_Plan_Result,
) -> bool {
	if a == b {return true}
	if move_write^ >= len(moves) {return false}
	moves[move_write^] = {
		stable_id = contracts.stable_id_child(
			path_id,
			.Path,
			u64(1)<<63,
		),
		path_id = path_id,
		kind = .Travel,
		source_edge_index = max(u32),
		point_a = a,
		point_b = b,
	}
	move_write^ += 1
	result.travel_move_count += 1
	return true
}

unified_path_plan_emit_extrude :: proc(
	a, b: polygon.Polygon_Point,
	width_a, width_b: contracts.Micrometres,
	role: profiles.Printable_Role,
	path_id: contracts.Stable_ID,
	source_edge_index: u32,
	moves: []Unified_Planned_Move,
	move_write: ^int,
	result: ^Unified_Path_Plan_Result,
) -> bool {
	if move_write^ >= len(moves) || a == b {return false}
	moves[move_write^] = {
		stable_id = contracts.stable_id_child(
			path_id,
			.Path,
			u64(source_edge_index),
		),
		path_id = path_id,
		kind = .Extrude,
		role = role,
		source_edge_index = source_edge_index,
		point_a = a,
		point_b = b,
		line_width_a = width_a,
		line_width_b = width_b,
	}
	move_write^ += 1
	result.extrude_move_count += 1
	return true
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

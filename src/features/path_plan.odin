package features

import contracts "../contracts"
import geometry "../geometry"
import polygon "../polygon"

Planned_Source_Kind :: enum u8 {
	Invalid,
	Perimeter,
	Infill,
}

Planned_Move_Kind :: enum u8 {
	Invalid,
	Travel,
	Extrude,
}

Path_Plan_Config :: struct {
	start: polygon.Polygon_Point,
	inner_perimeters_first: bool,
}

Path_Plan_Limits :: struct {
	max_paths: u64,
	max_moves: u64,
}

DEFAULT_PATH_PLAN_LIMITS :: Path_Plan_Limits{
	max_paths = 1_000_000_000,
	max_moves = 4_000_000_000,
}

Planned_Layer :: struct {
	path_offset: u64,
	path_count:  u32,
	move_offset: u64,
	move_count:  u32,
}

Planned_Path :: struct {
	stable_id:       contracts.Stable_ID,
	source_id:       contracts.Stable_ID,
	source_kind:     Planned_Source_Kind,
	source_index:    u32,
	region_id:       contracts.Stable_ID,
	region_index:    u32,
	layer_index:     u32,
	start_index:     u32,
	reversed:        bool,
	closed:          bool,
	move_offset:     u64,
	move_count:      u32,
}

Planned_Move :: struct {
	stable_id:        contracts.Stable_ID,
	path_id:          contracts.Stable_ID,
	kind:             Planned_Move_Kind,
	source_edge_index: u32,
	point_a:          polygon.Polygon_Point,
	point_b:          polygon.Polygon_Point,
}

Path_Plan_Result :: struct {
	config: Path_Plan_Config,
	topology_policy: Feature_Topology_Policy,
	layers: []Planned_Layer,
	paths:  []Planned_Path,
	moves:  []Planned_Move,
	travel_move_count: u64,
	extrude_move_count: u64,
}

Path_Plan_Error :: enum u8 {
	None,
	Invalid_Config,
	Invalid_Input,
	Path_Limit,
	Move_Limit,
	Allocation_Failed,
	Arithmetic,
}

path_plan_build :: proc(
	perimeters: Perimeter_Result,
	infill: Infill_Result,
	config: Path_Plan_Config,
	limits := DEFAULT_PATH_PLAN_LIMITS,
	allocator := context.allocator,
) -> (Path_Plan_Result, Path_Plan_Error) {
	if geometry.point_2_validate({
		config.start.x,
		config.start.y,
	}) != .None {
		return {}, .Invalid_Config
	}
	_, perimeters_ok := perimeter_result_hash(
		contracts.Content_Hash{},
		perimeters,
	)
	_, infill_ok := infill_result_hash(
		contracts.Content_Hash{},
		infill,
	)
	if !perimeters_ok || !infill_ok ||
	   len(perimeters.layers) != len(infill.layers) ||
	   perimeters.config.topology_policy !=
	   	infill.config.topology_policy ||
	   perimeters.config.count == 0 ||
	   len(perimeters.groups)%int(perimeters.config.count) != 0 {
		return {}, .Invalid_Input
	}
	if u64(len(perimeters.layers)) > u64(max(u32)) {
		return {}, .Arithmetic
	}
	path_count := u64(len(perimeters.paths))+u64(len(infill.segments))
	if path_count > limits.max_paths {return {}, .Path_Limit}
	if path_count > u64(max(int)) ||
	   path_count > u64(max(u32)) {
		return {}, .Arithmetic
	}
	maximum_moves := u128(len(perimeters.points))+
		u128(len(infill.segments))+u128(path_count)
	if maximum_moves > u128(limits.max_moves) {
		return {}, .Move_Limit
	}
	if maximum_moves > u128(max(int)) {return {}, .Arithmetic}

	result := Path_Plan_Result{
		config = config,
		topology_policy = perimeters.config.topology_policy,
	}
	result.layers = make(
		[]Planned_Layer,
		len(perimeters.layers),
		allocator,
	)
	result.paths = make([]Planned_Path, int(path_count), allocator)
	result.moves = make([]Planned_Move, int(maximum_moves), allocator)
	if len(result.layers) > 0 && result.layers == nil ||
	   path_count > 0 && result.paths == nil ||
	   maximum_moves > 0 && result.moves == nil {
		path_plan_result_destroy(&result, allocator)
		return {}, .Allocation_Failed
	}

	current := config.start
	path_write := 0
	move_write := 0
	for perimeter_layer, layer_index in perimeters.layers {
		infill_layer := infill.layers[layer_index]
		layer_path_start := path_write
		layer_move_start := move_write
		group_start := int(perimeter_layer.group_offset)
		group_end := group_start+int(perimeter_layer.group_count)
		infill_start := int(infill_layer.segment_offset)
		infill_end := infill_start+int(infill_layer.segment_count)
		infill_cursor := infill_start
		group_cursor := group_start
		for group_cursor < group_end {
			region_group_end :=
				group_cursor+int(perimeters.config.count)
			if region_group_end > group_end {
				path_plan_result_destroy(&result, allocator)
				return {}, .Invalid_Input
			}
			region_index := perimeters.groups[group_cursor].region_index
			if config.inner_perimeters_first {
				for reverse_index in 0..<int(perimeters.config.count) {
					group_index := region_group_end-1-reverse_index
					path_plan_emit_perimeter_group(
						perimeters,
						group_index,
						&current,
						result.paths,
						result.moves,
						&path_write,
						&move_write,
						&result,
					)
				}
			} else {
				for group_index in group_cursor..<region_group_end {
					path_plan_emit_perimeter_group(
						perimeters,
						group_index,
						&current,
						result.paths,
						result.moves,
						&path_write,
						&move_write,
						&result,
					)
				}
			}
			for infill_cursor < infill_end &&
			    infill.segments[infill_cursor].region_index ==
			    	region_index {
				path_plan_emit_infill(
					infill.segments[infill_cursor],
					u32(infill_cursor),
					&current,
					result.paths,
					result.moves,
					&path_write,
					&move_write,
					&result,
				)
				infill_cursor += 1
			}
			group_cursor = region_group_end
		}
		if infill_cursor != infill_end {
			path_plan_result_destroy(&result, allocator)
			return {}, .Invalid_Input
		}
		layer_path_count := path_write-layer_path_start
		layer_move_count := move_write-layer_move_start
		if layer_path_count > int(max(u32)) ||
		   layer_move_count > int(max(u32)) {
			path_plan_result_destroy(&result, allocator)
			return {}, .Arithmetic
		}
		result.layers[layer_index] = {
			path_offset = u64(layer_path_start),
			path_count = u32(layer_path_count),
			move_offset = u64(layer_move_start),
			move_count = u32(layer_move_count),
		}
	}
	if path_write != len(result.paths) {
		path_plan_result_destroy(&result, allocator)
		return {}, .Arithmetic
	}
	result.moves = result.moves[:move_write]
	return result, .None
}

path_plan_emit_perimeter_group :: proc(
	perimeters: Perimeter_Result,
	group_index: int,
	current: ^polygon.Polygon_Point,
	paths: []Planned_Path,
	moves: []Planned_Move,
	path_write, move_write: ^int,
	result: ^Path_Plan_Result,
) {
	group := perimeters.groups[group_index]
	start := int(group.path_offset)
	end := start+int(group.path_count)
	for source_path_index in start..<end {
		source := perimeters.paths[source_path_index]
		point_start := int(source.point_offset)
		point_end := point_start+int(source.point_count)
		points := perimeters.points[point_start:point_end]
		start_index := path_plan_nearest_point(points, current^)
		path_id := contracts.stable_id_child(source.stable_id, .Path, 0)
		path_move_start := move_write^
		start_point := points[start_index]
		path_plan_emit_travel(
			current^,
			start_point,
			path_id,
			moves,
			move_write,
			result,
		)
		for local_edge in 0..<len(points) {
			edge_index := (start_index+local_edge)%len(points)
			next_index := (edge_index+1)%len(points)
			path_plan_emit_extrude(
				points[edge_index],
				points[next_index],
				path_id,
				u32(edge_index),
				moves,
				move_write,
				result,
			)
		}
		current^ = start_point
		paths[path_write^] = {
			stable_id = path_id,
			source_id = source.stable_id,
			source_kind = .Perimeter,
			source_index = u32(source_path_index),
			region_id = source.region_id,
			region_index = source.region_index,
			layer_index = source.layer_index,
			start_index = u32(start_index),
			reversed = false,
			closed = true,
			move_offset = u64(path_move_start),
			move_count = u32(move_write^-path_move_start),
		}
		path_write^ += 1
	}
}

path_plan_emit_infill :: proc(
	source: Infill_Segment,
	source_index: u32,
	current: ^polygon.Polygon_Point,
	paths: []Planned_Path,
	moves: []Planned_Move,
	path_write, move_write: ^int,
	result: ^Path_Plan_Result,
) {
	reversed := path_plan_distance_2(current^, source.point_b) <
		path_plan_distance_2(current^, source.point_a)
	first, second := source.point_a, source.point_b
	start_index: u32
	if reversed {
		first, second = second, first
		start_index = 1
	}
	path_id := contracts.stable_id_child(source.stable_id, .Path, 0)
	path_move_start := move_write^
	path_plan_emit_travel(
		current^,
		first,
		path_id,
		moves,
		move_write,
		result,
	)
	path_plan_emit_extrude(
		first,
		second,
		path_id,
		0,
		moves,
		move_write,
		result,
	)
	current^ = second
	paths[path_write^] = {
		stable_id = path_id,
		source_id = source.stable_id,
		source_kind = .Infill,
		source_index = source_index,
		region_id = source.region_id,
		region_index = source.region_index,
		layer_index = source.layer_index,
		start_index = start_index,
		reversed = reversed,
		closed = false,
		move_offset = u64(path_move_start),
		move_count = u32(move_write^-path_move_start),
	}
	path_write^ += 1
}

path_plan_emit_travel :: proc(
	a, b: polygon.Polygon_Point,
	path_id: contracts.Stable_ID,
	moves: []Planned_Move,
	move_write: ^int,
	result: ^Path_Plan_Result,
) {
	if a == b {return}
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
}

path_plan_emit_extrude :: proc(
	a, b: polygon.Polygon_Point,
	path_id: contracts.Stable_ID,
	source_edge_index: u32,
	moves: []Planned_Move,
	move_write: ^int,
	result: ^Path_Plan_Result,
) {
	moves[move_write^] = {
		stable_id = contracts.stable_id_child(
			path_id,
			.Path,
			u64(source_edge_index),
		),
		path_id = path_id,
		kind = .Extrude,
		source_edge_index = source_edge_index,
		point_a = a,
		point_b = b,
	}
	move_write^ += 1
	result.extrude_move_count += 1
}

path_plan_nearest_point :: proc(
	points: []polygon.Polygon_Point,
	current: polygon.Polygon_Point,
) -> int {
	best_index := 0
	best_distance := path_plan_distance_2(current, points[0])
	for index in 1..<len(points) {
		distance := path_plan_distance_2(current, points[index])
		if distance < best_distance {
			best_index = index
			best_distance = distance
		}
	}
	return best_index
}

path_plan_distance_2 :: proc(
	a, b: polygon.Polygon_Point,
) -> u128 {
	dx := i128(i64(a.x))-i128(i64(b.x))
	dy := i128(i64(a.y))-i128(i64(b.y))
	return u128(dx*dx+dy*dy)
}

path_plan_result_destroy :: proc(
	result: ^Path_Plan_Result,
	allocator := context.allocator,
) {
	delete(result.layers, allocator)
	delete(result.paths, allocator)
	delete(result.moves, allocator)
	result^ = {}
}

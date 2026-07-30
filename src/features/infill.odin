package features

import "core:slice"

import contracts "../contracts"
import geometry "../geometry"
import polygon "../polygon"
import slicing "../slicing"

Infill_Axis :: enum u8 {
	Invalid,
	Vertical,
	Horizontal,
}

Infill_Config :: struct {
	spacing:              contracts.Micrometres,
	boundary_inset:       contracts.Micrometres,
	phase:                contracts.Micrometres,
	base_axis:            Infill_Axis,
	alternate_each_layer: bool,
	topology_policy:      Feature_Topology_Policy,
	join_type:            polygon.Polygon_Join_Type,
	miter_limit:          f64,
	arc_tolerance:        f64,
}

Infill_Limits :: struct {
	max_scanlines: u64,
	max_segments:  u64,
	polygon:       polygon.Polygon_Limits,
}

DEFAULT_INFILL_LIMITS :: Infill_Limits{
	max_scanlines = 1_000_000_000,
	max_segments = 1_000_000_000,
	polygon = polygon.DEFAULT_POLYGON_LIMITS,
}

Infill_Layer :: struct {
	segment_offset: u64,
	segment_count:  u32,
	axis:           Infill_Axis,
}

Infill_Segment :: struct {
	stable_id:           contracts.Stable_ID,
	region_id:           contracts.Stable_ID,
	region_index:        u32,
	layer_index:         u32,
	region_segment_index: u64,
	axis:                Infill_Axis,
	line_coordinate:     contracts.Micrometres,
	point_a:             polygon.Polygon_Point,
	point_b:             polygon.Polygon_Point,
	hit_offset:          u64,
}

Infill_Boundary_Hit :: struct {
	boundary_path_index: u32,
	boundary_edge_index: u32,
	numerator:           i128,
	denominator:         i128,
	rounded_coordinate:  contracts.Micrometres,
	error_numerator:     u128,
}

Infill_Result :: struct {
	config:         Infill_Config,
	layers:         []Infill_Layer,
	segments:       []Infill_Segment,
	boundary_hits:  []Infill_Boundary_Hit,
	scanline_count: u64,
}

Infill_Error :: enum u8 {
	None,
	Invalid_Config,
	Invalid_Input,
	Scanline_Limit,
	Segment_Limit,
	Provider,
	Odd_Intersection_Count,
	Allocation_Failed,
	Arithmetic,
}

Infill_Rational_Hit :: struct {
	numerator:           i128,
	denominator:         i128,
	rounded_coordinate:  contracts.Micrometres,
	error_numerator:     u128,
	boundary_path_index: u32,
	boundary_edge_index: u32,
}

infill_generate :: proc(
	topology: slicing.Topology_Result,
	regions: slicing.Region_Result,
	provider: polygon.Polygon_Provider,
	requested_config: Infill_Config,
	limits := DEFAULT_INFILL_LIMITS,
	allocator := context.allocator,
) -> (Infill_Result, Infill_Error) {
	config := requested_config
	if !infill_config_valid(config) || provider.offset == nil {
		return {}, .Invalid_Config
	}
	if config.arc_tolerance == 0 {config.arc_tolerance = 0}
	if len(regions.layers) != len(topology.layers) {
		return {}, .Invalid_Input
	}
	_, regions_ok := slicing.region_result_hash(
		contracts.Content_Hash{},
		topology,
		regions,
	)
	if !regions_ok {return {}, .Invalid_Input}
	if config.topology_policy == .Strict_Printable &&
	   (topology.open_chain_count > 0 ||
	    topology.degenerate_loop_count > 0 ||
	    topology.non_manifold_vertex_count > 0) {
		return {}, .Invalid_Input
	}
	if u64(len(regions.layers)) > u64(max(u32)) ||
	   u64(len(regions.regions)) > u64(max(u32)) {
		return {}, .Arithmetic
	}
	boundaries := make(
		[]polygon.Polygon_Set,
		len(regions.regions),
		allocator,
	)
	result := Infill_Result{config = config}
	result.layers = make(
		[]Infill_Layer,
		len(regions.layers),
		allocator,
	)
	if len(regions.regions) > 0 && boundaries == nil ||
	   len(regions.layers) > 0 && result.layers == nil {
		delete(boundaries, allocator)
		infill_result_destroy(&result, allocator)
		return {}, .Allocation_Failed
	}
	defer {
		for &boundary in boundaries {
			polygon.polygon_set_destroy(&boundary, allocator)
		}
		delete(boundaries, allocator)
	}

	maximum_boundary_points := 0
	for _, region_index in regions.regions {
		input, input_error := perimeter_region_input(
			topology,
			regions,
			u32(region_index),
			allocator,
		)
		if input_error != .None {
			infill_result_destroy(&result, allocator)
			#partial switch input_error {
			case .Allocation_Failed:
				return {}, .Allocation_Failed
			case .Arithmetic:
				return {}, .Arithmetic
			}
			return {}, .Invalid_Input
		}
		provider_error: polygon.Polygon_Error
		boundaries[region_index], provider_error = provider.offset(
			input,
			-contracts.Micrometres(i64(config.boundary_inset)),
			config.join_type,
			config.miter_limit,
			config.arc_tolerance,
			limits.polygon,
			allocator,
		)
		polygon.polygon_set_destroy(&input, allocator)
		if provider_error != .None {
			infill_result_destroy(&result, allocator)
			return {}, .Provider
		}
		maximum_boundary_points = max(
			maximum_boundary_points,
			len(boundaries[region_index].points),
		)
	}
	hits := make(
		[]Infill_Rational_Hit,
		maximum_boundary_points,
		allocator,
	)
	if maximum_boundary_points > 0 && hits == nil {
		infill_result_destroy(&result, allocator)
		return {}, .Allocation_Failed
	}
	defer delete(hits, allocator)

	segment_count: u64
	for region, region_index in regions.regions {
		axis := infill_layer_axis(config, region.layer_index)
		count, scanline_count, scan_error := infill_scan_region(
			boundaries[region_index],
			axis,
			config,
			hits,
			nil,
			nil,
			region,
			u32(region_index),
			0,
			limits,
		)
		if scan_error != .None {
			infill_result_destroy(&result, allocator)
			return {}, scan_error
		}
		if segment_count > limits.max_segments ||
		   count > limits.max_segments-segment_count {
			infill_result_destroy(&result, allocator)
			return {}, .Segment_Limit
		}
		if result.scanline_count > limits.max_scanlines ||
		   scanline_count >
		   	limits.max_scanlines-result.scanline_count {
			infill_result_destroy(&result, allocator)
			return {}, .Scanline_Limit
		}
		segment_count += count
		result.scanline_count += scanline_count
	}
	if segment_count > u64(max(int)) ||
	   segment_count > u64(max(int))/2 {
		infill_result_destroy(&result, allocator)
		return {}, .Arithmetic
	}
	result.segments = make(
		[]Infill_Segment,
		int(segment_count),
		allocator,
	)
	result.boundary_hits = make(
		[]Infill_Boundary_Hit,
		int(segment_count*2),
		allocator,
	)
	if segment_count > 0 &&
	   (result.segments == nil || result.boundary_hits == nil) {
		infill_result_destroy(&result, allocator)
		return {}, .Allocation_Failed
	}

	segment_write: u64
	layer_region_cursor := 0
	for region_layer, layer_index in regions.layers {
		layer_segment_start := segment_write
		region_end :=
			int(region_layer.region_offset)+int(region_layer.region_count)
		for layer_region_cursor < region_end {
			region := regions.regions[layer_region_cursor]
			axis := infill_layer_axis(config, region.layer_index)
			written, _, scan_error := infill_scan_region(
				boundaries[layer_region_cursor],
				axis,
				config,
				hits,
				result.segments,
				result.boundary_hits,
				region,
				u32(layer_region_cursor),
				segment_write,
				limits,
			)
			if scan_error != .None {
				infill_result_destroy(&result, allocator)
				return {}, scan_error
			}
			segment_write += written
			layer_region_cursor += 1
		}
		layer_segment_count := segment_write-layer_segment_start
		if layer_segment_count > u64(max(u32)) {
			infill_result_destroy(&result, allocator)
			return {}, .Arithmetic
		}
		result.layers[layer_index] = {
			segment_offset = layer_segment_start,
			segment_count = u32(layer_segment_count),
			axis = infill_layer_axis(config, u32(layer_index)),
		}
	}
	if segment_write != segment_count ||
	   layer_region_cursor != len(regions.regions) {
		infill_result_destroy(&result, allocator)
		return {}, .Arithmetic
	}
	return result, .None
}

infill_scan_region :: proc(
	boundary: polygon.Polygon_Set,
	axis: Infill_Axis,
	config: Infill_Config,
	hits: []Infill_Rational_Hit,
	segments: []Infill_Segment,
	boundary_hits: []Infill_Boundary_Hit,
	region: slicing.Region,
	region_index: u32,
	segment_offset: u64,
	limits: Infill_Limits,
) -> (
	segment_count: u64,
	scanline_count: u64,
	error: Infill_Error,
) {
	if len(boundary.points) == 0 {return}
	minimum, maximum := infill_boundary_axis_bounds(boundary, axis)
	line, line_ok := infill_first_scanline(
		minimum,
		config.phase,
		config.spacing,
	)
	if !line_ok {error = .Arithmetic; return}
	region_segment_index: u64
	for i128(i64(line)) < i128(i64(maximum)) {
		if scanline_count >= limits.max_scanlines {
			error = .Scanline_Limit
			return
		}
		scanline_count += 1
		hit_count, hit_error := infill_collect_hits(
			boundary,
			axis,
			line,
			hits,
		)
		if hit_error != .None {error = hit_error; return}
		if hit_count&1 != 0 {
			error = .Odd_Intersection_Count
			return
		}
		hit_index := 0
		for hit_index < hit_count {
			first := hits[hit_index]
			second := hits[hit_index+1]
			if first.rounded_coordinate ==
			   second.rounded_coordinate {
				hit_index += 2
				continue
			}
			if segment_count >= limits.max_segments {
				error = .Segment_Limit
				return
			}
			ordinal, ordinal_ok :=
				feature_infill_ordinal(region_segment_index)
			if !ordinal_ok {
				error = .Arithmetic
				return
			}
			if segments != nil {
				write_index := segment_offset+segment_count
				if write_index >= u64(len(segments)) ||
				   write_index*2+1 >= u64(len(boundary_hits)) {
					error = .Arithmetic
					return
				}
				point_a, point_b := infill_segment_points(
					axis,
					line,
					first.rounded_coordinate,
					second.rounded_coordinate,
				)
				segments[write_index] = {
					stable_id = contracts.stable_id_child(
						region.stable_id,
						.Feature,
						ordinal,
					),
					region_id = region.stable_id,
					region_index = region_index,
					layer_index = region.layer_index,
					region_segment_index = region_segment_index,
					axis = axis,
					line_coordinate = line,
					point_a = point_a,
					point_b = point_b,
					hit_offset = write_index*2,
				}
				boundary_hits[write_index*2] =
					infill_boundary_hit(first)
				boundary_hits[write_index*2+1] =
					infill_boundary_hit(second)
			}
			segment_count += 1
			region_segment_index += 1
			hit_index += 2
		}
		next := i128(i64(line))+i128(i64(config.spacing))
		if next > i128(geometry.MAX_PLANAR_COORDINATE_UM) {
			break
		}
		line = contracts.Micrometres(i64(next))
	}
	return
}

infill_collect_hits :: proc(
	boundary: polygon.Polygon_Set,
	axis: Infill_Axis,
	line: contracts.Micrometres,
	hits: []Infill_Rational_Hit,
) -> (int, Infill_Error) {
	hit_count := 0
	for path, path_index in boundary.paths {
		start := int(path.offset)
		for edge_index in 0..<int(path.count) {
			a := boundary.points[start+edge_index]
			b := boundary.points[
				start+(edge_index+1)%int(path.count)
			]
			numerator, denominator, crosses :=
				infill_edge_intersection(a, b, axis, line)
			if !crosses {continue}
			if hit_count >= len(hits) {
				return 0, .Arithmetic
			}
			rounded, error_numerator, round_ok :=
				infill_rational_round(numerator, denominator)
			if !round_ok {return 0, .Arithmetic}
			hits[hit_count] = {
				numerator = numerator,
				denominator = denominator,
				rounded_coordinate = rounded,
				error_numerator = error_numerator,
				boundary_path_index = u32(path_index),
				boundary_edge_index = u32(edge_index),
			}
			hit_count += 1
		}
	}
	slice.sort_by(hits[:hit_count], infill_rational_hit_less)
	return hit_count, .None
}

infill_edge_intersection :: proc(
	a, b: polygon.Polygon_Point,
	axis: Infill_Axis,
	line: contracts.Micrometres,
) -> (numerator, denominator: i128, crosses: bool) {
	a_fixed, b_fixed := i64(a.x), i64(b.x)
	a_variable, b_variable := i64(a.y), i64(b.y)
	if axis == .Horizontal {
		a_fixed, b_fixed = i64(a.y), i64(b.y)
		a_variable, b_variable = i64(a.x), i64(b.x)
	}
	line_value := i64(line)
	if !((a_fixed <= line_value && line_value < b_fixed) ||
	     (b_fixed <= line_value && line_value < a_fixed)) {
		return
	}
	denominator = i128(b_fixed)-i128(a_fixed)
	numerator = i128(a_variable)*denominator+
		(i128(line_value)-i128(a_fixed))*
		(i128(b_variable)-i128(a_variable))
	if denominator < 0 {
		numerator = -numerator
		denominator = -denominator
	}
	crosses = true
	return
}

infill_rational_round :: proc(
	numerator, denominator: i128,
) -> (contracts.Micrometres, u128, bool) {
	if denominator <= 0 || numerator == min(i128) {
		return 0, 0, false
	}
	negative := numerator < 0
	magnitude := numerator
	if negative {magnitude = -magnitude}
	if magnitude > max(i128)-denominator/2 {
		return 0, 0, false
	}
	rounded_magnitude := (magnitude+denominator/2)/denominator
	rounded := rounded_magnitude
	if negative {rounded = -rounded}
	if rounded < -i128(geometry.MAX_PLANAR_COORDINATE_UM) ||
	   rounded > i128(geometry.MAX_PLANAR_COORDINATE_UM) {
		return 0, 0, false
	}
	error := numerator-rounded*denominator
	if error < 0 {error = -error}
	return contracts.Micrometres(i64(rounded)), u128(error), true
}

infill_rational_hit_less :: proc(
	a, b: Infill_Rational_Hit,
) -> bool {
	left := a.numerator*b.denominator
	right := b.numerator*a.denominator
	if left != right {return left < right}
	if a.boundary_path_index != b.boundary_path_index {
		return a.boundary_path_index < b.boundary_path_index
	}
	return a.boundary_edge_index < b.boundary_edge_index
}

infill_boundary_axis_bounds :: proc(
	boundary: polygon.Polygon_Set,
	axis: Infill_Axis,
) -> (contracts.Micrometres, contracts.Micrometres) {
	first := boundary.points[0].x
	if axis == .Horizontal {first = boundary.points[0].y}
	minimum, maximum := first, first
	for point in boundary.points[1:] {
		value := point.x
		if axis == .Horizontal {value = point.y}
		minimum = min(minimum, value)
		maximum = max(maximum, value)
	}
	return minimum, maximum
}

infill_first_scanline :: proc(
	minimum, phase, spacing: contracts.Micrometres,
) -> (contracts.Micrometres, bool) {
	if i64(spacing) <= 0 ||
	   i64(minimum) < -geometry.MAX_PLANAR_COORDINATE_UM ||
	   i64(minimum) > geometry.MAX_PLANAR_COORDINATE_UM ||
	   i64(phase) < -geometry.MAX_PLANAR_COORDINATE_UM ||
	   i64(phase) > geometry.MAX_PLANAR_COORDINATE_UM {
		return 0, false
	}
	numerator := i128(i64(minimum))-i128(i64(phase))
	denominator := i128(i64(spacing))
	quotient := numerator/denominator
	remainder := numerator%denominator
	if remainder < 0 {quotient -= 1}
	line := i128(i64(phase))+(quotient+1)*denominator
	if line < -i128(geometry.MAX_PLANAR_COORDINATE_UM) ||
	   line > i128(geometry.MAX_PLANAR_COORDINATE_UM) {
		return 0, false
	}
	return contracts.Micrometres(i64(line)), true
}

infill_layer_axis :: proc(
	config: Infill_Config,
	layer_index: u32,
) -> Infill_Axis {
	if !config.alternate_each_layer || layer_index&1 == 0 {
		return config.base_axis
	}
	if config.base_axis == .Vertical {return .Horizontal}
	return .Vertical
}

infill_segment_points :: proc(
	axis: Infill_Axis,
	line, first, second: contracts.Micrometres,
) -> (polygon.Polygon_Point, polygon.Polygon_Point) {
	if axis == .Vertical {
		return {line, first}, {line, second}
	}
	return {first, line}, {second, line}
}

infill_boundary_hit :: proc(
	hit: Infill_Rational_Hit,
) -> Infill_Boundary_Hit {
	return {
		boundary_path_index = hit.boundary_path_index,
		boundary_edge_index = hit.boundary_edge_index,
		numerator = hit.numerator,
		denominator = hit.denominator,
		rounded_coordinate = hit.rounded_coordinate,
		error_numerator = hit.error_numerator,
	}
}

infill_config_valid :: proc(config: Infill_Config) -> bool {
	return i64(config.spacing) > 0 &&
		i64(config.spacing) <= geometry.MAX_PLANAR_COORDINATE_UM &&
		i64(config.boundary_inset) > 0 &&
		i64(config.boundary_inset) <=
			geometry.MAX_PLANAR_COORDINATE_UM &&
		i64(config.phase) >= 0 &&
		i64(config.phase) < i64(config.spacing) &&
		(config.base_axis == .Vertical ||
		 config.base_axis == .Horizontal) &&
		perimeter_config_valid({
			count = 1,
			line_width = 2,
			topology_policy = config.topology_policy,
			join_type = config.join_type,
			miter_limit = config.miter_limit,
			arc_tolerance = config.arc_tolerance,
		})
}

infill_result_destroy :: proc(
	result: ^Infill_Result,
	allocator := context.allocator,
) {
	delete(result.layers, allocator)
	delete(result.segments, allocator)
	delete(result.boundary_hits, allocator)
	result^ = {}
}

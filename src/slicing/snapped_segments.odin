package slicing

import "core:math"
import "core:mem"
import "core:slice"

import contracts "../contracts"
import geometry "../geometry"

ENDPOINT_SNAP_GRID_UM :: contracts.Micrometres(1)

Snapped_Layer :: struct {
	offset: u64,
	count:  u32,
}

Snapped_Segment_SoA :: struct {
	layer_indices:    []u32,
	triangle_indices: []u32,
	segment_ids:      []contracts.Stable_ID,
	triangle_ids:     []contracts.Stable_ID,
	edge_a:           []Triangle_Edge,
	edge_b:           []Triangle_Edge,
	x0:               []contracts.Micrometres,
	y0:               []contracts.Micrometres,
	x1:               []contracts.Micrometres,
	y1:               []contracts.Micrometres,
	x0_error_um:      []f64,
	y0_error_um:      []f64,
	x1_error_um:      []f64,
	y1_error_um:      []f64,
}

Snapped_Segment_Result :: struct {
	layers:                []Snapped_Layer,
	segments:              Snapped_Segment_SoA,
	collapsed_count:       u64,
	maximum_snap_error_um: f64,
}

Snapped_Segment_Error :: enum u8 {
	None,
	Invalid_Input,
	Coordinate_Range,
	Allocation_Failed,
}

Snapped_Point :: struct {
	x: contracts.Micrometres,
	y: contracts.Micrometres,
}

Snapped_Segment_Evaluation :: struct {
	point_a:     Snapped_Point,
	point_b:     Snapped_Point,
	edge_a:      Triangle_Edge,
	edge_b:      Triangle_Edge,
	x0_error_um: f64,
	y0_error_um: f64,
	x1_error_um: f64,
	y1_error_um: f64,
	collapsed:   bool,
}

Snapped_Segment_Record :: struct {
	layer_index:    u32,
	triangle_index: u32,
	segment_id:     contracts.Stable_ID,
	triangle_id:    contracts.Stable_ID,
	edge_a:         Triangle_Edge,
	edge_b:         Triangle_Edge,
	point_a:        Snapped_Point,
	point_b:        Snapped_Point,
	x0_error_um:    f64,
	y0_error_um:    f64,
	x1_error_um:    f64,
	y1_error_um:    f64,
}

// Snaps every raw segment to the micrometre grid, drops the ones that collapse to a point, and
// sorts each layer. Layers are independent, so they run on the worker threads; the result does not
// depend on the thread count.
snapped_segments_build :: proc(
	raw: CPU_Intersection_Result,
	allocator := context.allocator,
) -> (Snapped_Segment_Result, Snapped_Segment_Error) {
	segment_count := len(raw.segments.segment_ids)
	layer_count := len(raw.layers)
	if layer_count == 0 || !raw_segment_soa_shape_valid(
		raw.segments,
		segment_count,
	) {
		return {}, .Invalid_Input
	}
	// The layers must tile the segment array in order. `tiled` is the number of layers before the
	// first one that does not, so that errors are reported in layer order as a serial pass would.
	tiled := layer_count
	expected_offset: u64
	for layer, layer_index in raw.layers {
		if layer.segment_offset != expected_offset ||
		   u64(layer.segment_count) > u64(segment_count)-expected_offset {
			tiled = layer_index
			break
		}
		expected_offset += u64(layer.segment_count)
	}

	Count_Context :: struct {
		raw:       CPU_Intersection_Result,
		kept:      []u64,
		collapsed: []u64,
		max_error: []f64,
		errors:    []Snapped_Segment_Error,
	}
	count_ctx := Count_Context{
		raw       = raw,
		kept      = make([]u64, tiled, allocator),
		collapsed = make([]u64, tiled, allocator),
		max_error = make([]f64, tiled, allocator),
		errors    = make([]Snapped_Segment_Error, tiled, allocator),
	}
	defer {
		delete(count_ctx.kept, allocator)
		delete(count_ctx.collapsed, allocator)
		delete(count_ctx.max_error, allocator)
		delete(count_ctx.errors, allocator)
	}
	if tiled > 0 && (count_ctx.kept == nil || count_ctx.collapsed == nil ||
	   count_ctx.max_error == nil || count_ctx.errors == nil) {
		return {}, .Allocation_Failed
	}
	slicing_parallel_for(tiled, &count_ctx, proc(c: ^Count_Context, layer_index: int) {
		layer := c.raw.layers[layer_index]
		segments := c.raw.segments
		for local_segment in 0..<int(layer.segment_count) {
			segment_index := int(layer.segment_offset)+local_segment
			if segments.layer_indices[segment_index] != u32(layer_index) ||
			   segments.segment_ids[segment_index] == contracts.INVALID_STABLE_ID ||
			   segments.triangle_ids[segment_index] == contracts.INVALID_STABLE_ID {
				c.errors[layer_index] = .Invalid_Input
				return
			}
			evaluation, error := snapped_segment_evaluate(segments, segment_index)
			if error != .None {
				c.errors[layer_index] = error
				return
			}
			c.max_error[layer_index] = max(c.max_error[layer_index], snapped_segment_maximum_error(evaluation))
			if evaluation.collapsed {
				c.collapsed[layer_index] += 1
			} else {
				c.kept[layer_index] += 1
			}
		}
	})

	result: Snapped_Segment_Result
	output_count: u64
	for layer_index in 0..<tiled {
		if count_ctx.errors[layer_index] != .None {return {}, count_ctx.errors[layer_index]}
		result.maximum_snap_error_um = max(result.maximum_snap_error_um, count_ctx.max_error[layer_index])
		result.collapsed_count += count_ctx.collapsed[layer_index]
		output_count += count_ctx.kept[layer_index]
	}
	if tiled < layer_count || expected_offset != u64(segment_count) {return {}, .Invalid_Input}
	if output_count > u64(max(int)) {return {}, .Allocation_Failed}

	result.layers = make([]Snapped_Layer, layer_count, allocator)
	if result.layers == nil {return {}, .Allocation_Failed}
	output_offset: u64
	for kept, layer_index in count_ctx.kept {
		if kept > u64(max(u32)) {
			snapped_segments_destroy(&result, allocator)
			return {}, .Allocation_Failed
		}
		result.layers[layer_index] = {offset = output_offset, count = u32(kept)}
		output_offset += kept
	}
	records := make([]Snapped_Segment_Record, int(output_count), allocator)
	if output_count > 0 && records == nil {
		snapped_segments_destroy(&result, allocator)
		return {}, .Allocation_Failed
	}
	defer delete(records, allocator)
	if !snapped_segment_soa_allocate(&result.segments, int(output_count), allocator) {
		snapped_segments_destroy(&result, allocator)
		return {}, .Allocation_Failed
	}

	Write_Context :: struct {
		raw:     CPU_Intersection_Result,
		layers:  []Snapped_Layer,
		records: []Snapped_Segment_Record,
		output:  ^Snapped_Segment_SoA,
	}
	write_ctx := Write_Context{raw = raw, layers = result.layers, records = records, output = &result.segments}
	slicing_parallel_for(layer_count, &write_ctx, proc(c: ^Write_Context, layer_index: int) {
		layer := c.raw.layers[layer_index]
		start := int(c.layers[layer_index].offset)
		end := start+int(c.layers[layer_index].count)
		write_index := start
		for local_segment in 0..<int(layer.segment_count) {
			source_index := int(layer.segment_offset)+local_segment
			evaluation, error := snapped_segment_evaluate(c.raw.segments, source_index)
			assert(error == .None, "the counting pass accepted every segment")
			if evaluation.collapsed {continue}
			c.records[write_index] = snapped_segment_record_make(c.raw.segments, source_index, evaluation)
			write_index += 1
		}
		assert(write_index == end)
		slice.sort_by(c.records[start:end], snapped_segment_record_less)
		for index in start..<end {snapped_segment_record_write(c.output, index, c.records[index])}
	})
	return result, .None
}

// Joins two snapped results layer by layer and sorts each layer. Layers run on the worker threads.
snapped_segments_merge :: proc(
	left, right: Snapped_Segment_Result,
	allocator := context.allocator,
) -> (Snapped_Segment_Result, Snapped_Segment_Error) {
	layer_count := len(left.layers)
	left_count := len(left.segments.segment_ids)
	right_count := len(right.segments.segment_ids)
	if layer_count == 0 || len(right.layers) != layer_count ||
	   !snapped_segment_soa_shape_valid(left.segments, left_count) ||
	   !snapped_segment_soa_shape_valid(right.segments, right_count) ||
	   left_count > max(int)-right_count ||
	   !snapped_segment_layers_valid(left) ||
	   !snapped_segment_layers_valid(right) {
		return {}, .Invalid_Input
	}
	total_count := left_count+right_count
	result: Snapped_Segment_Result
	result.layers = make([]Snapped_Layer, layer_count, allocator)
	records := make([]Snapped_Segment_Record, total_count, allocator)
	if result.layers == nil || (total_count > 0 && records == nil) {
		delete(records, allocator)
		snapped_segments_destroy(&result, allocator)
		return {}, .Allocation_Failed
	}
	defer delete(records, allocator)
	result.collapsed_count = left.collapsed_count+right.collapsed_count
	result.maximum_snap_error_um = max(
		left.maximum_snap_error_um,
		right.maximum_snap_error_um,
	)
	record_write: u64
	for layer_index in 0..<layer_count {
		combined_count := u64(left.layers[layer_index].count)+u64(right.layers[layer_index].count)
		if combined_count > u64(max(u32)) {
			snapped_segments_destroy(&result, allocator)
			return {}, .Allocation_Failed
		}
		result.layers[layer_index] = {offset = record_write, count = u32(combined_count)}
		record_write += combined_count
	}
	if record_write != u64(total_count) {
		snapped_segments_destroy(&result, allocator)
		return {}, .Invalid_Input
	}
	if !snapped_segment_soa_allocate(&result.segments, total_count, allocator) {
		snapped_segments_destroy(&result, allocator)
		return {}, .Allocation_Failed
	}

	Merge_Context :: struct {
		left, right: Snapped_Segment_Result,
		layers:      []Snapped_Layer,
		records:     []Snapped_Segment_Record,
		output:      ^Snapped_Segment_SoA,
	}
	merge_ctx := Merge_Context{left = left, right = right, layers = result.layers, records = records, output = &result.segments}
	slicing_parallel_for(layer_count, &merge_ctx, proc(c: ^Merge_Context, layer_index: int) {
		start := int(c.layers[layer_index].offset)
		end := start+int(c.layers[layer_index].count)
		write_index := start
		sources := [2]Snapped_Segment_Result{c.left, c.right}
		for source in sources {
			layer := source.layers[layer_index]
			for local_segment in 0..<int(layer.count) {
				c.records[write_index] = snapped_segment_record_from_soa(source.segments, int(layer.offset)+local_segment)
				write_index += 1
			}
		}
		assert(write_index == end)
		slice.sort_by(c.records[start:end], snapped_segment_record_less)
		for index in start..<end {snapped_segment_record_write(c.output, index, c.records[index])}
	})
	return result, .None
}

snapped_segment_evaluate :: proc(
	raw: Raw_Segment_SoA,
	index: int,
) -> (Snapped_Segment_Evaluation, Snapped_Segment_Error) {
	x0, x0_error := geometry.millimetres_to_micrometres(
		contracts.Millimetres(raw.x0[index]),
	)
	y0, y0_error := geometry.millimetres_to_micrometres(
		contracts.Millimetres(raw.y0[index]),
	)
	x1, x1_error := geometry.millimetres_to_micrometres(
		contracts.Millimetres(raw.x1[index]),
	)
	y1, y1_error := geometry.millimetres_to_micrometres(
		contracts.Millimetres(raw.y1[index]),
	)
	if x0_error != .None || y0_error != .None ||
	   x1_error != .None || y1_error != .None {
		return {}, .Coordinate_Range
	}
	evaluation := Snapped_Segment_Evaluation{
		point_a = {x0, y0},
		point_b = {x1, y1},
		edge_a = raw.edge_a[index],
		edge_b = raw.edge_b[index],
		x0_error_um = f64(x0)-raw.x0[index]*1000,
		y0_error_um = f64(y0)-raw.y0[index]*1000,
		x1_error_um = f64(x1)-raw.x1[index]*1000,
		y1_error_um = f64(y1)-raw.y1[index]*1000,
	}
	if snapped_point_less(evaluation.point_b, evaluation.point_a) {
		evaluation.point_a, evaluation.point_b =
			evaluation.point_b, evaluation.point_a
		evaluation.edge_a, evaluation.edge_b =
			evaluation.edge_b, evaluation.edge_a
		evaluation.x0_error_um, evaluation.x1_error_um =
			evaluation.x1_error_um, evaluation.x0_error_um
		evaluation.y0_error_um, evaluation.y1_error_um =
			evaluation.y1_error_um, evaluation.y0_error_um
	}
	evaluation.collapsed = evaluation.point_a == evaluation.point_b
	return evaluation, .None
}

snapped_point_less :: proc(a, b: Snapped_Point) -> bool {
	return a.x < b.x || (a.x == b.x && a.y < b.y)
}

snapped_segment_maximum_error :: proc(
	evaluation: Snapped_Segment_Evaluation,
) -> f64 {
	return max(
		max(
			math.abs(evaluation.x0_error_um),
			math.abs(evaluation.y0_error_um),
		),
		max(
			math.abs(evaluation.x1_error_um),
			math.abs(evaluation.y1_error_um),
		),
	)
}

snapped_segment_record_make :: proc(
	raw: Raw_Segment_SoA,
	source_index: int,
	evaluation: Snapped_Segment_Evaluation,
) -> Snapped_Segment_Record {
	return {
		layer_index = raw.layer_indices[source_index],
		triangle_index = raw.triangle_indices[source_index],
		segment_id = raw.segment_ids[source_index],
		triangle_id = raw.triangle_ids[source_index],
		edge_a = evaluation.edge_a,
		edge_b = evaluation.edge_b,
		point_a = evaluation.point_a,
		point_b = evaluation.point_b,
		x0_error_um = evaluation.x0_error_um,
		y0_error_um = evaluation.y0_error_um,
		x1_error_um = evaluation.x1_error_um,
		y1_error_um = evaluation.y1_error_um,
	}
}

snapped_segment_record_from_soa :: proc(
	segments: Snapped_Segment_SoA,
	index: int,
) -> Snapped_Segment_Record {
	return {
		layer_index = segments.layer_indices[index],
		triangle_index = segments.triangle_indices[index],
		segment_id = segments.segment_ids[index],
		triangle_id = segments.triangle_ids[index],
		edge_a = segments.edge_a[index],
		edge_b = segments.edge_b[index],
		point_a = {segments.x0[index], segments.y0[index]},
		point_b = {segments.x1[index], segments.y1[index]},
		x0_error_um = segments.x0_error_um[index],
		y0_error_um = segments.y0_error_um[index],
		x1_error_um = segments.x1_error_um[index],
		y1_error_um = segments.y1_error_um[index],
	}
}

snapped_segment_record_less :: proc(
	a, b: Snapped_Segment_Record,
) -> bool {
	if a.point_a.x != b.point_a.x {return a.point_a.x < b.point_a.x}
	if a.point_a.y != b.point_a.y {return a.point_a.y < b.point_a.y}
	if a.point_b.x != b.point_b.x {return a.point_b.x < b.point_b.x}
	if a.point_b.y != b.point_b.y {return a.point_b.y < b.point_b.y}
	if a.triangle_id != b.triangle_id {
		return u64(a.triangle_id) < u64(b.triangle_id)
	}
	if a.edge_a != b.edge_a {return a.edge_a < b.edge_a}
	if a.edge_b != b.edge_b {return a.edge_b < b.edge_b}
	return u64(a.segment_id) < u64(b.segment_id)
}

snapped_segment_record_write :: proc(
	output: ^Snapped_Segment_SoA,
	write_index: int,
	record: Snapped_Segment_Record,
) {
	output.layer_indices[write_index] = record.layer_index
	output.triangle_indices[write_index] = record.triangle_index
	output.segment_ids[write_index] = record.segment_id
	output.triangle_ids[write_index] = record.triangle_id
	output.edge_a[write_index] = record.edge_a
	output.edge_b[write_index] = record.edge_b
	output.x0[write_index] = record.point_a.x
	output.y0[write_index] = record.point_a.y
	output.x1[write_index] = record.point_b.x
	output.y1[write_index] = record.point_b.y
	output.x0_error_um[write_index] = record.x0_error_um
	output.y0_error_um[write_index] = record.y0_error_um
	output.x1_error_um[write_index] = record.x1_error_um
	output.y1_error_um[write_index] = record.y1_error_um
}

raw_segment_soa_shape_valid :: proc(
	segments: Raw_Segment_SoA,
	count: int,
) -> bool {
	return len(segments.layer_indices) == count &&
		len(segments.triangle_indices) == count &&
		len(segments.triangle_ids) == count &&
		len(segments.edge_a) == count &&
		len(segments.edge_b) == count &&
		len(segments.x0) == count &&
		len(segments.y0) == count &&
		len(segments.x1) == count &&
		len(segments.y1) == count
}

snapped_segment_soa_shape_valid :: proc(
	segments: Snapped_Segment_SoA,
	count: int,
) -> bool {
	return len(segments.layer_indices) == count &&
		len(segments.triangle_indices) == count &&
		len(segments.triangle_ids) == count &&
		len(segments.edge_a) == count &&
		len(segments.edge_b) == count &&
		len(segments.x0) == count &&
		len(segments.y0) == count &&
		len(segments.x1) == count &&
		len(segments.y1) == count &&
		len(segments.x0_error_um) == count &&
		len(segments.y0_error_um) == count &&
		len(segments.x1_error_um) == count &&
		len(segments.y1_error_um) == count
}

snapped_segment_layers_valid :: proc(result: Snapped_Segment_Result) -> bool {
	segment_count := len(result.segments.segment_ids)
	expected_offset: u64
	for layer, layer_index in result.layers {
		if layer.offset != expected_offset ||
		   u64(layer.count) > u64(segment_count)-expected_offset {
			return false
		}
		for local_segment in 0..<int(layer.count) {
			segment_index := int(layer.offset)+local_segment
			if result.segments.layer_indices[segment_index] !=
			   	u32(layer_index) {
				return false
			}
		}
		expected_offset += u64(layer.count)
	}
	return expected_offset == u64(segment_count)
}

snapped_segment_soa_allocate :: proc(
	segments: ^Snapped_Segment_SoA,
	count: int,
	allocator: mem.Allocator,
) -> bool {
	segments.layer_indices = make([]u32, count, allocator)
	segments.triangle_indices = make([]u32, count, allocator)
	segments.segment_ids = make([]contracts.Stable_ID, count, allocator)
	segments.triangle_ids = make([]contracts.Stable_ID, count, allocator)
	segments.edge_a = make([]Triangle_Edge, count, allocator)
	segments.edge_b = make([]Triangle_Edge, count, allocator)
	segments.x0 = make([]contracts.Micrometres, count, allocator)
	segments.y0 = make([]contracts.Micrometres, count, allocator)
	segments.x1 = make([]contracts.Micrometres, count, allocator)
	segments.y1 = make([]contracts.Micrometres, count, allocator)
	segments.x0_error_um = make([]f64, count, allocator)
	segments.y0_error_um = make([]f64, count, allocator)
	segments.x1_error_um = make([]f64, count, allocator)
	segments.y1_error_um = make([]f64, count, allocator)
	if count == 0 {return true}
	return segments.layer_indices != nil &&
		segments.triangle_indices != nil &&
		segments.segment_ids != nil &&
		segments.triangle_ids != nil &&
		segments.edge_a != nil &&
		segments.edge_b != nil &&
		segments.x0 != nil &&
		segments.y0 != nil &&
		segments.x1 != nil &&
		segments.y1 != nil &&
		segments.x0_error_um != nil &&
		segments.y0_error_um != nil &&
		segments.x1_error_um != nil &&
		segments.y1_error_um != nil
}

snapped_segments_destroy :: proc(
	result: ^Snapped_Segment_Result,
	allocator := context.allocator,
) {
	delete(result.layers, allocator)
	delete(result.segments.layer_indices, allocator)
	delete(result.segments.triangle_indices, allocator)
	delete(result.segments.segment_ids, allocator)
	delete(result.segments.triangle_ids, allocator)
	delete(result.segments.edge_a, allocator)
	delete(result.segments.edge_b, allocator)
	delete(result.segments.x0, allocator)
	delete(result.segments.y0, allocator)
	delete(result.segments.x1, allocator)
	delete(result.segments.y1, allocator)
	delete(result.segments.x0_error_um, allocator)
	delete(result.segments.y0_error_um, allocator)
	delete(result.segments.x1_error_um, allocator)
	delete(result.segments.y1_error_um, allocator)
	result^ = {}
}

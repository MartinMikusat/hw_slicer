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
	result: Snapped_Segment_Result
	result.layers = make([]Snapped_Layer, layer_count, allocator)
	layer_counts := make([]u64, layer_count, allocator)
	if result.layers == nil || layer_counts == nil {
		delete(layer_counts, allocator)
		snapped_segments_destroy(&result, allocator)
		return {}, .Allocation_Failed
	}
	defer delete(layer_counts, allocator)

	expected_offset: u64
	output_count: u64
	for layer, layer_index in raw.layers {
		if layer.segment_offset != expected_offset ||
		   u64(layer.segment_count) > u64(segment_count)-expected_offset {
			snapped_segments_destroy(&result, allocator)
			return {}, .Invalid_Input
		}
		expected_offset += u64(layer.segment_count)
		for local_segment in 0..<int(layer.segment_count) {
			segment_index := int(layer.segment_offset)+local_segment
			if raw.segments.layer_indices[segment_index] != u32(layer_index) ||
			   raw.segments.segment_ids[segment_index] ==
			   	contracts.INVALID_STABLE_ID ||
			   raw.segments.triangle_ids[segment_index] ==
			   	contracts.INVALID_STABLE_ID {
				snapped_segments_destroy(&result, allocator)
				return {}, .Invalid_Input
			}
			evaluation, error := snapped_segment_evaluate(
				raw.segments,
				segment_index,
			)
			if error != .None {
				snapped_segments_destroy(&result, allocator)
				return {}, error
			}
			result.maximum_snap_error_um = max(
				result.maximum_snap_error_um,
				snapped_segment_maximum_error(evaluation),
			)
			if evaluation.collapsed {
				result.collapsed_count += 1
				continue
			}
			output_count += 1
			layer_counts[layer_index] += 1
		}
	}
	if expected_offset != u64(segment_count) {
		snapped_segments_destroy(&result, allocator)
		return {}, .Invalid_Input
	}
	if output_count > u64(max(int)) {
		snapped_segments_destroy(&result, allocator)
		return {}, .Allocation_Failed
	}

	output_offset: u64
	for layer_count_value, layer_index in layer_counts {
		if layer_count_value > u64(max(u32)) {
			snapped_segments_destroy(&result, allocator)
			return {}, .Allocation_Failed
		}
		result.layers[layer_index] = {
			offset = output_offset,
			count = u32(layer_count_value),
		}
		output_offset += layer_count_value
	}
	records := make([]Snapped_Segment_Record, int(output_count), allocator)
	if output_count > 0 && records == nil {
		snapped_segments_destroy(&result, allocator)
		return {}, .Allocation_Failed
	}
	defer delete(records, allocator)
	layer_cursors := make([]u64, layer_count, allocator)
	if layer_cursors == nil {
		snapped_segments_destroy(&result, allocator)
		return {}, .Allocation_Failed
	}
	defer delete(layer_cursors, allocator)
	for layer, layer_index in result.layers {
		layer_cursors[layer_index] = layer.offset
	}
	for layer, layer_index in raw.layers {
		for local_segment in 0..<int(layer.segment_count) {
			source_index := int(layer.segment_offset)+local_segment
			evaluation, error := snapped_segment_evaluate(
				raw.segments,
				source_index,
			)
			if error != .None {
				snapped_segments_destroy(&result, allocator)
				return {}, error
			}
			if evaluation.collapsed {continue}
			write_index := int(layer_cursors[layer_index])
			records[write_index] = snapped_segment_record_make(
				raw.segments,
				source_index,
				evaluation,
			)
			layer_cursors[layer_index] += 1
		}
	}
	for layer in result.layers {
		start := int(layer.offset)
		end := start+int(layer.count)
		slice.sort_by(records[start:end], snapped_segment_record_less)
	}
	if !snapped_segment_soa_allocate(
		&result.segments,
		int(output_count),
		allocator,
	) {
		snapped_segments_destroy(&result, allocator)
		return {}, .Allocation_Failed
	}
	for record, write_index in records {
		snapped_segment_record_write(&result.segments, write_index, record)
	}
	return result, .None
}

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
	record_write := 0
	for layer_index in 0..<layer_count {
		result.layers[layer_index].offset = u64(record_write)
		left_layer := left.layers[layer_index]
		right_layer := right.layers[layer_index]
		combined_count := u64(left_layer.count)+u64(right_layer.count)
		if combined_count > u64(max(u32)) {
			snapped_segments_destroy(&result, allocator)
			return {}, .Allocation_Failed
		}
		result.layers[layer_index].count = u32(combined_count)
		for local_segment in 0..<int(left_layer.count) {
			source_index := int(left_layer.offset)+local_segment
			records[record_write] = snapped_segment_record_from_soa(
				left.segments,
				source_index,
			)
			record_write += 1
		}
		for local_segment in 0..<int(right_layer.count) {
			source_index := int(right_layer.offset)+local_segment
			records[record_write] = snapped_segment_record_from_soa(
				right.segments,
				source_index,
			)
			record_write += 1
		}
		start := int(result.layers[layer_index].offset)
		slice.sort_by(
			records[start:record_write],
			snapped_segment_record_less,
		)
	}
	if record_write != total_count {
		snapped_segments_destroy(&result, allocator)
		return {}, .Invalid_Input
	}
	if !snapped_segment_soa_allocate(
		&result.segments,
		total_count,
		allocator,
	) {
		snapped_segments_destroy(&result, allocator)
		return {}, .Allocation_Failed
	}
	for record, write_index in records {
		snapped_segment_record_write(&result.segments, write_index, record)
	}
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

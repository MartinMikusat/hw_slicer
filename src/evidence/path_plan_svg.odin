package evidence

import "core:fmt"
import "core:strings"

import features "../features"

PATH_PLAN_SVG_SCHEMA_VERSION :: u32(1)

Path_Plan_SVG_Limits :: struct {
	max_moves: u64,
	max_bytes: u64,
}

DEFAULT_PATH_PLAN_SVG_LIMITS :: Path_Plan_SVG_Limits{
	max_moves = 250_000,
	max_bytes = 64*1024*1024,
}

Path_Plan_SVG_Error :: enum u8 {
	None,
	Invalid_Artifact,
	Layer_Out_Of_Range,
	Empty_Layer,
	Move_Limit,
	Byte_Limit,
	Allocation_Failed,
}

path_plan_svg_render_layer :: proc(
	artifact: Path_Plan_Artifact,
	layer_index: u32,
	limits := DEFAULT_PATH_PLAN_SVG_LIMITS,
	allocator := context.allocator,
) -> ([]u8, Path_Plan_SVG_Error) {
	calculated_hash, hash_ok := features.path_plan_result_hash(
		artifact.perimeter_hash,
		artifact.infill_hash,
		artifact.result,
	)
	if !hash_ok || calculated_hash != artifact.result_hash {
		return nil, .Invalid_Artifact
	}
	if u64(layer_index) >= u64(len(artifact.result.layers)) {
		return nil, .Layer_Out_Of_Range
	}
	layer := artifact.result.layers[layer_index]
	if layer.move_count == 0 {return nil, .Empty_Layer}
	if u64(layer.move_count) > limits.max_moves {
		return nil, .Move_Limit
	}
	estimated_byte_count := u64(4096)
	if u64(layer.move_count) > (max(u64)-estimated_byte_count)/240 {
		return nil, .Byte_Limit
	}
	estimated_byte_count += u64(layer.move_count)*240
	if estimated_byte_count > limits.max_bytes ||
	   estimated_byte_count > u64(max(int)) {
		return nil, .Byte_Limit
	}

	move_start := int(layer.move_offset)
	move_end := move_start+int(layer.move_count)
	moves := artifact.result.moves[move_start:move_end]
	minimum := [2]i64{i64(moves[0].point_a.x), i64(moves[0].point_a.y)}
	maximum := minimum
	for move in moves {
		points := [2][2]i64{
			{i64(move.point_a.x), i64(move.point_a.y)},
			{i64(move.point_b.x), i64(move.point_b.y)},
		}
		for point in points {
			minimum[0] = min(minimum[0], point[0])
			minimum[1] = min(minimum[1], point[1])
			maximum[0] = max(maximum[0], point[0])
			maximum[1] = max(maximum[1], point[1])
		}
	}
	span_x := maximum[0]-minimum[0]
	span_y := maximum[1]-minimum[1]
	padding := max(max(span_x, span_y)/100, i64(1))
	view_x := minimum[0]-padding
	view_y := -maximum[1]-padding
	view_width := span_x+padding*2
	view_height := span_y+padding*2

	builder, builder_error := strings.builder_make(
		0,
		int(estimated_byte_count),
		allocator,
	)
	if builder_error != nil {return nil, .Allocation_Failed}
	defer strings.builder_destroy(&builder)
	fmt.sbprintf(
		&builder,
		"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"+
		"<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"1200\" height=\"800\" "+
		"viewBox=\"%d %d %d %d\" preserveAspectRatio=\"xMidYMid meet\" "+
		"data-schema-version=\"%d\" data-layer-index=\"%d\" data-result-hash=\"",
		view_x,
		view_y,
		view_width,
		view_height,
		PATH_PLAN_SVG_SCHEMA_VERSION,
		layer_index,
	)
	for byte in artifact.result_hash {
		fmt.sbprintf(&builder, "%02x", byte)
	}
	fmt.sbprintf(
		&builder,
		"\">\n"+
		"  <rect x=\"%d\" y=\"%d\" width=\"%d\" height=\"%d\" fill=\"#0E0F0E\"/>\n"+
		"  <g fill=\"none\" stroke-linecap=\"round\">\n",
		view_x,
		view_y,
		view_width,
		view_height,
	)
	for move in moves {
		class_name := "travel" if move.kind == .Travel else "extrude"
		fmt.sbprintf(
			&builder,
			"    <line class=\"%s\" data-move-id=\"%016x\" "+
			"data-path-id=\"%016x\" x1=\"%d\" y1=\"%d\" x2=\"%d\" y2=\"%d\"/>\n",
			class_name,
			u64(move.stable_id),
			u64(move.path_id),
			i64(move.point_a.x),
			-i64(move.point_a.y),
			i64(move.point_b.x),
			-i64(move.point_b.y),
		)
	}
	strings.write_string(
		&builder,
		"  </g>\n"+
		"  <style>\n"+
		"    .travel { stroke: #787D75; stroke-width: 1; "+
		"stroke-dasharray: 4 3; vector-effect: non-scaling-stroke; }\n"+
		"    .extrude { stroke: #B27D57; stroke-width: 1.5; "+
		"vector-effect: non-scaling-stroke; }\n"+
		"  </style>\n"+
		"</svg>\n",
	)
	text := strings.to_string(builder)
	if u64(len(text)) > limits.max_bytes {
		return nil, .Byte_Limit
	}
	output := make([]u8, len(text), allocator)
	if len(text) > 0 && output == nil {return nil, .Allocation_Failed}
	copy(output, transmute([]u8)text)
	return output, .None
}

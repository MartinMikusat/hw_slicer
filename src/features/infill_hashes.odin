package features

import contracts "../contracts"
import geometry "../geometry"

SCHEMA_VERSION_INFILL_HASH :: u32(1)

infill_result_hash :: proc(
	region_hash: contracts.Content_Hash,
	result: Infill_Result,
) -> (contracts.Content_Hash, bool) {
	if !infill_config_valid(result.config) ||
	   result.config.arc_tolerance == 0 &&
	   	transmute(u64)result.config.arc_tolerance != 0 ||
	   len(result.boundary_hits) != len(result.segments)*2 {
		return {}, false
	}
	expected_segment_offset: u64
	for layer, layer_index in result.layers {
		if layer.segment_offset != expected_segment_offset ||
		   layer.segment_offset >
			max(u64)-u64(layer.segment_count) ||
		   layer.segment_offset+u64(layer.segment_count) >
		   	u64(len(result.segments)) ||
		   layer.axis != infill_layer_axis(
		   	result.config,
		   	u32(layer_index),
		   ) {
			return {}, false
		}
		start := int(layer.segment_offset)
		end := start+int(layer.segment_count)
		for segment in result.segments[start:end] {
			if segment.layer_index != u32(layer_index) ||
			   segment.axis != layer.axis {
				return {}, false
			}
		}
		expected_segment_offset += u64(layer.segment_count)
	}
	if expected_segment_offset != u64(len(result.segments)) {
		return {}, false
	}

	previous_region_index: u32
	previous_region_id: contracts.Stable_ID
	previous_region_segment_index: u64
	previous_line: contracts.Micrometres
	for segment, segment_index in result.segments {
		ordinal, ordinal_ok := feature_infill_ordinal(
			segment.region_segment_index,
		)
		if segment.region_id == contracts.INVALID_STABLE_ID ||
		   !ordinal_ok ||
		   segment.hit_offset != u64(segment_index)*2 ||
		   segment.axis != infill_layer_axis(
		   	result.config,
		   	segment.layer_index,
		   ) ||
		   segment.stable_id != contracts.stable_id_child(
		   	segment.region_id,
		   	.Feature,
		   	ordinal,
		   ) {
			return {}, false
		}
		if segment_index == 0 ||
		   segment.region_index != previous_region_index {
			if segment_index > 0 &&
			   segment.region_index <= previous_region_index {
				return {}, false
			}
			if segment.region_segment_index != 0 {
				return {}, false
			}
		} else {
			if segment.region_id != previous_region_id ||
			   segment.region_segment_index !=
			   	previous_region_segment_index+1 ||
			   segment.line_coordinate < previous_line {
				return {}, false
			}
		}
		if geometry.point_2_validate({
			segment.point_a.x,
			segment.point_a.y,
		}) != .None ||
		   geometry.point_2_validate({
		   	segment.point_b.x,
		   	segment.point_b.y,
		   }) != .None ||
		   segment.point_a == segment.point_b {
			return {}, false
		}
		first_coordinate, second_coordinate :=
			segment.point_a.y, segment.point_b.y
		if segment.axis == .Vertical {
			if segment.point_a.x != segment.line_coordinate ||
			   segment.point_b.x != segment.line_coordinate {
				return {}, false
			}
		} else {
			if segment.point_a.y != segment.line_coordinate ||
			   segment.point_b.y != segment.line_coordinate {
				return {}, false
			}
			first_coordinate, second_coordinate =
				segment.point_a.x, segment.point_b.x
		}
		if first_coordinate >= second_coordinate {
			return {}, false
		}
		line_delta := i128(i64(segment.line_coordinate))-
			i128(i64(result.config.phase))
		if line_delta%i128(i64(result.config.spacing)) != 0 {
			return {}, false
		}
		first_hit := result.boundary_hits[segment.hit_offset]
		second_hit := result.boundary_hits[segment.hit_offset+1]
		if first_hit.rounded_coordinate != first_coordinate ||
		   second_hit.rounded_coordinate != second_coordinate ||
		   !infill_boundary_hit_valid(first_hit) ||
		   !infill_boundary_hit_valid(second_hit) ||
		   !infill_boundary_hit_less(first_hit, second_hit) {
			return {}, false
		}
		previous_region_id = segment.region_id
		previous_region_index = segment.region_index
		previous_region_segment_index = segment.region_segment_index
		previous_line = segment.line_coordinate
	}

	hash: contracts.Canonical_Hash
	contracts.canonical_hash_init(
		&hash,
		"hw-slicer/rectilinear-infill",
		SCHEMA_VERSION_INFILL_HASH,
	)
	contracts.canonical_hash_append_content_hash(&hash, region_hash)
	contracts.canonical_hash_append_i64(&hash, i64(result.config.spacing))
	contracts.canonical_hash_append_i64(
		&hash,
		i64(result.config.boundary_inset),
	)
	contracts.canonical_hash_append_i64(&hash, i64(result.config.phase))
	contracts.canonical_hash_append_u8(&hash, u8(result.config.base_axis))
	contracts.canonical_hash_append_u8(
		&hash,
		u8(result.config.alternate_each_layer),
	)
	contracts.canonical_hash_append_u8(
		&hash,
		u8(result.config.topology_policy),
	)
	contracts.canonical_hash_append_u8(&hash, u8(result.config.join_type))
	contracts.canonical_hash_append_f64_bits(
		&hash,
		result.config.miter_limit,
	)
	contracts.canonical_hash_append_f64_bits(
		&hash,
		result.config.arc_tolerance,
	)
	contracts.canonical_hash_append_u64(&hash, result.scanline_count)
	contracts.canonical_hash_append_u64(&hash, u64(len(result.layers)))
	for layer in result.layers {
		contracts.canonical_hash_append_u64(&hash, layer.segment_offset)
		contracts.canonical_hash_append_u32(&hash, layer.segment_count)
		contracts.canonical_hash_append_u8(&hash, u8(layer.axis))
	}
	contracts.canonical_hash_append_u64(&hash, u64(len(result.segments)))
	for segment in result.segments {
		contracts.canonical_hash_append_stable_id(&hash, segment.stable_id)
		contracts.canonical_hash_append_stable_id(&hash, segment.region_id)
		contracts.canonical_hash_append_u32(&hash, segment.region_index)
		contracts.canonical_hash_append_u32(&hash, segment.layer_index)
		contracts.canonical_hash_append_u64(
			&hash,
			segment.region_segment_index,
		)
		contracts.canonical_hash_append_u8(&hash, u8(segment.axis))
		contracts.canonical_hash_append_i64(
			&hash,
			i64(segment.line_coordinate),
		)
		contracts.canonical_hash_append_i64(&hash, i64(segment.point_a.x))
		contracts.canonical_hash_append_i64(&hash, i64(segment.point_a.y))
		contracts.canonical_hash_append_i64(&hash, i64(segment.point_b.x))
		contracts.canonical_hash_append_i64(&hash, i64(segment.point_b.y))
		contracts.canonical_hash_append_u64(&hash, segment.hit_offset)
	}
	contracts.canonical_hash_append_u64(
		&hash,
		u64(len(result.boundary_hits)),
	)
	for hit in result.boundary_hits {
		contracts.canonical_hash_append_u32(
			&hash,
			hit.boundary_path_index,
		)
		contracts.canonical_hash_append_u32(
			&hash,
			hit.boundary_edge_index,
		)
		contracts.canonical_hash_append_i128(&hash, hit.numerator)
		contracts.canonical_hash_append_i128(&hash, hit.denominator)
		contracts.canonical_hash_append_i64(
			&hash,
			i64(hit.rounded_coordinate),
		)
		contracts.canonical_hash_append_u64(
			&hash,
			u64(hit.error_numerator),
		)
		contracts.canonical_hash_append_u64(
			&hash,
			u64(hit.error_numerator>>64),
		)
	}
	return contracts.canonical_hash_final(&hash), true
}

infill_boundary_hit_valid :: proc(hit: Infill_Boundary_Hit) -> bool {
	maximum_coordinate := i128(geometry.MAX_PLANAR_COORDINATE_UM)
	maximum_denominator := maximum_coordinate*2
	maximum_numerator := maximum_coordinate*maximum_coordinate*8
	if hit.denominator <= 0 ||
	   hit.denominator > maximum_denominator ||
	   hit.numerator < -maximum_numerator ||
	   hit.numerator > maximum_numerator {
		return false
	}
	rounded, error_numerator, ok :=
		infill_rational_round(hit.numerator, hit.denominator)
	return ok &&
		rounded == hit.rounded_coordinate &&
		error_numerator == hit.error_numerator
}

infill_boundary_hit_less :: proc(
	a, b: Infill_Boundary_Hit,
) -> bool {
	return a.numerator*b.denominator < b.numerator*a.denominator
}

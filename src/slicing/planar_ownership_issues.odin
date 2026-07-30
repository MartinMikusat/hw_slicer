package slicing

import "core:mem"

import contracts "../contracts"
import geometry "../geometry"

PLANAR_OWNERSHIP_ISSUE_HASH_SCHEMA_VERSION :: u32(1)

Planar_Ownership_Issue_Group :: struct {
	stable_id:        contracts.Stable_ID,
	layer_index:      u32,
	point_a:          Snapped_Point,
	point_b:          Snapped_Point,
	face_count:       u32,
	third_below_count: u32,
	third_above_count: u32,
	reference_offset: u64,
	reference_count:  u32,
}

Planar_Ownership_Issue_Reference :: struct {
	triangle_index: u32,
	triangle_id:    contracts.Stable_ID,
	source_edge:    Triangle_Edge,
	kind:           Planar_Incidence_Kind,
}

Planar_Ownership_Issue_Report :: struct {
	groups:     []Planar_Ownership_Issue_Group,
	references: []Planar_Ownership_Issue_Reference,
}

Planar_Ownership_Issue_Limits :: struct {
	max_groups:     u64,
	max_references: u64,
}

DEFAULT_PLANAR_OWNERSHIP_ISSUE_LIMITS ::
	Planar_Ownership_Issue_Limits{
		max_groups = 100_000_000,
		max_references = 300_000_000,
	}

Planar_Ownership_Issue_Error :: enum u8 {
	None,
	Invalid_Input,
	Group_Limit,
	Reference_Limit,
	Allocation_Failed,
	Arithmetic,
}

planar_ownership_issue_report_build :: proc(
	mesh: geometry.Canonical_Mesh,
	schedule: Fixed_Layer_Schedule,
	intersections: CPU_Intersection_Result,
	ownership: Planar_Ownership_Result,
	limits := DEFAULT_PLANAR_OWNERSHIP_ISSUE_LIMITS,
	allocator := context.allocator,
) -> (
	Planar_Ownership_Issue_Report,
	Planar_Ownership_Issue_Error,
) {
	incidences, collapsed_count, exact_count, incidence_error :=
		planar_incidences_collect(
			mesh,
			schedule,
			intersections,
			DEFAULT_PLANAR_OWNERSHIP_LIMITS,
			allocator,
		)
	if incidence_error != .None {return {}, .Invalid_Input}
	defer delete(incidences, allocator)
	if u64(len(incidences)) != ownership.incidence_count ||
	   collapsed_count != ownership.collapsed_incidence_count ||
	   exact_count != ownership.exact_predicate_count {
		return {}, .Invalid_Input
	}

	group_count: u64
	reference_count: u64
	unresolved_count: u64
	suppressed_count: u64
	for group_start := 0; group_start < len(incidences); {
		group_end := planar_incidence_group_end(incidences, group_start)
		emit, unresolved := planar_incidence_group_should_emit(
			incidences[group_start:group_end],
		)
		if unresolved {
			unresolved_count += 1
			group_count += 1
			group_size := u64(group_end-group_start)
			if reference_count > max(u64)-group_size {
				return {}, .Arithmetic
			}
			reference_count += group_size
		} else if !emit {
			suppressed_count += 1
		}
		group_start = group_end
	}
	if unresolved_count != ownership.unresolved_group_count ||
	   suppressed_count != ownership.suppressed_group_count {
		return {}, .Invalid_Input
	}
	if group_count > limits.max_groups ||
	   group_count > u64(max(int)) {
		return {}, .Group_Limit
	}
	if reference_count > limits.max_references ||
	   reference_count > u64(max(int)) {
		return {}, .Reference_Limit
	}

	result := Planar_Ownership_Issue_Report{
		groups = make(
			[]Planar_Ownership_Issue_Group,
			int(group_count),
			allocator,
		),
		references = make(
			[]Planar_Ownership_Issue_Reference,
			int(reference_count),
			allocator,
		),
	}
	if group_count > 0 && result.groups == nil ||
	   reference_count > 0 && result.references == nil {
		planar_ownership_issue_report_destroy(&result, allocator)
		return {}, .Allocation_Failed
	}

	group_write := 0
	reference_write := 0
	layer_group_ordinal: u64
	previous_layer := max(u32)
	for group_start := 0; group_start < len(incidences); {
		group_end := planar_incidence_group_end(incidences, group_start)
		group := incidences[group_start:group_end]
		_, unresolved := planar_incidence_group_should_emit(group)
		if !unresolved {
			group_start = group_end
			continue
		}
		layer_index := group[0].layer_index
		if layer_index != previous_layer {
			layer_group_ordinal = 0
			previous_layer = layer_index
		}
		if len(group) > int(max(u32)) {
			planar_ownership_issue_report_destroy(&result, allocator)
			return {}, .Arithmetic
		}
		output_group := &result.groups[group_write]
		output_group^ = {
			stable_id = contracts.stable_id_child(
				schedule.layer_ids[layer_index],
				.Topology_Issue,
				layer_group_ordinal,
			),
			layer_index = layer_index,
			point_a = group[0].point_a,
			point_b = group[0].point_b,
			reference_offset = u64(reference_write),
			reference_count = u32(len(group)),
		}
		for incidence in group {
			switch incidence.kind {
			case .Face:
				output_group.face_count += 1
			case .Third_Below:
				output_group.third_below_count += 1
			case .Third_Above:
				output_group.third_above_count += 1
			case .Invalid:
				planar_ownership_issue_report_destroy(&result, allocator)
				return {}, .Invalid_Input
			}
			result.references[reference_write] = {
				triangle_index = incidence.triangle_index,
				triangle_id = incidence.triangle_id,
				source_edge = incidence.source_edge,
				kind = incidence.kind,
			}
			reference_write += 1
		}
		group_write += 1
		layer_group_ordinal += 1
		group_start = group_end
	}
	if group_write != len(result.groups) ||
	   reference_write != len(result.references) {
		planar_ownership_issue_report_destroy(&result, allocator)
		return {}, .Arithmetic
	}
	return result, .None
}

planar_ownership_issue_report_hash :: proc(
	ownership_hash: contracts.Content_Hash,
	report: Planar_Ownership_Issue_Report,
) -> (contracts.Content_Hash, bool) {
	expected_reference_offset: u64
	for group in report.groups {
		if group.stable_id == contracts.INVALID_STABLE_ID ||
		   group.reference_count == 2 ||
		   group.reference_count == 0 ||
		   group.reference_offset != expected_reference_offset ||
		   u64(group.reference_count) >
		   	u64(len(report.references))-expected_reference_offset ||
		   u64(group.face_count)+
		   	u64(group.third_below_count)+
		   	u64(group.third_above_count) !=
		   	u64(group.reference_count) ||
		   geometry.point_2_validate({
		   	group.point_a.x,
		   	group.point_a.y,
		   }) != .None ||
		   geometry.point_2_validate({
		   	group.point_b.x,
		   	group.point_b.y,
		   }) != .None ||
		   group.point_a == group.point_b ||
		   !snapped_point_less(group.point_a, group.point_b) {
			return {}, false
		}
		expected_reference_offset += u64(group.reference_count)
	}
	if expected_reference_offset != u64(len(report.references)) {
		return {}, false
	}
	for reference in report.references {
		if reference.triangle_id == contracts.INVALID_STABLE_ID ||
		   reference.source_edge == .Invalid ||
		   reference.kind == .Invalid {
			return {}, false
		}
	}

	hash: contracts.Canonical_Hash
	contracts.canonical_hash_init(
		&hash,
		"hw-slicer/planar-ownership-issue-report",
		PLANAR_OWNERSHIP_ISSUE_HASH_SCHEMA_VERSION,
	)
	contracts.canonical_hash_append_content_hash(&hash, ownership_hash)
	contracts.canonical_hash_append_u64(&hash, u64(len(report.groups)))
	for group in report.groups {
		contracts.canonical_hash_append_stable_id(&hash, group.stable_id)
		contracts.canonical_hash_append_u32(&hash, group.layer_index)
		contracts.canonical_hash_append_i64(&hash, i64(group.point_a.x))
		contracts.canonical_hash_append_i64(&hash, i64(group.point_a.y))
		contracts.canonical_hash_append_i64(&hash, i64(group.point_b.x))
		contracts.canonical_hash_append_i64(&hash, i64(group.point_b.y))
		contracts.canonical_hash_append_u32(&hash, group.face_count)
		contracts.canonical_hash_append_u32(
			&hash,
			group.third_below_count,
		)
		contracts.canonical_hash_append_u32(
			&hash,
			group.third_above_count,
		)
		contracts.canonical_hash_append_u64(
			&hash,
			group.reference_offset,
		)
		contracts.canonical_hash_append_u32(
			&hash,
			group.reference_count,
		)
	}
	contracts.canonical_hash_append_u64(
		&hash,
		u64(len(report.references)),
	)
	for reference in report.references {
		contracts.canonical_hash_append_u32(
			&hash,
			reference.triangle_index,
		)
		contracts.canonical_hash_append_stable_id(
			&hash,
			reference.triangle_id,
		)
		contracts.canonical_hash_append_u8(
			&hash,
			u8(reference.source_edge),
		)
		contracts.canonical_hash_append_u8(&hash, u8(reference.kind))
	}
	return contracts.canonical_hash_final(&hash), true
}

planar_ownership_issue_report_destroy :: proc(
	report: ^Planar_Ownership_Issue_Report,
	allocator := context.allocator,
) {
	delete(report.groups, allocator)
	delete(report.references, allocator)
	report^ = {}
}

package features

FEATURE_ORDINAL_CLASS_SHIFT :: 62
FEATURE_ORDINAL_PAYLOAD_MASK :: u64(1)<<FEATURE_ORDINAL_CLASS_SHIFT-1
FEATURE_ORDINAL_SURFACE_PREFIX :: u64(1)<<FEATURE_ORDINAL_CLASS_SHIFT
FEATURE_ORDINAL_INFILL_PREFIX :: u64(2)<<FEATURE_ORDINAL_CLASS_SHIFT
FEATURE_ORDINAL_SKIN_PREFIX :: u64(3)<<FEATURE_ORDINAL_CLASS_SHIFT
FEATURE_ORDINAL_GAP_EVIDENCE_BASE :: u64(1)<<32
FEATURE_ORDINAL_BRIDGE_EVIDENCE_BASE :: u64(2)<<32
FEATURE_ORDINAL_SUPPORT_DEMAND_BASE :: u64(3)<<32
FEATURE_ORDINAL_SUPPORT_GEOMETRY_BASE :: u64(4)<<32
FEATURE_PERIMETER_COUNT_LIMIT :: u32(1)<<30

feature_perimeter_ordinal :: proc(
	perimeter_index, path_index: u32,
) -> (u64, bool) {
	if perimeter_index >= FEATURE_PERIMETER_COUNT_LIMIT {
		return 0, false
	}
	return u64(perimeter_index)<<32 | u64(path_index), true
}

feature_surface_ordinal :: proc(kind: Surface_Kind) -> (u64, bool) {
	if kind != .Bottom_Exposed && kind != .Top_Exposed {
		return 0, false
	}
	return FEATURE_ORDINAL_SURFACE_PREFIX | u64(kind), true
}

feature_infill_ordinal :: proc(
	region_segment_index: u64,
) -> (u64, bool) {
	if region_segment_index > FEATURE_ORDINAL_PAYLOAD_MASK {
		return 0, false
	}
	return FEATURE_ORDINAL_INFILL_PREFIX | region_segment_index, true
}

feature_skin_ordinal :: proc(kind: Skin_Kind) -> (u64, bool) {
	if kind != .Bottom && kind != .Top && kind != .Top_Bottom {
		return 0, false
	}
	return FEATURE_ORDINAL_SKIN_PREFIX | u64(kind), true
}

feature_gap_evidence_ordinal :: proc(
	kind: Gap_Evidence_Kind,
) -> (u64, bool) {
	if kind == .Invalid {
		return 0, false
	}
	return FEATURE_ORDINAL_SKIN_PREFIX |
		FEATURE_ORDINAL_GAP_EVIDENCE_BASE |
		u64(kind), true
}

feature_bridge_evidence_ordinal :: proc(
	kind: Bridge_Evidence_Kind,
) -> (u64, bool) {
	if kind == .Invalid {
		return 0, false
	}
	return FEATURE_ORDINAL_SKIN_PREFIX |
		FEATURE_ORDINAL_BRIDGE_EVIDENCE_BASE |
		u64(kind), true
}

feature_support_demand_ordinal :: proc() -> u64 {
	return FEATURE_ORDINAL_SKIN_PREFIX |
		FEATURE_ORDINAL_SUPPORT_DEMAND_BASE
}

feature_support_geometry_ordinal :: proc(
	kind: Support_Geometry_Kind,
) -> (u64, bool) {
	if kind == .Invalid {return 0, false}
	return FEATURE_ORDINAL_SKIN_PREFIX |
		FEATURE_ORDINAL_SUPPORT_GEOMETRY_BASE |
		u64(kind), true
}

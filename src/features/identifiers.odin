package features

FEATURE_ORDINAL_CLASS_SHIFT :: 62
FEATURE_ORDINAL_PAYLOAD_MASK :: u64(1)<<FEATURE_ORDINAL_CLASS_SHIFT-1
FEATURE_ORDINAL_SURFACE_PREFIX :: u64(1)<<FEATURE_ORDINAL_CLASS_SHIFT
FEATURE_ORDINAL_INFILL_PREFIX :: u64(2)<<FEATURE_ORDINAL_CLASS_SHIFT
FEATURE_ORDINAL_SKIN_PREFIX :: u64(3)<<FEATURE_ORDINAL_CLASS_SHIFT
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

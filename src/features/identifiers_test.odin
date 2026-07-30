package features

import "core:testing"

@(test)
feature_ordinals_partition_the_feature_identifier_space_test :: proc(
	t: ^testing.T,
) {
	perimeter, perimeter_ok := feature_perimeter_ordinal(
		FEATURE_PERIMETER_COUNT_LIMIT-1,
		max(u32),
	)
	bottom, bottom_ok := feature_surface_ordinal(.Bottom_Exposed)
	top, top_ok := feature_surface_ordinal(.Top_Exposed)
	infill, infill_ok := feature_infill_ordinal(
		FEATURE_ORDINAL_PAYLOAD_MASK,
	)
	_, perimeter_overflow_ok := feature_perimeter_ordinal(
		FEATURE_PERIMETER_COUNT_LIMIT,
		0,
	)
	_, invalid_surface_ok := feature_surface_ordinal(.Invalid)
	_, infill_overflow_ok := feature_infill_ordinal(
		FEATURE_ORDINAL_PAYLOAD_MASK+1,
	)
	testing.expect(t, perimeter_ok)
	testing.expect(t, bottom_ok)
	testing.expect(t, top_ok)
	testing.expect(t, infill_ok)
	testing.expect(t, !perimeter_overflow_ok)
	testing.expect(t, !invalid_surface_ok)
	testing.expect(t, !infill_overflow_ok)
	testing.expect_value(t, perimeter, u64(0x3fff_ffff_ffff_ffff))
	testing.expect_value(t, bottom, u64(0x4000_0000_0000_0001))
	testing.expect_value(t, top, u64(0x4000_0000_0000_0002))
	testing.expect_value(t, infill, u64(0xbfff_ffff_ffff_ffff))
	testing.expect_value(
		t,
		perimeter>>FEATURE_ORDINAL_CLASS_SHIFT,
		u64(0),
	)
	testing.expect_value(
		t,
		bottom>>FEATURE_ORDINAL_CLASS_SHIFT,
		u64(1),
	)
	testing.expect_value(
		t,
		top>>FEATURE_ORDINAL_CLASS_SHIFT,
		u64(1),
	)
	testing.expect_value(
		t,
		infill>>FEATURE_ORDINAL_CLASS_SHIFT,
		u64(2),
	)
	testing.expect(t, bottom != top)
}

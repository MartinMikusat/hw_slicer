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
	skin, skin_ok := feature_skin_ordinal(.Top_Bottom)
	gap, gap_ok := feature_gap_evidence_ordinal(.Unprinted_Remainder)
	overlap, overlap_ok :=
		feature_role_overlap_ordinal(.Sparse_Infill)
	infill, infill_ok := feature_infill_ordinal(
		FEATURE_ORDINAL_PAYLOAD_MASK,
	)
	_, perimeter_overflow_ok := feature_perimeter_ordinal(
		FEATURE_PERIMETER_COUNT_LIMIT,
		0,
	)
	_, invalid_surface_ok := feature_surface_ordinal(.Invalid)
	_, invalid_skin_ok := feature_skin_ordinal(.Invalid)
	_, invalid_gap_ok := feature_gap_evidence_ordinal(.Invalid)
	_, invalid_overlap_ok :=
		feature_role_overlap_ordinal(.Support)
	_, infill_overflow_ok := feature_infill_ordinal(
		FEATURE_ORDINAL_PAYLOAD_MASK+1,
	)
	testing.expect(t, perimeter_ok)
	testing.expect(t, bottom_ok)
	testing.expect(t, top_ok)
	testing.expect(t, skin_ok)
	testing.expect(t, gap_ok)
	testing.expect(t, overlap_ok)
	testing.expect(t, infill_ok)
	testing.expect(t, !perimeter_overflow_ok)
	testing.expect(t, !invalid_surface_ok)
	testing.expect(t, !invalid_skin_ok)
	testing.expect(t, !invalid_gap_ok)
	testing.expect(t, !invalid_overlap_ok)
	testing.expect(t, !infill_overflow_ok)
	testing.expect_value(t, perimeter, u64(0x3fff_ffff_ffff_ffff))
	testing.expect_value(t, bottom, u64(0x4000_0000_0000_0001))
	testing.expect_value(t, top, u64(0x4000_0000_0000_0002))
	testing.expect_value(t, infill, u64(0xbfff_ffff_ffff_ffff))
	testing.expect_value(t, skin, u64(0xc000_0000_0000_0003))
	testing.expect_value(t, gap, u64(0xc000_0001_0000_0006))
	testing.expect_value(t, overlap, u64(0xc000_0005_0000_0008))
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
	testing.expect_value(
		t,
		skin>>FEATURE_ORDINAL_CLASS_SHIFT,
		u64(3),
	)
	testing.expect_value(
		t,
		gap>>FEATURE_ORDINAL_CLASS_SHIFT,
		u64(3),
	)
	testing.expect(t, bottom != top)
	testing.expect(t, skin != gap)
	testing.expect(t, overlap != gap)
}

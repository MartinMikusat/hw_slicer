package evidence

import "core:os"
import "core:testing"

BUNDLE_GOLDEN_SUMMARY := Evidence_Artifact{
	path = "summary.json",
	format = "json",
	schema_version = 1,
	item_count = 1,
	byte_count = 256,
	sha256 = GOLDEN_HASH,
}

BUNDLE_GOLDEN_STAGES := [1]Evidence_Bundle_Stage{
	{
		ordinal = 10,
		stage = {
			name = "plan-paths",
			schema_version = 1,
			revision = 1,
		},
		provider = {
			id = "8d284a7409f377bb",
			name = "cpu-canonical-nearest",
			version = "0.1.0",
		},
		manifest = {
			path = "stages/10-plan-paths/manifest.json",
			format = "json",
			schema_version = 1,
			item_count = 1,
			byte_count = 1854,
			sha256 = GOLDEN_HASH,
		},
	},
}

BUNDLE_GOLDEN_FILES := [2]Evidence_Artifact{
	{
		path = "stages/10-plan-paths/primitives/path-plan.bin",
		format = "hws-path-plan-le",
		schema_version = 1,
		item_count = 633143,
		byte_count = 35504552,
		sha256 =
			"e0074543cb5db6a85e0e53a5588bf7ee37a21211d3b193d25895df2620625f5f",
	},
	{
		path = "stages/10-plan-paths/renders/layer-000538.svg",
		format = "svg",
		schema_version = 1,
		item_count = 5,
		byte_count = 1338,
		sha256 =
			"fd7a02c7882d2d0fdc7a9db3cfb6da283e0b569b30348e00b288462bc514ff4a",
	},
}

bundle_golden_manifest :: proc() -> Evidence_Bundle_Manifest {
	return {
		schema_version = EVIDENCE_BUNDLE_SCHEMA_VERSION,
		request_hash =
			"6bb3d6d574ec659bccd429e88a8f3ec20a161581fe0fb14da35c322b0c0fdd73",
		source_root_id = "524d81e204d4e634",
		summary = BUNDLE_GOLDEN_SUMMARY,
		stages = BUNDLE_GOLDEN_STAGES[:],
		files = BUNDLE_GOLDEN_FILES[:],
	}
}

@(test)
evidence_bundle_manifest_matches_golden_fixture_test :: proc(t: ^testing.T) {
	manifest := bundle_golden_manifest()
	encoded, encode_error := evidence_bundle_manifest_encode(
		manifest,
		context.temp_allocator,
	)
	testing.expect_value(t, encode_error, Evidence_Bundle_Error.None)
	expected, read_ok := os.read_entire_file(
		"testdata/evidence/bundle-manifest-v1.json",
		context.temp_allocator,
	)
	testing.expect(t, read_ok)
	testing.expect_value(t, string(encoded), string(expected))
}

@(test)
evidence_bundle_manifest_round_trip_and_validation_test :: proc(t: ^testing.T) {
	manifest := bundle_golden_manifest()
	encoded, encode_error := evidence_bundle_manifest_encode(manifest)
	defer delete(encoded)
	testing.expect_value(t, encode_error, Evidence_Bundle_Error.None)
	decoded, decode_error := evidence_bundle_manifest_decode(encoded)
	defer evidence_bundle_manifest_destroy(&decoded)
	testing.expect_value(t, decode_error, Evidence_Bundle_Error.None)
	testing.expect_value(t, len(decoded.stages), 1)
	testing.expect_value(t, len(decoded.files), 2)
	testing.expect_value(
		t,
		decoded.stages[0].provider.id,
		"8d284a7409f377bb",
	)

	manifest = bundle_golden_manifest()
	stages := BUNDLE_GOLDEN_STAGES
	manifest.stages = stages[:]
	manifest.stages[0].provider.id = "1122334455667788"
	_, provider_error := evidence_bundle_manifest_encode(manifest)
	testing.expect_value(
		t,
		provider_error,
		Evidence_Bundle_Error.Invalid_Record,
	)

	manifest = bundle_golden_manifest()
	files := BUNDLE_GOLDEN_FILES
	manifest.files = files[:]
	manifest.files[1].path = manifest.files[0].path
	_, duplicate_error := evidence_bundle_manifest_encode(manifest)
	testing.expect_value(
		t,
		duplicate_error,
		Evidence_Bundle_Error.Invalid_Record,
	)

	manifest = bundle_golden_manifest()
	stages = BUNDLE_GOLDEN_STAGES
	manifest.stages = stages[:]
	manifest.stages[0].ordinal = 9
	_, ordinal_error := evidence_bundle_manifest_encode(manifest)
	testing.expect_value(
		t,
		ordinal_error,
		Evidence_Bundle_Error.Invalid_Record,
	)

	manifest = bundle_golden_manifest()
	manifest.schema_version = 2
	_, version_error := evidence_bundle_manifest_encode(manifest)
	testing.expect_value(
		t,
		version_error,
		Evidence_Bundle_Error.Unsupported_Version,
	)

	unsupported_payload := `{"schema_version":2}`
	_, unsupported_decode_error := evidence_bundle_manifest_decode(
		transmute([]u8)unsupported_payload,
	)
	testing.expect_value(
		t,
		unsupported_decode_error,
		Evidence_Bundle_Error.Unsupported_Version,
	)
	malformed_payload := "{"
	_, malformed_error := evidence_bundle_manifest_decode(
		transmute([]u8)malformed_payload,
	)
	testing.expect_value(
		t,
		malformed_error,
		Evidence_Bundle_Error.Decode_Failed,
	)
	oversized := make(
		[]u8,
		int(EVIDENCE_BUNDLE_MANIFEST_BYTE_LIMIT)+1,
		context.temp_allocator,
	)
	_, byte_limit_error := evidence_bundle_manifest_decode(oversized)
	testing.expect_value(
		t,
		byte_limit_error,
		Evidence_Bundle_Error.Byte_Limit,
	)
}

@(test)
evidence_bundle_summary_round_trip_and_validation_test :: proc(t: ^testing.T) {
	summary := Evidence_Bundle_Summary{
		schema_version = EVIDENCE_BUNDLE_SCHEMA_VERSION,
		request_hash = GOLDEN_HASH,
		source_root_id = "8877665544332211",
		stage_count = 1,
		file_count = 2,
	}
	bytes, encode_error := evidence_bundle_summary_encode(summary)
	defer delete(bytes)
	testing.expect_value(t, encode_error, Evidence_Bundle_Error.None)
	expected, read_ok := os.read_entire_file(
		"testdata/evidence/bundle-summary-v1.json",
		context.temp_allocator,
	)
	testing.expect(t, read_ok)
	testing.expect_value(t, string(bytes), string(expected))
	decoded, decode_error := evidence_bundle_summary_decode(bytes)
	defer evidence_bundle_summary_destroy(&decoded)
	testing.expect_value(t, decode_error, Evidence_Bundle_Error.None)
	testing.expect_value(t, decoded.request_hash, summary.request_hash)
	testing.expect_value(t, decoded.stage_count, u64(1))
	testing.expect_value(t, decoded.file_count, u64(2))

	summary.stage_count = 0
	_, count_error := evidence_bundle_summary_encode(summary)
	testing.expect_value(
		t,
		count_error,
		Evidence_Bundle_Error.Invalid_Record,
	)
	summary.stage_count = 1
	summary.schema_version = 2
	_, version_error := evidence_bundle_summary_encode(summary)
	testing.expect_value(
		t,
		version_error,
		Evidence_Bundle_Error.Unsupported_Version,
	)
	oversized := make(
		[]u8,
		int(EVIDENCE_BUNDLE_SUMMARY_BYTE_LIMIT)+1,
		context.temp_allocator,
	)
	_, limit_error := evidence_bundle_summary_decode(oversized)
	testing.expect_value(
		t,
		limit_error,
		Evidence_Bundle_Error.Byte_Limit,
	)
}

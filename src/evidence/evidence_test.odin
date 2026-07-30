package evidence

import "core:os"
import "core:testing"

import contracts "../contracts"

GOLDEN_HASH :: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

GOLDEN_SUMMARY := [2]Evidence_Counter{
	{"candidate_triangles", 12},
	{"segments", 8},
}

GOLDEN_INVARIANTS := [1]Evidence_Invariant{
	{"finite_endpoints", true, "8", "8"},
}

GOLDEN_PROVENANCE := [1]Evidence_Provenance{
	{"1122334455667788", "2233445566778899", "triangle-to-segment"},
}

GOLDEN_PRIMITIVES := [1]Evidence_Artifact{
	{
		path = "stages/intersect/segments.bin",
		format = "hws-segments-le",
		schema_version = 1,
		item_count = 8,
		byte_count = 384,
		sha256 = GOLDEN_HASH,
	},
}

GOLDEN_RENDERS := [1]Evidence_Artifact{
	{
		path = "renders/intersect-layer-000042.svg",
		format = "svg",
		schema_version = 1,
		sha256 = GOLDEN_HASH,
	},
}

golden_manifest :: proc() -> Evidence_Manifest {
	return {
		schema_version = contracts.SCHEMA_VERSION_DEBUG_EVIDENCE,
		request_hash = GOLDEN_HASH,
		stage = {
			name = "intersect",
			schema_version = 1,
			revision = 3,
		},
		provider = {
			id = "71ff96d7e1de4738",
			name = "cpu-checked",
			version = "0.1.0",
		},
		source_root_id = "8877665544332211",
		source_bounds = {
			valid = true,
			minimum = {-10, -20, 0},
			maximum = {10, 20, 30},
			units = "millimetre",
		},
		planar_bounds = {
			valid = true,
			minimum = {-10000, -20000},
			maximum = {10000, 20000},
			units = "micrometre",
		},
		summary = GOLDEN_SUMMARY[:],
		invariants = GOLDEN_INVARIANTS[:],
		provenance = GOLDEN_PROVENANCE[:],
		primitives = GOLDEN_PRIMITIVES[:],
		renders = GOLDEN_RENDERS[:],
		elapsed_ns = 125000,
	}
}

@(test)
evidence_manifest_matches_golden_fixture_test :: proc(t: ^testing.T) {
	manifest := golden_manifest()
	encoded, encode_error := evidence_manifest_encode(
		manifest,
		context.temp_allocator,
	)
	testing.expect_value(t, encode_error, Evidence_Error.None)
	expected, read_ok := os.read_entire_file(
		"testdata/evidence/stage-manifest-v1.json",
		context.temp_allocator,
	)
	testing.expect(t, read_ok)
	testing.expect_value(t, string(encoded), string(expected))
}

@(test)
evidence_manifest_round_trip_preserves_required_records_test :: proc(
	t: ^testing.T,
) {
	original := golden_manifest()
	encoded, encode_error := evidence_manifest_encode(original)
	testing.expect_value(t, encode_error, Evidence_Error.None)
	defer delete(encoded)
	decoded, decode_error := evidence_manifest_decode(encoded)
	testing.expect_value(t, decode_error, Evidence_Error.None)
	defer evidence_manifest_destroy(&decoded)
	testing.expect_value(t, decoded.request_hash, original.request_hash)
	testing.expect_value(t, decoded.stage.name, original.stage.name)
	testing.expect_value(t, len(decoded.summary), 2)
	testing.expect_value(t, len(decoded.primitives), 1)
	testing.expect_value(t, len(decoded.renders), 1)
}

@(test)
evidence_manifest_rejects_unsupported_version_test :: proc(t: ^testing.T) {
	payload := `{
		"schema_version": 99
	}`
	_, error := evidence_manifest_decode(transmute([]u8)payload)
	testing.expect_value(t, error, Evidence_Error.Unsupported_Version)
}

@(test)
evidence_manifest_encoder_rejects_records_the_decoder_rejects_test :: proc(
	t: ^testing.T,
) {
	manifest := golden_manifest()
	manifest.schema_version = 99
	_, version_error := evidence_manifest_encode(manifest)
	testing.expect_value(
		t,
		version_error,
		Evidence_Error.Unsupported_Version,
	)

	manifest = golden_manifest()
	summary := GOLDEN_SUMMARY
	manifest.summary = summary[:]
	manifest.summary[0].name = ""
	_, summary_error := evidence_manifest_encode(manifest)
	testing.expect_value(t, summary_error, Evidence_Error.Invalid_Record)

	manifest = golden_manifest()
	invariants := GOLDEN_INVARIANTS
	manifest.invariants = invariants[:]
	manifest.invariants[0].observed = ""
	_, invariant_error := evidence_manifest_encode(manifest)
	testing.expect_value(t, invariant_error, Evidence_Error.Invalid_Record)

	manifest = golden_manifest()
	provenance := GOLDEN_PROVENANCE
	manifest.provenance = provenance[:]
	manifest.provenance[0].relation = ""
	_, provenance_error := evidence_manifest_encode(manifest)
	testing.expect_value(t, provenance_error, Evidence_Error.Invalid_Record)

	manifest = golden_manifest()
	primitives := GOLDEN_PRIMITIVES
	manifest.primitives = primitives[:]
	manifest.primitives[0].schema_version = 0
	_, artifact_error := evidence_manifest_encode(manifest)
	testing.expect_value(t, artifact_error, Evidence_Error.Invalid_Record)

	manifest = golden_manifest()
	renders := GOLDEN_RENDERS
	manifest.renders = renders[:]
	manifest.renders[0].schema_version = 0
	_, render_error := evidence_manifest_encode(manifest)
	testing.expect_value(t, render_error, Evidence_Error.Invalid_Record)

	manifest = golden_manifest()
	primitives = GOLDEN_PRIMITIVES
	manifest.primitives = primitives[:]
	manifest.primitives[0].format = "HWS Segments"
	_, format_error := evidence_manifest_encode(manifest)
	testing.expect_value(t, format_error, Evidence_Error.Invalid_Record)

	manifest = golden_manifest()
	manifest.provider.name = "cpu\ninvalid"
	_, provider_name_error := evidence_manifest_encode(manifest)
	testing.expect_value(
		t,
		provider_name_error,
		Evidence_Error.Invalid_Record,
	)

	manifest = golden_manifest()
	manifest.provider.version = "00.1.0"
	_, provider_version_error := evidence_manifest_encode(manifest)
	testing.expect_value(
		t,
		provider_version_error,
		Evidence_Error.Invalid_Record,
	)

	manifest = golden_manifest()
	manifest.provider.id = "1122334455667788"
	_, provider_id_error := evidence_manifest_encode(manifest)
	testing.expect_value(
		t,
		provider_id_error,
		Evidence_Error.Invalid_Record,
	)
}

@(test)
evidence_manifest_rejects_unsafe_or_duplicate_artifact_paths_test :: proc(
	t: ^testing.T,
) {
	unsafe_paths := [?]string{
		"/absolute.bin",
		"../outside.bin",
		"stages/../outside.bin",
		"stages//segments.bin",
		"stages\\segments.bin",
		"C:/outside.bin",
		"stages/\nsegments.bin",
	}
	for path in unsafe_paths {
		manifest := golden_manifest()
		primitives := GOLDEN_PRIMITIVES
		manifest.primitives = primitives[:]
		manifest.primitives[0].path = path
		_, error := evidence_manifest_encode(manifest)
		testing.expect_value(t, error, Evidence_Error.Invalid_Record)
	}

	manifest := golden_manifest()
	renders := GOLDEN_RENDERS
	manifest.renders = renders[:]
	manifest.renders[0].path = manifest.primitives[0].path
	_, duplicate_error := evidence_manifest_encode(manifest)
	testing.expect_value(
		t,
		duplicate_error,
		Evidence_Error.Invalid_Record,
	)

	invalid_utf8 := [2]u8{0xff, 'x'}
	testing.expect(t, !artifact_path_valid(string(invalid_utf8[:])))
	testing.expect(t, artifact_path_valid("stages/vrstva-ž.bin"))
}

@(test)
evidence_manifest_rejects_duplicate_record_names_test :: proc(t: ^testing.T) {
	manifest := golden_manifest()
	summary := [2]Evidence_Counter{
		{"segments", 8},
		{"segments", 9},
	}
	manifest.summary = summary[:]
	_, summary_error := evidence_manifest_encode(manifest)
	testing.expect_value(t, summary_error, Evidence_Error.Invalid_Record)

	invariants := [2]Evidence_Invariant{
		{"finite_endpoints", true, "8", "8"},
		{"finite_endpoints", false, "7", "8"},
	}
	manifest = golden_manifest()
	manifest.invariants = invariants[:]
	_, invariant_error := evidence_manifest_encode(manifest)
	testing.expect_value(t, invariant_error, Evidence_Error.Invalid_Record)

	provenance := [2]Evidence_Provenance{
		GOLDEN_PROVENANCE[0],
		GOLDEN_PROVENANCE[0],
	}
	manifest = golden_manifest()
	manifest.provenance = provenance[:]
	_, provenance_error := evidence_manifest_encode(manifest)
	testing.expect_value(t, provenance_error, Evidence_Error.Invalid_Record)
}

@(test)
evidence_artifact_verifier_binds_descriptor_to_exact_bytes_test :: proc(
	t: ^testing.T,
) {
	artifact := Evidence_Artifact{
		path = "stages/plan-paths/path-plan.bin",
		format = "hws-path-plan-le",
		schema_version = 1,
		item_count = 3,
		byte_count = 3,
		sha256 =
			"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
	}
	payload := "abc"
	bytes := transmute([]u8)payload
	testing.expect_value(
		t,
		evidence_artifact_verify(artifact, bytes),
		Evidence_Artifact_Verify_Error.None,
	)

	mutated := artifact
	mutated.byte_count += 1
	testing.expect_value(
		t,
		evidence_artifact_verify(mutated, bytes),
		Evidence_Artifact_Verify_Error.Byte_Count_Mismatch,
	)

	mutated = artifact
	mutated.sha256 =
		"aa7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
	testing.expect_value(
		t,
		evidence_artifact_verify(mutated, bytes),
		Evidence_Artifact_Verify_Error.Hash_Mismatch,
	)

	mutated = artifact
	mutated.path = "../path-plan.bin"
	testing.expect_value(
		t,
		evidence_artifact_verify(mutated, bytes),
		Evidence_Artifact_Verify_Error.Invalid_Descriptor,
	)
}

@(test)
capture_preflight_rejects_item_byte_and_disabled_overruns_test :: proc(
	t: ^testing.T,
) {
	request := contracts.Evidence_Request{
		level = .Primitives,
		item_limit = 10,
		byte_limit = 100,
	}
	testing.expect_value(
		t,
		capture_preflight(request, {5, 40}, {5, 60}),
		Evidence_Error.None,
	)
	testing.expect_value(
		t,
		capture_preflight(request, {5, 40}, {6, 60}),
		Evidence_Error.Item_Limit,
	)
	testing.expect_value(
		t,
		capture_preflight(request, {5, 40}, {5, 61}),
		Evidence_Error.Byte_Limit,
	)
	request.level = .Disabled
	testing.expect_value(
		t,
		capture_preflight(request, {}, {1, 1}),
		Evidence_Error.Capture_Disabled,
	)
	testing.expect_value(
		t,
		capture_preflight(request, {1, 1}, {}),
		Evidence_Error.Capture_Disabled,
	)
	request.level = transmute(contracts.Evidence_Level)u8(255)
	testing.expect_value(
		t,
		capture_preflight(request, {}, {}),
		Evidence_Error.Invalid_Request,
	)
}

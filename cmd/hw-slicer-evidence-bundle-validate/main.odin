package main

import "core:crypto/sha2"
import "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"

import contracts "../../src/contracts"
import evidence "../../src/evidence"
import formats "../../src/formats"

Evidence_Bundle_Validate_Wire :: struct {
	schema_version: u32,
	bundle:         string,
	bundle_bytes:   u64,
	bundle_sha256:  string,
	validated:      bool,
}

main :: proc() {
	if len(os.args) != 2 {
		fmt.eprintln(
			"usage: hw-slicer-evidence-bundle-validate <evidence-bundle>",
		)
		os.exit(2)
	}
	bytes, read_error := formats.source_file_read_bounded(
		os.args[1],
		22,
		formats.DEFAULT_BOUNDED_ZIP_LIMITS.max_source_bytes,
	)
	if read_error != .None {
		fmt.eprintf(
			"[hw_slicer] evidence bundle read failed: %v\n",
			read_error,
		)
		os.exit(1)
	}
	defer delete(bytes)
	validate_error := evidence.evidence_bundle_package_validate(bytes)
	if validate_error != .None {
		fmt.eprintf(
			"[hw_slicer] evidence bundle validation failed: %v\n",
			validate_error,
		)
		os.exit(1)
	}
	digest: contracts.Content_Hash
	hash_context: sha2.Context_256
	sha2.init_256(&hash_context)
	sha2.update(&hash_context, bytes)
	sha2.final(&hash_context, digest[:])
	digest_text := hex.encode(digest[:])
	defer delete(digest_text)
	wire := Evidence_Bundle_Validate_Wire{
		schema_version = 1,
		bundle = filepath.base(os.args[1]),
		bundle_bytes = u64(len(bytes)),
		bundle_sha256 = string(digest_text),
		validated = true,
	}
	output, encode_error := json.marshal(
		wire,
		{
			pretty = true,
			use_spaces = true,
			spaces = 2,
			sort_maps_by_key = true,
		},
	)
	if encode_error != nil {
		fmt.eprintln("[hw_slicer] evidence bundle result encoding failed")
		os.exit(1)
	}
	defer delete(output)
	fmt.println(string(output))
}

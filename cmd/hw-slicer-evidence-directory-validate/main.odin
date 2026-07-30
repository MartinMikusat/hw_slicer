package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"

import evidence "../../src/evidence"

Evidence_Directory_Validate_Wire :: struct {
	schema_version: u32,
	directory:      string,
	validated:      bool,
}

main :: proc() {
	if len(os.args) != 2 {
		fmt.eprintln(
			"usage: hw-slicer-evidence-directory-validate <evidence-directory>",
		)
		os.exit(2)
	}
	validate_error :=
		evidence.evidence_bundle_directory_validate(os.args[1])
	if validate_error != .None {
		fmt.eprintf(
			"[hw_slicer] evidence directory validation failed: %v\n",
			validate_error,
		)
		os.exit(1)
	}
	wire := Evidence_Directory_Validate_Wire{
		schema_version = 1,
		directory = filepath.base(os.args[1]),
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
		fmt.eprintln(
			"[hw_slicer] evidence directory result encoding failed",
		)
		os.exit(1)
	}
	defer delete(output)
	fmt.println(string(output))
}

package evidence

import "core:crypto/sha2"
import "core:encoding/hex"
import "core:encoding/json"
import "core:math"
import "core:strings"
import "core:unicode/utf8"

import contracts "../contracts"

Evidence_Stage :: struct {
	name:           string,
	schema_version: u32,
	revision:       u32,
}

Evidence_Provider :: struct {
	id:      string,
	name:    string,
	version: string,
}

Evidence_Bounds_3D :: struct {
	valid:   bool,
	minimum: [3]f64,
	maximum: [3]f64,
	units:   string,
}

Evidence_Bounds_2D :: struct {
	valid:   bool,
	minimum: [2]i64,
	maximum: [2]i64,
	units:   string,
}

Evidence_Counter :: struct {
	name:  string,
	value: u64,
}

Evidence_Invariant :: struct {
	code:     string,
	passed:   bool,
	observed: string,
	expected: string,
}

Evidence_Provenance :: struct {
	parent_id: string,
	child_id:  string,
	relation:  string,
}

Evidence_Artifact :: struct {
	path:           string,
	format:         string,
	schema_version: u32,
	item_count:     u64,
	byte_count:     u64,
	sha256:         string,
}

Evidence_Manifest :: struct {
	schema_version:  u32,
	request_hash:    string,
	stage:           Evidence_Stage,
	provider:        Evidence_Provider,
	source_root_id:  string,
	source_bounds:   Evidence_Bounds_3D,
	planar_bounds:   Evidence_Bounds_2D,
	summary:         []Evidence_Counter,
	invariants:      []Evidence_Invariant,
	provenance:      []Evidence_Provenance,
	primitives:      []Evidence_Artifact,
	renders:         []Evidence_Artifact,
	elapsed_ns:      u64,
}

Capture_Usage :: struct {
	item_count: u64,
	byte_count: u64,
}

Evidence_Error :: enum u8 {
	None,
	Encode_Failed,
	Decode_Failed,
	Unsupported_Version,
	Invalid_Record,
	Invalid_Request,
	Capture_Disabled,
	Item_Limit,
	Byte_Limit,
}

Evidence_Artifact_Verify_Error :: enum u8 {
	None,
	Invalid_Descriptor,
	Byte_Count_Mismatch,
	Hash_Mismatch,
}

Evidence_Artifact_Describe_Error :: enum u8 {
	None,
	Invalid_Descriptor,
	Allocation_Failed,
}

evidence_manifest_encode :: proc(
	manifest: Evidence_Manifest,
	allocator := context.allocator,
) -> ([]u8, Evidence_Error) {
	if manifest.schema_version != contracts.SCHEMA_VERSION_DEBUG_EVIDENCE {
		return nil, .Unsupported_Version
	}
	if !evidence_manifest_valid(manifest) {
		return nil, .Invalid_Record
	}
	bytes, error := json.marshal(
		manifest,
		{
			pretty = true,
			use_spaces = true,
			spaces = 2,
			sort_maps_by_key = true,
			use_enum_names = true,
		},
		allocator,
	)
	if error != nil {return nil, .Encode_Failed}
	result := make([]u8, len(bytes)+1, allocator)
	copy(result, bytes)
	result[len(bytes)] = '\n'
	delete(bytes, allocator)
	return result, .None
}

evidence_manifest_decode :: proc(
	bytes: []u8,
	allocator := context.allocator,
) -> (Evidence_Manifest, Evidence_Error) {
	manifest: Evidence_Manifest
	if error := json.unmarshal(bytes, &manifest, .JSON, allocator); error != nil {
		evidence_manifest_destroy(&manifest, allocator)
		return {}, .Decode_Failed
	}
	if manifest.schema_version != contracts.SCHEMA_VERSION_DEBUG_EVIDENCE {
		evidence_manifest_destroy(&manifest, allocator)
		return {}, .Unsupported_Version
	}
	if !evidence_manifest_valid(manifest) {
		evidence_manifest_destroy(&manifest, allocator)
		return {}, .Invalid_Record
	}
	return manifest, .None
}

evidence_manifest_valid :: proc(manifest: Evidence_Manifest) -> bool {
	if !sha256_text_valid(manifest.request_hash) ||
	   !stable_id_text_valid(manifest.source_root_id) ||
	   !stage_text_valid(manifest.stage.name) ||
	   manifest.stage.schema_version == 0 ||
	   !evidence_provider_valid(manifest.provider, manifest.stage.name) ||
	   manifest.source_bounds.units != "millimetre" ||
	   manifest.planar_bounds.units != "micrometre" {
		return false
	}
	if manifest.source_bounds.valid {
		for axis in 0..<3 {
			if !finite_f64(manifest.source_bounds.minimum[axis]) ||
			   !finite_f64(manifest.source_bounds.maximum[axis]) ||
			   manifest.source_bounds.minimum[axis] >
			   manifest.source_bounds.maximum[axis] {
				return false
			}
		}
	}
	if manifest.planar_bounds.valid {
		for axis in 0..<2 {
			if manifest.planar_bounds.minimum[axis] >
			   manifest.planar_bounds.maximum[axis] {
				return false
			}
		}
	}
	for counter, counter_index in manifest.summary {
		if counter.name == "" {return false}
		for previous in manifest.summary[:counter_index] {
			if previous.name == counter.name {return false}
		}
	}
	for invariant, invariant_index in manifest.invariants {
		if invariant.code == "" ||
		   invariant.observed == "" ||
		   invariant.expected == "" {
			return false
		}
		for previous in manifest.invariants[:invariant_index] {
			if previous.code == invariant.code {return false}
		}
	}
	for artifact, artifact_index in manifest.primitives {
		if !evidence_artifact_valid(artifact) {
			return false
		}
		for previous in manifest.primitives[:artifact_index] {
			if previous.path == artifact.path {return false}
		}
	}
	for artifact, artifact_index in manifest.renders {
		if !evidence_artifact_valid(artifact) {
			return false
		}
		for previous in manifest.renders[:artifact_index] {
			if previous.path == artifact.path {return false}
		}
		for primitive in manifest.primitives {
			if primitive.path == artifact.path {return false}
		}
	}
	for edge, edge_index in manifest.provenance {
		if !stable_id_text_valid(edge.parent_id) ||
		   !stable_id_text_valid(edge.child_id) ||
		   edge.relation == "" {
			return false
		}
		for previous in manifest.provenance[:edge_index] {
			if previous.parent_id == edge.parent_id &&
			   previous.child_id == edge.child_id &&
			   previous.relation == edge.relation {
				return false
			}
		}
	}
	return true
}

capture_preflight :: proc(
	request: contracts.Evidence_Request,
	current, additional: Capture_Usage,
) -> Evidence_Error {
	if request.level != .Disabled &&
	   request.level != .Summary &&
	   request.level != .Primitives &&
	   request.level != .Renders {
		return .Invalid_Request
	}
	if request.level == .Disabled &&
	   (current.item_count != 0 || current.byte_count != 0 ||
	    additional.item_count != 0 || additional.byte_count != 0) {
		return .Capture_Disabled
	}
	if current.item_count > request.item_limit ||
	   additional.item_count > request.item_limit-current.item_count {
		return .Item_Limit
	}
	if current.byte_count > request.byte_limit ||
	   additional.byte_count > request.byte_limit-current.byte_count {
		return .Byte_Limit
	}
	return .None
}

evidence_artifact_valid :: proc(artifact: Evidence_Artifact) -> bool {
	return artifact_path_valid(artifact.path) &&
		artifact_format_valid(artifact.format) &&
		artifact.schema_version > 0 &&
		sha256_text_valid(artifact.sha256)
}

evidence_artifact_describe :: proc(
	path, format: string,
	schema_version: u32,
	item_count: u64,
	bytes: []u8,
	allocator := context.allocator,
) -> (Evidence_Artifact, Evidence_Artifact_Describe_Error) {
	if !artifact_path_valid(path) ||
	   !artifact_format_valid(format) ||
	   schema_version == 0 {
		return {}, .Invalid_Descriptor
	}
	digest: contracts.Content_Hash
	hash_context: sha2.Context_256
	sha2.init_256(&hash_context)
	sha2.update(&hash_context, bytes)
	sha2.final(&hash_context, digest[:])
	hash_text := hex.encode(digest[:], allocator)
	if hash_text == nil {return {}, .Allocation_Failed}
	path_text, path_error := strings.clone(path, allocator)
	if path_error != nil {
		delete(hash_text, allocator)
		return {}, .Allocation_Failed
	}
	format_text, format_error := strings.clone(format, allocator)
	if format_error != nil {
		delete(path_text, allocator)
		delete(hash_text, allocator)
		return {}, .Allocation_Failed
	}
	return {
		path = path_text,
		format = format_text,
		schema_version = schema_version,
		item_count = item_count,
		byte_count = u64(len(bytes)),
		sha256 = string(hash_text),
	}, .None
}

evidence_artifact_verify :: proc(
	artifact: Evidence_Artifact,
	bytes: []u8,
) -> Evidence_Artifact_Verify_Error {
	if !evidence_artifact_valid(artifact) {
		return .Invalid_Descriptor
	}
	if artifact.byte_count != u64(len(bytes)) {
		return .Byte_Count_Mismatch
	}

	digest: [sha2.DIGEST_SIZE_256]u8
	hash_context: sha2.Context_256
	sha2.init_256(&hash_context)
	sha2.update(&hash_context, bytes)
	sha2.final(&hash_context, digest[:])
	expected := transmute([]u8)artifact.sha256
	for byte, byte_index in digest {
		if expected[byte_index*2] != evidence_hex_digit(byte>>4) ||
		   expected[byte_index*2+1] != evidence_hex_digit(byte&0x0f) {
			return .Hash_Mismatch
		}
	}
	return .None
}

evidence_manifest_destroy :: proc(
	manifest: ^Evidence_Manifest,
	allocator := context.allocator,
) {
	delete(manifest.request_hash, allocator)
	delete(manifest.stage.name, allocator)
	delete(manifest.provider.id, allocator)
	delete(manifest.provider.name, allocator)
	delete(manifest.provider.version, allocator)
	delete(manifest.source_root_id, allocator)
	delete(manifest.source_bounds.units, allocator)
	delete(manifest.planar_bounds.units, allocator)
	for &counter in manifest.summary {
		delete(counter.name, allocator)
	}
	delete(manifest.summary, allocator)
	for &invariant in manifest.invariants {
		delete(invariant.code, allocator)
		delete(invariant.observed, allocator)
		delete(invariant.expected, allocator)
	}
	delete(manifest.invariants, allocator)
	for &edge in manifest.provenance {
		delete(edge.parent_id, allocator)
		delete(edge.child_id, allocator)
		delete(edge.relation, allocator)
	}
	delete(manifest.provenance, allocator)
	for &artifact in manifest.primitives {
		evidence_artifact_destroy(&artifact, allocator)
	}
	delete(manifest.primitives, allocator)
	for &artifact in manifest.renders {
		evidence_artifact_destroy(&artifact, allocator)
	}
	delete(manifest.renders, allocator)
	manifest^ = {}
}

evidence_artifact_destroy :: proc(
	artifact: ^Evidence_Artifact,
	allocator := context.allocator,
) {
	delete(artifact.path, allocator)
	delete(artifact.format, allocator)
	delete(artifact.sha256, allocator)
	artifact^ = {}
}

sha256_text_valid :: proc(value: string) -> bool {
	return len(value) == 64 && lowercase_hex_text(value, false)
}

stable_id_text_valid :: proc(value: string) -> bool {
	return len(value) == 16 && lowercase_hex_text(value, true)
}

lowercase_hex_text :: proc(value: string, require_nonzero: bool) -> bool {
	nonzero := false
	for rune in value {
		if rune >= '1' && rune <= '9' || rune >= 'a' && rune <= 'f' {
			nonzero = true
		}
		if !(rune >= '0' && rune <= '9' || rune >= 'a' && rune <= 'f') {
			return false
		}
	}
	return !require_nonzero || nonzero
}

stage_text_valid :: proc(value: string) -> bool {
	switch value {
	case "decode",
	     "resolve",
	     "normalize",
	     "schedule-layers",
	     "build-acceleration",
	     "intersect",
	     "reconstruct-topology",
	     "calculate-regions",
	     "generate-features",
	     "plan-paths",
	     "emit-gcode":
		return true
	}
	return false
}

evidence_provider_valid :: proc(
	provider: Evidence_Provider,
	stage: string,
) -> bool {
	stage_kind, stage_ok := evidence_stage_kind_parse(stage)
	version, version_ok := evidence_semantic_version_parse(provider.version)
	if !stage_ok || !version_ok || !stable_id_text_valid(provider.id) {
		return false
	}
	descriptor, descriptor_ok := contracts.provider_descriptor_make(
		provider.name,
		version,
		stage_kind,
	)
	return descriptor_ok &&
		evidence_stable_id_text_matches(provider.id, descriptor.id)
}

evidence_stage_kind_parse :: proc(value: string) -> (contracts.Stage_Kind, bool) {
	switch value {
	case "decode":                 return .Decode, true
	case "resolve":                return .Resolve, true
	case "normalize":              return .Normalize, true
	case "schedule-layers":        return .Schedule_Layers, true
	case "build-acceleration":     return .Build_Acceleration, true
	case "intersect":              return .Intersect, true
	case "reconstruct-topology":   return .Reconstruct_Topology, true
	case "calculate-regions":      return .Calculate_Regions, true
	case "generate-features":      return .Generate_Features, true
	case "plan-paths":             return .Plan_Paths, true
	case "emit-gcode":             return .Emit_GCode, true
	}
	return .Invalid, false
}

evidence_semantic_version_parse :: proc(
	value: string,
) -> (contracts.Semantic_Version, bool) {
	parts: [3]u16
	part_index := 0
	part_value: u32
	part_digits := 0
	leading_zero := false
	for byte in transmute([]u8)value {
		if byte >= '0' && byte <= '9' {
			if part_digits == 0 {
				leading_zero = byte == '0'
			} else if leading_zero {
				return {}, false
			}
			digit := u32(byte-'0')
			if part_value > (u32(max(u16))-digit)/10 {
				return {}, false
			}
			part_value = part_value*10+digit
			part_digits += 1
			continue
		}
		if byte != '.' || part_digits == 0 || part_index >= 2 {
			return {}, false
		}
		parts[part_index] = u16(part_value)
		part_index += 1
		part_value = 0
		part_digits = 0
		leading_zero = false
	}
	if part_index != 2 || part_digits == 0 {
		return {}, false
	}
	parts[2] = u16(part_value)
	version := contracts.Semantic_Version{parts[0], parts[1], parts[2]}
	if version.major == 0 && version.minor == 0 && version.patch == 0 {
		return {}, false
	}
	return version, true
}

evidence_stable_id_text_matches :: proc(
	value: string,
	id: contracts.Stable_ID,
) -> bool {
	if !stable_id_text_valid(value) {return false}
	bytes := transmute([]u8)value
	for byte, byte_index in bytes {
		shift := u64((len(bytes)-byte_index-1)*4)
		if byte != evidence_hex_digit(u8(u64(id)>>shift&0x0f)) {
			return false
		}
	}
	return true
}

artifact_path_valid :: proc(value: string) -> bool {
	if value == "" || value[0] == '/' || !utf8.valid_string(value) {
		return false
	}
	segment_start := 0
	for byte, byte_index in transmute([]u8)value {
		if byte < 0x20 || byte == 0x7f ||
		   byte == '\\' || byte == ':' {
			return false
		}
		if byte != '/' {continue}
		segment := value[segment_start:byte_index]
		if segment == "" || segment == "." || segment == ".." {
			return false
		}
		segment_start = byte_index+1
	}
	segment := value[segment_start:]
	return segment != "" && segment != "." && segment != ".."
}

artifact_format_valid :: proc(value: string) -> bool {
	if value == "" {return false}
	for byte in transmute([]u8)value {
		if !(byte >= 'a' && byte <= 'z' ||
		     byte >= '0' && byte <= '9' ||
		     byte == '-' || byte == '+' || byte == '.') {
			return false
		}
	}
	return true
}

finite_f64 :: proc(value: f64) -> bool {
	return !math.is_nan(value) && !math.is_inf(value)
}

evidence_hex_digit :: proc(value: u8) -> u8 {
	if value < 10 {return '0'+value}
	return 'a'+value-10
}

evidence_stage_from_descriptor :: proc(
	descriptor: contracts.Stage_Descriptor,
) -> Evidence_Stage {
	return {
		name = contracts.stage_name(descriptor.kind),
		schema_version = descriptor.schema_version,
		revision = descriptor.revision,
	}
}

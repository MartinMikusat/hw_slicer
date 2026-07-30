package contracts

import "core:unicode/utf8"

SCHEMA_VERSION_SLICE_REQUEST :: u32(1)
SCHEMA_VERSION_STAGE_RESULT  :: u32(1)
SCHEMA_VERSION_DEBUG_EVIDENCE :: u32(1)
STABLE_ID_ALGORITHM_VERSION  :: u32(1)
PROVIDER_DESCRIPTOR_SCHEMA_VERSION :: u32(1)

Content_Hash :: [32]u8
Stable_ID :: distinct u64
Micrometres :: distinct i64
Millimetres :: distinct f64

INVALID_STABLE_ID :: Stable_ID(0)

Semantic_Version :: struct {
	major: u16,
	minor: u16,
	patch: u16,
}

Source_Format :: enum u8 {
	Invalid,
	Binary_STL,
	ASCII_STL,
	OBJ,
	Three_MF,
}

Source_Units :: enum u8 {
	Unspecified,
	Micrometres,
	Millimetres,
	Centimetres,
	Metres,
	Inches,
	Feet,
}

Numeric_Mode :: enum u8 {
	Invalid,
	Strict,
	Optimized,
	Metal_Assisted,
}

Repair_Policy :: enum u8 {
	Invalid,
	Strict,
	Safe_Local,
	Explicit_Volume_Change,
}

Stage_Kind :: enum u8 {
	Invalid,
	Decode,
	Resolve,
	Normalize,
	Schedule_Layers,
	Build_Acceleration,
	Intersect,
	Reconstruct_Topology,
	Calculate_Regions,
	Generate_Features,
	Plan_Paths,
	Emit_GCode,
}

Stage_Status :: enum u8 {
	Invalid,
	Complete,
	Failed,
	Cancelled,
}

Evidence_Level :: enum u8 {
	Disabled,
	Summary,
	Primitives,
	Renders,
}

Entity_Kind :: enum u8 {
	Invalid,
	Source,
	Object,
	Component,
	Triangle,
	Layer,
	Segment,
	Loop,
	Region,
	Feature,
	Path,
	Vertex,
	Chain,
	Instance,
	Property_Group,
	Property,
	Metadata,
	Face,
	Extension_Resource,
	Package_Part,
	Region_Contour,
	Mesh_Issue,
	Topology_Issue,
	Provider,
	Motion,
	Command,
}

Issue_Severity :: enum u8 {
	Information,
	Warning,
	Error,
	Fatal,
}

Source_Asset :: struct {
	content_hash: Content_Hash,
	byte_count:   u64,
	format:       Source_Format,
	units:        Source_Units,
}

Profile_Revisions :: struct {
	printer:  Content_Hash,
	process:  Content_Hash,
	material: Content_Hash,
	dialect:  Content_Hash,
}

Layer_Settings :: struct {
	first_layer_height: Micrometres,
	layer_height:       Micrometres,
	adaptive:           bool,
	minimum_height:     Micrometres,
	maximum_height:     Micrometres,
}

Evidence_Request :: struct {
	level:      Evidence_Level,
	byte_limit: u64,
	item_limit: u64,
}

Slice_Request :: struct {
	schema_version:  u32,
	source:          Source_Asset,
	profiles:        Profile_Revisions,
	settings_hash:   Content_Hash,
	provider_hash:   Content_Hash,
	numeric_mode:    Numeric_Mode,
	repair_policy:   Repair_Policy,
	layers:          Layer_Settings,
	evidence:        Evidence_Request,
}

Stage_Descriptor :: struct {
	kind:           Stage_Kind,
	schema_version: u32,
	revision:       u32,
}

Provider_Descriptor :: struct {
	id:      Stable_ID,
	name:    string,
	version: Semantic_Version,
	stage:   Stage_Kind,
}

Stage_Result_Header :: struct {
	schema_version: u32,
	request_hash:   Content_Hash,
	result_hash:    Content_Hash,
	stage:          Stage_Descriptor,
	provider:       Provider_Descriptor,
	status:         Stage_Status,
	issue_count:    u64,
	output_bytes:   u64,
}

Debug_Evidence_Header :: struct {
	schema_version:   u32,
	request_hash:     Content_Hash,
	stage:            Stage_Descriptor,
	provider:         Provider_Descriptor,
	source_root_id:   Stable_ID,
	summary_count:    u64,
	invariant_count:  u64,
	provenance_count: u64,
	primitive_count:  u64,
	primitive_bytes:  u64,
	elapsed_ns:       u64,
}

stage_name :: proc(kind: Stage_Kind) -> string {
	switch kind {
	case .Decode:               return "decode"
	case .Resolve:              return "resolve"
	case .Normalize:            return "normalize"
	case .Schedule_Layers:      return "schedule-layers"
	case .Build_Acceleration:   return "build-acceleration"
	case .Intersect:            return "intersect"
	case .Reconstruct_Topology: return "reconstruct-topology"
	case .Calculate_Regions:    return "calculate-regions"
	case .Generate_Features:    return "generate-features"
	case .Plan_Paths:           return "plan-paths"
	case .Emit_GCode:           return "emit-gcode"
	case .Invalid:              return "invalid"
	}
	return "invalid"
}

provider_descriptor_make :: proc(
	name: string,
	version: Semantic_Version,
	stage: Stage_Kind,
) -> (Provider_Descriptor, bool) {
	if !provider_name_valid(name) || stage_name(stage) == "invalid" ||
	   version.major == 0 && version.minor == 0 && version.patch == 0 {
		return {}, false
	}
	hash: Canonical_Hash
	canonical_hash_init(
		&hash,
		"hw-slicer/provider",
		PROVIDER_DESCRIPTOR_SCHEMA_VERSION,
	)
	canonical_hash_append_string(&hash, name)
	canonical_hash_append_u32(&hash, u32(version.major))
	canonical_hash_append_u32(&hash, u32(version.minor))
	canonical_hash_append_u32(&hash, u32(version.patch))
	canonical_hash_append_u8(&hash, u8(stage))
	content_hash := canonical_hash_final(&hash)
	return {
		id = stable_id_root(content_hash, .Provider),
		name = name,
		version = version,
		stage = stage,
	}, true
}

provider_name_valid :: proc(name: string) -> bool {
	if name == "" || !utf8.valid_string(name) {return false}
	for rune in name {
		if rune < 0x20 || rune >= 0x7f && rune <= 0x9f {
			return false
		}
	}
	return true
}

provider_descriptor_valid :: proc(provider: Provider_Descriptor) -> bool {
	expected, ok := provider_descriptor_make(
		provider.name,
		provider.version,
		provider.stage,
	)
	return ok && expected.id == provider.id
}

stable_id_root :: proc(content_hash: Content_Hash, kind: Entity_Kind) -> Stable_ID {
	hash := stable_id_hash_begin()
	hash = stable_id_hash_u32(hash, STABLE_ID_ALGORITHM_VERSION)
	hash = stable_id_hash_u8(hash, u8(kind))
	for value in content_hash {
		hash = stable_id_hash_u8(hash, value)
	}
	return stable_id_nonzero(hash)
}

stable_id_child :: proc(
	parent: Stable_ID,
	kind: Entity_Kind,
	canonical_ordinal: u64,
) -> Stable_ID {
	hash := stable_id_hash_begin()
	hash = stable_id_hash_u32(hash, STABLE_ID_ALGORITHM_VERSION)
	hash = stable_id_hash_u64(hash, u64(parent))
	hash = stable_id_hash_u8(hash, u8(kind))
	hash = stable_id_hash_u64(hash, canonical_ordinal)
	return stable_id_nonzero(hash)
}

stable_id_hash_begin :: proc() -> u64 {
	return 14695981039346656037
}

stable_id_hash_u8 :: proc(hash: u64, value: u8) -> u64 {
	return (hash ~ u64(value))*1099511628211
}

stable_id_hash_u32 :: proc(hash: u64, value: u32) -> u64 {
	result := hash
	for shift: u32 = 0; shift < 32; shift += 8 {
		result = stable_id_hash_u8(result, u8(value>>shift))
	}
	return result
}

stable_id_hash_u64 :: proc(hash: u64, value: u64) -> u64 {
	result := hash
	for shift: u64 = 0; shift < 64; shift += 8 {
		result = stable_id_hash_u8(result, u8(value>>shift))
	}
	return result
}

stable_id_nonzero :: proc(value: u64) -> Stable_ID {
	if value == 0 {return Stable_ID(1)}
	return Stable_ID(value)
}

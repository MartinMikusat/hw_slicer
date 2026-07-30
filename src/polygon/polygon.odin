package polygon

import "core:mem"

import contracts "../contracts"

Polygon_Point :: struct {
	x: contracts.Micrometres,
	y: contracts.Micrometres,
}

Polygon_Path :: struct {
	offset: u64,
	count:  u64,
}

Polygon_Set :: struct {
	points: []Polygon_Point,
	paths:  []Polygon_Path,
}

Polygon_Operation :: enum u8 {
	Invalid,
	Intersection,
	Union,
	Difference,
	Xor,
}

Polygon_Fill_Rule :: enum u8 {
	Even_Odd,
	Non_Zero,
	Positive,
	Negative,
}

Polygon_Join_Type :: enum u8 {
	Square,
	Bevel,
	Round,
	Miter,
}

Polygon_Limits :: struct {
	max_input_points:  u64,
	max_input_paths:   u64,
	max_output_points: u64,
	max_output_paths:  u64,
}

DEFAULT_POLYGON_LIMITS :: Polygon_Limits{
	max_input_points = 100_000_000,
	max_input_paths = 10_000_000,
	max_output_points = 200_000_000,
	max_output_paths = 20_000_000,
}

Polygon_Error :: enum u8 {
	None,
	Invalid_Input,
	Input_Limit,
	Output_Limit,
	Coordinate_Range,
	Provider_Version,
	Provider_Failed,
	Allocation_Failed,
}

Polygon_Boolean_Proc :: proc(
	subjects, clips: Polygon_Set,
	operation: Polygon_Operation,
	fill_rule: Polygon_Fill_Rule,
	limits: Polygon_Limits,
	allocator: mem.Allocator,
) -> (Polygon_Set, Polygon_Error)

Polygon_Offset_Proc :: proc(
	input: Polygon_Set,
	delta: contracts.Micrometres,
	join_type: Polygon_Join_Type,
	miter_limit, arc_tolerance: f64,
	limits: Polygon_Limits,
	allocator: mem.Allocator,
) -> (Polygon_Set, Polygon_Error)

Polygon_Provider :: struct {
	name:             string,
	version:          contracts.Semantic_Version,
	boolean:          Polygon_Boolean_Proc,
	offset:           Polygon_Offset_Proc,
}

CLIPPER2_PROVIDER :: Polygon_Provider{
	name = "Clipper2",
	version = {2, 0, 1},
	boolean = clipper2_boolean,
	offset = clipper2_offset,
}

polygon_set_destroy :: proc(
	set: ^Polygon_Set,
	allocator := context.allocator,
) {
	delete(set.points, allocator)
	delete(set.paths, allocator)
	set^ = {}
}

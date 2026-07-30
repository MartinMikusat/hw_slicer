package profiles

import contracts "../contracts"

PRINTER_PROFILE_SCHEMA_VERSION :: u32(1)
MATERIAL_PROFILE_SCHEMA_VERSION :: u32(1)
PROCESS_PROFILE_SCHEMA_VERSION :: u32(1)
DIALECT_PROFILE_SCHEMA_VERSION :: u32(1)

RATIO_SCALE :: u32(1_000_000)
MAX_BRIDGE_ANGLE_CANDIDATES :: 8

Ratio_Ppm :: distinct u32
Speed_Um_Per_Second :: distinct i64
Acceleration_Um_Per_Second_Squared :: distinct i64
Temperature_Celsius :: distinct i32
Angle_Millidegrees :: distinct i32
Area_Square_Micrometres :: distinct i64
Volume_Rate_Cubic_Micrometres_Per_Second :: distinct i64
Density_Milligrams_Per_Cubic_Centimetre :: distinct u32
Duration_Milliseconds :: distinct u32

Profile_Owner :: enum u8 {
	Invalid,
	Printer,
	Material,
	Process,
	Dialect,
	Derived,
}

Role_Overlap_Policy :: enum u8 {
	Invalid,
	Subtract_Higher_Priority,
}

Printable_Role :: enum u8 {
	Invalid,
	Perimeter,
	Bridge,
	Gap,
	Thin_Wall,
	Top_Skin,
	Bottom_Skin,
	Top_Bottom_Skin,
	Sparse_Infill,
	Support,
	Support_Interface,
}

Thin_Wall_Remainder_Policy :: enum u8 {
	Invalid,
	Preserve_Unprinted,
}

Gap_Allocation_Policy :: enum u8 {
	Invalid,
	One_Then_Two_Lines,
}

Bridge_Geometry_Policy :: enum u8 {
	Invalid,
	Previous_Layer_Expanded_Support,
}

Bridge_Direction_Policy :: enum u8 {
	Invalid,
	Bounded_Candidate_Score,
}

Support_Demand_Policy :: enum u8 {
	Invalid,
	Mesh_And_Layer_Projection,
}

Support_Mode :: enum u8 {
	Invalid,
	Everywhere,
	Build_Plate_Only,
}

Support_Pattern :: enum u8 {
	Invalid,
	Rectilinear,
}

Seam_Policy :: enum u8 {
	Invalid,
	Deterministic_Cost,
}

Retraction_Policy :: enum u8 {
	Invalid,
	Distance_And_Exterior_Crossing,
}

Travel_Policy :: enum u8 {
	Invalid,
	Direct,
}

Extrusion_Accumulation_Policy :: enum u8 {
	Invalid,
	Volume_Then_Fixed_Point_Length,
}

GCode_Dialect :: enum u8 {
	Invalid,
	Marlin_Conservative,
}

Coordinate_Mode :: enum u8 {
	Invalid,
	Absolute,
	Relative,
}

Extrusion_Mode :: enum u8 {
	Invalid,
	Absolute,
	Relative,
}

Line_Ending :: enum u8 {
	Invalid,
	LF,
	CRLF,
}

Skin_Target :: struct {
	thickness:    contracts.Micrometres,
	minimum_layers: u32,
}

Role_Target :: struct {
	speed:        Speed_Um_Per_Second,
	acceleration: Acceleration_Um_Per_Second_Squared,
	flow_ratio:   Ratio_Ppm,
	fan_ratio:    Ratio_Ppm,
}

Travel_Target :: struct {
	speed:        Speed_Um_Per_Second,
	acceleration: Acceleration_Um_Per_Second_Squared,
}

First_Layer_Overrides :: struct {
	line_width_enabled:        bool,
	line_width:                contracts.Micrometres,
	perimeter_count_enabled:   bool,
	perimeter_count:           u32,
	top_skin_enabled:          bool,
	top_skin:                  Skin_Target,
	bottom_skin_enabled:       bool,
	bottom_skin:               Skin_Target,
}

Printer_Profile :: struct {
	schema_version:       u32,
	build_size_x:         contracts.Micrometres,
	build_size_y:         contracts.Micrometres,
	build_size_z:         contracts.Micrometres,
	nozzle_diameter:      contracts.Micrometres,
	minimum_layer_height: contracts.Micrometres,
	maximum_layer_height: contracts.Micrometres,
	minimum_line_width:   contracts.Micrometres,
	maximum_line_width:   contracts.Micrometres,
	maximum_speed:        Speed_Um_Per_Second,
	maximum_acceleration: Acceleration_Um_Per_Second_Squared,
}

Material_Profile :: struct {
	schema_version:          u32,
	filament_diameter:       contracts.Micrometres,
	density:                 Density_Milligrams_Per_Cubic_Centimetre,
	minimum_nozzle_temperature: Temperature_Celsius,
	maximum_nozzle_temperature: Temperature_Celsius,
	minimum_bed_temperature: Temperature_Celsius,
	maximum_bed_temperature: Temperature_Celsius,
	minimum_fan_ratio:       Ratio_Ppm,
	maximum_fan_ratio:       Ratio_Ppm,
	maximum_volumetric_flow: Volume_Rate_Cubic_Micrometres_Per_Second,
}

Process_Profile :: struct {
	schema_version:          u32,

	first_layer_height:      contracts.Micrometres,
	layer_height:            contracts.Micrometres,
	adaptive_layers:         bool,
	minimum_adaptive_height: contracts.Micrometres,
	maximum_adaptive_height: contracts.Micrometres,

	perimeter_count:         u32,
	nominal_line_width:      contracts.Micrometres,
	top_skin:                Skin_Target,
	bottom_skin:             Skin_Target,
	solid_infill_spacing:    contracts.Micrometres,
	solid_infill_base_angle: Angle_Millidegrees,
	solid_infill_angle_step: Angle_Millidegrees,
	first_layer:             First_Layer_Overrides,

	role_overlap:            Role_Overlap_Policy,
	thin_wall_minimum_ratio: Ratio_Ppm,
	thin_wall_maximum_ratio: Ratio_Ppm,
	thin_wall_remainder:     Thin_Wall_Remainder_Policy,
	gap_allocation:          Gap_Allocation_Policy,
	maximum_centerline_deviation: contracts.Micrometres,

	bridge_geometry:         Bridge_Geometry_Policy,
	bridge_anchor_margin:    contracts.Micrometres,
	bridge_direction:        Bridge_Direction_Policy,
	bridge_angle_count:      u8,
	bridge_angles:           [MAX_BRIDGE_ANGLE_CANDIDATES]Angle_Millidegrees,
	minimum_bridge_area:     Area_Square_Micrometres,

	support_demand:          Support_Demand_Policy,
	support_mode:            Support_Mode,
	support_overhang_angle:  Angle_Millidegrees,
	support_clearance_xy:    contracts.Micrometres,
	support_clearance_z:     contracts.Micrometres,
	support_expansion:       contracts.Micrometres,
	support_density:         Ratio_Ppm,
	support_pattern:         Support_Pattern,
	support_interface_layers: u32,
	support_interface_spacing: contracts.Micrometres,

	perimeter:               Role_Target,
	skin:                    Role_Target,
	sparse_infill:           Role_Target,
	gap:                     Role_Target,
	bridge:                  Role_Target,
	support:                 Role_Target,
	support_interface:       Role_Target,
	travel:                  Travel_Target,

	nozzle_temperature:      Temperature_Celsius,
	bed_temperature:         Temperature_Celsius,
	minimum_layer_time:      Duration_Milliseconds,

	seam:                    Seam_Policy,
	retraction:              Retraction_Policy,
	retraction_distance:     contracts.Micrometres,
	minimum_retraction_travel: contracts.Micrometres,
	travel_policy:           Travel_Policy,
	z_hop_enabled:           bool,
	z_hop_height:            contracts.Micrometres,

	extrusion_accumulation:  Extrusion_Accumulation_Policy,
	extrusion_length_quantum_nm: u32,
}

Dialect_Profile :: struct {
	schema_version:       u32,
	dialect:             GCode_Dialect,
	coordinate_mode:     Coordinate_Mode,
	extrusion_mode:      Extrusion_Mode,
	xy_decimal_places:   u8,
	z_decimal_places:    u8,
	e_decimal_places:    u8,
	feed_decimal_places: u8,
	line_ending:         Line_Ending,
	line_numbers:        bool,
	checksums:           bool,
}

Effective_First_Layer :: struct {
	line_width:      contracts.Micrometres,
	perimeter_count: u32,
	top_skin:        Skin_Target,
	bottom_skin:     Skin_Target,
}

Resolved_Process_Profile :: struct {
	source:                  Process_Profile,
	first_layer:             Effective_First_Layer,
	thin_wall_minimum_width: contracts.Micrometres,
	thin_wall_maximum_width: contracts.Micrometres,
}

Resolved_Profiles :: struct {
	printer:  Printer_Profile,
	material: Material_Profile,
	process:  Resolved_Process_Profile,
	dialect:  Dialect_Profile,
}

Profile_Resolve_Error :: enum u8 {
	None,
	Printer_Schema,
	Printer_Geometry,
	Printer_Limits,
	Material_Schema,
	Material_Geometry,
	Material_Thermal_Limits,
	Material_Cooling_Limits,
	Process_Schema,
	Process_Layer_Target,
	Process_Shell_Target,
	Process_Thin_Wall_Target,
	Process_Bridge_Target,
	Process_Support_Target,
	Process_Motion_Target,
	Process_Thermal_Target,
	Process_Travel_Target,
	Process_Extrusion_Target,
	Dialect_Schema,
	Dialect_Target,
	Volumetric_Flow_Target,
}

printable_role_priority :: proc(role: Printable_Role) -> (u8, bool) {
	switch role {
	case .Perimeter:
		return 1, true
	case .Bridge:
		return 2, true
	case .Gap, .Thin_Wall:
		return 3, true
	case .Top_Skin, .Bottom_Skin, .Top_Bottom_Skin:
		return 4, true
	case .Sparse_Infill:
		return 5, true
	case .Support, .Support_Interface:
		return 6, true
	case .Invalid:
		return 0, false
	}
	return 0, false
}

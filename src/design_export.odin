package main

import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strings"

import contracts "./contracts"
import design "./design"
import features "./features"
import gcode "./gcode"
import polygon "./polygon"
import profiles "./profiles"

// ponytail: dev-only absolute directory for exported design G-code.
DEV_GCODE_DIRECTORY :: "/Users/martin/projects/hw_slicer/build/gcode"

// ponytail: the operator's RatOS V-Core 3 until printer profiles exist. Machine values come
// from the Klipper configuration captured in hw_ratos/research/captured-config/configfile.json:
// [stepper_*] position_max, [printer] max_velocity and max_accel, [extruder]
// max_extrude_only_velocity, max_extrude_only_accel (RatOS.cfg) and [firmware_retraction].
DEV_BED_X_UM :: 500_000
DEV_BED_Y_UM :: 500_000
DEV_BED_Z_UM :: 500_000
DEV_MAX_SPEED :: 300_000 // µm/s
DEV_MAX_ACCELERATION :: 3_000_000 // µm/s²
DEV_MAX_EXTRUDER_SPEED :: 120_000
DEV_MAX_EXTRUDER_ACCELERATION :: 800_000
DEV_RETRACTION_UM :: 500
DEV_RETRACTION_SPEED :: 120_000
// ponytail: PLA and toolhead assumptions; the captured configuration does not contain them.
DEV_NOZZLE_TEMPERATURE :: 210
DEV_BED_TEMPERATURE :: 60
DEV_MAX_VOLUMETRIC_FLOW :: 15_000_000_000 // µm³/s, 15 mm³/s
DEV_PRINT_ACCELERATION :: 1_000_000
DEV_TRAVEL_ACCELERATION :: 3_000_000
DEV_MINIMUM_RETRACTION_TRAVEL_UM :: 1_500

Design_Export_Error :: enum u8 {
	None,
	Profile,
	Outside_Bed,
	Too_Many_Moves,
	Emit,
	Directory,
	Publish,
}

design_export_error_text :: proc(error: Design_Export_Error) -> string {
	switch error {
	case .None:           return "exported"
	case .Profile:        return "printer profile rejected the design values"
	case .Outside_Bed:    return "the design leaves the bed"
	case .Too_Many_Moves: return "too many moves"
	case .Emit:           return "G-code emission failed"
	case .Directory:      return "output directory unavailable"
	case .Publish:        return "G-code file write failed"
	}
	return "unknown"
}

// Speeds in µm/s rounded to the 50 µm/s step that profiles require.
design_speed :: proc(mm_per_second: f64) -> profiles.Speed_Um_Per_Second {
	return profiles.Speed_Um_Per_Second(max(i64(1), i64(math.round(mm_per_second*1000/50)))*50)
}

design_um :: proc(mm: f64) -> contracts.Micrometres {
	return contracts.Micrometres(i64(math.round(mm*1000)))
}

// Builds and resolves the development profiles from the design's derived values.
design_profiles :: proc(d: ^design.Design, nozzle_mm: f64) -> (profiles.Resolved_Profiles, profiles.Profile_Resolve_Error) {
	nozzle := design_um(nozzle_mm)
	role := profiles.Role_Target{
		speed        = design_speed(d.print_speed),
		acceleration = DEV_PRINT_ACCELERATION,
		flow_ratio   = profiles.Ratio_Ppm(profiles.RATIO_SCALE),
		fan_ratio    = profiles.Ratio_Ppm(profiles.RATIO_SCALE),
	}
	printer := profiles.Printer_Profile{
		schema_version = profiles.PRINTER_PROFILE_SCHEMA_VERSION,
		axis_maximum_x = DEV_BED_X_UM,
		axis_maximum_y = DEV_BED_Y_UM,
		axis_maximum_z = DEV_BED_Z_UM,
		extruder_count = 1,
		nozzle_diameter = nozzle,
		minimum_layer_height = contracts.Micrometres(i64(nozzle)/5),
		maximum_layer_height = contracts.Micrometres(i64(nozzle)*4/5),
		minimum_line_width = contracts.Micrometres(i64(nozzle)/2),
		maximum_line_width = contracts.Micrometres(i64(nozzle)*2),
		maximum_speed = DEV_MAX_SPEED,
		maximum_acceleration = DEV_MAX_ACCELERATION,
		maximum_extruder_speed = DEV_MAX_EXTRUDER_SPEED,
		maximum_extruder_acceleration = DEV_MAX_EXTRUDER_ACCELERATION,
	}
	material := profiles.Material_Profile{
		schema_version = profiles.MATERIAL_PROFILE_SCHEMA_VERSION,
		filament_diameter = design_um(d.filament_diameter),
		density = 1_240,
		minimum_nozzle_temperature = 180,
		maximum_nozzle_temperature = 230,
		maximum_bed_temperature = 70,
		maximum_fan_ratio = profiles.Ratio_Ppm(profiles.RATIO_SCALE),
		maximum_volumetric_flow = DEV_MAX_VOLUMETRIC_FLOW,
	}
	line_width := design_um(d.line_width)
	layer_height := design_um(d.layer_height)
	process := profiles.Process_Profile{
		schema_version = profiles.PROCESS_PROFILE_SCHEMA_VERSION,
		first_layer_height = design_um(d.first_layer_height),
		layer_height = layer_height,
		minimum_adaptive_height = printer.minimum_layer_height,
		maximum_adaptive_height = printer.maximum_layer_height,
		perimeter_count = 1,
		nominal_line_width = line_width,
		top_skin = {layer_height, 1},
		bottom_skin = {layer_height, 1},
		solid_infill_spacing = line_width,
		solid_infill_angle_step = 90_000,
		role_overlap = .Subtract_Higher_Priority,
		thin_wall_minimum_ratio = 600_000,
		thin_wall_maximum_ratio = 1_300_000,
		thin_wall_remainder = .Preserve_Unprinted,
		gap_allocation = .One_Then_Two_Lines,
		bridge_geometry = .Previous_Layer_Expanded_Support,
		bridge_direction = .Bounded_Candidate_Score,
		bridge_angle_count = 1,
		minimum_bridge_area = 1_000_000,
		support_demand = .Mesh_And_Layer_Projection,
		support_mode = .Everywhere,
		support_overhang_angle = 45_000,
		support_density = 150_000,
		support_pattern = .Rectilinear,
		support_interface_layers = 1,
		support_interface_spacing = line_width,
		perimeter = role,
		skin = role,
		sparse_infill = role,
		gap = role,
		bridge = role,
		support = role,
		support_interface = role,
		travel = {design_speed(d.travel_speed), DEV_TRAVEL_ACCELERATION},
		nozzle_temperature = DEV_NOZZLE_TEMPERATURE,
		bed_temperature = DEV_BED_TEMPERATURE,
		minimum_layer_time = 5_000,
		minimum_layer_time_policy = .Slowdown_Then_Dwell,
		minimum_print_speed = min(design_speed(d.print_speed), 10_000),
		seam = .Deterministic_Cost,
		seam_visibility = .Rear_Maximum_Y,
		retraction = .Distance_And_Exterior_Crossing,
		retraction_distance = DEV_RETRACTION_UM,
		minimum_retraction_travel = DEV_MINIMUM_RETRACTION_TRAVEL_UM,
		retraction_speed = DEV_RETRACTION_SPEED,
		recovery_speed = DEV_RETRACTION_SPEED,
		retraction_acceleration = DEV_MAX_EXTRUDER_ACCELERATION,
		travel_policy = .Direct,
		extrusion_accumulation = .Volume_Then_Fixed_Point_Length,
		extrusion_length_quantum_nm = 10,
	}
	dialect := profiles.Dialect_Profile{
		schema_version = profiles.DIALECT_PROFILE_SCHEMA_VERSION,
		dialect = .Klipper,
		coordinate_mode = .Absolute,
		extrusion_mode = .Relative,
		xy_decimal_places = 3,
		z_decimal_places = 3,
		e_decimal_places = 5,
		feed_decimal_places = 0,
		line_ending = .LF,
		acceleration_commands = .Profile_Approved,
		output_mode = .File,
		emit_layer_comments = true,
	}
	return profiles.profiles_resolve(printer, material, process, dialect)
}

@(private = "file")
Plan_Builder :: struct {
	profile:     ^profiles.Resolved_Profiles,
	layers:      [dynamic]features.Motion_Layer,
	operations:  [dynamic]features.Motion_Operation,
	result:      features.Motion_Plan_Result,
	position:    polygon.Polygon_Point,
	filament_nm: i128, // filament fed so far, before quantizing
	emitted_nm:  i128, // filament emitted so far, in 10 nm steps
}

@(private = "file")
plan_point :: proc(p: [3]f64) -> (polygon.Polygon_Point, bool) {
	x := design_um(p.x)+DEV_BED_X_UM/2
	y := design_um(p.y)+DEV_BED_Y_UM/2
	inside := i64(x) >= 0 && i64(x) <= DEV_BED_X_UM && i64(y) >= 0 && i64(y) <= DEV_BED_Y_UM
	return {x, y}, inside
}

@(private = "file")
plan_operation :: proc(b: ^Plan_Builder, operation: features.Motion_Operation) {
	operation := operation
	layer := &b.layers[len(b.layers)-1]
	operation.stable_id = contracts.Stable_ID(u64(len(b.operations))+1)
	operation.layer_index = layer.layer_index
	operation.duration_us = max(operation.duration_us, 1)
	append(&b.operations, operation)
	layer.operation_count += 1
	layer.motion_duration_us += operation.duration_us
	layer.base_duration_us += operation.duration_us
	layer.planned_duration_us += operation.duration_us
	#partial switch operation.kind {
	case .Retract: b.result.retraction_count += 1
	case .Travel:  b.result.travel_count += 1
	case .Extrude: b.result.extrusion_count += 1
	}
	b.result.total_motion_duration_us += operation.duration_us
	b.result.total_planned_duration_us += operation.duration_us
	b.position = operation.point_b
}

@(private = "file")
plan_duration_us :: proc(distance_um: f64, speed: profiles.Speed_Um_Per_Second) -> u64 {
	return u64(math.ceil(distance_um/f64(speed)*1_000_000))
}

@(private = "file")
plan_filament :: proc(b: ^Plan_Builder, speed: profiles.Speed_Um_Per_Second, sign: i128) -> features.Motion_Operation {
	process := b.profile.process.source
	return {
		kind = .Retract if sign < 0 else .Recover,
		point_a = b.position,
		point_b = b.position,
		speed = speed,
		acceleration = process.retraction_acceleration,
		filament_delta_nm = sign*i128(i64(process.retraction_distance))*1_000,
		duration_us = plan_duration_us(f64(i64(process.retraction_distance)), speed),
	}
}

// Converts the layer-ordered design toolpath into a validated motion plan in bed coordinates.
// Long travels retract and recover; the extrusion length follows the bead's stadium area.
design_motion_plan :: proc(t: ^design.Toolpath, profile: ^profiles.Resolved_Profiles) -> (features.Motion_Plan_Result, Design_Export_Error) {
	b := Plan_Builder{profile = profile}
	b.layers = make([dynamic]features.Motion_Layer)
	b.operations = make([dynamic]features.Motion_Operation, 0, len(t.moves)+len(t.moves)/4)
	cleanup :: proc(b: ^Plan_Builder) {
		delete(b.layers)
		delete(b.operations)
	}
	start, start_inside := plan_point(t.start)
	if !start_inside {cleanup(&b); return {}, .Outside_Bed}
	b.position = start
	process := profile.process.source
	role, _ := features.motion_role_target(profile.process, .Perimeter)
	filament_area := math.PI*f64(i64(profile.material.filament_diameter))*f64(i64(profile.material.filament_diameter))/4
	z := t.start.z
	append(&b.layers, features.Motion_Layer{z = design_um(z), speed_scale_ppm = profiles.RATIO_SCALE})
	for move in t.moves {
		if move.to.z != z {
			z = move.to.z
			append(&b.layers, features.Motion_Layer{
				layer_index = u32(len(b.layers)),
				z = design_um(z),
				operation_offset = u64(len(b.operations)),
				speed_scale_ppm = profiles.RATIO_SCALE,
			})
		}
		target, inside := plan_point(move.to)
		if !inside {cleanup(&b); return {}, .Outside_Bed}
		dx := f64(i64(target.x)-i64(b.position.x))
		dy := f64(i64(target.y)-i64(b.position.y))
		distance_um := math.sqrt(dx*dx+dy*dy)
		if target == b.position {continue}
		if !move.extrude {
			long := distance_um >= f64(i64(process.minimum_retraction_travel))
			if long {plan_operation(&b, plan_filament(&b, process.retraction_speed, -1))}
			plan_operation(&b, {
				kind = .Travel,
				point_a = b.position,
				point_b = target,
				speed = process.travel.speed,
				acceleration = process.travel.acceleration,
				duration_us = plan_duration_us(distance_um, process.travel.speed),
			})
			if long {plan_operation(&b, plan_filament(&b, process.recovery_speed, 1))}
			continue
		}
		w, h := move.width*1000, move.height*1000
		area := (w-h)*h+math.PI*h*h/4
		b.filament_nm += i128(math.round(distance_um*area/filament_area*1000))
		emitted := b.filament_nm/10*10
		delta := max(emitted-b.emitted_nm, 10)
		b.emitted_nm += delta
		speed := role.speed
		plan_operation(&b, {
			kind = .Extrude,
			role = .Perimeter,
			point_a = b.position,
			point_b = target,
			speed = speed,
			acceleration = role.acceleration,
			fan_ratio = role.fan_ratio,
			filament_delta_nm = delta,
			duration_us = plan_duration_us(distance_um, speed),
		})
	}
	for &layer, index in b.layers {
		layer.stable_id = contracts.Stable_ID(u64(1) << 40+u64(index)+1)
	}
	if len(b.operations) > int(max(u32)) {cleanup(&b); return {}, .Too_Many_Moves}
	b.result.layers = b.layers[:]
	b.result.operations = b.operations[:]
	return b.result, .None
}

// Writes the G-code for the loaded design to DEV_GCODE_DIRECTORY and returns its path,
// allocated with `allocator`.
design_export :: proc(s: ^Design_State, allocator := context.allocator) -> (path: string, error: Design_Export_Error) {
	assert(s.active)
	profile, profile_error := design_profiles(&s.evaluated, design_nozzle(s))
	if profile_error != .None {return "", .Profile}
	plan, plan_error := design_motion_plan(&s.toolpath, &profile)
	if plan_error != .None {return "", plan_error}
	defer {
		delete(plan.layers)
		delete(plan.operations)
	}
	emitted, emit_error := gcode.klipper_emit(plan, profile)
	if emit_error != .None {return "", .Emit}
	defer gcode.klipper_result_destroy(&emitted)
	if os.make_directory_all(DEV_GCODE_DIRECTORY) != nil && !os.is_dir(DEV_GCODE_DIRECTORY) {return "", .Directory}
	stem := strings.trim_suffix(filepath.base(s.path), filepath.ext(s.path))
	name := fmt.tprintf("%s-%.2fmm.gcode", stem, design_nozzle(s))
	destination, _ := filepath.join({DEV_GCODE_DIRECTORY, name}, allocator)
	if gcode.klipper_file_publish(emitted, profile, plan, destination, replace_existing = true) != .None {
		delete(destination, allocator)
		return "", .Publish
	}
	return destination, .None
}

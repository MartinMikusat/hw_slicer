package gcode

import profiles "../profiles"
import toolpath "../toolpath"
import workers "../workers"

KLIPPER_DEFAULT_SQUARE_CORNER_VELOCITY :: 5.0
KLIPPER_DEFAULT_INSTANTANEOUS_CORNER_VELOCITY :: 1.0
KLIPPER_DEFAULT_ARC_RESOLUTION :: 1.0

klipper_planner_limits :: proc(
	profile: profiles.Resolved_Profiles,
	minimum_cruise_ratio_ppm: i64,
) -> toolpath.Limits {
	max_velocity := f64(i64(profile.printer.maximum_speed)) * 0.001
	max_accel := f64(i64(profile.printer.maximum_acceleration)) * 0.001
	cruise_ratio_ppm := i64(profile.printer.minimum_cruise_ratio)
	if minimum_cruise_ratio_ppm >= 0 {cruise_ratio_ppm = minimum_cruise_ratio_ppm}
	cruise_ratio := f64(cruise_ratio_ppm) / f64(profiles.RATIO_SCALE)
	return {
		max_velocity                  = max_velocity,
		max_accel                     = max_accel,
		square_corner_velocity        = KLIPPER_DEFAULT_SQUARE_CORNER_VELOCITY,
		minimum_cruise_ratio          = cruise_ratio,
		max_z_velocity                = max_velocity,
		max_z_accel                   = max_accel,
		max_extrude_only_velocity     = f64(i64(profile.printer.maximum_extruder_speed)) * 0.001,
		max_extrude_only_accel        = f64(i64(profile.printer.maximum_extruder_acceleration)) * 0.001,
		instantaneous_corner_velocity = KLIPPER_DEFAULT_INSTANTANEOUS_CORNER_VELOCITY,
		arc_resolution                = KLIPPER_DEFAULT_ARC_RESOLUTION,
		filament_diameter             = f64(i64(profile.material.filament_diameter)) * 0.001,
	}
}

@(private = "file")
Klipper_Estimate_Context :: struct {
	bytes:   []u8,
	cuts:    []Klipper_Plan_Cut,
	limits:  toolpath.Limits,
	seconds: []f64,
}

klipper_estimate_seconds :: proc(
	result: Klipper_Result,
	profile: profiles.Resolved_Profiles,
	minimum_cruise_ratio_ppm: i64,
) -> f64 {
	if len(result.bytes) == 0 {return 0}
	span_count := len(result.plan_cuts) + 1
	ctx := Klipper_Estimate_Context{
		bytes   = result.bytes,
		cuts    = result.plan_cuts,
		limits  = klipper_planner_limits(profile, minimum_cruise_ratio_ppm),
		seconds = make([]f64, span_count),
	}
	defer delete(ctx.seconds)
	workers.parallel_for(span_count, &ctx, proc(c: ^Klipper_Estimate_Context, index: int) {
		start := u64(0) if index == 0 else c.cuts[index-1].byte_offset
		end := u64(len(c.bytes)) if index == len(c.cuts) else c.cuts[index].byte_offset
		assert(start <= end && end <= u64(len(c.bytes)))
		path: toolpath.Path
		toolpath.init(&path, 1, c.limits, record_deposits = false)
		defer toolpath.destroy(&path)
		if index > 0 {
			cut := c.cuts[index-1]
			toolpath.resume(
				&path,
				{f64(i64(cut.x)) * 0.001, f64(i64(cut.y)) * 0.001, f64(i64(cut.z)) * 0.001},
				f64(cut.feed),
				f64(cut.acceleration),
				absolute_e = false,
			)
		}
		toolpath.feed(&path, c.bytes[start:end])
		toolpath.finish(&path)
		c.seconds[index] = path.cursor_time + path.next_dwell
	}, g_gcode_worker_threads)
	total := 0.0
	for seconds in ctx.seconds {total += seconds}
	return total
}

package pipeline

import "base:runtime"
import "core:math"
import "core:strconv"
import "core:strings"

import contracts "../contracts"
import features "../features"
import profiles "../profiles"

Modifier_Zone :: struct {
	z_min_um:        contracts.Micrometres,
	z_max_um:        contracts.Micrometres,
	use_xy_box:      bool,
	x_min_um:        contracts.Micrometres,
	x_max_um:        contracts.Micrometres,
	y_min_um:        contracts.Micrometres,
	y_max_um:        contracts.Micrometres,
	has_speed_scale: bool,
	speed_scale:     f64,
	has_fan_pct:     bool,
	fan_pct:         f64,
	has_flow_scale:  bool,
	flow_scale:      f64,
}

// Parses a CLI modifier spec:
//   "z:10..20:speed_scale=0.5"  or  "z:5..15:fan=100"  or  "box:100,100,0,200,200,10:flow=1.05"
modifier_parse :: proc(spec: string) -> (mod: Modifier_Zone, ok: bool) {
	parts := strings.split(spec, ":", context.temp_allocator)
	if len(parts) != 3 {return {}, false}

	if strings.equal_fold(parts[0], "z") {
		rng := strings.split(parts[1], "..", context.temp_allocator)
		if len(rng) != 2 {return {}, false}
		z0, ok0 := strconv.parse_f64(rng[0])
		z1, ok1 := strconv.parse_f64(rng[1])
		if !ok0 || !ok1 || z1 <= z0 {return {}, false}
		mod.z_min_um = contracts.Micrometres(i64(math.round(z0 * 1000.0)))
		mod.z_max_um = contracts.Micrometres(i64(math.round(z1 * 1000.0)))
	} else if strings.equal_fold(parts[0], "box") {
		coords := strings.split(parts[1], ",", context.temp_allocator)
		if len(coords) != 6 {return {}, false}
		vals: [6]f64
		for i in 0..<6 {
			v, vok := strconv.parse_f64(coords[i])
			if !vok {return {}, false}
			vals[i] = v
		}
		mod.use_xy_box = true
		mod.x_min_um = contracts.Micrometres(i64(math.round(min(vals[0], vals[3]) * 1000.0)))
		mod.x_max_um = contracts.Micrometres(i64(math.round(max(vals[0], vals[3]) * 1000.0)))
		mod.y_min_um = contracts.Micrometres(i64(math.round(min(vals[1], vals[4]) * 1000.0)))
		mod.y_max_um = contracts.Micrometres(i64(math.round(max(vals[1], vals[4]) * 1000.0)))
		mod.z_min_um = contracts.Micrometres(i64(math.round(min(vals[2], vals[5]) * 1000.0)))
		mod.z_max_um = contracts.Micrometres(i64(math.round(max(vals[2], vals[5]) * 1000.0)))
	} else {
		return {}, false
	}

	kv := strings.split(parts[2], "=", context.temp_allocator)
	if len(kv) != 2 {return {}, false}
	val, vok := strconv.parse_f64(kv[1])
	if !vok {return {}, false}
	switch kv[0] {
	case "speed_scale":
		mod.has_speed_scale = true
		mod.speed_scale = clamp(val, 0.1, 2.0)
	case "fan", "fan_percent":
		mod.has_fan_pct = true
		mod.fan_pct = clamp(val, 0.0, 100.0)
	case "flow", "flow_scale":
		mod.has_flow_scale = true
		mod.flow_scale = clamp(val, 0.5, 1.5)
	case:
		return {}, false
	}
	return mod, true
}

// Applies height-range and box-volume modifiers onto Motion_Plan_Result while maintaining
// strict Klipper quantization invariants (% 50 speed, % 10 filament, material fan bounds).
// Speed changes rescale each operation's duration and the layer and plan totals. A layer whose
// speed-up would end below the minimum layer time keeps its original speeds.
modifiers_apply_motion :: proc(
	motion: ^features.Motion_Plan_Result,
	modifiers: []Modifier_Zone,
	profile: profiles.Resolved_Profiles,
) -> u64 {
	if motion == nil || len(modifiers) == 0 {return 0}
	process := profile.process.source
	quantum := i128(max(u32(10), process.extrusion_length_quantum_nm))
	minimum_layer_us := u64(process.minimum_layer_time)*1_000
	modified: u64

	Original_Speed :: struct {
		index:       int,
		speed:       profiles.Speed_Um_Per_Second,
		duration_us: u64,
	}
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	originals := make([dynamic]Original_Speed, 0, 64, context.temp_allocator)

	for &layer in motion.layers {
		op_start := int(layer.operation_offset)
		op_end := op_start + int(layer.operation_count)
		clear(&originals)
		for oi in op_start..<op_end {
			op := &motion.operations[oi]
			if op.kind != .Extrude {continue}
			mx := contracts.Micrometres((i64(op.point_a.x) + i64(op.point_b.x)) / 2)
			my := contracts.Micrometres((i64(op.point_a.y) + i64(op.point_b.y)) / 2)
			original := Original_Speed{oi, op.speed, op.duration_us}
			for mod in modifiers {
				if i64(layer.z) < i64(mod.z_min_um) || i64(layer.z) > i64(mod.z_max_um) {continue}
				if mod.use_xy_box &&
				   (i64(mx) < i64(mod.x_min_um) || i64(mx) > i64(mod.x_max_um) ||
				    i64(my) < i64(mod.y_min_um) || i64(my) > i64(mod.y_max_um)) {
					continue
				}
				if mod.has_speed_scale {
					raw_v := i64(math.round(f64(i64(op.speed)) * mod.speed_scale))
					raw_v = clamp(raw_v, i64(process.minimum_print_speed), i64(profile.printer.maximum_speed))
					qv := (raw_v / 50) * 50
					if qv < i64(process.minimum_print_speed) {
						qv = ((i64(process.minimum_print_speed) + 49) / 50) * 50
					}
					op.speed = profiles.Speed_Um_Per_Second(qv)
				}
				if mod.has_fan_pct {
					// The material fan bounds are hard limits that G-code emission enforces, so a
					// modifier below the material minimum (including fan=0) prints at that minimum.
					ppm := profiles.Ratio_Ppm(u32(math.round(mod.fan_pct * 10_000.0)))
					op.fan_ratio = clamp(ppm, profile.material.minimum_fan_ratio, profile.material.maximum_fan_ratio)
				}
				if mod.has_flow_scale {
					raw_e := i128(math.round(f64(op.filament_delta_nm) * mod.flow_scale))
					qe := (raw_e / quantum) * quantum
					if qe < quantum {qe = quantum}
					op.filament_delta_nm = qe
				}
				modified += 1
			}
			if op.speed != original.speed {
				op.duration_us = modifier_scaled_duration(original.duration_us, original.speed, op.speed)
				append(&originals, original)
			}
		}
		if len(originals) == 0 {continue}

		motion_us := layer.motion_duration_us
		for original in originals {
			motion_us = motion_us - original.duration_us + motion.operations[original.index].duration_us
		}
		planned_us := motion_us + layer.dwell_duration_us
		if planned_us < layer.planned_duration_us && planned_us < minimum_layer_us {
			for original in originals {
				motion.operations[original.index].speed = original.speed
				motion.operations[original.index].duration_us = original.duration_us
			}
			continue
		}
		motion.total_motion_duration_us = motion.total_motion_duration_us - layer.motion_duration_us + motion_us
		motion.total_planned_duration_us = motion.total_planned_duration_us - layer.planned_duration_us + planned_us
		layer.motion_duration_us = motion_us
		layer.planned_duration_us = planned_us
	}
	return modified
}

// The duration of a move at `new_speed` that took `duration_us` at `old_speed`, at least 1 µs.
@(private = "file")
modifier_scaled_duration :: proc(duration_us: u64, old_speed, new_speed: profiles.Speed_Um_Per_Second) -> u64 {
	if i64(new_speed) <= 0 {return duration_us}
	scaled := (u128(duration_us)*u128(i64(old_speed)) + u128(i64(new_speed)) - 1) / u128(i64(new_speed))
	return max(u64(1), u64(min(scaled, u128(max(u64)))))
}

package features

import "core:math"

// Klipper-compatible trapezoidal acceleration + square-corner-velocity (SCV) print-time estimator.
// Produces realistic print duration estimates accounting for acceleration/deceleration and cornering.
Print_Time_Estimate :: struct {
	total_seconds:       f64,
	extrude_seconds:     f64,
	travel_seconds:      f64,
	retract_seconds:     f64,
	dwell_seconds:       f64,
	constant_vel_seconds: f64,
}

motion_plan_estimate_klipper_time :: proc(
	motion: Motion_Plan_Result,
	square_corner_velocity_mm_s := 5.0,
) -> Print_Time_Estimate {
	est := Print_Time_Estimate{}
	scv := max(1.0, square_corner_velocity_mm_s)

	has_prev := false
	prev_dx, prev_dy: f64
	prev_v: f64

	for op in motion.operations {
		est.constant_vel_seconds += f64(op.duration_us) / 1_000_000.0
		switch op.kind {
		case .Dwell:
			dt := f64(op.duration_us) / 1_000_000.0
			est.dwell_seconds += dt
			est.total_seconds += dt
			has_prev = false
		case .Retract, .Recover:
			dt := f64(op.duration_us) / 1_000_000.0
			est.retract_seconds += dt
			est.total_seconds += dt
			has_prev = false
		case .Travel, .Extrude:
			dx := f64(i64(op.point_b.x) - i64(op.point_a.x)) / 1000.0
			dy := f64(i64(op.point_b.y) - i64(op.point_a.y)) / 1000.0
			dist := math.hypot(dx, dy)
			ux, uy: f64
			exit_ux, exit_uy: f64
			if op.kind == .Extrude && op.arc != .None {
				rx0 := f64(i64(op.point_a.x) - i64(op.arc_center.x)) / 1000.0
				ry0 := f64(i64(op.point_a.y) - i64(op.arc_center.y)) / 1000.0
				rx1 := f64(i64(op.point_b.x) - i64(op.arc_center.x)) / 1000.0
				ry1 := f64(i64(op.point_b.y) - i64(op.arc_center.y)) / 1000.0
				r := math.hypot(rx0, ry0)
				if r > 1e-6 {
					a0 := math.atan2(ry0, rx0)
					a1 := math.atan2(ry1, rx1)
					sweep := a1 - a0
					if op.arc == .CCW {
						if sweep <= 0 {sweep += 2.0 * math.PI}
						ux, uy = -ry0 / r, rx0 / r
						r1 := max(1e-6, math.hypot(rx1, ry1))
						exit_ux, exit_uy = -ry1 / r1, rx1 / r1
					} else {
						if sweep >= 0 {sweep -= 2.0 * math.PI}
						sweep = -sweep
						ux, uy = ry0 / r, -rx0 / r
						r1 := max(1e-6, math.hypot(rx1, ry1))
						exit_ux, exit_uy = ry1 / r1, -rx1 / r1
					}
					dist = r * sweep
				} else {
					if dist < 1e-6 {continue}
					ux, uy = dx / dist, dy / dist
					exit_ux, exit_uy = ux, uy
				}
			} else {
				if dist < 1e-6 {continue}
				ux, uy = dx / dist, dy / dist
				exit_ux, exit_uy = ux, uy
			}
			v_cruise := max(0.1, f64(i64(op.speed)) / 1000.0)
			accel := max(10.0, f64(i64(op.acceleration)) / 1000.0)

			// Klipper junction speed from square_corner_velocity and turning angle.
			v_entry := 0.0
			if has_prev {
				cos_t := clamp(prev_dx*ux + prev_dy*uy, -1.0, 1.0)
				sin_half := math.sqrt(max(0.0, 0.5 * (1.0 - cos_t)))
				if sin_half < 1e-4 {
					v_entry = min(prev_v, v_cruise)
				} else {
					// Klipper centripetal junction approximation: v_j = scv * sqrt((1 + cos_t) / (1 - cos_t))
					v_j := scv * math.sqrt(max(0.0, (1.0 + cos_t) / max(1e-6, 1.0 - cos_t)))
					v_entry = min(min(prev_v, v_cruise), v_j)
				}
			}
			v_exit := v_entry

			// Trapezoidal / triangular acceleration time.
			dt := trap_move_time(dist, v_entry, v_cruise, v_exit, accel)
			if op.kind == .Travel && i64(op.z_hop_um) > 0 {
				hop_mm := f64(i64(op.z_hop_um)) / 1000.0
				dt += 2.0 * trap_move_time(hop_mm, 0.0, min(v_cruise, 25.0), 0.0, min(accel, 500.0))
			}
			if op.kind == .Extrude {
				est.extrude_seconds += dt
			} else {
				est.travel_seconds += dt
			}
			est.total_seconds += dt
			has_prev = true
			prev_dx, prev_dy = exit_ux, exit_uy
			prev_v = v_cruise
		case .Invalid:
		}
	}
	return est
}

@(private = "file")
trap_move_time :: proc(dist, v0, v_max, v1, accel: f64) -> f64 {
	if dist <= 0 || v_max <= 0 || accel <= 0 {return 0}
	d_acc := max(0.0, (v_max*v_max - v0*v0) / (2.0 * accel))
	d_dec := max(0.0, (v_max*v_max - v1*v1) / (2.0 * accel))
	if d_acc + d_dec <= dist {
		t_acc := max(0.0, (v_max - v0) / accel)
		t_dec := max(0.0, (v_max - v1) / accel)
		t_cruise := (dist - d_acc - d_dec) / v_max
		return t_acc + t_cruise + t_dec
	}
	// Triangular profile: peak velocity v_p < v_max.
	v_p := math.sqrt(max(0.0, 0.5*(v0*v0 + v1*v1) + accel*dist))
	return max(0.0, (v_p - v0)/accel) + max(0.0, (v_p - v1)/accel)
}

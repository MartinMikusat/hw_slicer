package features

import "base:runtime"
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

	Estimate_Move :: struct {
		operation:   int,
		dist:        f64,
		v_cruise:    f64,
		accel:       f64,
		v_entry:     f64, // junction speed limit, then the planned entry speed
		stop_before: bool,
	}
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	moves := make([dynamic]Estimate_Move, 0, len(motion.operations), context.temp_allocator)

	// Pass 1: per-move geometry and the junction speed limit with the previous move.
	stop_pending := true
	prev_ux, prev_uy: f64
	for op, oi in motion.operations {
		est.constant_vel_seconds += f64(op.duration_us) / 1_000_000.0
		switch op.kind {
		case .Dwell:
			dt := f64(op.duration_us) / 1_000_000.0
			est.dwell_seconds += dt
			est.total_seconds += dt
			stop_pending = true
		case .Retract, .Recover:
			dt := f64(op.duration_us) / 1_000_000.0
			est.retract_seconds += dt
			est.total_seconds += dt
			stop_pending = true
		case .Travel, .Extrude:
			dx := f64(i64(op.point_b.x) - i64(op.point_a.x)) / 1000.0
			dy := f64(i64(op.point_b.y) - i64(op.point_a.y)) / 1000.0
			dist := math.hypot(dx, dy)
			ux, uy: f64
			exit_ux, exit_uy: f64
			r := 0.0
			if op.kind == .Extrude && op.arc != .None {
				rx0 := f64(i64(op.point_a.x) - i64(op.arc_center.x)) / 1000.0
				ry0 := f64(i64(op.point_a.y) - i64(op.arc_center.y)) / 1000.0
				rx1 := f64(i64(op.point_b.x) - i64(op.arc_center.x)) / 1000.0
				ry1 := f64(i64(op.point_b.y) - i64(op.arc_center.y)) / 1000.0
				r = math.hypot(rx0, ry0)
				if r > 1e-6 {
					a0 := math.atan2(ry0, rx0)
					a1 := math.atan2(ry1, rx1)
					sweep := a1 - a0
					r1 := max(1e-6, math.hypot(rx1, ry1))
					if op.arc == .CCW {
						if sweep <= 0 {sweep += 2.0 * math.PI}
						ux, uy = -ry0 / r, rx0 / r
						exit_ux, exit_uy = -ry1 / r1, rx1 / r1
					} else {
						if sweep >= 0 {sweep -= 2.0 * math.PI}
						sweep = -sweep
						ux, uy = ry0 / r, -rx0 / r
						exit_ux, exit_uy = ry1 / r1, -rx1 / r1
					}
					dist = r * sweep
				}
			}
			if r <= 1e-6 {
				if dist < 1e-6 {continue}
				ux, uy = dx / dist, dy / dist
				exit_ux, exit_uy = ux, uy
			}
			v_cruise := max(0.1, f64(i64(op.speed)) / 1000.0)
			accel := max(10.0, f64(i64(op.acceleration)) / 1000.0)

			// Klipper junction speed from square_corner_velocity and turning angle.
			v_junction := 0.0
			if !stop_pending && len(moves) > 0 {
				prev := moves[len(moves)-1]
				cos_t := clamp(prev_ux*ux + prev_uy*uy, -1.0, 1.0)
				v_junction = min(prev.v_cruise, v_cruise)
				if 0.5 * (1.0 - cos_t) >= 1e-8 {
					// Centripetal junction approximation: v_j = scv * sqrt((1 + cos_t) / (1 - cos_t))
					v_junction = min(v_junction, scv * math.sqrt(max(0.0, (1.0 + cos_t) / max(1e-6, 1.0 - cos_t))))
				}
			}
			// A z-hop travel lifts before and lowers after its XY move, so it stops at both ends.
			hop := op.kind == .Travel && i64(op.z_hop_um) > 0
			if hop {v_junction = 0}
			append(&moves, Estimate_Move{
				operation = oi,
				dist = dist,
				v_cruise = v_cruise,
				accel = accel,
				v_entry = v_junction,
				stop_before = stop_pending || hop,
			})
			stop_pending = hop
			prev_ux, prev_uy = exit_ux, exit_uy
		case .Invalid:
		}
	}

	// Pass 2 (backward): each move must be able to decelerate to the next move's entry speed,
	// and the toolhead stops after the last move and before every dwell, retraction or recovery.
	next_entry := 0.0
	for i := len(moves) - 1; i >= 0; i -= 1 {
		m := &moves[i]
		m.v_entry = min(m.v_entry, math.sqrt(next_entry*next_entry + 2.0*m.accel*m.dist))
		next_entry = 0.0 if m.stop_before else m.v_entry
	}
	// Pass 3 (forward): each move must be able to accelerate from its entry speed to the next
	// move's entry speed.
	for i in 0..<len(moves) - 1 {
		if moves[i+1].stop_before {continue}
		m := moves[i]
		moves[i+1].v_entry = min(moves[i+1].v_entry, math.sqrt(m.v_entry*m.v_entry + 2.0*m.accel*m.dist))
	}

	for m, i in moves {
		v_exit := 0.0
		if i + 1 < len(moves) && !moves[i+1].stop_before {v_exit = moves[i+1].v_entry}
		dt := trap_move_time(m.dist, m.v_entry, m.v_cruise, v_exit, m.accel)
		op := motion.operations[m.operation]
		if op.kind == .Travel && i64(op.z_hop_um) > 0 {
			hop_mm := f64(i64(op.z_hop_um)) / 1000.0
			dt += 2.0 * trap_move_time(hop_mm, 0.0, min(m.v_cruise, 25.0), 0.0, min(m.accel, 500.0))
		}
		if op.kind == .Extrude {
			est.extrude_seconds += dt
		} else {
			est.travel_seconds += dt
		}
		est.total_seconds += dt
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

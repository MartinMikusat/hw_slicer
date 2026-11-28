package main

import "core:strings"
import "core:time"
import devlog "devlog:."

import mr "./moonraker"
import tp "./toolpath"

// Tracks the live print position at the display rate. During a print the active G-code file is
// streamed from Moonraker, planned with Klipper's look-ahead planner, locked to live position
// samples, and uploaded as 3D extruded beads to hw_slicer's Metal renderer.

TRACKING_MOVES_MAX :: 1 << 17
TRACKING_READ_AHEAD_BYTES :: 512 * 1024
TRACKING_PARSE_SECONDS :: 0.004
REPLAY_SAMPLES :: 16
REPLAY_DELAY_SECONDS :: 0.3
TRACKING_SITE :: devlog.Site{feature = "motion", operation = "print_tracking"}
REVEAL_ALL :: 1e9

Tracking_Status :: enum u8 {
	Off,
	Loading,
	Syncing,
	Locked,
	Replay,
}

TRACKING_STATUS_NAMES := [Tracking_Status]string{
	.Off     = "",
	.Loading = "reading G-code",
	.Syncing = "syncing to G-code",
	.Locked  = "G-code locked",
	.Replay  = "live replay",
}

Replay_Sample :: struct {
	eventtime: f64,
	pos:       [3]f32,
}

Print_Tracking :: struct {
	active:          bool,
	file:            string,
	path:            tp.Path,
	lock:            tp.Lock,
	chunk_used:      int,
	failed:          bool,
	samples:         [REPLAY_SAMPLES]Replay_Sample,
	sample_count:    int,
	sample_serial:   u64,
	status:          Tracking_Status,
	part_file:       string,
	part_shown:      bool,
	reveal_time:     f64,
	generation:      u64,
	design_revision: u64,
	beads:           [dynamic]Gpu_Colored_Bead,
	bead_end_times:  [dynamic]f64,
	beads_uploaded:  int,
	last_pos:        [3]f32,
	has_pos:         bool,
	moving:          bool,
}

printer_tracking_destroy :: proc(p: ^Printer_State) {
	printer_tracking_stop(p)
	delete(p.tracking.part_file)
	delete(p.tracking.beads)
	delete(p.tracking.bead_end_times)
	p.tracking = {}
}

printer_tracking_stop :: proc(p: ^Printer_State) {
	t := &p.tracking
	if !t.active {return}
	tp.destroy(&t.path)
	mr.print_file_stop(&p.client)
	delete(t.file)
	t.file = ""
	t.active = false
	t.lock = {}
	t.chunk_used = 0
	t.failed = false
	devlog.stopped(devlog.global(), TRACKING_SITE)
}

@(private = "file")
printer_tracking_start :: proc(p: ^Printer_State, file: string) {
	s := &p.client.state
	settings := mr.planner_settings(&p.client)
	limits := tp.Limits{
		max_velocity                  = s.max_velocity if s.velocity_limits_available else 300,
		max_accel                     = s.max_accel if s.velocity_limits_available else 3000,
		square_corner_velocity        = s.square_corner_velocity if s.velocity_limits_available else 5,
		minimum_cruise_ratio          = s.minimum_cruise_ratio if s.velocity_limits_available else 0.5,
		max_z_velocity                = settings.max_z_velocity,
		max_z_accel                   = settings.max_z_accel,
		max_extrude_only_velocity     = settings.max_extrude_only_velocity,
		max_extrude_only_accel        = settings.max_extrude_only_accel,
		instantaneous_corner_velocity = settings.instantaneous_corner_velocity,
		arc_resolution                = settings.arc_resolution,
		filament_diameter             = settings.filament_diameter,
	}
	t := &p.tracking
	tp.init(&t.path, TRACKING_MOVES_MAX, limits)
	delete(t.file)
	t.file = strings.clone(file)
	t.active = true
	t.generation += 1
	delete(t.part_file)
	t.part_file = strings.clone(file)
	t.part_shown = true
	t.reveal_time = 0
	clear(&t.beads)
	clear(&t.bead_end_times)
	t.beads_uploaded = 0
	devlog.started(devlog.global(), TRACKING_SITE, {stage = "load"})
}

@(private = "file")
printer_deposit_color :: proc(tone: u8, theme: Theme) -> Vec4 {
	// Vary bead luminance subtly by role tone while staying cohesive with the active theme.
	base := theme.bead
	shade := f32(0.86) + (f32(tone % 5) * 0.06)
	return {
		clamp(base.x * shade, 0, 1),
		clamp(base.y * shade, 0, 1),
		clamp(base.z * shade, 0, 1),
		1.0,
	}
}

@(private = "file")
printer_tracking_drain_beads :: proc(p: ^Printer_State) {
	t := &p.tracking
	if len(t.path.deposits) == 0 {return}
	s := &p.client.state
	bx := f32(s.axis_maximum[0] if (s.limits_available && s.axis_maximum[0] > 0) else 250.0)
	by := f32(s.axis_maximum[1] if (s.limits_available && s.axis_maximum[1] > 0) else 250.0)
	cx := bx * 0.5
	cy := by * 0.5
	theme := ui_theme(&app.ui)
	reserve(&t.beads, len(t.beads) + len(t.path.deposits))
	reserve(&t.bead_end_times, len(t.bead_end_times) + len(t.path.deposits))
	for dep in t.path.deposits {
		w := dep.width if dep.width > 0 else f32(0.42)
		h := dep.height if dep.height > 0 else f32(0.20)
		append(&t.beads, Gpu_Colored_Bead{
			a     = Vec4{dep.p0[0] - cx, dep.p0[1] - cy, dep.p0[2], w},
			b     = Vec4{dep.p1[0] - cx, dep.p1[1] - cy, dep.p1[2], h},
			color = printer_deposit_color(dep.tone, theme),
		})
		append(&t.bead_end_times, dep.t1)
	}
	clear(&t.path.deposits)
}

@(private = "file")
printer_tracking_parse :: proc(p: ^Printer_State) {
	t := &p.tracking
	started := time.tick_now()
	for !t.path.finished && time.duration_seconds(time.tick_since(started)) < TRACKING_PARSE_SECONDS {
		data, offset, ok := mr.print_file_chunk(&p.client)
		if !ok {
			eof, failed := mr.print_file_status(&p.client)
			if eof {
				tp.finish(&t.path)
				printer_tracking_drain_beads(p)
				devlog.succeeded(devlog.global(), TRACKING_SITE, {stage = "planned"})
			}
			if failed && !t.failed {
				t.failed = true
				devlog.failed(devlog.global(), TRACKING_SITE, {reason = "Print file could not be read; showing live replay"})
			}
			return
		}
		assert(offset + i64(t.chunk_used) == t.path.parsed)
		n := min(len(data) - t.chunk_used, 64 * 1024)
		tp.feed(&t.path, data[t.chunk_used:][:n])
		t.chunk_used += n
		if t.chunk_used == len(data) {
			mr.print_file_release(&p.client)
			t.chunk_used = 0
		}
	}
	printer_tracking_drain_beads(p)
}

@(private = "file")
printer_replay_push :: proc(t: ^Print_Tracking, sample: Replay_Sample) {
	if t.sample_count == REPLAY_SAMPLES {
		copy(t.samples[:], t.samples[1:])
		t.sample_count -= 1
	}
	t.samples[t.sample_count] = sample
	t.sample_count += 1
}

@(private = "file")
printer_replay_position :: proc(t: ^Print_Tracking, eventtime: f64) -> (pos: [3]f32, ok: bool) {
	if t.sample_count == 0 {return}
	last := t.samples[t.sample_count - 1]
	if eventtime >= last.eventtime {return last.pos, true}
	for i := t.sample_count - 1; i > 0; i -= 1 {
		after, before := t.samples[i], t.samples[i - 1]
		if eventtime < before.eventtime {continue}
		from := max(before.eventtime, after.eventtime - 0.25)
		if eventtime <= from {return before.pos, true}
		f := f32((eventtime - from) / (after.eventtime - from))
		return before.pos + (after.pos - before.pos) * f, true
	}
	return t.samples[0].pos, true
}

// Advances live print tracking each frame; returns true when the 3D view should redraw.
printer_tracking_step :: proc(p: ^Printer_State) -> bool {
	s := &p.client.state
	t := &p.tracking
	connected := !p.demo && s.connection == .Connected && !s.stale && s.clock_available
	printing := connected && (s.job_state == "printing" || s.job_state == "paused") && s.filename != ""

	if !connected {
		t.sample_count = 0
		t.sample_serial = s.live_sample_serial
	}
	rev_changed := t.active && s.job_is_design && t.design_revision != s.job_design_revision
	if !printing || (t.active && (t.file != s.filename || rev_changed)) {
		prev_reveal := t.reveal_time if rev_changed else 0
		printer_tracking_stop(p)
		if printing {
			printer_tracking_start(p, s.filename)
			t.design_revision = s.job_design_revision
			if rev_changed {t.reveal_time = prev_reveal}
		}
	} else if printing && !t.active {
		printer_tracking_start(p, s.filename)
		t.design_revision = s.job_design_revision
	}

	// Keep finished/cancelled part visible until standby or another file loads. The part records
	// the print, so a missing clock (only needed for live motion) must not hide it.
	part_reporting := !p.demo && s.connection == .Connected && !s.stale
	if part_reporting && !t.active {
		switch {
		case s.job_state == "standby" || s.job_state == "" || (s.filename != "" && s.filename != t.part_file):
			t.part_shown = false
		case s.job_state == "complete":
			t.reveal_time = REVEAL_ALL
		}
	}

	if t.active {
		want := TRACKING_READ_AHEAD_BYTES + (s.file_position if s.file_position_available else 0)
		mr.print_file_follow(&p.client, t.file, i64(want))
		printer_tracking_parse(p)
	}

	if connected && s.live_sample_serial != t.sample_serial && s.live_position_available {
		t.sample_serial = s.live_sample_serial
		sample := Replay_Sample{
			s.live_sample_eventtime,
			{f32(s.live_position[0]), f32(s.live_position[1]), f32(s.live_position[2])},
		}
		printer_replay_push(t, sample)
		if t.active && tp.lock_sample(&t.lock, &t.path, sample.eventtime, sample.pos, s.file_position, s.file_position_available) {
			if t.lock.state == .Locked {
				devlog.succeeded(devlog.global(), TRACKING_SITE, {stage = "locked"})
			} else {
				devlog.failed(devlog.global(), TRACKING_SITE, {reason = "G-code lock lost; showing live replay"})
			}
		}
	}

	if !connected || t.sample_count == 0 {
		t.status = .Off
		t.has_pos = false
		t.moving = false
		return false
	}

	now := mr.local_now(&p.client) - s.clock_offset
	switch {
	case !t.active:               t.status = .Off
	case t.failed:                t.status = .Replay
	case t.lock.state == .Locked: t.status = .Locked
	case t.path.count == 0:       t.status = .Loading
	case:                         t.status = .Syncing
	}

	playback := -1.0
	if t.active {
		if t.status == .Locked {
			playback = tp.lock_render_time(&t.lock, &t.path, now)
		} else if s.file_position_available {
			if read_t, read_ok := tp.time_at_offset(&t.path, s.file_position); read_ok {
				playback = max(read_t - 1.5, 0)
			}
		}
	}
	if playback >= 0 {
		t.reveal_time = playback if playback < t.reveal_time - 1 else max(t.reveal_time, playback)
	}

	if t.status == .Locked {
		if pos, found := tp.position(&t.path, playback); found {
			t.last_pos = pos
			t.has_pos = true
			t.moving = true
			return true
		}
	}
	if pos, ok := printer_replay_position(t, now - REPLAY_DELAY_SECONDS); ok {
		t.last_pos = pos
		t.has_pos = true
		t.moving = printing || now - REPLAY_DELAY_SECONDS < t.samples[t.sample_count - 1].eventtime
		return t.moving
	}
	t.has_pos = false
	t.moving = false
	return false
}

// Returns the number of live-printed beads revealed up to the current playback time, and ensures
// the Metal colored-bead buffer holds the live print beads when rendering the Printer Control view.
printer_tracking_revealed_beads :: proc(p: ^Printer_State) -> int {
	t := &p.tracking
	if !t.part_shown || len(t.beads) == 0 {return 0}
	if t.beads_uploaded != len(t.beads) || app.gcode_colored_hash != {} {
		_ = renderer_set_colored_beads(&app.renderer, t.beads[:])
		app.gcode_colored_hash = {}
		t.beads_uploaded = len(t.beads)
	}
	if t.reveal_time >= REVEAL_ALL {return len(t.beads)}
	lo, hi := 0, len(t.bead_end_times)
	for lo < hi {
		mid := (lo + hi) / 2
		if t.bead_end_times[mid] <= t.reveal_time {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo
}

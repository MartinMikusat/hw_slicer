package main

import "core:time"
import devlog "devlog:."

Profile_Drag_Update :: enum { None, Updated, Rejected }

Profile_Drag_Stage :: enum { Frame, Source, Evaluate, Generate, Beads, Upload, Draw }
Profile_Drag_Timing :: [Profile_Drag_Stage]time.Duration

Profile_Drag_Trace :: [Profile_Drag_Update]struct {
	count: i64,
	slowest: Profile_Drag_Timing,
}

profile_drag_trace_id: u64

profile_drag_trace_frame :: proc(trace: ^Profile_Drag_Trace, update: Profile_Drag_Update,
								timing: ^Profile_Drag_Timing, finished: bool) {
	if update != .None {
		bucket := &trace[update]
		bucket.count += 1
		if timing[.Frame] > bucket.slowest[.Frame] {bucket.slowest = timing^}
	}
	if !finished {return}
	defer trace^ = {}
	if trace[.Updated].count == 0 && trace[.Rejected].count == 0 {return}
	profile_drag_trace_id += 1

	site := devlog.Site{feature = "design", operation = "profile_drag"}
	state := devlog.global()
	stage_names := [Profile_Drag_Stage]string{
		.Frame = "frame", .Source = "serialize", .Evaluate = "evaluate", .Generate = "generate",
		.Beads = "beads", .Upload = "upload", .Draw = "draw",
	}
	for bucket, outcome in trace^ {
		if bucket.count == 0 {continue}
		context_info := devlog.Context{
			scope = "design", request_id = profile_drag_trace_id,
			completed_stage = "updated" if outcome == .Updated else "rejected",
		}
		devlog.succeeded(state, site, context_info, {rows = bucket.count})
		for duration, stage in bucket.slowest {
			if duration == 0 {continue}
			context_info.stage = stage_names[stage]
			devlog.sample(state, site, i64(duration/time.Millisecond), context_info)
		}
	}
}

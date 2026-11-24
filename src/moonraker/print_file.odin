package moonraker

import "core:encoding/json"
import "core:slice"
import "core:strings"
import "core:time"
import devlog "devlog:."

// Streams the active print file in byte ranges for the toolpath simulation. Requests use the
// single native HTTP slot only while no operator transfer or thumbnail read needs it.
PRINT_FILE_CHUNK_BYTES :: 1 << 20
PRINT_FILE_TIMEOUT_SECONDS :: 30
PRINT_FILE_RETRIES_MAX :: 3
PRINT_FILE_SITE :: devlog.Site{feature = "moonraker", operation = "print_file_read"}

Print_File_Fetch :: struct {
    path: string,
    want, next_offset, size: i64,
    id: i64,
    deadline, retry_at: f64,
    retries: int,
    chunk: []byte,
    chunk_offset: i64,
    eof, failed: bool,
}

// Requests the file through `want` bytes. A different path restarts the stream from its start.
print_file_follow :: proc(c: ^Client, path: string, want: i64) {
    assert(c != nil)
    assert(want >= 0)
    context.allocator = c.allocator
    f := &c.print_file
    if f.path != path {
        print_file_stop(c)
        if path == "" || !valid_path(path) do return
        f.path = strings.clone(path)
        f.size = -1
        if c.state.job_is_design && c.state.filename == path && c.state.job_preview_size > 0 {
            f.size = c.state.job_preview_size
        } else {
            for file in c.state.files do if file.path == path do f.size = file.size
        }
        devlog.started(devlog.global(), PRINT_FILE_SITE)
    }
    f.want = max(f.want, want)
}

print_file_stop :: proc(c: ^Client) {
    assert(c != nil)
    context.allocator = c.allocator
    print_file_abort(c)
    if c.print_file.path != "" do devlog.stopped(devlog.global(), PRINT_FILE_SITE)
    delete(c.print_file.path)
    delete(c.print_file.chunk)
    c.print_file = {}
}

// The next unread chunk and its file offset; it stays valid until print_file_release.
print_file_chunk :: proc(c: ^Client) -> (data: []byte, offset: i64, ok: bool) {
    assert(c != nil)
    f := &c.print_file
    if f.chunk == nil do return nil, 0, false
    return f.chunk, f.chunk_offset, true
}

print_file_release :: proc(c: ^Client) {
    assert(c != nil)
    context.allocator = c.allocator
    delete(c.print_file.chunk)
    c.print_file.chunk = nil
}

// Whether the whole file has been delivered, and whether reading stopped after errors.
print_file_status :: proc(c: ^Client) -> (eof, failed: bool) {
    return c.print_file.eof, c.print_file.failed
}

print_file_abort :: proc(c: ^Client) {
    assert(c != nil)
    if c.print_file.id == 0 do return
    if c.native != nil do mr_native_http_cancel(c.native)
    c.print_file.id = 0
}

print_file_pump :: proc(c: ^Client) {
    assert(c != nil)
    f := &c.print_file
    if f.id != 0 && c.now >= f.deadline {
        print_file_abort(c)
        print_file_retry(c, "Print file read timed out", 0)
    }
    if f.path == "" || f.eof || f.failed || f.id != 0 || f.chunk != nil || f.next_offset >= f.want ||
        c.now < f.retry_at || c.native == nil || c.state.connection != .Connected ||
        c.thumbnail_fetch.id != 0 || c.state.transfer.status == .Running {
        return
    }
    if f.size >= 0 && f.next_offset >= f.size {
        f.eof = true
        devlog.succeeded(devlog.global(), PRINT_FILE_SITE, {stage = "complete"})
        return
    }
    if c.next_id >= 9_007_199_254_740_990 do return
    encoded := percent_encode(f.path, true)
    defer delete(encoded, c.allocator)
    url := strings.concatenate({"/server/files/gcodes/", encoded}, c.allocator)
    defer delete(url, c.allocator)
    id := c.next_id
    c.next_id += 1
    last := f.next_offset + PRINT_FILE_CHUNK_BYTES - 1
    if mr_native_http_range(c.native, id, raw_data(url), i64(len(url)), f.next_offset, last) == 0 {
        f.retry_at = c.now + 1
        return
    }
    f.id = id
    f.deadline = c.now + PRINT_FILE_TIMEOUT_SECONDS
}

print_file_retry :: proc(c: ^Client, reason: string, code: i32) {
    f := &c.print_file
    f.retries += 1
    if f.retries > PRINT_FILE_RETRIES_MAX {
        f.failed = true
        devlog.failed(devlog.global(), PRINT_FILE_SITE, {reason = reason, code = code})
        return
    }
    f.retry_at = c.now + f64(i64(1) << uint(f.retries))
    devlog.failed(devlog.global(), PRINT_FILE_SITE, {reason = reason, code = code}, {stage = "retry"})
}

print_file_response :: proc(c: ^Client, event: Native_Event) {
    assert(c != nil)
    context.allocator = c.allocator
    f := &c.print_file
    assert(event.id == f.id)
    f.id = 0
    length := i64(event.length)
    switch {
    case event.status == 416:
        f.eof = true
        devlog.succeeded(devlog.global(), PRINT_FILE_SITE, {stage = "complete"})
        return
    case event.status == 206 || (event.status == 200 && f.next_offset == 0 && length < PRINT_FILE_CHUNK_BYTES):
    case:
        print_file_retry(c, "Print file range read failed", i32(event.status))
        return
    }
    if length < 0 || length > PRINT_FILE_CHUNK_BYTES {
        print_file_retry(c, "Print file range exceeds the requested length", i32(event.status))
        return
    }
    f.retries = 0
    if length > 0 {
        f.chunk = slice.clone(slice.from_ptr(cast(^byte)event.bytes, int(length)))
        f.chunk_offset = f.next_offset
        f.next_offset += length
    }
    if length < PRINT_FILE_CHUNK_BYTES || event.status == 200 || (f.size >= 0 && f.next_offset >= f.size) {
        f.eof = true
        devlog.succeeded(devlog.global(), PRINT_FILE_SITE, {stage = "complete"})
    }
}

// Printer eventtime mapped from the local poll clock; Klipper samples carry this clock.
clock_observe :: proc(c: ^Client, eventtime: f64) {
    candidate := c.now - eventtime
    if !c.state.clock_available || candidate < c.state.clock_offset {
        c.state.clock_offset = candidate
        c.state.clock_available = true
    } else {
        // Forget old minima slowly so that clock drift cannot freeze the estimate.
        c.state.clock_offset = min(candidate, c.state.clock_offset + 0.0005 * max(0, c.now - c.clock_updated_at))
    }
    c.clock_updated_at = c.now
}

// Seconds on the client's poll clock now, comparable to clock_offset.
local_now :: proc(c: ^Client) -> f64 {
    return time.duration_seconds(time.tick_since(c.epoch))
}

Planner_Settings :: struct {
    max_z_velocity, max_z_accel: f64,
    max_extrude_only_velocity, max_extrude_only_accel: f64,
    instantaneous_corner_velocity: f64,
    arc_resolution: f64,
    filament_diameter: f64,
}

// Planner limits from Klipper's parsed configuration, with Klipper's defaults where it reports none.
planner_settings :: proc(c: ^Client) -> Planner_Settings {
    assert(c != nil)
    settings := get_path(c.status["configfile"], "settings")
    s := &c.state
    extruder := s.active_extruder if s.active_extruder != "" else "extruder"
    value :: proc(v: json.Value, fallback: f64, minimum: f64 = 1e-9) -> f64 {
        n, ok := number(v)
        return n if ok && n >= minimum && n < 1e9 else fallback
    }
    max_v := s.max_velocity if s.max_velocity > 0 else 300
    max_a := s.max_accel if s.max_accel > 0 else 3000
    nozzle := value(get_path(settings, extruder, "nozzle_diameter"), 0.4)
    filament := value(get_path(settings, extruder, "filament_diameter"), 1.75)
    ratio := 4 * nozzle * nozzle / (3.14159265358979 * filament * filament * 0.25)
    return {
        max_z_velocity = value(get_path(settings, "printer", "max_z_velocity"), max_v),
        max_z_accel = value(get_path(settings, "printer", "max_z_accel"), max_a),
        max_extrude_only_velocity = value(get_path(settings, extruder, "max_extrude_only_velocity"), max_v * ratio),
        max_extrude_only_accel = value(get_path(settings, extruder, "max_extrude_only_accel"), max_a * ratio),
        instantaneous_corner_velocity = value(get_path(settings, extruder, "instantaneous_corner_velocity"), 1, 0),
        arc_resolution = value(get_path(settings, "gcode_arcs", "resolution"), 0.2),
        filament_diameter = filament,
    }
}

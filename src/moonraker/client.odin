#+feature dynamic-literals
package moonraker

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"
import "core:unicode/utf8"
import devlog "devlog:."

MESSAGE_BYTES_MAX :: 4 * 1024 * 1024
TRANSFER_BYTES_MAX :: 32 * 1024 * 1024
PENDING_MAX :: 32
OBJECTS_MAX :: 256
FILES_MAX :: 4096
CONFIG_BYTES_MAX :: 4 * 1024 * 1024
CONSOLE_MAX :: 256
CONNECTION_SITE :: devlog.Site{feature="moonraker", operation="connection"}
THUMBNAIL_SITE :: devlog.Site{feature="files", operation="read_thumbnail"}

Connection :: enum { Offline, Connecting, Initializing, Connected, Reconnecting, Failed }
Axis :: enum { X, Y, Z }
Command_Kind :: enum { Start, Pause, Resume, Cancel, Heater, Fan, Home, Disable_Motors, Jog, Move, Extrude, Macro,
                      Script, Emergency, Restart, Firmware_Restart }
Command :: struct {
    kind: Command_Kind,
    text, arguments: string,
    value: f64,
    axis: Axis,
    feed_mm_per_second: f64,
    confirmed: bool,
}
Heater :: struct {
    name: string,
    temperature, target, power, min_temp, max_temp: f64,
    available, target_available, power_available, limits_available, controllable, can_extrude: bool,
}
Fan :: struct { name: string, speed: f64, available, controllable: bool }
Job_Feature :: struct {
    index, layers: int,
    label, shape: string,
    speed, acceleration, fan: f64,
    base_speed, base_acceleration, base_fan: f64,
    max_speed, max_acceleration: f64,
}
Design_Param :: struct {
    name, unit, reason: string,
    value: f64,
    editable, overridden: bool,
}
Macro :: struct { name, description, parameters: string }
Info_Status :: enum u8 { None, Pending, Ready, Failed }
Thumbnail_Kind :: enum u8 { Icon, Image }
Thumbnail :: struct { status: Info_Status, data: []byte, serial: u64 }
File :: struct {
    path: string,
    size: i64,
    modified: f64,
    permissions: string,
    metadata: Metadata,
    metadata_status: Info_Status,
    thumbnails: [Thumbnail_Kind]Thumbnail,
}
Thumbnail_Fetch :: struct { id: i64, path: string, kind: Thumbnail_Kind, deadline: f64 }
Log_Kind :: enum { Info, Sent, Response, Error }
Log :: struct { text: string, kind: Log_Kind }
Transfer_Status :: enum { Idle, Running, Complete, Failed, Cancelled }
Transfer_Kind :: enum { Download, Upload, Delete, Config_Download, Config_Upload }
Transfer :: struct {
    status: Transfer_Status,
    kind: Transfer_Kind,
    path: string,
    data: []byte,
    id: i64,
    deadline: f64,
}
Metadata_Number :: enum {
    Estimated_Time, Filament_Total, Filament_Weight, Layer_Height, First_Layer_Height,
    Object_Height, Nozzle_Diameter, First_Layer_Extruder_Temp, First_Layer_Bed_Temp,
}
METADATA_NUMBER_KEYS :: [Metadata_Number]string{
    .Estimated_Time = "estimated_time", .Filament_Total = "filament_total",
    .Filament_Weight = "filament_weight_total", .Layer_Height = "layer_height",
    .First_Layer_Height = "first_layer_height", .Object_Height = "object_height",
    .Nozzle_Diameter = "nozzle_diameter", .First_Layer_Extruder_Temp = "first_layer_extr_temp",
    .First_Layer_Bed_Temp = "first_layer_bed_temp",
}
METADATA_NUMBER_MAX :: 1e9
METADATA_TEXT_BYTES_MAX :: 128
METADATA_CONCURRENT_MAX :: 4
THUMBNAIL_BYTES_MAX :: 1024 * 1024
THUMBNAIL_ICON_PIXELS_MIN :: 32
THUMBNAIL_ICON_RETAIN_ROWS :: 32
THUMBNAIL_TIMEOUT_SECONDS :: 15
Metadata :: struct {
    thumbnails: [Thumbnail_Kind]string,
    slicer, filament_type, filament_name: string,
    size: i64,
    size_available: bool,
    numbers: [Metadata_Number]f64,
    available: bit_set[Metadata_Number],
}
State :: struct {
    connection: Connection,
    stale, armed: bool,
    printer_state, printer_message, hostname: string,
    job_state, filename, job_message: string,
    progress, print_duration: f64,
    progress_available, duration_available: bool,
    position, live_position: [4]f64,
    live_velocity: f64,
    axis_minimum, axis_maximum: [3]f64,
    position_available, live_position_available, limits_available: bool,
    homed_axes, active_extruder: string,
    motors_available, motors_engaged: bool,
    max_velocity, max_accel, square_corner_velocity, minimum_cruise_ratio: f64,
    velocity_limits_available: bool,
    // Read position of the active print file; Klipper executes moves some way behind it.
    file_position: i64,
    file_position_available: bool,
    // Printer clock (Klipper eventtime) of the latest motion_report.live_position sample.
    live_sample_eventtime: f64,
    live_sample_serial: u64,
    // Local poll clock minus printer eventtime, tracked as the least observed delay.
    clock_offset: f64,
    clock_available: bool,
    heaters: [dynamic]Heater,
    temperature_history: [dynamic]Temperature_History,
    history_error: string,
    history_updated_at: f64,
    history_loading: bool,
    fans: [dynamic]Fan,
    macros: [dynamic]Macro,
    files: [dynamic]File,
    config_files: [dynamic]File,
    config_revision: u64,
    console: [dynamic]Log,
    error, operation: string,
    transfer: Transfer,
    gcodes_writable: bool,
    hw_printer_host: bool,
    job_is_design: bool,
    job_design_revision: u64,
    job_preview_size: i64,
    job_current_layer, job_total_layers, job_current_feature: int,
    features: [dynamic]Job_Feature,
    design_params: [dynamic]Design_Param,
    revision: u64,
}
Wake :: #type proc "c" (userdata: rawptr)
Request_Kind :: enum { Server, Printer, Objects, Subscribe, Help, Files, Config_Files, Roots, Metadata,
                      Heartbeat, History, Control, Emergency }
Pending :: struct { id: i64, kind: Request_Kind, deadline: f64, label: string }
Client :: struct {
    state: State,
    allocator: mem.Allocator,
    native: rawptr,
    endpoint, api_key: string,
    status: json.Object,
    status_bytes: int,
    objects: [dynamic]string,
    help: json.Value,
    pending: [PENDING_MAX]Pending,
    next_id: i64,
    now, reconnect_at, connect_deadline, heartbeat_at, last_received: f64,
    eventtime: f64,
    reconnect_attempts: int,
    thumbnail_fetch: Thumbnail_Fetch,
    thumbnail_serial: u64,
    monitoring, snapshot_received: bool,
    history_capability: History_Capability,
    history_disabled: bool,
    history_failed: bool,
    history_poll_at, history_append_at: f64,
    read_only, limited: bool,
    epoch: time.Tick,
    wake: Wake,
    wake_userdata: rawptr,
    print_file: Print_File_Fetch,
    clock_updated_at: f64,
}
Native_Event :: struct {
    kind, status: i32,
    id: i64,
    bytes: rawptr,
    length: i64,
}
#assert(size_of(Native_Event) == 32)
#assert(align_of(Native_Event) == 8)
foreign {
    mr_native_connect :: proc "c" (endpoint: rawptr, endpoint_length: i64, key: rawptr,
        key_length: i64, access_mode: i32, wake: Wake, userdata: rawptr) -> rawptr ---
    mr_native_wake :: proc "c" (handle: rawptr, wake: Wake, userdata: rawptr) ---
    mr_native_destroy :: proc "c" (handle: rawptr) ---
    mr_native_poll :: proc "c" (handle: rawptr, event: ^Native_Event) -> i32 ---
    mr_native_event_release :: proc "c" (event: ^Native_Event) ---
    mr_native_send :: proc "c" (handle: rawptr, bytes: rawptr, length, id: i64) -> i32 ---
    mr_native_http :: proc "c" (handle: rawptr, id: i64, method: rawptr, method_length: i64,
        path: rawptr, path_length: i64, body: rawptr, body_length: i64,
        content_type: rawptr, content_type_length: i64) -> i32 ---
    mr_native_http_cancel :: proc "c" (handle: rawptr) ---
    mr_native_http_range :: proc "c" (handle: rawptr, id: i64, path: rawptr, path_length, first, last: i64) -> i32 ---
}

initialize :: proc(c: ^Client, allocator := context.allocator, read_only := false, limited := false) {
    assert(c != nil)
    assert(c.allocator.procedure == nil)
    assert(!(read_only && limited))
    c.allocator = allocator
    c.read_only = read_only
    c.limited = limited
    c.epoch = time.tick_now()
    c.next_id = 1
    c.state.stale = true
    c.status = make(json.Object, allocator=allocator)
    c.objects = make([dynamic]string, 0, OBJECTS_MAX, allocator)
    c.state.console = make([dynamic]Log, 0, CONSOLE_MAX, allocator)
    c.state.temperature_history = make([dynamic]Temperature_History, 0,
        TEMPERATURE_HISTORY_SENSORS_MAX, allocator)
}

is_read_only :: proc(c: ^Client) -> bool {
    assert(c != nil)
    return c.read_only
}

is_limited :: proc(c: ^Client) -> bool {
    assert(c != nil)
    return c.limited
}

readonly_selfcheck :: proc() -> bool {
    c: Client
    initialize(&c, read_only=true)
    defer destroy(&c)
    assert(is_read_only(&c))
    load_demo(&c)
    c.state.connection = .Connected
    c.state.stale = false
    c.state.armed = true
    c.state.gcodes_writable = true
    assert(!arm(&c, true))
    assert(c.state.error == "This session is read-only")
    for kind in Command_Kind {
        assert(!command(&c, Command{kind=kind, text="G28", confirmed=true}))
        assert(c.state.error == "This session is read-only")
    }
    assert(!upload(&c, "sample_part.gcode", transmute([]byte)string("G90\n"), true))
    assert(c.state.error == "This session is read-only")
    assert(!delete_file(&c, "sample_part.gcode", true))
    assert(c.state.error == "This session is read-only")
    assert(!request(&c, .Server, "printer.gcode.script", json.Object{"script"="G28"}))
    assert(c.state.error == "This session permits only monitoring requests")
    assert(!begin_transfer(&c, .Download, "sample_part.gcode", "POST",
        "/server/files/gcodes/sample_part.gcode", nil, ""))
    assert(c.state.error == "This session permits only read-only file downloads")
    assert(arm(&c, false))
    disconnect(&c)
    load_demo(&c)
    assert(is_read_only(&c))
    assert(!c.state.armed)
    assert(!arm(&c, true))
    return true
}

set_wake :: proc(c: ^Client, wake: Wake, userdata: rawptr) {
    assert(c != nil)
    c.wake = wake
    c.wake_userdata = userdata
    if c.native != nil do mr_native_wake(c.native, wake, userdata)
}

destroy :: proc(c: ^Client) {
    assert(c != nil)
    if c.allocator.procedure == nil do return
    context.allocator = c.allocator
    set_wake(c, nil, nil)
    disconnect(c)
    clear_observed(c)
    delete(c.status)
    delete(c.objects)
    delete(c.state.heaters)
    delete(c.state.temperature_history)
    delete(c.state.fans)
    for feature in c.state.features { delete(feature.label); delete(feature.shape) }
    delete(c.state.features)
    for param in c.state.design_params { delete(param.name); delete(param.unit); delete(param.reason) }
    delete(c.state.design_params)
    delete(c.state.macros)
    delete(c.state.files)
    delete(c.state.config_files)
    for log in c.state.console do delete(log.text)
    delete(c.state.console)
    delete(c.state.error)
    delete(c.state.operation)
    delete(c.state.transfer.path)
    delete(c.state.transfer.data)
    print_file_stop(c)
    c^ = {}
}

connect :: proc(c: ^Client, endpoint, api_key: string) -> bool {
    assert(c != nil)
    assert(c.allocator.procedure != nil)
    context.allocator = c.allocator
    if len(endpoint) == 0 || len(endpoint) > 2048 || len(api_key) > 512 ||
       !plain_text(endpoint) || !plain_text(api_key) {
        return fail(c, "Enter an HTTP(S) endpoint and a valid memory-only API key")
    }
    desired_endpoint := strings.clone(endpoint)
    desired_key := strings.clone(api_key)
    disconnect(c)
    clear_observed(c)
    c.endpoint = desired_endpoint
    c.api_key = desired_key
    c.now = time.duration_seconds(time.tick_since(c.epoch))
    c.native = mr_native_connect(raw_data(c.endpoint), i64(len(c.endpoint)), raw_data(c.api_key),
        i64(len(c.api_key)), c.read_only ? 1 : c.limited ? 2 : 0, c.wake, c.wake_userdata)
    if c.native == nil {
        delete(c.endpoint)
        delete(c.api_key)
        c.endpoint = ""
        c.api_key = ""
        return fail(c, "Invalid endpoint: use HTTP(S), optional base path, no credentials/query/fragment")
    }
    c.monitoring = true
    c.reconnect_attempts = 0
    devlog.started(devlog.global(), CONNECTION_SITE, {stage="heater_control"})
    c.state.connection = .Connecting
    c.connect_deadline = c.now + 15
    assign_text(&c.state.error, "")
    assign_text(&c.state.operation, "Connecting for monitoring; controls are disarmed")
    c.state.revision += 1
    return true
}

disconnect :: proc(c: ^Client) {
    assert(c != nil)
    context.allocator = c.allocator
    close_native(c)
    clear_temperature_history(c)
    if c.monitoring do devlog.stopped(devlog.global(), CONNECTION_SITE)
    c.monitoring = false
    c.state.connection = .Offline
    c.state.armed = false
    c.state.stale = true
    delete(c.endpoint)
    if len(c.api_key) != 0 do mem.zero(raw_data(c.api_key), len(c.api_key))
    delete(c.api_key)
    c.endpoint = ""
    c.api_key = ""
    c.reconnect_at = 0
    c.state.revision += 1
}

needs_tick :: proc(c: ^Client) -> bool {
    assert(c != nil)
    return c.monitoring || c.state.transfer.status == .Running
}

poll :: proc(c: ^Client, now_seconds: f64 = -1) -> bool {
    assert(c != nil)
    assert(c.allocator.procedure != nil)
    context.allocator = c.allocator
    previous_revision := c.state.revision
    c.now = now_seconds < 0 ? time.duration_seconds(time.tick_since(c.epoch)) : now_seconds
    assert(finite(c.now))
    for _ in 0..<32 {
        if c.native == nil do break
        event: Native_Event
        if mr_native_poll(c.native, &event) == 0 do break
        switch event.kind {
        case 1:
            c.state.connection = .Initializing
            c.state.revision += 1
            c.last_received = c.now
            c.heartbeat_at = c.now + 10
            _ = request(c, .Server, "server.info", nil)
            _ = request(c, .Files, "server.files.list", json.Object{"root"="gcodes"})
            _ = request(c, .Roots, "server.files.roots", nil)
        case 2:
            if event.length <= 0 || event.length > MESSAGE_BYTES_MAX {
                lost(c, "Invalid or oversized WebSocket message", false)
            } else {
                c.last_received = c.now
                receive(c, string(slice.from_ptr(cast(^byte)event.bytes, int(event.length))))
            }
        case 3:
            authentication := event.status == 401 || event.status == 403
            message := event.length != 0 ? string(slice.from_ptr(cast(^byte)event.bytes,
                int(event.length))) : "Native transport queue or message limit exceeded"
            lost(c, authentication ? "Authentication rejected; reconnect with a valid API key" :
                message, authentication, authentication ? "" : "Transport reported a connection error")
        case 4:
            if c.print_file.id != 0 && event.id == c.print_file.id {
                print_file_response(c, event)
            } else if c.thumbnail_fetch.id != 0 && event.id == c.thumbnail_fetch.id {
                thumbnail_response(c, event)
            } else {
                transfer_response(c, event)
            }
        case 5:
            for &pending in c.pending {
                if pending.id == event.id {
                    if pending.kind == .History {
                        _ = temperature_history_fail(c, "Temperature history request could not be sent")
                    } else if pending.kind == .Control || pending.kind == .Emergency {
                        _ = fail_operation(c, "send_request", "Command send failed; outcome is uncertain")
                    } else {
                        _ = fail_operation(c, "send_request", "Monitoring request could not be sent")
                    }
                    release_pending(&pending)
                    break
                }
            }
        }
        mr_native_event_release(&event)
    }
    for &pending in c.pending {
        if pending.id == 0 || c.now < pending.deadline do continue
        if pending.kind == .History {
            _ = temperature_history_fail(c, "Temperature history request timed out")
            release_pending(&pending)
            continue
        }
        control := pending.kind == .Control || pending.kind == .Emergency
        _ = fail_operation(c, "request_timeout", control ? "Command timed out; outcome is uncertain, command will not be replayed" :
            "Monitoring request timed out")
        release_pending(&pending)
        if !control {
            lost(c, "Monitoring request timed out", false)
            break
        }
    }
    if c.thumbnail_fetch.id != 0 && c.now >= c.thumbnail_fetch.deadline {
        devlog.failed(devlog.global(), THUMBNAIL_SITE, {reason="Thumbnail read timed out"})
        thumbnail_abort(c, false)
    }
    print_file_pump(c)
    if c.state.transfer.status == .Running && c.now >= c.state.transfer.deadline {
        cancel_transfer(c)
        _ = fail_operation(c, "file_transfer", "File transfer timed out; server outcome may be uncertain")
    }
    if c.native != nil && c.state.connection in (bit_set[Connection]{.Connecting, .Initializing}) &&
       c.now >= c.connect_deadline {
        lost(c, "Connection initialization timed out", false)
    }
    if c.native != nil && c.state.connection == .Connected && c.now >= c.heartbeat_at {
        c.heartbeat_at = c.now + 10
        if !has_pending(c, .Heartbeat) do _ = request(c, .Heartbeat, "server.info", nil)
    }
    if c.native != nil && c.state.connection == .Connected && c.snapshot_received &&
        c.now - c.last_received > 15 && !c.state.stale {
        c.state.stale = true
        c.state.revision += 1
    }
    if temperature_history_ready(c) && !c.history_disabled && c.now >= c.history_poll_at &&
        !has_pending(c, .History) {
        _ = refresh_temperature_history(c)
    }
    if temperature_history_ready(c) && c.now >= c.history_append_at { append_temperature_samples(c) }
    if c.state.connection == .Reconnecting && c.now >= c.reconnect_at && c.monitoring {
        clear_observed(c)
        c.native = mr_native_connect(raw_data(c.endpoint), i64(len(c.endpoint)),
            raw_data(c.api_key), i64(len(c.api_key)), c.read_only ? 1 : c.limited ? 2 : 0, c.wake, c.wake_userdata)
        if c.native == nil {
            lost(c, "Cannot recreate monitoring connection", true)
        } else {
            c.state.connection = .Connecting
            c.connect_deadline = c.now + 15
        }
        c.state.revision += 1
    }
    return previous_revision != c.state.revision
}

arm :: proc(c: ^Client, enabled: bool) -> bool {
    assert(c != nil)
    context.allocator = c.allocator
    if enabled && c.read_only do return fail(c, "This session is read-only")
    if enabled && c.limited do return fail(c, "This session permits only heater target changes")
    if enabled && (c.state.connection != .Connected || c.state.stale ||
        c.state.printer_state != "ready") {
        return fail(c, "Controls need a connected, fresh, ready printer")
    }
    c.state.armed = enabled
    assign_text(&c.state.operation, enabled ? "Controls explicitly armed for this connection" :
        "Monitoring only; controls disarmed")
    c.state.revision += 1
    return true
}

command :: proc(c: ^Client, cmd: Command) -> bool {
    assert(c != nil)
    context.allocator = c.allocator
    if c.read_only do return fail(c, "This session is read-only")
    hw_local_cmd := c.state.hw_printer_host && (cmd.kind == .Start || cmd.kind == .Pause ||
        cmd.kind == .Resume || cmd.kind == .Cancel || cmd.kind == .Fan)
    if c.limited && !hw_local_cmd && cmd.kind != .Heater && cmd.kind != .Jog && cmd.kind != .Move && cmd.kind != .Emergency && cmd.kind != .Home &&
       cmd.kind != .Restart && cmd.kind != .Firmware_Restart && cmd.kind != .Disable_Motors {
        return fail(c, "This session permits only heater targets, homing, single-axis toolhead moves, emergency stop and restarts")
    }
    if cmd.kind == .Script && contains_emergency(cmd.text) {
        return command(c, Command{kind=.Emergency})
    }
    if (!c.limited && !c.state.armed) || c.native == nil || c.state.connection != .Connected {
        return fail(c, "Controls are disarmed or disconnected")
    }
    if cmd.kind == .Emergency {
        return request(c, .Emergency, "printer.emergency_stop", nil,
            "Emergency stop requested; awaiting backend acknowledgement")
    }
    if cmd.kind == .Restart || cmd.kind == .Firmware_Restart {
        if has_pending(c, .Control) { return fail(c, "Wait for the outstanding control request") }
        if c.state.printer_state == "ready" && !motion_idle(c) {
            return fail(c, "Finish or cancel the print before restarting")
        }
        return request(c, .Control, cmd.kind == .Restart ? "printer.restart" : "printer.firmware_restart", nil,
            "Restart submitted; waiting for Klipper to reconnect")
    }
    if c.state.stale || c.state.printer_state != "ready" || !c.snapshot_received {
        return fail(c, "Printer readiness is unavailable or stale")
    }
    if has_pending(c, .Control) {
        return fail(c, c.limited ? "Wait for the outstanding heater or move request" :
            "Wait for the outstanding control request; emergency stop remains available")
    }
    if !finite(cmd.value) || !finite(cmd.feed_mm_per_second) {
        return fail(c, "Enter finite numeric values")
    }
    if cmd.kind == .Start {
        if !motion_idle(c) || !valid_path(cmd.text) ||
            !file_permission(c, cmd.text, 'r') {
            return fail(c, "Print start needs an idle printer and a listed readable G-code file")
        }
        return request(c, .Control, "printer.print.start", json.Object{"filename"=cmd.text},
            "Print start submitted; observe job state for completion")
    }
    if cmd.kind == .Pause {
        if c.state.job_state != "printing" do return fail(c, "Only an active print can pause")
        return request(c, .Control, "printer.print.pause", nil, "Pause submitted")
    }
    if cmd.kind == .Resume {
        if c.state.job_state != "paused" do return fail(c, "Only a paused print can resume")
        return request(c, .Control, "printer.print.resume", nil, "Resume submitted")
    }
    if cmd.kind == .Cancel {
        if !cmd.confirmed || (c.state.job_state != "printing" && c.state.job_state != "paused") {
            return fail(c, "Confirm cancellation of an active or paused print")
        }
        return request(c, .Control, "printer.print.cancel", nil, "Cancel submitted")
    }
    script := ""
    defer if len(script) != 0 do delete(script)
    #partial switch cmd.kind {
    case .Heater:
        matched := false
        for heater in c.state.heaters {
            if heater.name != cmd.text do continue
            if !heater.controllable || cmd.value < 0 ||
                (cmd.value != 0 && (cmd.value < heater.min_temp || cmd.value > heater.max_temp)) {
                return fail(c, "Heater target exceeds its reported limits")
            }
            target := abs(cmd.value)
            heater_name := heater.name
            if strings.has_prefix(heater_name, "heater_generic ") {
                heater_name = heater_name[len("heater_generic "):]
            }
            if strings.has_prefix(heater_name, "temperature_fan ") {
                script = fmt.aprintf("SET_TEMPERATURE_FAN_TARGET TEMPERATURE_FAN=%s TARGET=%.3f",
                    heater_name[len("temperature_fan "):], target)
            } else {
                script = fmt.aprintf("SET_HEATER_TEMPERATURE HEATER=%s TARGET=%.3f", heater_name, target)
            }
            matched = true
            break
        }
        if !matched do return fail(c, "Heater is unavailable")
    case .Fan:
        if cmd.value < 0 || cmd.value > 1 do return fail(c, "Fan speed must be between 0 and 1")
        matched := false
        for fan in c.state.fans {
            if fan.name != cmd.text do continue
            if !fan.controllable do return fail(c, "This fan cannot be controlled manually")
            script = fan.name == "fan" ? fmt.aprintf("M106 S%.3f", cmd.value * 255) :
                fmt.aprintf("SET_FAN_SPEED FAN=%s SPEED=%.3f", fan.name[len("fan_generic "):],
                    cmd.value)
            matched = true
            break
        }
        if !matched do return fail(c, "Fan is unavailable")
    case .Home:
        if !motion_idle(c) || !c.state.position_available {
            return fail(c, "Homing needs an idle printer and an available toolhead")
        }
        if cmd.text != "" && cmd.text != "X" && cmd.text != "Y" && cmd.text != "Z" {
            return fail(c, "Home one axis or all axes")
        }
        script = cmd.text == "" ? strings.clone("G28") : fmt.aprintf("G28 %s", cmd.text)
    case .Disable_Motors:
        if !motion_idle(c) { return fail(c, "Disable motors only when the printer is idle") }
        script = strings.clone("M84")
    case .Jog, .Move:
        index := int(cmd.axis)
        absolute := cmd.kind == .Move
        if !motion_permitted(c, index, cmd.value, cmd.feed_mm_per_second, absolute) {
            return fail(c, absolute ? "Move needs a homed axis, known limits, idle state and an in-range position" :
                "Jog needs a homed axis, known limits, idle state and an in-range move")
        }
        axes := "XYZ"
        axis := axes[index:index+1]
        script = fmt.aprintf("SAVE_GCODE_STATE NAME=%s\n%s\nG1 %s%.3f F%.3f\nRESTORE_GCODE_STATE NAME=%s",
            absolute ? "HW_RATOS_MOVE" : "HW_RATOS_JOG", absolute ? "G90" : "G91", axis, cmd.value,
            cmd.feed_mm_per_second * 60, absolute ? "HW_RATOS_MOVE" : "HW_RATOS_JOG")
    case .Extrude:
        can_extrude := false
        max_distance := number(get_path(c.status["configfile"], "settings",
            c.state.active_extruder, "max_extrude_only_distance")) or_else 0
        for heater in c.state.heaters {
            if heater.name == c.state.active_extruder do can_extrude = heater.can_extrude
        }
        if !motion_idle(c) || !can_extrude || max_distance <= 0 || abs(cmd.value) > max_distance ||
            cmd.value == 0 || cmd.feed_mm_per_second <= 0 || cmd.feed_mm_per_second > 5 {
            return fail(c, "Extrusion needs a warm ready extruder, idle state and reported distance limits")
        }
        script = fmt.aprintf("SAVE_GCODE_STATE NAME=HW_RATOS_EXTRUDE\nM83\nG1 E%.3f F%.3f\nRESTORE_GCODE_STATE NAME=HW_RATOS_EXTRUDE",
            cmd.value, cmd.feed_mm_per_second * 60)
    case .Macro:
        found := false
        for macro in c.state.macros do if macro.name == cmd.text do found = true
        if !found || !plain_text(cmd.arguments) || len(cmd.arguments) > 2048 {
            return fail(c, "Choose a discovered macro and one-line arguments")
        }
        script = fmt.aprintf("%s %s", cmd.text, cmd.arguments)
    case .Script:
        if !valid_script(cmd.text) do return fail(c, "Enter a bounded UTF-8 G-code script")
        script = strings.clone(cmd.text)
    case:
        return fail(c, "Unsupported command")
    }
    return request(c, .Control, "printer.gcode.script", json.Object{"script"=script},
        "Command submitted; backend acknowledgement is separate from observed printer state")
}

// Updates a feature's live speed, acceleration, and fan settings on a connected local hw_printer host.
set_feature :: proc(c: ^Client, feature_idx: int, speed, acceleration, fan: f64) -> bool {
    assert(c != nil)
    context.allocator = c.allocator
    if c.read_only || !c.state.hw_printer_host {
        return fail(c, "Live feature editing requires a local hw_printer host")
    }
    if c.native == nil || c.state.connection != .Connected || c.state.stale ||
       c.state.printer_state != "ready" || !c.snapshot_received {
        return fail(c, "Printer readiness is unavailable or stale")
    }
    if has_pending(c, .Control) {
        return fail(c, "Wait for the outstanding control request")
    }
    if feature_idx < 0 || feature_idx >= len(c.state.features) {
        return fail(c, "Feature index is out of range")
    }
    f := c.state.features[feature_idx]
    if !finite(speed) || !finite(acceleration) || !finite(fan) ||
       speed <= 0 || speed > f.max_speed + 1e-6 ||
       acceleration <= 0 || acceleration > f.max_acceleration + 1e-6 ||
       fan < 0 || fan > 100 {
        return fail(c, fmt.tprintf("Enter speed 1–%.1f mm/s, accel 1–%.0f mm/s², fan 0–100%%",
            f.max_speed, f.max_acceleration))
    }
    return request(c, .Control, "hw_printer.feature.set", json.Object{
        "feature"      = json.Integer(feature_idx),
        "speed"        = json.Float(speed),
        "acceleration" = json.Float(acceleration),
        "fan"          = json.Float(fan),
    }, "Feature settings submitted")
}

// Re-evaluates a design `let` parameter during an active `.hwsdesign` print on a local hw_printer host.
set_design_param :: proc(c: ^Client, name: string, value: f64, reset := false) -> bool {
    assert(c != nil)
    context.allocator = c.allocator
    if c.read_only || !c.state.hw_printer_host {
        return fail(c, "Live design editing requires a local hw_printer host")
    }
    if c.native == nil || c.state.connection != .Connected || c.state.stale ||
       c.state.printer_state != "ready" || !c.snapshot_received {
        return fail(c, "Printer readiness is unavailable or stale")
    }
    if has_pending(c, .Control) {
        return fail(c, "Wait for the outstanding control request")
    }
    if name == "" || !identifier(name) {
        return fail(c, "Invalid design parameter name")
    }
    if !reset && !finite(value) {
        return fail(c, "Enter a finite numeric value")
    }
    params := json.Object{"name" = name}
    if reset {
        params["reset"] = true
    } else {
        params["value"] = json.Float(value)
    }
    return request(c, .Control, "hw_printer.design.set_param", params, "Design parameter submitted")
}

refresh_files :: proc(c: ^Client) -> bool {
    assert(c != nil)
    context.allocator = c.allocator
    if c.native == nil || c.state.connection != .Connected do return fail(c, "Connect to list files")
    if has_pending(c, .Files) do return true
    return request(c, .Files, "server.files.list", json.Object{"root"="gcodes"})
}

refresh_config_files :: proc(c: ^Client) -> bool {
    assert(c != nil)
    context.allocator = c.allocator
    if c.native == nil || c.state.connection != .Connected do return fail(c, "Connect to list configuration files")
    if has_pending(c, .Config_Files) do return true
    return request(c, .Config_Files, "server.files.list", json.Object{"root"="config"})
}

read_config :: proc(c: ^Client, path: string) -> bool {
    assert(c != nil)
    context.allocator = c.allocator
    if !valid_config_path(path) do return fail(c, "Configuration file path is not readable")
    listed := false
    for file in c.state.config_files {
        if file.path != path do continue
        if file.size > CONFIG_BYTES_MAX do return fail(c, "Configuration file exceeds 4 MiB")
        listed = strings.contains(file.permissions, "r")
    }
    if !listed do return fail(c, "Configuration file is not listed as readable")
    encoded := percent_encode(path, true)
    defer delete(encoded)
    url := strings.concatenate({"/server/files/config/", encoded})
    defer delete(url)
    return begin_transfer(c, .Config_Download, path, "GET", url, nil, "")
}

upload_config :: proc(c: ^Client, path: string, data: []byte) -> bool {
    assert(c != nil)
    context.allocator = c.allocator
    if c.read_only do return fail(c, "This session is read-only")
    if path != "printer.cfg" || len(data) == 0 || len(data) > CONFIG_BYTES_MAX ||
        !utf8.valid_string(string(data)) {
        return fail(c, "Only printer.cfg below 4 MiB of valid UTF-8 can be uploaded")
    }
    boundary := fmt.aprintf("hw_ratos_cfg_%d_%d", c.next_id, c.state.revision)
    defer delete(boundary)
    if strings.contains(string(data), boundary) {
        c.next_id += 1
        return fail(c, "Configuration contains the upload delimiter; retry with a fresh delimiter")
    }
    prefix := strings.concatenate({"--", boundary,
        "\r\nContent-Disposition: form-data; name=\"root\"\r\n\r\nconfig\r\n--", boundary,
        "\r\nContent-Disposition: form-data; name=\"file\"; filename=\"", path,
        "\"\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n"})
    defer delete(prefix)
    suffix := strings.concatenate({"\r\n--", boundary, "--\r\n"})
    defer delete(suffix)
    body := make([]byte, len(prefix) + len(data) + len(suffix))
    defer delete(body)
    copy(body, transmute([]byte)prefix)
    copy(body[len(prefix):], data)
    copy(body[len(prefix)+len(data):], transmute([]byte)suffix)
    content_type := strings.concatenate({"multipart/form-data; boundary=", boundary})
    defer delete(content_type)
    return begin_transfer(c, .Config_Upload, path, "POST", "/server/files/upload", body, content_type)
}

metadata :: proc(c: ^Client, path: string) -> bool {
    assert(c != nil)
    context.allocator = c.allocator
    index := file_index(c, path)
    if index < 0 || !valid_path(path) || !file_permission(c, path, 'r') {
        return fail(c, "Metadata needs a listed readable G-code file")
    }
    if !request(c, .Metadata, "server.files.metadata", json.Object{"filename"=path}, path) do return false
    c.state.files[index].metadata_status = .Pending
    return true
}

file_index :: proc(c: ^Client, path: string) -> int {
    assert(c != nil)
    if path == "" do return -1
    for file, index in c.state.files do if file.path == path do return index
    return -1
}

file_destroy :: proc(file: ^File) {
    delete(file.path)
    delete(file.permissions)
    metadata_destroy(&file.metadata)
    for &thumbnail in file.thumbnails do delete(thumbnail.data)
    file^ = {}
}

file_info_retry :: proc(c: ^Client, path: string) {
    assert(c != nil)
    index := file_index(c, path)
    if index < 0 do return
    file := &c.state.files[index]
    if file.metadata_status == .Failed do file.metadata_status = .None
    for &thumbnail in file.thumbnails do if thumbnail.status == .Failed do thumbnail.status = .None
}

file_info_step :: proc(c: ^Client, selected: string, first, count: int) -> bool {
    assert(c != nil)
    assert(first >= 0 && count >= 0)
    context.allocator = c.allocator
    changed := false
    files := c.state.files[:]
    keep_first := max(0, first - THUMBNAIL_ICON_RETAIN_ROWS)
    keep_last := first + count + THUMBNAIL_ICON_RETAIN_ROWS
    for &file, index in files {
        if file.path == c.thumbnail_fetch.path do continue
        icon := &file.thumbnails[.Icon]
        if (index < keep_first || index >= keep_last) && icon.status != .None {
            delete(icon.data)
            icon^ = {}
            changed = true
        }
        image := &file.thumbnails[.Image]
        if file.path != selected && image.status != .None {
            delete(image.data)
            image^ = {}
            changed = true
        }
    }
    if c.native == nil || c.state.connection != .Connected do return changed
    selected_index := file_index(c, selected)
    last := max(first, min(len(files), first + count))
    pending := 0
    for request_entry in c.pending do if request_entry.id != 0 && request_entry.kind == .Metadata do pending += 1
    for order in -1..<last-first {
        if pending >= METADATA_CONCURRENT_MAX do break
        index := selected_index if order < 0 else first + order
        if index < 0 || files[index].metadata_status != .None || !strings.contains(files[index].permissions, "r") do continue
        if !metadata(c, files[index].path) do break
        pending += 1
        changed = true
    }
    if c.thumbnail_fetch.id != 0 || c.print_file.id != 0 || c.state.transfer.status == .Running do return changed
    if selected_index >= 0 && thumbnail_wanted(&files[selected_index], .Image) {
        return thumbnail_begin(c, selected_index, .Image) || changed
    }
    for index in first..<last {
        if thumbnail_wanted(&files[index], .Icon) do return thumbnail_begin(c, index, .Icon) || changed
    }
    return changed
}

thumbnail_wanted :: proc(file: ^File, kind: Thumbnail_Kind) -> bool {
    return file.metadata_status == .Ready && file.metadata.thumbnails[kind] != "" &&
        file.thumbnails[kind].status == .None
}

thumbnail_begin :: proc(c: ^Client, index: int, kind: Thumbnail_Kind) -> bool {
    assert(c != nil)
    assert(c.thumbnail_fetch.id == 0)
    file := &c.state.files[index]
    parent_end := strings.last_index(file.path, "/") + 1
    relative := strings.concatenate({file.path[:parent_end], file.metadata.thumbnails[kind]})
    defer delete(relative)
    encoded := percent_encode(relative, true)
    defer delete(encoded)
    url := strings.concatenate({"/server/files/gcodes/", encoded})
    defer delete(url)
    file.thumbnails[kind].status = .Failed
    if c.next_id >= 9_007_199_254_740_990 do return true
    id := c.next_id
    c.next_id += 1
    method := "GET"
    if mr_native_http(c.native, id, raw_data(method), i64(len(method)), raw_data(url), i64(len(url)),
        nil, 0, nil, 0) == 0 {
        devlog.failed(devlog.global(), THUMBNAIL_SITE, {reason="Native thumbnail read rejected"})
        return true
    }
    file.thumbnails[kind].status = .Pending
    c.thumbnail_fetch = Thumbnail_Fetch{id=id, path=strings.clone(file.path), kind=kind,
        deadline=c.now+THUMBNAIL_TIMEOUT_SECONDS}
    return true
}

thumbnail_abort :: proc(c: ^Client, retry: bool) {
    assert(c != nil)
    if c.thumbnail_fetch.id == 0 do return
    if c.native != nil do mr_native_http_cancel(c.native)
    if index := file_index(c, c.thumbnail_fetch.path); index >= 0 {
        c.state.files[index].thumbnails[c.thumbnail_fetch.kind].status = retry ? .None : .Failed
    }
    delete(c.thumbnail_fetch.path)
    c.thumbnail_fetch = {}
    c.state.revision += 1
}

thumbnail_response :: proc(c: ^Client, event: Native_Event) {
    assert(c != nil)
    assert(event.id == c.thumbnail_fetch.id)
    context.allocator = c.allocator
    fetch := c.thumbnail_fetch
    c.thumbnail_fetch = {}
    defer delete(fetch.path)
    c.state.revision += 1
    index := file_index(c, fetch.path)
    if index < 0 do return
    thumbnail := &c.state.files[index].thumbnails[fetch.kind]
    if thumbnail.status != .Pending do return
    if event.status < 200 || event.status >= 300 || event.length <= 0 || event.length > THUMBNAIL_BYTES_MAX {
        thumbnail.status = .Failed
        devlog.failed(devlog.global(), THUMBNAIL_SITE, {reason="Thumbnail read failed", code=event.status})
        return
    }
    delete(thumbnail.data)
    thumbnail.data = slice.clone(slice.from_ptr(cast(^byte)event.bytes, int(event.length)))
    c.thumbnail_serial += 1
    thumbnail.serial = c.thumbnail_serial
    thumbnail.status = .Ready
}

metadata_destroy :: proc(m: ^Metadata) {
    for path in m.thumbnails do delete(path)
    delete(m.slicer)
    delete(m.filament_type)
    delete(m.filament_name)
    m^ = {}
}

metadata_text :: proc(value: json.Value, key: string) -> string {
    result := text(get_path(value, key))
    if len(result) > METADATA_TEXT_BYTES_MAX || !plain_text(result) do return ""
    return strings.trim_space(result)
}

metadata_thumbnail :: proc(value: json.Value) -> (result: [Thumbnail_Kind]string) {
    thumbnails, ok := value.(json.Array)
    if !ok do return
    best, icon: string
    best_area, icon_area: f64
    for entry in thumbnails {
        path := text(get_path(entry, "relative_path"))
        directory_end := strings.index(path, "/")
        if directory_end < 0 do continue
        directory, name := path[:directory_end], path[directory_end+1:]
        if (directory != ".thumbs" && directory != "thumbs") || len(name) > 512 ||
            !plain_text(name) || strings.contains_any(name, "/\\%\"?#") ||
            !strings.has_suffix(name, ".png") { continue }
        width, _ := number(get_path(entry, "width"))
        height, _ := number(get_path(entry, "height"))
        size, _ := number(get_path(entry, "size"))
        if width < 1 || width > 1024 || height < 1 || height > 1024 ||
            size < 1 || size > 1024*1024 { continue }
        if width*height > best_area {
            best = path
            best_area = width*height
        }
        if max(width, height) >= THUMBNAIL_ICON_PIXELS_MIN && (icon == "" || width*height < icon_area) {
            icon = path
            icon_area = width*height
        }
    }
    result[.Image] = best
    result[.Icon] = icon if icon != "" else best
    return
}

download :: proc(c: ^Client, path: string) -> bool {
    assert(c != nil)
    context.allocator = c.allocator
    if !valid_path(path) || !file_permission(c, path, 'r') do return fail(c, "File is not readable")
    for file in c.state.files {
        if file.path == path && file.size > TRANSFER_BYTES_MAX {
            return fail(c, "First version limits file transfers to 32 MiB")
        }
    }
    encoded := percent_encode(path, true)
    defer delete(encoded)
    url := strings.concatenate({"/server/files/gcodes/", encoded})
    defer delete(url)
    return begin_transfer(c, .Download, path, "GET", url, nil, "")
}

upload :: proc(c: ^Client, path: string, data: []byte, overwrite_confirmed: bool) -> bool {
    assert(c != nil)
    context.allocator = c.allocator
    if c.read_only do return fail(c, "This session is read-only")
    if c.limited do return fail(c, "This session permits only heater target changes")
    if !c.state.armed || c.state.stale || !c.state.gcodes_writable || !valid_path(path) ||
        len(data) == 0 || len(data) > TRANSFER_BYTES_MAX - 4096 {
        return fail(c, "Upload needs armed controls, writable gcodes root and a file below 32 MiB")
    }
    for file in c.state.files {
        if file.path == path && (!overwrite_confirmed || !strings.contains(file.permissions, "w")) {
            return fail(c, "Confirm overwrite of a writable file")
        }
    }
    boundary := fmt.aprintf("hw_ratos_%d_%d", c.next_id, c.state.revision)
    defer delete(boundary)
    if strings.contains(string(data), boundary) {
        c.next_id += 1
        return fail(c, "File contains the upload delimiter; retry with a fresh delimiter")
    }
    prefix := strings.concatenate({"--", boundary,
        "\r\nContent-Disposition: form-data; name=\"root\"\r\n\r\ngcodes\r\n--", boundary,
        "\r\nContent-Disposition: form-data; name=\"file\"; filename=\"", path,
        "\"\r\nContent-Type: application/octet-stream\r\n\r\n"})
    defer delete(prefix)
    suffix := strings.concatenate({"\r\n--", boundary, "--\r\n"})
    defer delete(suffix)
    body := make([]byte, len(prefix) + len(data) + len(suffix))
    defer delete(body)
    copy(body, transmute([]byte)prefix)
    copy(body[len(prefix):], data)
    copy(body[len(prefix)+len(data):], transmute([]byte)suffix)
    content_type := strings.concatenate({"multipart/form-data; boundary=", boundary})
    defer delete(content_type)
    return begin_transfer(c, .Upload, path, "POST", "/server/files/upload", body, content_type)
}

delete_file :: proc(c: ^Client, path: string, confirmed: bool) -> bool {
    assert(c != nil)
    context.allocator = c.allocator
    if c.read_only do return fail(c, "This session is read-only")
    if c.limited do return fail(c, "This session permits only heater target changes")
    if !c.state.armed || c.state.stale || !c.state.gcodes_writable || !confirmed ||
        !valid_path(path) || !file_permission(c, path, 'w') {
        return fail(c, "Confirm deletion of a listed writable G-code file with controls armed")
    }
    if c.state.filename == path && (c.state.job_state == "printing" || c.state.job_state == "paused") {
        return fail(c, "Cannot delete the active print file")
    }
    encoded := percent_encode(path, true)
    defer delete(encoded)
    url := strings.concatenate({"/server/files/gcodes/", encoded})
    defer delete(url)
    return begin_transfer(c, .Delete, path, "DELETE", url, nil, "")
}

cancel_transfer :: proc(c: ^Client) {
    assert(c != nil)
    if c.state.transfer.status != .Running do return
    if c.native != nil do mr_native_http_cancel(c.native)
    c.state.transfer.status = .Cancelled
    c.state.transfer.id = 0
    assign_text(&c.state.operation, "Transfer cancelled locally; server outcome may be uncertain")
    c.state.revision += 1
}

begin_transfer :: proc(c: ^Client, kind: Transfer_Kind, path, method, url: string,
    body: []byte, content_type: string) -> bool {
    assert(c != nil)
    if kind == .Config_Upload {
        if c.read_only || path != "printer.cfg" || method != "POST" ||
            url != "/server/files/upload" || len(body) == 0 ||
            !strings.has_prefix(content_type, "multipart/form-data; boundary=") {
            return fail(c, "Configuration upload is restricted to printer.cfg")
        }
    } else {
        root_prefix := kind == .Config_Download ? "/server/files/config/" : "/server/files/gcodes/"
        if (kind == .Config_Download || c.read_only || c.limited) && ((kind != .Download && kind != .Config_Download) ||
            method != "GET" || len(body) != 0 || len(content_type) != 0 || !strings.has_prefix(url, root_prefix)) {
            return fail(c, "This session permits only read-only file downloads")
        }
    }
    if c.native == nil || c.state.connection != .Connected || c.state.transfer.status == .Running {
        return fail(c, "Connect and finish or cancel the current file transfer first")
    }
    thumbnail_abort(c, true)
    print_file_abort(c)
    context.allocator = c.allocator
    if c.next_id >= 9_007_199_254_740_990 do return fail(c, "Request identifier limit reached")
    id := c.next_id
    c.next_id += 1
    if mr_native_http(c.native, id, raw_data(method), i64(len(method)), raw_data(url), i64(len(url)),
        raw_data(body), i64(len(body)), raw_data(content_type), i64(len(content_type))) == 0 {
        return fail(c, "Native file transfer is busy or unavailable")
    }
    delete(c.state.transfer.path)
    delete(c.state.transfer.data)
    c.state.transfer = Transfer{kind=kind, status=.Running, path=strings.clone(path), id=id,
        deadline=c.now+60}
    assign_text(&c.state.operation, "File transfer running; cancellation is local")
    c.state.revision += 1
    return true
}

transfer_response :: proc(c: ^Client, event: Native_Event) {
    assert(c != nil)
    if event.id != c.state.transfer.id || c.state.transfer.status != .Running do return
    c.state.transfer.id = 0
    if event.status < 200 || event.status >= 300 {
        c.state.transfer.status = .Failed
        _ = fail_operation(c, "file_transfer", (event.status == 401 || event.status == 403) ? "File operation authentication/permissions rejected" :
            "File transfer failed; a mutation may have an uncertain server outcome", i32(event.status))
        return
    }
    data := slice.from_ptr(cast(^byte)event.bytes, int(event.length))
    if c.state.transfer.kind == .Download || c.state.transfer.kind == .Config_Download {
        c.state.transfer.data = slice.clone(data, c.allocator)
    } else {
        value, ok := parse_json(string(data))
        if !ok {
            c.state.transfer.status = .Failed
            _ = fail_operation(c, "file_transfer", "Invalid file-operation reply; server outcome is uncertain")
            return
        }
        defer json.destroy_value(value)
        root := text(get_path(value, "result", "item", "root"))
        expected_root := c.state.transfer.kind == .Config_Upload ? "config" : "gcodes"
        if root != expected_root {
            c.state.transfer.status = .Failed
            _ = fail_operation(c, "file_transfer", "File operation returned an unexpected root; server outcome is uncertain")
            return
        }
        if c.state.transfer.kind == .Config_Upload {
            _ = refresh_config_files(c)
        } else {
            _ = refresh_files(c)
        }
    }
    c.state.transfer.status = .Complete
    assign_text(&c.state.operation, "File operation completed")
    c.state.revision += 1
}

request :: proc(c: ^Client, kind: Request_Kind, method: string, params: json.Value,
    label: string = "") -> bool {
    assert(c != nil)
    assert(len(method) > 0)
    context.allocator = c.allocator
    defer if object, ok := params.(json.Object); ok do delete(object)
    if c.read_only && (!read_only_method(method) ||
        kind in (bit_set[Request_Kind]{.Control, .Emergency})) {
        return request_fail(c, kind, "This session permits only monitoring requests")
    }
    if c.limited && !(read_only_method(method) &&
        kind not_in (bit_set[Request_Kind]{.Control, .Emergency})) &&
        !limited_request(c, kind, method, params) {
        return request_fail(c, kind, "This session permits only monitoring and checked heater target requests")
    }
    if kind == .History && has_pending(c, .History) { return false }
    if c.native == nil do return request_fail(c, kind, "No active connection")
    slot := -1
    if kind == .Emergency {
        slot = PENDING_MAX - 1
        release_pending(&c.pending[slot])
    } else {
        for pending, index in c.pending[:PENDING_MAX-1] {
            if pending.id == 0 { slot = index; break }
        }
    }
    if slot < 0 do return request_fail(c, kind, "Request limit reached; wait for pending requests")
    if c.next_id >= 9_007_199_254_740_990 do return request_fail(c, kind, "Request identifier limit reached")
    id := c.next_id
    c.next_id += 1
    payload := json.Object{"jsonrpc"="2.0", "method"=method, "id"=json.Integer(id)}
    defer delete(payload)
    if params != nil do payload["params"] = params
    data, err := json.marshal(json.Value(payload))
    if err != nil do return request_fail(c, kind, "Cannot encode request", true)
    defer delete(data)
    if len(data) > MESSAGE_BYTES_MAX || mr_native_send(c.native, raw_data(data), i64(len(data)), id) == 0 {
        return request_fail(c, kind, "Cannot send request; command was not retried", true)
    }
    c.pending[slot] = Pending{id=id, kind=kind, deadline=c.now+15, label=strings.clone(label)}
    if kind in (bit_set[Request_Kind]{.Control, .Emergency}) {
        assign_text(&c.state.error, "")
        assign_text(&c.state.operation, label)
        script := text(get_path(params, "script"))
        append_log(c, .Sent, script != "" ? script : method)
        c.state.revision += 1
    }
    return true
}

read_only_method :: proc(method: string) -> bool {
    return method == "server.info" || method == "printer.info" ||
        method == "printer.objects.list" || method == "printer.objects.subscribe" ||
        method == "printer.gcode.help" || method == "server.files.list" ||
        method == "server.files.roots" || method == "server.files.metadata" ||
        method == "server.temperature_store"
}

request_fail :: proc(c: ^Client, kind: Request_Kind, message: string, operating := false) -> bool {
    if kind == .History { return temperature_history_fail(c, message) }
    if operating do return fail_operation(c, "send_request", message)
    return fail(c, message)
}

motion_permitted :: proc(c: ^Client, index: int, value, feed: f64, absolute: bool) -> bool {
    assert(c != nil)
    if index < 0 || index > 2 || !finite(value) || !finite(feed) { return false }
    if !motion_idle(c) || !c.state.position_available || !c.state.limits_available ||
       !strings.contains(c.state.homed_axes, string([]byte{u8('x') + u8(index)})) ||
       feed <= 0 || feed > c.state.max_velocity { return false }
    if !absolute && (value == 0 || abs(value) > 100) { return false }
    destination := absolute ? value : c.state.position[index] + value
    return destination >= c.state.axis_minimum[index] && destination <= c.state.axis_maximum[index]
}

limited_request :: proc(c: ^Client, kind: Request_Kind, method: string, params: json.Value) -> bool {
    assert(c != nil)
    if kind == .Emergency { return method == "printer.emergency_stop" && params == nil }
    if kind == .Control && (method == "printer.restart" || method == "printer.firmware_restart") {
        return params == nil && !has_pending(c, .Control)
    }
    if kind == .Control && c.state.hw_printer_host && !c.state.stale &&
       c.state.connection == .Connected && c.state.printer_state == "ready" &&
       c.snapshot_received && !has_pending(c, .Control) {
        if method == "printer.print.start" || method == "printer.print.pause" ||
           method == "printer.print.resume" || method == "printer.print.cancel" ||
           method == "hw_printer.feature.set" || method == "hw_printer.design.set_param" {
            return true
        }
    }
    if kind != .Control || method != "printer.gcode.script" || c.state.stale ||
        c.state.connection != .Connected || c.state.printer_state != "ready" ||
        !c.snapshot_received || has_pending(c, .Control) { return false }
    object, object_ok := params.(json.Object)
    if !object_ok || len(object) != 1 { return false }
    script := text(get_path(params, "script"))
    if script == "M84" { return motion_idle(c) }
    if c.state.hw_printer_host && (script == "M107" || strings.has_prefix(script, "M106 S")) { return true }
    name, target, temperature_fan, ok := heater_script(script)
    if !ok {
        if homing_script(script) { return motion_idle(c) && c.state.position_available }
        axis, value, feed, absolute, motion_ok := motion_script(script)
        return motion_ok && motion_permitted(c, axis, value, feed / 60, absolute)
    }
    for heater in c.state.heaters {
        heater_name := heater.name
        fan := strings.has_prefix(heater_name, "temperature_fan ")
        if fan {
            heater_name = heater_name[len("temperature_fan "):]
        } else if strings.has_prefix(heater_name, "heater_generic ") {
            heater_name = heater_name[len("heater_generic "):]
        }
        if heater_name != name || fan != temperature_fan { continue }
        return heater.controllable && (target == 0 ||
            (target >= heater.min_temp && target <= heater.max_temp))
    }
    return false
}

heater_script :: proc(script: string) -> (name: string, target: f64, temperature_fan, ok: bool) {
    if len(script) > 512 { return }
    heater_prefix :: "SET_HEATER_TEMPERATURE HEATER="
    fan_prefix :: "SET_TEMPERATURE_FAN_TARGET TEMPERATURE_FAN="
    remainder := script
    if strings.has_prefix(script, heater_prefix) {
        remainder = script[len(heater_prefix):]
    } else if strings.has_prefix(script, fan_prefix) {
        remainder = script[len(fan_prefix):]
        temperature_fan = true
    } else { return }
    separator := strings.index(remainder, " TARGET=")
    if separator <= 0 || !identifier(remainder[:separator]) { return }
    number_text := remainder[separator+len(" TARGET="):]
    decimal := len(number_text) - 4
    if decimal < 1 || decimal > 309 || number_text[decimal] != '.' ||
        (decimal > 1 && number_text[0] == '0') { return }
    for character, index in number_text {
        if index == decimal { continue }
        if character < '0' || character > '9' { return }
    }
    value, parsed := strconv.parse_f64(number_text)
    if !parsed || !finite(value) || value < 0 { return }
    name = remainder[:separator]
    target = value
    ok = true
    return
}

homing_script :: proc(script: string) -> bool {
    return script == "G28" || script == "G28 X" || script == "G28 Y" || script == "G28 Z"
}

// Accepts only the exact single-axis jog/move script that command() builds.
motion_script :: proc(script: string) -> (axis: int, value, feed: f64, absolute, ok: bool) {
    if len(script) > 160 { return }
    lines := strings.split(script, "\n", context.temp_allocator)
    if len(lines) != 4 { return }
    name: string
    switch lines[1] {
    case "G91": name = "HW_RATOS_JOG"
    case "G90": name = "HW_RATOS_MOVE"; absolute = true
    case: return
    }
    if lines[0] != fmt.tprintf("SAVE_GCODE_STATE NAME=%s", name) ||
       lines[3] != fmt.tprintf("RESTORE_GCODE_STATE NAME=%s", name) { return }
    fields := strings.split(lines[2], " ", context.temp_allocator)
    if len(fields) != 3 || fields[0] != "G1" || len(fields[1]) < 2 || len(fields[2]) < 2 ||
       fields[2][0] != 'F' { return }
    switch fields[1][0] {
    case 'X': axis = 0
    case 'Y': axis = 1
    case 'Z': axis = 2
    case: return
    }
    value_ok, feed_ok: bool
    value, value_ok = fixed_three(fields[1][1:], true)
    feed, feed_ok = fixed_three(fields[2][1:], false)
    ok = value_ok && feed_ok
    return
}

fixed_three :: proc(text: string, signed: bool) -> (f64, bool) {
    digits := text
    if signed && len(digits) > 0 && digits[0] == '-' { digits = digits[1:] }
    dot := len(digits) - 4
    if dot < 1 || dot > 7 || digits[dot] != '.' { return 0, false }
    for character, index in digits {
        if index != dot && (character < '0' || character > '9') { return 0, false }
    }
    value, parsed := strconv.parse_f64(text)
    return value, parsed && finite(value)
}

receive :: proc(c: ^Client, data: string) {
    assert(c != nil)
    value, ok := parse_json(data)
    if !ok { lost(c, "Malformed JSON-RPC message; monitoring disconnected", true); return }
    defer json.destroy_value(value)
    object, is_object := value.(json.Object)
    if !is_object || text(object["jsonrpc"]) != "2.0" {
        lost(c, "Invalid JSON-RPC envelope", true)
        return
    }
    method := text(object["method"])
    if method != "" {
        if _, has_id := object["id"]; has_id { lost(c, "Unexpected server request", true); return }
        notification(c, method, object["params"])
        return
    }
    id, id_ok := object["id"].(json.Integer)
    if !id_ok || id <= 0 { lost(c, "Invalid JSON-RPC response identifier", true); return }
    index := -1
    for pending, slot in c.pending do if pending.id == id { index = slot; break }
    if index < 0 do return
    pending := c.pending[index]
    defer release_pending(&c.pending[index])
    error_value, has_error := object["error"]
    result, has_result := object["result"]
    if has_error == has_result {
        if pending.kind == .History {
            _ = temperature_history_fail(c, "Invalid temperature history response envelope")
        } else { lost(c, "Invalid JSON-RPC result/error envelope", true) }
        return
    }
    if has_error {
        message := text(get_path(error_value, "message"))
        code := number(get_path(error_value, "code")) or_else 0
        if pending.kind == .History {
            _ = temperature_history_fail(c, message != "" ? message : "Invalid temperature history error response",
                message != "" ? "Server rejected the temperature history request" : "")
            return
        }
        if message == "" { lost(c, "Invalid JSON-RPC error object", true); return }
        if pending.kind == .Metadata && code != 401 && code != 403 {
            if file := file_index(c, pending.label); file >= 0 do c.state.files[file].metadata_status = .Failed
            c.state.revision += 1
            return
        }
        _ = fail(c, message)
        if code == 401 || code == 403 {
            lost(c, "Authentication rejected; monitoring stopped", true)
        } else if pending.kind in (bit_set[Request_Kind]{.Server, .Objects, .Subscribe}) {
            lost(c, message, false, "Server rejected a monitoring request")
        }
        return
    }
    switch pending.kind {
    case .Server, .Heartbeat:
        previous_stale := c.state.stale
        previous_connection := c.state.connection
        readiness_changed := c.state.printer_state != text(get_path(result, "klippy_state"))
        temperature_history_capability(c, result)
        hw_host := false
        if is_loopback_endpoint(c.endpoint) {
            if comps, cok := get_path(result, "components").(json.Array); cok {
                for comp in comps {
                    if text(comp) == "hw_printer" { hw_host = true; break }
                }
            }
        }
        if c.state.hw_printer_host != hw_host {
            c.state.hw_printer_host = hw_host
            readiness_changed = true
        }
        assign_text(&c.state.printer_state, text(get_path(result, "klippy_state")))
        if c.state.printer_state == "" { lost(c, "Missing server readiness state", true); return }
        if pending.kind == .Server && c.state.printer_state == "ready" {
            _ = request(c, .Printer, "printer.info", nil)
            _ = request(c, .Objects, "printer.objects.list", nil)
            _ = request(c, .Help, "printer.gcode.help", nil)
        } else if c.state.printer_state != "ready" {
            c.state.stale = true
            c.snapshot_received = false
            connection_up(c)
            c.state.connection = .Connected
            c.heartbeat_at = c.now + 2
            _ = request(c, .Printer, "printer.info", nil)
        } else if !c.snapshot_received && !has_pending(c, .Objects) && !has_pending(c, .Subscribe) {
            _ = request(c, .Objects, "printer.objects.list", nil)
            _ = request(c, .Help, "printer.gcode.help", nil)
        } else if c.state.printer_state == "ready" && c.snapshot_received {
            c.state.stale = false
        }
        if readiness_changed || previous_stale != c.state.stale || previous_connection != c.state.connection {
            c.state.revision += 1
        }
        return
    case .Printer:
        hostname := text(get_path(result, "hostname"))
        message := text(get_path(result, "state_message"))
        if c.state.hostname == hostname && c.state.printer_message == message do return
        assign_text(&c.state.hostname, hostname)
        assign_text(&c.state.printer_message, message)
    case .Objects:
        names, names_ok := get_path(result, "objects").(json.Array)
        if !names_ok || len(names) > OBJECTS_MAX { lost(c, "Object discovery exceeds limits", true); return }
        for name in c.objects do delete(name)
        clear(&c.objects)
        wanted := make(json.Object)
        defer {
            for _, fields in wanted do delete(fields.(json.Array))
            delete(wanted)
        }
        for name_value in names {
            name := text(name_value)
            if len(name) == 0 || len(name) > 256 || !plain_text(name) {
                lost(c, "Invalid discovered printer object", true)
                return
            }
            append(&c.objects, strings.clone(name))
            fields := subscription_fields(name)
            if fields[0] == "" { continue }
            selected := make(json.Array, 0, len(fields))
            for field in fields {
                if field == "" { break }
                append(&selected, field)
            }
            wanted[name] = selected
        }
        _ = request(c, .Subscribe, "printer.objects.subscribe", json.Object{"objects"=wanted})
        return
    case .Subscribe:
        status, status_ok := get_path(result, "status").(json.Object)
        eventtime, eventtime_ok := number(get_path(result, "eventtime"))
        if !status_ok || !eventtime_ok || eventtime < 0 {
            lost(c, "Invalid initial subscription snapshot", true)
            return
        }
        json.destroy_value(json.Value(c.status))
        c.status = make(json.Object)
        c.status_bytes = 0
        if merged, _ := merge_status(c, status); !merged do return
        c.eventtime = eventtime
        c.state.clock_available = false
        clock_observe(c, eventtime)
        c.snapshot_received = true
        c.state.stale = false
        connection_up(c)
        c.state.connection = .Connected
        c.reconnect_attempts = 0
        update_view(c)
        assign_text(&c.state.operation, "Monitoring connected; controls remain disarmed")
        if !c.history_disabled { _ = refresh_temperature_history(c) }
    case .History:
        _ = receive_temperature_history(c, result)
    case .Help:
        if _, object_ok := result.(json.Object); object_ok {
            if json_values_equal(c.help, result) do return
            json.destroy_value(c.help)
            c.help = json.clone_value(result)
            update_view(c)
        }
    case .Files:
        parse_files(c, result, &c.state.files, false)
    case .Config_Files:
        parse_files(c, result, &c.state.config_files, true)
    case .Roots:
        roots, roots_ok := result.(json.Array)
        if roots_ok && len(roots) <= 64 {
            c.state.gcodes_writable = false
            for root in roots {
                if text(get_path(root, "name")) == "gcodes" &&
                    strings.contains(text(get_path(root, "permissions")), "w") {
                    c.state.gcodes_writable = true
                }
            }
        }
    case .Metadata:
        file_slot := file_index(c, pending.label)
        if file_slot < 0 do return
        file := &c.state.files[file_slot]
        metadata_destroy(&file.metadata)
        for &thumbnail in file.thumbnails { delete(thumbnail.data); thumbnail = {} }
        file.metadata_status = .Ready
        m := &file.metadata
        for path, kind in metadata_thumbnail(get_path(result, "thumbnails")) do m.thumbnails[kind] = strings.clone(path)
        slicer := metadata_text(result, "slicer")
        version := metadata_text(result, "slicer_version")
        m.slicer = strings.join({slicer, version}, " ") if slicer != "" && version != "" else strings.clone(slicer)
        m.filament_type = strings.clone(metadata_text(result, "filament_type"))
        m.filament_name = strings.clone(metadata_text(result, "filament_name"))
        if size, size_ok := number(get_path(result, "size")); size_ok && size >= 0 && size <= 9e15 {
            m.size = i64(size)
            m.size_available = true
        }
        keys := METADATA_NUMBER_KEYS
        for key, kind in keys {
            value, value_ok := number(get_path(result, key))
            if !value_ok || value < 0 || value > METADATA_NUMBER_MAX do continue
            m.numbers[kind] = value
            m.available += {kind}
        }
    case .Control, .Emergency:
        assign_text(&c.state.operation, "Backend acknowledged request; printer status remains authoritative")
        append_log(c, .Response, "Backend acknowledged command")
    }
    c.state.revision += 1
}

notification :: proc(c: ^Client, method: string, params_value: json.Value) {
    assert(c != nil)
    if method != "notify_status_update" && method != "notify_klippy_ready" &&
        method != "notify_klippy_shutdown" && method != "notify_klippy_disconnected" &&
        method != "notify_gcode_response" && method != "notify_filelist_changed" { return }
    params, params_ok := params_value.(json.Array)
    if params_value == nil && (method == "notify_klippy_ready" ||
        method == "notify_klippy_shutdown" || method == "notify_klippy_disconnected") {
        params_ok = true
    }
    if !params_ok || len(params) > 32 { lost(c, "Invalid notification parameters", true); return }
    switch method {
    case "notify_status_update":
        if len(params) != 2 { lost(c, "Invalid status notification", true); return }
        status, status_ok := params[0].(json.Object)
        eventtime, eventtime_ok := number(params[1])
        if !status_ok || !eventtime_ok || eventtime < 0 {
            lost(c, "Invalid status delta", true)
            return
        }
        if !c.snapshot_received || eventtime < c.eventtime do return
        ok, changed := merge_status(c, status)
        if !ok do return
        c.eventtime = eventtime
        clock_observe(c, eventtime)
        if !changed do return
        _, config_changed := status["configfile"]
        update_view(c, config_changed)
        if motion, has_motion := status["motion_report"].(json.Object); has_motion {
            if _, has_position := motion["live_position"]; has_position && c.state.live_position_available {
                c.state.live_sample_eventtime = eventtime
                c.state.live_sample_serial += 1
            }
        }
    case "notify_klippy_ready":
        clear_temperature_history(c)
        c.state.stale = true
        c.snapshot_received = false
        c.state.connection = .Initializing
        c.connect_deadline = c.now + 15
        _ = request(c, .Server, "server.info", nil)
    case "notify_klippy_shutdown", "notify_klippy_disconnected":
        clear_temperature_history(c)
        c.state.stale = true
        c.snapshot_received = false
        assign_text(&c.state.printer_state, method == "notify_klippy_shutdown" ? "shutdown" :
            "disconnected")
        c.heartbeat_at = c.now + 2
        append_log(c, .Error, c.state.printer_state)
    case "notify_gcode_response":
        if len(params) != 1 { lost(c, "Invalid G-code response notification", true); return }
        response := text(params[0])
        if len(response) > 8192 do response = response[:8192]
        append_log(c, .Response, response)
    case "notify_filelist_changed":
        root := len(params) > 0 ? text(get_path(params[0], "item", "root")) : ""
        if root == "config" {
            c.state.config_revision += 1
        } else if !has_pending(c, .Files) do _ = refresh_files(c)
    }
    c.state.revision += 1
}

merge_status :: proc(c: ^Client, delta: json.Object) -> (bool, bool) {
    assert(c != nil)
    if len(delta) > OBJECTS_MAX { lost(c, "Status object limit exceeded", true); return false, false }
    projected := c.status_bytes
    for name, value in delta {
        fields := subscription_fields(name)
        if fields[0] == "" do continue
        changes, ok := value.(json.Object)
        if !ok || len(changes) > 128 { lost(c, "Invalid printer object status", true); return false, false }
        previous, _ := c.status[name].(json.Object)
        if len(previous) + len(changes) > 256 { lost(c, "Status field limit exceeded", true); return false, false }
        for field, item in changes {
            if len(field) > 256 { lost(c, "Status field name exceeds limit", true); return false, false }
            if field == "" || !slice.contains(fields[:], field) do continue
            projected += value_cost(item) + len(field)
            if old, exists := previous[field]; exists do projected -= value_cost(old) + len(field)
        }
        if projected > MESSAGE_BYTES_MAX { lost(c, "Retained status limit exceeded", true); return false, false }
    }
    changed := false
    for name, value in delta {
        fields := subscription_fields(name)
        if fields[0] == "" do continue
        changes := value.(json.Object)
        previous, exists := c.status[name].(json.Object)
        for field, item in changes {
            if field == "" || !slice.contains(fields[:], field) do continue
            if !exists {
                if len(c.status) >= OBJECTS_MAX { lost(c, "Retained object limit exceeded", true); return false, false }
                previous = make(json.Object)
                c.status[strings.clone(name)] = previous
                exists = true
            }
            if old, field_exists := previous[field]; field_exists {
                if json_values_equal(old, item) do continue
                json.destroy_value(old)
                previous[field] = json.clone_value(item)
            } else {
                previous[strings.clone(field)] = json.clone_value(item)
            }
            changed = true
        }
        if exists do c.status[name] = previous
    }
    c.status_bytes = projected
    assert(c.status_bytes >= 0)
    return true, changed
}

json_values_equal :: proc(left, right: json.Value) -> bool {
    if left == nil || right == nil { return left == nil && right == nil }
    switch item in left {
    case json.Null: other, ok := right.(json.Null); return ok && item == other
    case json.Boolean: other, ok := right.(json.Boolean); return ok && item == other
    case json.Integer: other, ok := right.(json.Integer); return ok && item == other
    case json.Float: other, ok := right.(json.Float); return ok && item == other
    case json.String: other, ok := right.(json.String); return ok && item == other
    case json.Array:
        other, ok := right.(json.Array)
        if !ok || len(item) != len(other) { return false }
        for value, index in item do if !json_values_equal(value, other[index]) do return false
    case json.Object:
        other, ok := right.(json.Object)
        if !ok || len(item) != len(other) { return false }
        for key, value in item {
            previous, exists := other[key]
            if !exists || !json_values_equal(value, previous) { return false }
        }
    }
    return true
}

update_view :: proc(c: ^Client, rebuild_macros := true) {
    assert(c != nil)
    state := &c.state
    webhooks := c.status["webhooks"]
    if ready := text(get_path(webhooks, "state")); ready != "" do assign_text(&state.printer_state, ready)
    if message := text(get_path(webhooks, "state_message")); message != "" do assign_text(&state.printer_message, message)
    assign_text(&state.job_state, text(get_path(c.status["print_stats"], "state")))
    assign_text(&state.filename, text(get_path(c.status["print_stats"], "filename")))
    assign_text(&state.job_message, text(get_path(c.status["print_stats"], "message")))
    state.progress, state.progress_available = number(get_path(c.status["virtual_sdcard"], "progress"))
    state.progress_available = state.progress_available && state.progress >= 0 && state.progress <= 1
    state.print_duration, state.duration_available = number(get_path(c.status["print_stats"], "print_duration"))
    state.duration_available = state.duration_available && state.print_duration >= 0
    state.position_available = vector(get_path(c.status["toolhead"], "position"), state.position[:])
    state.live_position_available = vector(get_path(c.status["motion_report"], "live_position"), state.live_position[:])
    state.live_velocity = number(get_path(c.status["motion_report"], "live_velocity")) or_else 0
    state.limits_available = vector(get_path(c.status["toolhead"], "axis_minimum"), state.axis_minimum[:]) &&
        vector(get_path(c.status["toolhead"], "axis_maximum"), state.axis_maximum[:])
    for i in 0..<3 do if state.axis_minimum[i] > state.axis_maximum[i] do state.limits_available = false
    assign_text(&state.homed_axes, text(get_path(c.status["toolhead"], "homed_axes")))
    steppers, steppers_ok := get_path(c.status["stepper_enable"], "steppers").(json.Object)
    state.motors_available = steppers_ok && len(steppers) > 0
    state.motors_engaged = false
    for _, value in steppers {
        enabled, ok := value.(json.Boolean)
        if !ok { state.motors_available = false; break }
        if enabled { state.motors_engaged = true }
    }
    assign_text(&state.active_extruder, text(get_path(c.status["toolhead"], "extruder")))
    state.max_velocity = number(get_path(c.status["toolhead"], "max_velocity")) or_else 0
    max_accel, accel_ok := number(get_path(c.status["toolhead"], "max_accel"))
    corner, corner_ok := number(get_path(c.status["toolhead"], "square_corner_velocity"))
    cruise, cruise_ok := number(get_path(c.status["toolhead"], "minimum_cruise_ratio"))
    state.max_accel, state.square_corner_velocity, state.minimum_cruise_ratio = max_accel, corner, cruise
    state.velocity_limits_available = accel_ok && corner_ok && cruise_ok && state.max_velocity > 0 &&
        max_accel > 0 && corner >= 0 && cruise >= 0 && cruise < 1
    file_position, file_position_ok := number(get_path(c.status["virtual_sdcard"], "file_position"))
    state.file_position_available = file_position_ok && file_position >= 0 && file_position < 1e12
    state.file_position = i64(file_position) if state.file_position_available else 0
    for heater in state.heaters do delete(heater.name)
    clear(&state.heaters)
    for fan in state.fans do delete(fan.name)
    clear(&state.fans)
    if rebuild_macros {
        for macro in state.macros { delete(macro.name); delete(macro.description); delete(macro.parameters) }
        clear(&state.macros)
    }
    for feature in state.features { delete(feature.label); delete(feature.shape) }
    clear(&state.features)
    for param in state.design_params { delete(param.name); delete(param.unit); delete(param.reason) }
    clear(&state.design_params)
    state.job_is_design = false
    state.job_design_revision = 0
    state.job_preview_size = 0
    state.job_current_layer = 0
    state.job_total_layers = 0
    state.job_current_feature = -1
    if hw_job, ok := c.status["hw_printer_job"].(json.Object); ok {
        state.job_is_design = boolean(hw_job["is_design"]) or_else false
        if v, vok := number(hw_job["design_revision"]); vok && v >= 0 { state.job_design_revision = u64(v) }
        if v, vok := number(hw_job["preview_size"]); vok && v >= 0 { state.job_preview_size = i64(v) }
        if v, vok := number(hw_job["current_layer"]); vok { state.job_current_layer = int(v) }
        if v, vok := number(hw_job["total_layers"]); vok { state.job_total_layers = int(v) }
        if v, vok := number(hw_job["current_feature"]); vok { state.job_current_feature = int(v) }
        if arr, aok := hw_job["features"].(json.Array); aok {
            for item in arr {
                if len(state.features) >= 32 { break }
                fo, fok := item.(json.Object)
                if !fok { continue }
                idx_v, iok := number(fo["index"])
                if !iok { continue }
                append(&state.features, Job_Feature{
                    index             = int(idx_v),
                    layers            = int(number(fo["layers"]) or_else 0),
                    label             = strings.clone(text(fo["label"])),
                    shape             = strings.clone(text(fo["shape"])),
                    speed             = number(fo["speed"]) or_else 0,
                    acceleration      = number(fo["acceleration"]) or_else 0,
                    fan               = number(fo["fan"]) or_else 0,
                    base_speed        = number(fo["base_speed"]) or_else 0,
                    base_acceleration = number(fo["base_acceleration"]) or_else 0,
                    base_fan          = number(fo["base_fan"]) or_else 0,
                    max_speed         = number(fo["max_speed"]) or_else 300,
                    max_acceleration  = number(fo["max_acceleration"]) or_else 3000,
                })
            }
        }
        if arr, aok := hw_job["parameters"].(json.Array); aok {
            for item in arr {
                if len(state.design_params) >= 32 { break }
                po, pok := item.(json.Object)
                if !pok { continue }
                pname := text(po["name"])
                if pname == "" { continue }
                append(&state.design_params, Design_Param{
                    name       = strings.clone(pname),
                    unit       = strings.clone(text(po["unit"])),
                    reason     = strings.clone(text(po["reason"])),
                    value      = number(po["value"]) or_else 0,
                    editable   = boolean(po["editable"]) or_else false,
                    overridden = boolean(po["overridden"]) or_else false,
                })
            }
        }
    }
    for name in c.objects {
        object := c.status[name]
        if heater_object(name) && len(state.heaters) < 64 {
            heater := Heater{name=strings.clone(name)}
            heater.temperature, heater.available = number(get_path(object, "temperature"))
            heater.target, heater.target_available = number(get_path(object, "target"))
            heater.power, heater.power_available = number(get_path(object, "power"))
            heater.power_available = heater.power_available && heater.power >= 0 && heater.power <= 1
            heater.can_extrude = boolean(get_path(object, "can_extrude")) or_else false
            settings := get_path(c.status["configfile"], "settings", name)
            heater.min_temp = number(get_path(settings, "min_temp")) or_else 0
            max_temp, max_ok := number(get_path(settings, "max_temp"))
            heater.max_temp = max_temp
            heater.limits_available = max_ok && max_temp > heater.min_temp
            heater.controllable = heater.available && heater.target_available && heater.limits_available &&
                control_name(name) && (name == "heater_bed" || strings.has_prefix(name, "extruder") ||
                    strings.has_prefix(name, "heater_generic ") || strings.has_prefix(name, "temperature_fan "))
            append(&state.heaters, heater)
        } else if fan_object(name) && len(state.fans) < 64 {
            fan := Fan{name=strings.clone(name)}
            fan.speed, fan.available = number(get_path(object, "speed"))
            fan.available = fan.available && fan.speed >= 0 && fan.speed <= 1
            fan.controllable = fan.available && control_name(name) &&
                (name == "fan" || strings.has_prefix(name, "fan_generic "))
            append(&state.fans, fan)
        } else if rebuild_macros && strings.has_prefix(name, "gcode_macro ") && len(state.macros) < 128 {
            macro_name := name[len("gcode_macro "):]
            if !identifier(macro_name) do continue
            description := text(get_path(c.help, macro_name))
            if description == "" {
                description = text(get_path(c.status["configfile"], "config", name, "description"))
            }
            parameters := macro_parameters(text(get_path(c.status["configfile"], "config", name, "gcode")))
            append(&state.macros, Macro{name=strings.clone(macro_name),
                description=strings.clone(description), parameters=parameters})
        }
    }
    state.revision += 1
}

parse_files :: proc(c: ^Client, value: json.Value, target: ^[dynamic]File, config: bool) {
    assert(c != nil)
    files, ok := value.(json.Array)
    if !ok || len(files) > FILES_MAX { _ = fail_operation(c, "parse_files", "File listing exceeds bounds or is malformed"); return }
    for file in files {
        path := text(get_path(file, "path"))
        size, size_ok := number(get_path(file, "size"))
        permissions := text(get_path(file, "permissions"))
        if (!config && !valid_path(path)) || !size_ok || size < 0 || size > 9e15 ||
            (permissions != "r" && permissions != "rw" && permissions != "") {
            _ = fail_operation(c, "parse_files", "Invalid file path, size or permissions in server listing")
            return
        }
    }
    previous := target^
    defer {
        for &file in previous do file_destroy(&file)
        delete(previous)
    }
    target^ = make([dynamic]File, 0, max(64, len(files)))
    known := make(map[string]int, len(previous), context.temp_allocator)
    for file, index in previous do known[file.path] = index
    for file in files {
        path := text(get_path(file, "path"))
        if config && !valid_config_path(path) do continue
        next := File{path=strings.clone(path),
            size=i64(number(get_path(file, "size")) or_else 0),
            modified=number(get_path(file, "modified")) or_else 0,
            permissions=strings.clone(text(get_path(file, "permissions")))}
        if index, found := known[path]; found && !config {
            old := &previous[index]
            if old.size == next.size && old.modified == next.modified && old.metadata_status != .Pending {
                next.metadata, next.metadata_status, next.thumbnails = old.metadata, old.metadata_status, old.thumbnails
                old.metadata, old.metadata_status, old.thumbnails = {}, .None, {}
            }
        }
        append(target, next)
    }
}

clear_observed :: proc(c: ^Client) {
    assert(c != nil)
    context.allocator = c.allocator
    clear_temperature_history(c)
    json.destroy_value(json.Value(c.status))
    c.status = make(json.Object)
    c.status_bytes = 0
    json.destroy_value(c.help)
    c.help = nil
    for name in c.objects do delete(name)
    clear(&c.objects)
    for heater in c.state.heaters do delete(heater.name)
    delete(c.state.heaters)
    c.state.heaters = make([dynamic]Heater, 0, 64)
    for fan in c.state.fans do delete(fan.name)
    delete(c.state.fans)
    c.state.fans = make([dynamic]Fan, 0, 64)
    for feature in c.state.features { delete(feature.label); delete(feature.shape) }
    delete(c.state.features)
    for param in c.state.design_params { delete(param.name); delete(param.unit); delete(param.reason) }
    delete(c.state.design_params)
    c.state.features = make([dynamic]Job_Feature, 0, 32)
    c.state.design_params = make([dynamic]Design_Param, 0, 32)
    c.state.hw_printer_host = false
    c.state.job_is_design = false
    c.state.job_design_revision = 0
    c.state.job_preview_size = 0
    c.state.job_current_layer = 0
    c.state.job_total_layers = 0
    c.state.job_current_feature = -1
    for macro in c.state.macros { delete(macro.name); delete(macro.description); delete(macro.parameters) }
    delete(c.state.macros)
    c.state.macros = make([dynamic]Macro, 0, 128)
    thumbnail_abort(c, true)
    for &file in c.state.files do file_destroy(&file)
    delete(c.state.files)
    c.state.files = make([dynamic]File, 0, 64)
    for &file in c.state.config_files do file_destroy(&file)
    delete(c.state.config_files)
    c.state.config_files = make([dynamic]File, 0, 64)
    assign_text(&c.state.printer_state, "")
    assign_text(&c.state.printer_message, "")
    assign_text(&c.state.hostname, "")
    assign_text(&c.state.job_state, "")
    assign_text(&c.state.filename, "")
    assign_text(&c.state.job_message, "")
    assign_text(&c.state.homed_axes, "")
    assign_text(&c.state.active_extruder, "")
    c.state.progress_available = false
    c.state.duration_available = false
    c.state.position_available = false
    c.state.motors_available = false
    c.state.motors_engaged = false
    c.state.live_position_available = false
    c.state.live_velocity = 0
    c.state.limits_available = false
    c.state.gcodes_writable = false
    c.state.armed = false
    c.state.stale = true
    c.snapshot_received = false
    c.eventtime = 0
    c.state.revision += 1
}

close_native :: proc(c: ^Client) {
    assert(c != nil)
    thumbnail_abort(c, true)
    print_file_abort(c)
    if c.native != nil { mr_native_destroy(c.native); c.native = nil }
    uncertain := false
    for &pending in c.pending {
        if pending.id != 0 && pending.kind in (bit_set[Request_Kind]{.Control, .Emergency}) do uncertain = true
        release_pending(&pending)
    }
    if c.state.transfer.status == .Running {
        c.state.transfer.status = .Failed
        c.state.transfer.id = 0
        uncertain = true
    }
    if uncertain {
        assign_text(&c.state.operation, "Connection ended with an uncertain command/transfer outcome; nothing will be replayed")
    }
}

// reason must be a bounded literal; pass one when message carries transport or server text.
lost :: proc(c: ^Client, message: string, permanent: bool, reason := "") {
    assert(c != nil)
    context.allocator = c.allocator
    saved := strings.clone(message)
    defer delete(saved)
    devlog.failed(devlog.global(), CONNECTION_SITE, {reason=reason != "" ? reason : message,
        severity=permanent ? .Critical : .Error}, {attempt=u8(c.reconnect_attempts)})
    close_native(c)
    clear_temperature_history(c)
    c.state.armed = false
    c.state.stale = true
    c.snapshot_received = false
    _ = fail(c, saved)
    if !permanent && c.monitoring && c.reconnect_attempts < 5 {
        c.reconnect_at = c.now + f64(i64(1) << uint(c.reconnect_attempts))
        c.reconnect_attempts += 1
        c.state.connection = .Reconnecting
    } else {
        c.monitoring = false
        c.state.connection = .Failed
    }
    c.state.revision += 1
}

fail :: proc(c: ^Client, message: string) -> bool {
    assert(c != nil)
    context.allocator = c.allocator
    assign_text(&c.state.error, message)
    append_log(c, .Error, message)
    c.state.revision += 1
    return false
}

fail_operation :: proc(c: ^Client, operation, message: string, code: i32 = 0) -> bool {
    devlog.failed(devlog.global(), {feature="moonraker", operation=operation}, {reason=message, code=code})
    return fail(c, message)
}

connection_up :: proc(c: ^Client) {
    if c.state.connection == .Connected do return
    if c.reconnect_attempts > 0 {
        devlog.recovered(devlog.global(), CONNECTION_SITE, {attempt=u8(c.reconnect_attempts)})
    } else {
        devlog.succeeded(devlog.global(), CONNECTION_SITE, {stage="heater_control"})
    }
}

append_log :: proc(c: ^Client, kind: Log_Kind, message: string) {
    assert(c != nil)
    message := message
    if len(message) > 8192 do message = message[:8192]
    if len(c.state.console) == CONSOLE_MAX {
        delete(c.state.console[0].text)
        ordered_remove(&c.state.console, 0)
    }
    append(&c.state.console, Log{text=strings.clone(message, c.allocator), kind=kind})
}

assign_text :: proc(target: ^string, value: string) {
    assert(target != nil)
    if target^ == value do return
    next := strings.clone(value)
    delete(target^)
    target^ = next
}

release_pending :: proc(pending: ^Pending) {
    assert(pending != nil)
    delete(pending.label)
    pending^ = {}
}

has_pending :: proc(c: ^Client, kind: Request_Kind) -> bool {
    assert(c != nil)
    for pending in c.pending do if pending.id != 0 && pending.kind == kind do return true
    return false
}

motion_idle :: proc(c: ^Client) -> bool {
    assert(c != nil)
    return (c.state.job_state == "standby" || c.state.job_state == "complete" ||
        c.state.job_state == "cancelled" || c.state.job_state == "error") && c.state.printer_state == "ready"
}

file_permission :: proc(c: ^Client, path: string, permission: byte) -> bool {
    assert(c != nil)
    for file in c.state.files {
        if file.path == path do return strings.contains(file.permissions, string([]byte{permission}))
    }
    return false
}

valid_path :: proc(path: string) -> bool {
    if len(path) == 0 || len(path) > 1024 || path[0] == '/' || !plain_text(path) ||
        strings.contains_any(path, "\\%\"?#") { return false }
    if !strings.has_suffix(path, ".gcode") && !strings.has_suffix(path, ".g") &&
        !strings.has_suffix(path, ".gco") && !strings.has_suffix(path, ".ufp") &&
        !strings.has_suffix(path, ".hwsdesign") { return false }
    remaining := path
    for component in strings.split_iterator(&remaining, "/") {
        if component == "" || component == "." || component == ".." do return false
    }
    return true
}

valid_config_path :: proc(path: string) -> bool {
    if len(path) == 0 || len(path) > 1024 || path[0] == '/' || !plain_text(path) ||
        strings.contains_any(path, "\\%\"?#") { return false }
    if !strings.has_suffix(path, ".cfg") && !strings.has_suffix(path, ".conf") { return false }
    remaining := path
    for component in strings.split_iterator(&remaining, "/") {
        if component == "" || component == "." || component == ".." do return false
    }
    return true
}

identifier :: proc(value: string) -> bool {
    if len(value) == 0 || len(value) > 128 do return false
    for character in value {
        if !(character >= 'A' && character <= 'Z') && !(character >= 'a' && character <= 'z') &&
            !(character >= '0' && character <= '9') && character != '_' { return false }
    }
    return true
}

macro_parameters :: proc(template_text: string) -> string {
    assert(len(template_text) <= 131_072)
    names: [32]string
    count := 0
    cursor := 0
    for cursor < len(template_text) && count < len(names) {
        relative := strings.index(template_text[cursor:], "params.")
        if relative < 0 do break
        start := cursor + relative + len("params.")
        end := start
        for end < len(template_text) {
            character := template_text[end]
            if !(character >= 'A' && character <= 'Z') && !(character >= '0' && character <= '9') &&
                character != '_' { break }
            end += 1
        }
        cursor = max(start + 1, end)
        if end == start || end - start > 128 do continue
        name := template_text[start:end]
        duplicate := false
        for previous in names[:count] do if previous == name do duplicate = true
        if !duplicate { names[count] = name; count += 1 }
    }
    builder := strings.builder_make()
    for name, index in names[:count] {
        if index != 0 do strings.write_string(&builder, " ")
        strings.write_string(&builder, name)
        strings.write_string(&builder, "=…")
    }
    return strings.to_string(builder)
}

control_name :: proc(name: string) -> bool {
    if separator := strings.index(name, " "); separator >= 0 do return identifier(name[separator+1:])
    return identifier(name)
}

plain_text :: proc(value: string) -> bool {
    if !utf8.valid_string(value) do return false
    for character in value do if character < 32 || character == 127 do return false
    return true
}

valid_script :: proc(value: string) -> bool {
    if len(value) == 0 || len(value) > 8192 || !utf8.valid_string(value) do return false
    for character in value {
        if character < 32 && character != '\n' && character != '\r' && character != '\t' do return false
    }
    return true
}

contains_emergency :: proc(script: string) -> bool {
    if len(script) > 8192 do return false
    remaining := script
    for original in strings.split_iterator(&remaining, "\n") {
        line := strings.trim_space(original)
        if semicolon := strings.index(line, ";"); semicolon >= 0 do line = line[:semicolon]
        line = strings.trim_space(line)
        if len(line) > 1 && (line[0] == 'N' || line[0] == 'n') {
            index := 1
            for index < len(line) && line[index] >= '0' && line[index] <= '9' do index += 1
            line = strings.trim_space(line[index:])
        }
        if len(line) < 4 do continue
        if (line[0] == 'M' || line[0] == 'm') && line[1:4] == "112" &&
            (len(line) == 4 || line[4] < '0' || line[4] > '9') { return true }
    }
    return false
}

heater_object :: proc(name: string) -> bool {
    return name == "heater_bed" || strings.has_prefix(name, "extruder") ||
        strings.has_prefix(name, "heater_generic ") || strings.has_prefix(name, "temperature_sensor ") ||
        strings.has_prefix(name, "temperature_fan ")
}
fan_object :: proc(name: string) -> bool {
    return name == "fan" || strings.has_prefix(name, "fan_generic ") ||
        strings.has_prefix(name, "heater_fan ") || strings.has_prefix(name, "controller_fan ")
}
subscription_fields :: proc(name: string) -> [10]string {
    switch name {
    case "webhooks": return {0="state", 1="state_message"}
    case "configfile": return {0="config", 1="settings", 2="save_config_pending", 3="save_config_pending_items"}
    case "print_stats": return {0="state", 1="filename", 2="message", 3="print_duration"}
    case "virtual_sdcard": return {0="progress", 1="file_position"}
    case "toolhead": return {0="position", 1="axis_minimum", 2="axis_maximum", 3="homed_axes", 4="extruder", 5="max_velocity",
        6="max_accel", 7="square_corner_velocity", 8="minimum_cruise_ratio"}
    case "motion_report": return {0="live_position", 1="live_velocity"}
    case "stepper_enable": return {0="steppers"}
    case "hw_printer_job": return {0="filename", 1="state", 2="is_design", 3="current_layer", 4="total_layers", 5="current_feature", 6="features", 7="design_revision", 8="preview_size", 9="parameters"}
    }
    if heater_object(name) { return {0="temperature", 1="target", 2="can_extrude", 3="power"} }
    if fan_object(name) { return {0="speed"} }
    return {}
}

is_loopback_endpoint :: proc(endpoint: string) -> bool {
    rest := endpoint
    if strings.has_prefix(rest, "http://") {
        rest = rest[len("http://"):]
    } else if strings.has_prefix(rest, "https://") {
        rest = rest[len("https://"):]
    } else {
        return false
    }
    if slash := strings.index_byte(rest, '/'); slash >= 0 { rest = rest[:slash] }
    if strings.has_prefix(rest, "[::1]") {
        tail := rest[len("[::1]"):]
        return len(tail) == 0 || tail[0] == ':'
    }
    if colon := strings.index_byte(rest, ':'); colon >= 0 { rest = rest[:colon] }
    return rest == "127.0.0.1" || rest == "localhost"
}

// The subscribed `configfile.config` object, borrowed until the next poll.
running_configuration :: proc(c: ^Client) -> (config: json.Object, ok: bool) {
    assert(c != nil)
    config, ok = get_path(c.status["configfile"], "config").(json.Object)
    return
}

// Whether Klipper holds unsaved SAVE_CONFIG changes, and how many values.
save_config_pending :: proc(c: ^Client) -> (pending: bool, items: int) {
    assert(c != nil)
    pending, _ = get_path(c.status["configfile"], "save_config_pending").(json.Boolean)
    sections, _ := get_path(c.status["configfile"], "save_config_pending_items").(json.Object)
    for _, section in sections {
        keys, is_object := section.(json.Object)
        items += is_object ? len(keys) : 1
    }
    return
}

get_path :: proc(value: json.Value, keys: ..string) -> json.Value {
    value := value
    for key in keys {
        object, ok := value.(json.Object)
        if !ok do return nil
        value = object[key]
    }
    return value
}
text :: proc(value: json.Value) -> string { return value.(json.String) or_else "" }
boolean :: proc(value: json.Value) -> (bool, bool) { return value.(json.Boolean) }
number :: proc(value: json.Value) -> (f64, bool) {
    #partial switch item in value {
    case json.Integer: return f64(item), true
    case json.Float: return item, finite(item)
    case: return 0, false
    }
}
vector :: proc(value: json.Value, target: []f64) -> bool {
    values, ok := value.(json.Array)
    if !ok || len(values) < len(target) || len(values) > 4 do return false
    for item, index in values[:len(target)] {
        scalar, scalar_ok := number(item)
        if !scalar_ok do return false
        target[index] = scalar
    }
    return true
}

value_cost :: proc(value: json.Value) -> int {
    #partial switch item in value {
    case json.Object:
        result := 64
        for key, child in item do result += len(key) + 32 + value_cost(child)
        return result
    case json.Array:
        result := 32
        for child in item do result += 24 + value_cost(child)
        return result
    case json.String: return len(item) + 24
    case: return 24
    }
}

parse_json :: proc(data: string) -> (json.Value, bool) {
    if len(data) == 0 || len(data) > MESSAGE_BYTES_MAX || !strict_shape(data) do return nil, false
    value, err := json.parse(data, .JSON, parse_integers=true)
    if err != nil do return nil, false
    return value, true
}

strict_shape :: proc(data: string) -> bool {
    tokenizer := json.make_tokenizer(data, .JSON, parse_integers=true)
    depth := 0
    tokens := 0
    previous := json.Token_Kind.Invalid
    previous_end := 0
    for tokens < MESSAGE_BYTES_MAX {
        token, err := json.get_token(&tokenizer)
        if err != .None && !(err == .EOF && token.kind == .EOF) do return false
        for byte in data[previous_end:token.offset] {
            if byte != ' ' && byte != '\t' && byte != '\r' && byte != '\n' do return false
        }
        previous_end = token.offset + len(token.text)
        tokens += 1
        #partial switch token.kind {
        case .Open_Brace, .Open_Bracket:
            depth += 1
            if depth > 24 do return false
        case .Close_Brace, .Close_Bracket:
            if previous == .Comma || depth == 0 do return false
            depth -= 1
        case .EOF:
            if depth != 0 || token.offset != len(data) do return false
            parser := json.make_parser(data, .JSON, parse_integers=true)
            return json.validate_value(&parser) && parser.curr_token.kind == .EOF
        case .String:
            if len(token.text) > 131_072 do return false
        case .Integer:
            digits := token.text
            limit := "9223372036854775807"
            if digits[0] == '-' { digits = digits[1:]; limit = "9223372036854775808" }
            if len(digits) > 19 || len(digits) == 19 && digits > limit do return false
        case .Float:
            scalar, scalar_ok := strconv.parse_f64(token.text)
            if !scalar_ok || !finite(scalar) do return false
        case:
        }
        previous = token.kind
    }
    return false
}

percent_encode :: proc(value: string, preserve_slash: bool) -> string {
    builder := strings.builder_make()
    hex := "0123456789ABCDEF"
    for byte in transmute([]byte)value {
        if byte >= 'a' && byte <= 'z' || byte >= 'A' && byte <= 'Z' ||
            byte >= '0' && byte <= '9' || byte == '-' || byte == '_' || byte == '.' || byte == '~' ||
            preserve_slash && byte == '/' {
            strings.write_byte(&builder, byte)
        } else {
            strings.write_byte(&builder, '%')
            strings.write_byte(&builder, hex[byte >> 4])
            strings.write_byte(&builder, hex[byte & 15])
        }
    }
    return strings.to_string(builder)
}

finite :: proc(value: f64) -> bool { return !math.is_nan(value) && !math.is_inf(value) }

load_demo :: proc(c: ^Client) {
    assert(c != nil)
    assert(c.native == nil)
    assert(!c.monitoring)
    context.allocator = c.allocator
    clear_observed(c)
    assign_text(&c.state.printer_state, "ready")
    assign_text(&c.state.printer_message, "OFFLINE SAMPLE — no printer connection")
    assign_text(&c.state.hostname, "OFFLINE SAMPLE")
    assign_text(&c.state.job_state, "printing")
    assign_text(&c.state.filename, "sample_part.gcode")
    assign_text(&c.state.homed_axes, "xyz")
    assign_text(&c.state.active_extruder, "extruder")
    c.state.progress = 0.42
    c.state.progress_available = true
    c.state.print_duration = 1520
    c.state.duration_available = true
    c.state.position = {108.5, 92.0, 18.4, 0}
    c.state.position_available = true
    c.state.axis_minimum = {0, 0, 0}
    c.state.axis_maximum = {300, 300, 300}
    c.state.limits_available = true
    append(&c.state.heaters, Heater{name=strings.clone("extruder"), temperature=211.4, target=215,
        min_temp=0, max_temp=300, available=true, target_available=true, limits_available=true,
        controllable=true, can_extrude=true})
    append(&c.state.heaters, Heater{name=strings.clone("heater_bed"), temperature=59.8, target=60,
        min_temp=0, max_temp=120, available=true, target_available=true, limits_available=true, controllable=true})
    load_demo_temperature_history(c)
    append(&c.state.fans, Fan{name=strings.clone("fan"), speed=0.65, available=true, controllable=true})
    append(&c.state.macros, Macro{name=strings.clone("PREHEAT"),
        description=strings.clone("Offline sample macro; cannot run"), parameters=""})
    append(&c.state.files, File{path=strings.clone("sample_part.gcode"), size=3_482_600,
        modified=1_763_400_000, permissions=strings.clone("r")})
    c.state.files[0].metadata_status = .Ready
    c.state.files[0].metadata = Metadata{
        slicer=strings.clone("Offline sample slicer"), filament_type=strings.clone("PLA"),
        size=3_482_600, size_available=true,
        numbers={.Estimated_Time=2627, .Filament_Total=3930, .Filament_Weight=11.7,
            .Layer_Height=0.24, .First_Layer_Height=0.24, .Object_Height=48,
            .Nozzle_Diameter=0.4, .First_Layer_Extruder_Temp=215, .First_Layer_Bed_Temp=60}}
    c.state.files[0].metadata.available = ~bit_set[Metadata_Number]{}
    append_log(c, .Info, "Offline sample data. Enter an endpoint and connect deliberately.")
    c.state.connection = .Offline
    c.state.stale = true
    c.state.armed = false
    c.state.revision += 1
}

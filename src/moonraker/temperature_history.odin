#+feature dynamic-literals
package moonraker

import "core:encoding/json"
import "core:slice"
import "core:strings"
import devlog "devlog:."

TEMPERATURE_HISTORY_SENSORS_MAX :: 64
TEMPERATURE_HISTORY_SAMPLES_MAX :: 1200
TEMPERATURE_HISTORY_INPUT_SAMPLES_MAX :: 7200
TEMPERATURE_HISTORY_POLL_SECONDS :: 30
HISTORY_SITE :: devlog.Site{feature="moonraker", operation="temperature_history"}

Temperature_Sample :: struct {
    temperature, target, power: f64,
    temperature_available, target_available, power_available: bool,
}
Temperature_History :: struct { name: string, samples: []Temperature_Sample }
History_Capability :: enum { Unknown, Available, Unavailable }

find_temperature_history :: proc(c: ^Client, name: string) -> ^Temperature_History {
    assert(c != nil)
    for &history in c.state.temperature_history do if history.name == name { return &history }
    return nil
}

refresh_temperature_history :: proc(c: ^Client) -> bool {
    assert(c != nil)
    context.allocator = c.allocator
    if has_pending(c, .History) { return false }
    if !temperature_history_ready(c) {
        return temperature_history_fail(c, "Temperature history needs a connected, fresh, ready printer")
    }
    if c.history_capability == .Unavailable {
        return temperature_history_fail(c, "Temperature history is unavailable: Moonraker data_store is not loaded")
    }
    c.history_disabled = false
    assign_text(&c.state.history_error, "")
    if !request(c, .History, "server.temperature_store", json.Object{"include_monitors"=true}) {
        return false
    }
    c.state.history_loading = true
    c.history_poll_at = c.now + TEMPERATURE_HISTORY_POLL_SECONDS
    c.state.revision += 1
    return true
}

append_temperature_samples :: proc(c: ^Client) {
    assert(c != nil)
    context.allocator = c.allocator
    c.history_append_at = c.now + 1
    if len(c.state.temperature_history) == 0 { return }
    for &history in c.state.temperature_history {
        sample: Temperature_Sample
        for heater in c.state.heaters do if heater.name == history.name {
            sample = {
                temperature=heater.temperature, target=heater.target, power=heater.power,
                temperature_available=heater.available, target_available=heater.target_available,
                power_available=heater.power_available,
            }
            break
        }
        kept := min(len(history.samples), TEMPERATURE_HISTORY_SAMPLES_MAX - 1)
        samples := make([]Temperature_Sample, kept + 1)
        copy(samples, history.samples[len(history.samples) - kept:])
        samples[kept] = sample
        delete(history.samples)
        history.samples = samples
    }
    c.state.revision += 1
}

temperature_history_ready :: proc(c: ^Client) -> bool {
    assert(c != nil)
    return c.native != nil && c.state.connection == .Connected && !c.state.stale &&
        c.state.printer_state == "ready" && c.snapshot_received
}

temperature_history_capability :: proc(c: ^Client, result: json.Value) {
    assert(c != nil)
    object, object_ok := result.(json.Object)
    if !object_ok { return }
    value, provided := object["components"]
    if !provided { return }
    components, components_ok := value.(json.Array)
    if !components_ok || len(components) > OBJECTS_MAX {
        _ = temperature_history_fail(c, "Invalid Moonraker temperature history capability")
        return
    }
    available := false
    for component in components {
        name := text(component)
        if len(name) == 0 || len(name) > 256 || !plain_text(name) {
            _ = temperature_history_fail(c, "Invalid Moonraker temperature history capability")
            return
        }
        if name == "data_store" { available = true }
    }
    c.history_capability = available ? .Available : .Unavailable
    if !available {
        message :: "Temperature history is unavailable: Moonraker data_store is not loaded"
        if !c.history_disabled || c.state.history_error != message {
            _ = temperature_history_fail(c, message)
        }
        for &pending in c.pending {
            if pending.id != 0 && pending.kind == .History { release_pending(&pending) }
        }
    }
}

receive_temperature_history :: proc(c: ^Client, result: json.Value) -> bool {
    assert(c != nil)
    context.allocator = c.allocator
    store, store_ok := result.(json.Object)
    if !store_ok || len(store) > TEMPERATURE_HISTORY_SENSORS_MAX {
        return temperature_history_fail(c, "Temperature history sensor shape or count exceeds its limit")
    }
    for name, value in store {
        sensor, sensor_ok := value.(json.Object)
        temperatures, temperatures_ok := get_path(value, "temperatures").(json.Array)
        if len(name) == 0 || len(name) > 256 || !plain_text(name) || !sensor_ok ||
            len(sensor) > 16 || !temperatures_ok ||
            len(temperatures) > TEMPERATURE_HISTORY_INPUT_SAMPLES_MAX {
            return temperature_history_fail(c, "Invalid or oversized temperature history sensor")
        }
        for field in ([]string{"temperatures", "targets", "powers"}) {
            values, provided := sensor[field]
            if !provided { continue }
            array, array_ok := values.(json.Array)
            if !array_ok || len(array) > TEMPERATURE_HISTORY_INPUT_SAMPLES_MAX {
                return temperature_history_fail(c, "Invalid or oversized temperature history array")
            }
            for sample in array {
                if _, is_null := sample.(json.Null); is_null { continue }
                scalar, valid := number(sample)
                if !valid || abs(scalar) > 1e6 {
                    return temperature_history_fail(c, "Temperature history contains an invalid sample")
                }
            }
        }
    }
    clear_temperature_history_data(c)
    if cap(c.state.temperature_history) < len(store) {
        reserve(&c.state.temperature_history, len(store))
    }
    for name, value in store {
        temperatures := get_path(value, "temperatures").(json.Array)
        targets, _ := get_path(value, "targets").(json.Array)
        powers, _ := get_path(value, "powers").(json.Array)
        count := min(len(temperatures), TEMPERATURE_HISTORY_SAMPLES_MAX)
        samples := make([]Temperature_Sample, count)
        for &sample, index in samples {
            source := len(temperatures) - count + index
            sample.temperature, sample.temperature_available = number(temperatures[source])
            target_index := source + len(targets) - len(temperatures)
            if target_index >= 0 {
                sample.target, sample.target_available = number(targets[target_index])
            }
            power_index := source + len(powers) - len(temperatures)
            if power_index >= 0 {
                sample.power, sample.power_available = number(powers[power_index])
                sample.power_available &&= sample.power >= 0 && sample.power <= 1
            }
        }
        append(&c.state.temperature_history, Temperature_History{name=strings.clone(name), samples=samples})
    }
    assert(len(c.state.temperature_history) == len(store))
    slice.sort_by(c.state.temperature_history[:], proc(a, b: Temperature_History) -> bool {
        return a.name < b.name
    })
    if c.history_failed do devlog.recovered(devlog.global(), HISTORY_SITE)
    c.history_failed = false
    assign_text(&c.state.history_error, "")
    c.state.history_loading = false
    c.state.history_updated_at = c.now
    c.history_append_at = c.now + 1
    c.history_disabled = false
    devlog.succeeded(devlog.global(), HISTORY_SITE, {stage="cached"}, {rows=i64(len(c.state.temperature_history))})
    c.state.revision += 1
    return true
}

// reason must be a bounded literal; pass one when message carries server text.
temperature_history_fail :: proc(c: ^Client, message: string, reason := "") -> bool {
    assert(c != nil)
    assert(len(message) > 0)
    context.allocator = c.allocator
    devlog.failed(devlog.global(), HISTORY_SITE, {reason=reason != "" ? reason : message})
    c.history_failed = true
    clear_temperature_history_data(c)
    assign_text(&c.state.history_error, message)
    c.state.history_loading = false
    c.state.history_updated_at = 0
    c.history_disabled = true
    c.state.revision += 1
    return false
}

clear_temperature_history_data :: proc(c: ^Client) {
    assert(c != nil)
    for history in c.state.temperature_history { delete(history.name); delete(history.samples) }
    clear(&c.state.temperature_history)
}

clear_temperature_history :: proc(c: ^Client) {
    assert(c != nil)
    context.allocator = c.allocator
    clear_temperature_history_data(c)
    assign_text(&c.state.history_error, "")
    c.state.history_loading = false
    c.state.history_updated_at = 0
    c.history_capability = .Unknown
    c.history_disabled = false
    c.history_poll_at = 0
    for &pending in c.pending {
        if pending.id != 0 && pending.kind == .History { release_pending(&pending) }
    }
}

load_demo_temperature_history :: proc(c: ^Client) {
    assert(c != nil)
    assert(c.native == nil)
    for heater in c.state.heaters {
        samples := make([]Temperature_Sample, TEMPERATURE_HISTORY_SAMPLES_MAX)
        for &sample, index in samples {
            target := index < 120 ? 0 : heater.target
            warmup := min(1, max(0, f64(index - 120) / 600))
            sample = Temperature_Sample{
                temperature=22 + (heater.temperature - 22) * warmup,
                target=target, power=target > 0 ? 0.4 : 0,
                temperature_available=true, target_available=true, power_available=true,
            }
        }
        append(&c.state.temperature_history, Temperature_History{
            name=strings.clone(heater.name), samples=samples,
        })
    }
}

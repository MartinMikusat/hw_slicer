#+feature dynamic-literals
package printer_mcp

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import devlog "devlog:."
import cfg "../configuration"
import mr "../moonraker"

CONFIG_TOOL :: "printer_config"
CONFIG_MAIN :: "printer.cfg"
ENDPOINT_DEFAULT :: "http://ratos.local/"
ENDPOINT_ENV :: "HW_SLICER_MCP_ENDPOINT"
ENDPOINT_LEGACY_ENV :: "HW_RATOS_MCP_ENDPOINT"
STEP_SECONDS :: 20.0
OUTPUT_BYTES_MAX :: 64 * 1024
DRIFT_LINES_MAX :: 30
DRIFT_VALUE_MAX :: 80

config_tool_definition :: proc() -> json.Value {
	string_property :: proc(description: string) -> json.Value {
		return json.Object{"type" = json.String("string"), "description" = json.String(description)}
	}
	return json.Object{
		"name" = json.String(CONFIG_TOOL),
		"description" = json.String("Read the printer's reconciled Klipper configuration: the final value of every key after all [include] files and the SAVE_CONFIG block are applied, " +
			"with the file:line that sets it and the earlier entries it overrides. Reads live from Moonraker (read-only). " +
			"With no arguments it lists the sections. Use it to find where something is configured and which file to edit. " +
			"Pass `snapshot` to save every final value, its source and the drift as one local JSON file."),
		"inputSchema" = json.Object{
			"type" = json.String("object"),
			"properties" = json.Object{
				"section" = string_property("Section name, exact (for example `stepper_x`) or a prefix (for example `gcode_macro`)."),
				"key" = string_property("Key name within the matched sections, exact (for example `rotation_distance`)."),
				"query" = string_property("Case-insensitive text to find in section names, key names and final values."),
				"snapshot" = string_property("Absolute path of a local `.json` file that receives the complete reconciled configuration. The filters do not apply to it."),
			},
		},
	}
}

// Connects read-only, resolves the configuration from the config root and
// formats it. The connection lasts for this call only.
config_tool_run :: proc(arguments: json.Object) -> (text: string, ok: bool) {
	op := devlog.Site{feature = "mcp", operation = "printer_config"}
	devlog.started(devlog.global(), op, {stage = "connect"})
	endpoint := os.get_env(ENDPOINT_ENV, context.temp_allocator)
	if endpoint == "" {endpoint = os.get_env(ENDPOINT_LEGACY_ENV, context.temp_allocator)}
	if endpoint == "" {endpoint = ENDPOINT_DEFAULT}

	client: mr.Client
	mr.initialize(&client, read_only = true)
	defer mr.destroy(&client)
	res: cfg.Resolution
	resolved := false
	defer if resolved {cfg.resolution_destroy(&res)}

	message: string
	resolved, message = load_resolution(&client, endpoint, &res)
	if !resolved {
		devlog.failed(devlog.global(), op, {reason = "Configuration read failed", detail = message})
		return fmt.tprintf("Could not read the printer configuration: %s", message), false
	}
	devlog.succeeded(devlog.global(), op, {stage = "resolved"}, {datasets = i64(len(res.layers))})

	section, _ := arguments["section"].(json.String)
	key, _ := arguments["key"].(json.String)
	query, _ := arguments["query"].(json.String)
	if snapshot, has_snapshot := arguments["snapshot"].(json.String); has_snapshot {
		return write_snapshot(&client, &res, endpoint, snapshot)
	}
	return format_resolution(&client, &res, section, key, query), true
}

pump :: proc(c: ^mr.Client, seconds: f64, done: proc(c: ^mr.Client) -> bool) -> bool {
	start := time.tick_now()
	for time.duration_seconds(time.tick_since(start)) < seconds {
		_ = mr.poll(c)
		if done(c) {return true}
		if c.state.connection == .Failed {return false}
		time.sleep(5 * time.Millisecond)
	}
	return false
}

is_ready :: proc(c: ^mr.Client) -> bool {
	return c.state.connection == .Connected && !c.state.stale && c.snapshot_received
}
is_listed :: proc(c: ^mr.Client) -> bool {return !mr.has_pending(c, .Config_Files)}
is_transferred :: proc(c: ^mr.Client) -> bool {return c.state.transfer.status != .Running}

failure :: proc(c: ^mr.Client, fallback: string) -> string {
	return c.state.error != "" ? c.state.error : fallback
}

load_resolution :: proc(c: ^mr.Client, endpoint: string, res: ^cfg.Resolution) -> (ok: bool, message: string) {
	if !mr.connect(c, endpoint, "") {return false, failure(c, "Connection refused by the client")}
	if !pump(c, STEP_SECONDS, is_ready) {return false, failure(c, "Timed out connecting to the printer")}
	if !mr.refresh_config_files(c) || !pump(c, STEP_SECONDS, is_listed) {
		return false, failure(c, "Timed out listing the configuration files")
	}
	listing := make([dynamic]string, context.temp_allocator)
	for file in c.state.config_files {append(&listing, strings.clone(file.path, context.temp_allocator))}
	if len(listing) == 0 {return false, "The printer lists no configuration files"}

	sources := make([dynamic]cfg.Source, context.temp_allocator)
	for len(sources) < cfg.LAYERS_MAX {
		if !cfg.resolve(res, CONFIG_MAIN, listing[:], sources[:]) {return false, "Configuration resolution could not start"}
		if cfg.complete(res) {return true, ""}
		path := strings.clone(res.missing[0], context.temp_allocator)
		cfg.resolution_destroy(res)
		if !mr.read_config(c, path) || !pump(c, STEP_SECONDS, is_transferred) {
			return false, failure(c, fmt.tprintf("Could not read %s", path))
		}
		if c.state.transfer.status != .Complete {return false, failure(c, fmt.tprintf("Download of %s failed", path))}
		append(&sources, cfg.Source{path, strings.clone(string(c.state.transfer.data), context.temp_allocator)})
	}
	return false, "Configuration include limit reached"
}

layer_name :: proc(res: ^cfg.Resolution, layer: i32) -> string {
	l := res.layers[layer]
	return l.kind == .Save_Config ? fmt.tprintf("%s (SAVE_CONFIG)", l.path) : l.path
}

contains_fold :: proc(text, needle: string) -> bool {
	return strings.contains(strings.to_lower(text, context.temp_allocator), strings.to_lower(needle, context.temp_allocator))
}

format_resolution :: proc(c: ^mr.Client, res: ^cfg.Resolution, section_filter, key_filter, query: string) -> string {
	b: strings.Builder
	strings.builder_init(&b, context.temp_allocator)
	fmt.sbprintf(&b, "# Reconciled configuration from %d files (main file %s). Format: `key: value`, then\n", len(res.layers), CONFIG_MAIN)
	strings.write_string(&b, "# `<- file:line` for the entry that wins and `shadowed|ignored file:line = value` for the others.\n")
	write_drift(&b, c, res, section_filter, key_filter, query)
	for diagnostic in res.diagnostics {
		fmt.sbprintf(&b, "# diagnostic: %s (%s:%d) %s\n", cfg.diagnostic_text(diagnostic.kind),
			layer_name(res, diagnostic.layer), diagnostic.line, diagnostic.detail)
	}

	filtered := section_filter != "" || key_filter != "" || query != ""
	if !filtered {
		strings.write_string(&b, "# No filter given: sections and key counts. Pass `section`, `key` or `query` for values.\n")
		for section in res.sections {fmt.sbprintf(&b, "[%s] %d keys\n", section.name, len(section.keys))}
		return strings.to_string(b)
	}

	matches := 0
	for section in res.sections {
		if section_filter != "" && section.name != section_filter && !strings.has_prefix(section.name, section_filter) {continue}
		wrote_header := false
		for &key in section.keys {
			final, has_final := cfg.final_entry(&key)
			if !has_final || (key_filter != "" && key.name != key_filter) {continue}
			if query != "" && !contains_fold(section.name, query) && !contains_fold(key.name, query) &&
				!contains_fold(final.value, query) {continue}
			if strings.builder_len(b) > OUTPUT_BYTES_MAX {
				strings.write_string(&b, "\n# Output truncated; narrow the filter.\n")
				return strings.to_string(b)
			}
			if !wrote_header {fmt.sbprintf(&b, "\n[%s]\n", section.name); wrote_header = true}
			matches += 1
			value, _ := strings.replace_all(final.value, "\n", "\n  ", context.temp_allocator)
			fmt.sbprintf(&b, "%s: %s\n# <- %s:%d\n", key.name, value, layer_name(res, final.layer), final.line)
			for entry in key.entries {
				if entry.layer == final.layer && entry.line == final.line {continue}
				flat, _ := strings.replace_all(entry.value, "\n", " | ", context.temp_allocator)
				fmt.sbprintf(&b, "#    %s %s:%d = %s\n", entry.ignored ? "ignored" : "shadowed",
					layer_name(res, entry.layer), entry.line, flat)
			}
		}
	}
	if matches == 0 {strings.write_string(&b, "\n# No keys match the filter.\n")}
	return strings.to_string(b)
}

write_drift :: proc(b: ^strings.Builder, c: ^mr.Client, res: ^cfg.Resolution, section_filter, key_filter, query: string) {
	pending, items := mr.save_config_pending(c)
	if pending {fmt.sbprintf(b, "# Klipper holds %d unsaved SAVE_CONFIG values.\n", items)}
	running, ok := mr.running_configuration(c)
	if !ok {
		strings.write_string(b, "# Running configuration unavailable; drift not checked.\n")
		return
	}
	differences := cfg.compare_running(res, running, context.temp_allocator)
	if len(differences) == 0 {
		strings.write_string(b, "# Files match Klipper's running configuration.\n")
		return
	}
	fmt.sbprintf(b, "# %d keys differ from Klipper's running configuration (files changed since the last restart)", len(differences))
	filtered := section_filter != "" || key_filter != "" || query != ""
	strings.write_string(b, filtered ? "; those that match the filter:\n" : ":\n")
	listed := 0
	for difference in differences {
		if filtered && !drift_matches(difference, section_filter, key_filter, query) {continue}
		if listed >= DRIFT_LINES_MAX {strings.write_string(b, "#   ...\n"); break}
		listed += 1
		fmt.sbprintf(b, "#   [%s] %s: files=%s running=%s\n", difference.section, difference.key,
			drift_value(difference.files_value), drift_value(difference.running_value))
	}
}

drift_matches :: proc(d: cfg.Difference, section_filter, key_filter, query: string) -> bool {
	if section_filter != "" && d.section != section_filter && !strings.has_prefix(d.section, section_filter) {return false}
	if key_filter != "" && d.key != key_filter {return false}
	if query != "" && !contains_fold(d.section, query) && !contains_fold(d.key, query) &&
		!contains_fold(d.files_value, query) && !contains_fold(d.running_value, query) {return false}
	return true
}

// One line per value: newlines become ` | ` and long values are cut at a rune
// boundary, so a changed macro body costs one line instead of its whole text.
drift_value :: proc(value: string) -> string {
	flat, _ := strings.replace_all(strings.trim_space(value), "\n", " | ", context.temp_allocator)
	if len(flat) <= DRIFT_VALUE_MAX {return flat}
	cut := 0
	for _, index in flat {
		if index > DRIFT_VALUE_MAX {break}
		cut = index
	}
	return fmt.tprintf("%s... (%d bytes)", flat[:cut], len(value))
}

Snapshot_Key :: struct {
	name: string,
	value: string,
	source: string,
	overridden: int,
}

Snapshot_Section :: struct {
	name: string,
	keys: [dynamic]Snapshot_Key,
}

Snapshot_Drift :: struct {
	section: string,
	key: string,
	files: string,
	running: string,
}

Snapshot :: struct {
	endpoint: string,
	main_file: string,
	files: [dynamic]string,
	save_config_pending_items: int,
	running_checked: bool,
	drift: [dynamic]Snapshot_Drift,
	diagnostics: [dynamic]string,
	sections: [dynamic]Snapshot_Section,
}

// Writes the whole reconciled configuration to a local JSON file and returns a
// short summary, so a baseline costs one call instead of one per section.
write_snapshot :: proc(c: ^mr.Client, res: ^cfg.Resolution, endpoint, path: string) -> (text: string, ok: bool) {
	if !strings.has_prefix(path, "/") || !strings.has_suffix(path, ".json") {
		return "The snapshot path must be absolute and end in `.json`.", false
	}
	a := context.temp_allocator
	snap := Snapshot{
		endpoint = endpoint,
		main_file = CONFIG_MAIN,
		files = make([dynamic]string, a),
		drift = make([dynamic]Snapshot_Drift, a),
		diagnostics = make([dynamic]string, a),
		sections = make([dynamic]Snapshot_Section, a),
	}
	for _, index in res.layers {append(&snap.files, layer_name(res, i32(index)))}
	_, snap.save_config_pending_items = mr.save_config_pending(c)
	if running, has_running := mr.running_configuration(c); has_running {
		snap.running_checked = true
		for d in cfg.compare_running(res, running, a) {
			append(&snap.drift, Snapshot_Drift{d.section, d.key, d.files_value, d.running_value})
		}
	}
	for diagnostic in res.diagnostics {
		append(&snap.diagnostics, fmt.tprintf("%s (%s:%d) %s", cfg.diagnostic_text(diagnostic.kind),
			layer_name(res, diagnostic.layer), diagnostic.line, diagnostic.detail))
	}
	key_count := 0
	for &section in res.sections {
		out := Snapshot_Section{name = section.name, keys = make([dynamic]Snapshot_Key, a)}
		for &key in section.keys {
			final, has_final := cfg.final_entry(&key)
			if !has_final {continue}
			append(&out.keys, Snapshot_Key{key.name, final.value,
				fmt.tprintf("%s:%d", layer_name(res, final.layer), final.line), len(key.entries) - 1})
			key_count += 1
		}
		append(&snap.sections, out)
	}
	data, marshal_error := json.marshal(snap, {pretty = true}, a)
	if marshal_error != nil {return fmt.tprintf("Could not encode the snapshot: %v", marshal_error), false}
	if write_error := os.write_entire_file_from_bytes(path, data); write_error != nil {
		return fmt.tprintf("Could not write %s: %v", path, write_error), false
	}
	return fmt.tprintf("Wrote %s: %d sections, %d keys from %d files; %d unsaved SAVE_CONFIG values; %d keys differ from the running configuration%s.",
		path, len(snap.sections), key_count, len(snap.files), snap.save_config_pending_items, len(snap.drift),
		snap.running_checked ? "" : " (running configuration unavailable)"), true
}

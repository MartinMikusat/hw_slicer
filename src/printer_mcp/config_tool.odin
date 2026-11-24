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

config_tool_definition :: proc() -> json.Value {
	string_property :: proc(description: string) -> json.Value {
		return json.Object{"type" = json.String("string"), "description" = json.String(description)}
	}
	return json.Object{
		"name" = json.String(CONFIG_TOOL),
		"description" = json.String("Read the printer's reconciled Klipper configuration: the final value of every key after all [include] files and the SAVE_CONFIG block are applied, " +
			"with the file:line that sets it and the earlier entries it overrides. Reads live from Moonraker (read-only). " +
			"With no arguments it lists the sections. Use it to find where something is configured and which file to edit."),
		"inputSchema" = json.Object{
			"type" = json.String("object"),
			"properties" = json.Object{
				"section" = string_property("Section name, exact (for example `stepper_x`) or a prefix (for example `gcode_macro`)."),
				"key" = string_property("Key name within the matched sections, exact (for example `rotation_distance`)."),
				"query" = string_property("Case-insensitive text to find in section names, key names and final values."),
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
	write_drift(&b, c, res)
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

write_drift :: proc(b: ^strings.Builder, c: ^mr.Client, res: ^cfg.Resolution) {
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
	fmt.sbprintf(b, "# %d keys differ from Klipper's running configuration (files changed since the last restart):\n", len(differences))
	for difference, index in differences {
		if index >= DRIFT_LINES_MAX {strings.write_string(b, "#   ...\n"); break}
		fmt.sbprintf(b, "#   [%s] %s: files=%s running=%s\n", difference.section, difference.key,
			difference.files_value, difference.running_value)
	}
}

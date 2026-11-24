#+feature dynamic-literals
package printer_mcp

import "core:bufio"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import NS "core:sys/darwin/Foundation"
import devlog "devlog:."

SERVER_NAME :: "hw_slicer_printer"
SERVER_VERSION :: "0.1.0"
PROTOCOL_DEFAULT :: "2025-06-18"
REQUEST_BYTES_MAX :: 1 << 20

main :: proc() {
	pool := NS.AutoreleasePool.alloc()->init()
	defer pool->drain()
	config := devlog.DEFAULT_CONFIG
	config.profile = devlog.profile_from_env()
	if devlog.global_start(devlog.default_directory("hw_slicer", "mcp", context.temp_allocator), config) {
		context.assertion_failure_proc = devlog.fatal_hook()
	}
	defer devlog.global_destroy()

	reader: bufio.Reader
	bufio.reader_init(&reader, os.to_stream(os.stdin))
	defer bufio.reader_destroy(&reader)
	for {
		line, err := bufio.reader_read_string(&reader, '\n', context.temp_allocator)
		if len(line) > 0 && len(line) <= REQUEST_BYTES_MAX {handle_message(strings.trim_space(line))}
		free_all(context.temp_allocator)
		if err != nil {break}
	}
}

write_line :: proc(text: string) {
	_, _ = os.write_string(os.stdout, text)
	_, _ = os.write_string(os.stdout, "\n")
}

marshal :: proc(value: json.Value) -> string {
	data, err := json.marshal(value, {}, context.temp_allocator)
	return err == nil ? string(data) : "null"
}

reply :: proc(id: json.Value, result: json.Value) {
	write_line(fmt.tprintf(`{{"jsonrpc":"2.0","id":%s,"result":%s}`, marshal(id), marshal(result)))
}

reply_error :: proc(id: json.Value, code: int, message: string) {
	write_line(fmt.tprintf(`{{"jsonrpc":"2.0","id":%s,"error":{{"code":%d,"message":%s}}}`,
		marshal(id), code, marshal(json.String(message))))
}

text_result :: proc(text: string, is_error: bool) -> json.Value {
	part := json.Object{"type" = json.String("text"), "text" = json.String(text)}
	return json.Object{"content" = json.Array{part}, "isError" = json.Boolean(is_error)}
}

handle_message :: proc(line: string) {
	context.allocator = context.temp_allocator
	parsed, err := json.parse(transmute([]byte)line, allocator = context.temp_allocator)
	request, is_object := parsed.(json.Object)
	if err != nil || !is_object {
		reply_error(nil, -32700, "Parse error")
		return
	}
	method, _ := request["method"].(json.String)
	id, has_id := request["id"]
	if !has_id {return}
	params, _ := request["params"].(json.Object)

	switch method {
	case "initialize":
		version, _ := params["protocolVersion"].(json.String)
		reply(id, json.Object{
			"protocolVersion" = json.String(version != "" ? version : PROTOCOL_DEFAULT),
			"capabilities" = json.Object{"tools" = json.Object{}},
			"serverInfo" = json.Object{"name" = json.String(SERVER_NAME), "version" = json.String(SERVER_VERSION)},
			"instructions" = json.String("Read-only access to the RatOS printer. Each call reads the live configuration from Moonraker; nothing is changed on the printer."),
		})
	case "ping": reply(id, json.Object{})
	case "tools/list": reply(id, json.Object{"tools" = json.Array{config_tool_definition()}})
	case "tools/call":
		name, _ := params["name"].(json.String)
		if name != CONFIG_TOOL {
			reply_error(id, -32602, "Unknown tool")
			return
		}
		arguments, _ := params["arguments"].(json.Object)
		text, ok := config_tool_run(arguments)
		reply(id, text_result(text, !ok))
	case: reply_error(id, -32601, "Method not found")
	}
}

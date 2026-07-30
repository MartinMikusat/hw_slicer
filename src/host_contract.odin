package main

Host_Rect :: struct {
	x, y, width, height: f64,
}

Host_Control :: struct {
	id:      u64,
	name:    cstring,
	label:   cstring,
	rect:    Host_Rect,
	role:    i32,
	enabled: bool,
	selected: bool,
}

Host_Services :: struct {
	application: rawptr,
	window:      rawptr,
	view:        rawptr,
	layer:       rawptr,
	resource_root: cstring,
	request_redraw: proc "c" (),
	window_close: proc "c" (),
	window_minimize: proc "c" (),
	window_zoom: proc "c" (),
	open_document: proc "c" (path: [^]u8, capacity: uint) -> bool,
	preference_get_int: proc "c" (
		key: cstring,
		fallback: i32,
	) -> i32,
	preference_set_int: proc "c" (key: cstring, value: i32),
}

Application_API :: struct {
	initialize: proc "c" (host: ^Host_Services) -> bool,
	shutdown: proc "c" (),
	frame: proc "c" (width, height, scale: f64),
	mouse: proc "c" (
		phase, button: i32,
		x, y, delta_x, delta_y: f64,
	),
	scroll: proc "c" (delta_x, delta_y: f64),
	key: proc "c" (key_code: u16, characters: cstring, modifiers: u64),
	control_count: proc "c" () -> uint,
	control_at: proc "c" (index: uint, control: ^Host_Control) -> bool,
	hit_test: proc "c" (x, y: f64) -> u64,
	activate_control: proc "c" (control_id: u64) -> bool,
	write_ui_snapshot: proc "c" (path: cstring) -> bool,
}

foreign {
	hw_slicer_host_run :: proc "c" (application: ^Application_API) -> i32 ---
}

package main

import "core:fmt"
import "core:math"
import "core:mem"
import MTL "vendor:darwin/Metal"
import "rune:gpu"
import "rune:text"

foreign import metal "system:Metal.framework"
foreign metal {
	MTLCreateSystemDefaultDevice :: proc "c" () -> Id ---
}

foreign import libsystem "system:System"
foreign libsystem {
	dispatch_data_create :: proc "c" (buffer: rawptr, size: uint, queue: rawptr, destructor: rawptr) -> Id ---
}

Scene_Uniforms :: struct {
	mvp:             Mat4,
	model:           Mat4,
	color:           Vec4,
	arc_color:       Vec4, // a > 0 shades G2/G3 arcs
	selected_color:  Vec4, // highlight color for selected bevel/fillet/corner junction
	camera:          Vec4,
	view_projection: Mat4,
	params:          Vec4,
	viewport:        Vec4,
	sh:              [9]Vec4,
}

Gpu_Bead :: struct {
	a:    [4]f32, // xyz = start top-centre, w = width
	b:    [4]f32, // xyz = end top-centre,   w = height
	meta: [4]f32, // x = fraction, y = is_arc (0/1), z = junction (-1 or >=0), w = 0
}

Renderer :: struct {
	environment: Id,
	harmonics: [9]Vec4,
	ao_depth: Id,
	scene_msaa: Id,
	scene_texture: Id,
	screen_depth_texture: Id,
	floor_pipeline: Id,
	resolve_pipeline: Id,
	layer:            Id,
	device:           Id,
	queue:            Id,
	mesh_pipeline:               Id,
	bead_pipeline:               Id,
	colored_bead_pipeline:       Id,
	depth_pipeline:              Id,
	bead_depth_pipeline:         Id,
	colored_bead_depth_pipeline: Id,
	line_pipeline:               Id,
	depth_state:                 Id,
	ui_depth_state:              Id,
	mesh_buffer:                 Id,
	bead_buffers:                [2]Id,
	bead_capacities:             [2]int,
	bead_slot:                   int,
	bead_buffer:                 Id,
	bead_count:                  int,
	colored_bead_buffer:         Id,
	colored_bead_capacity:       int,
	colored_bead_count:          int,
	section_buffer:      Id,
	marker_buffer:    Id,
	capture_texture:  Id,
	capture_path:     string,
	capture_written:  bool,
	capture_width:    uint,
	capture_height:   uint,
	depth_texture:    Id,
	mesh_vertex_count: int,
	section_vertex_count: int,
	marker_vertex_count: int,
	last_draw_calls:  int,
	last_triangles:   int,
	bench_sync:       bool,
	depth_width:      uint,
	depth_height:     uint,
	ss_width:         uint,
	ss_height:        uint,
	ui_renderer:      gpu.Renderer,
	ui_text:          text.System,
	ui_list:          gpu.Draw_List,
}

// Compiled from shaders/slicer_renderer.metal by scripts/compute-metallib.sh (run by scripts/odin.sh).
RENDERER_SHADER_LIBRARY :: #load("../build/compute/slicer_renderer.metallib")

renderer_initialize :: proc(renderer: ^Renderer, layer: Id) -> bool {
	if !objc_initialize() {return false}
	renderer.layer = layer
	renderer.device = MTLCreateSystemDefaultDevice()
	if renderer.device == nil {return false}
	msg_void_id(layer, sel_registerName("setDevice:"), renderer.device)
	msg_void_u(layer, sel_registerName("setPixelFormat:"), 80)
	msg_void_bool(layer, sel_registerName("setFramebufferOnly:"), true)
	renderer.queue = msg_id(
		renderer.device,
		sel_registerName("newCommandQueue"),
	)
	if renderer.queue == nil {return false}
	if !renderer_build_pipelines(renderer) {return false}
	device := (^MTL.Device)(renderer.device)
	if gpu.draw_list_init(&renderer.ui_list) != nil {return false}
	if !text.init(&renderer.ui_text, device) {return false}
	if !gpu.renderer_init(&renderer.ui_renderer, device, .BGRA8Unorm) {return false}
	gpu.renderer_set_atlas(&renderer.ui_renderer, renderer.ui_text.atlas)
	return renderer_environment_upload(renderer) && renderer_build_marker(renderer)
}

renderer_shutdown :: proc(renderer: ^Renderer) {
	if renderer.ui_renderer.pipeline != nil {gpu.renderer_destroy(&renderer.ui_renderer)}
	if renderer.ui_text.device != nil {text.destroy(&renderer.ui_text)}
	if renderer.ui_list.instances != nil {gpu.draw_list_destroy(&renderer.ui_list)}
	objects := [?]Id{
		renderer.environment,
		renderer.scene_msaa,
		renderer.scene_texture,
		renderer.screen_depth_texture,
		renderer.floor_pipeline,
		renderer.resolve_pipeline,
		renderer.depth_pipeline,
		renderer.bead_depth_pipeline,
		renderer.colored_bead_depth_pipeline,
		renderer.ao_depth,
		renderer.depth_texture,
		renderer.capture_texture,
		renderer.marker_buffer,
		renderer.section_buffer,
		renderer.mesh_buffer,
		renderer.bead_buffers[0],
		renderer.bead_buffers[1],
		renderer.colored_bead_buffer,
		renderer.ui_depth_state,
		renderer.depth_state,
		renderer.line_pipeline,
		renderer.mesh_pipeline,
		renderer.bead_pipeline,
		renderer.colored_bead_pipeline,
		renderer.queue,
		renderer.device,
	}
	for object in objects {
		if object != nil {msg_void(object, sel_registerName("release"))}
	}
	delete(renderer.capture_path)
	renderer^ = {}
}

renderer_build_pipeline :: proc(
	renderer: ^Renderer,
	library: Id,
	vertex_name, fragment_name: string,
	depth: bool,
	blend: bool,
	premultiplied := false,
	sample_count := uint(1),
) -> Id {
	vertex := msg_id_id(
		library,
		sel_registerName("newFunctionWithName:"),
		nsstring(vertex_name),
	)
	fragment: Id
	if len(fragment_name) > 0 {
		fragment = msg_id_id(
			library,
			sel_registerName("newFunctionWithName:"),
			nsstring(fragment_name),
		)
		if fragment == nil {
			msg_void(vertex, sel_registerName("release"))
			return nil
		}
	}
	if vertex == nil {return nil}
	defer msg_void(vertex, sel_registerName("release"))
	defer if fragment != nil {msg_void(fragment, sel_registerName("release"))}

	descriptor := msg_id(
		msg_id(objc_getClass("MTLRenderPipelineDescriptor"), sel_registerName("alloc")),
		sel_registerName("init"),
	)
	if descriptor == nil {return nil}
	defer msg_void(descriptor, sel_registerName("release"))
	msg_void_id(descriptor, sel_registerName("setVertexFunction:"), vertex)
	if fragment != nil {
		msg_void_id(descriptor, sel_registerName("setFragmentFunction:"), fragment)
		attachments := msg_id(descriptor, sel_registerName("colorAttachments"))
		attachment := msg_id_index(
			attachments,
			sel_registerName("objectAtIndexedSubscript:"),
			0,
		)
		msg_void_u(attachment, sel_registerName("setPixelFormat:"), 80)
		if blend {
			msg_void_bool(attachment, sel_registerName("setBlendingEnabled:"), true)
			msg_void_u(
				attachment,
				sel_registerName("setSourceRGBBlendFactor:"),
				1 if premultiplied else 4,
			)
			msg_void_u(attachment, sel_registerName("setDestinationRGBBlendFactor:"), 5)
			msg_void_u(attachment, sel_registerName("setSourceAlphaBlendFactor:"), 1)
			msg_void_u(attachment, sel_registerName("setDestinationAlphaBlendFactor:"), 5)
		}
	}
	if depth {
		msg_void_u(
			descriptor,
			sel_registerName("setDepthAttachmentPixelFormat:"),
			252,
		)
	}
	if sample_count > 1 {
		msg_void_u(descriptor, sel_registerName("setRasterSampleCount:"), sample_count)
	}
	error: Id
	result := msg_id_id_error(
		renderer.device,
		sel_registerName("newRenderPipelineStateWithDescriptor:error:"),
		descriptor,
		&error,
	)
	if result == nil {
		fmt.eprintf("Metal pipeline creation failed: %s\n", ns_error_text(error))
	}
	return result
}

renderer_build_pipelines :: proc(renderer: ^Renderer) -> bool {
	data := dispatch_data_create(raw_data(RENDERER_SHADER_LIBRARY), len(RENDERER_SHADER_LIBRARY), nil, nil)
	if data == nil {
		fmt.eprintf("Metal shader data creation failed\n")
		return false
	}
	defer msg_void(data, sel_registerName("release"))
	error: Id
	library := msg_id_id_error(
		renderer.device,
		sel_registerName("newLibraryWithData:error:"),
		data,
		&error,
	)
	if library == nil {
		fmt.eprintf("Metal shader library load failed: %s\n", ns_error_text(error))
		return false
	}
	defer msg_void(library, sel_registerName("release"))
	renderer.mesh_pipeline = renderer_build_pipeline(
		renderer,
		library,
		"mesh_vertex",
		"mesh_fragment",
		true,
		false,
		false,
		4,
	)
	renderer.bead_pipeline = renderer_build_pipeline(
		renderer,
		library,
		"bead_vertex",
		"mesh_fragment",
		true,
		false,
		false,
		4,
	)
	if renderer.bead_pipeline == nil {return false}
	renderer.colored_bead_pipeline = renderer_build_pipeline(
		renderer,
		library,
		"colored_bead_vertex",
		"mesh_fragment",
		true,
		false,
		false,
		4,
	)
	if renderer.colored_bead_pipeline == nil {return false}
	renderer.floor_pipeline = renderer_build_pipeline(renderer, library, "mesh_vertex", "floor_fragment", true, false)
	if renderer.floor_pipeline == nil {return false}
	renderer.resolve_pipeline = renderer_build_pipeline(renderer, library, "resolve_vertex", "resolve_fragment", true, true, false)
	if renderer.resolve_pipeline == nil {return false}
	renderer.depth_pipeline = renderer_build_pipeline(renderer, library, "mesh_vertex", "", true, false)
	if renderer.depth_pipeline == nil {return false}
	renderer.bead_depth_pipeline = renderer_build_pipeline(renderer, library, "bead_vertex", "", true, false)
	if renderer.bead_depth_pipeline == nil {return false}
	renderer.colored_bead_depth_pipeline = renderer_build_pipeline(renderer, library, "colored_bead_vertex", "", true, false)
	if renderer.colored_bead_depth_pipeline == nil {return false}
	renderer.line_pipeline = renderer_build_pipeline(
		renderer,
		library,
		"mesh_vertex",
		"line_fragment",
		true,
		true,
		false,
	)

	depth_descriptor := msg_id(
		msg_id(objc_getClass("MTLDepthStencilDescriptor"), sel_registerName("alloc")),
		sel_registerName("init"),
	)
	if depth_descriptor == nil {return false}
	defer msg_void(depth_descriptor, sel_registerName("release"))
	msg_void_u(
		depth_descriptor,
		sel_registerName("setDepthCompareFunction:"),
		1,
	)
	msg_void_bool(
		depth_descriptor,
		sel_registerName("setDepthWriteEnabled:"),
		true,
	)
	renderer.depth_state = msg_id_id(
		renderer.device,
		sel_registerName("newDepthStencilStateWithDescriptor:"),
		depth_descriptor,
	)
	ui_depth_descriptor := msg_id(
		msg_id(objc_getClass("MTLDepthStencilDescriptor"), sel_registerName("alloc")),
		sel_registerName("init"),
	)
	if ui_depth_descriptor == nil {return false}
	defer msg_void(ui_depth_descriptor, sel_registerName("release"))
	msg_void_u(
		ui_depth_descriptor,
		sel_registerName("setDepthCompareFunction:"),
		7,
	)
	msg_void_bool(
		ui_depth_descriptor,
		sel_registerName("setDepthWriteEnabled:"),
		false,
	)
	renderer.ui_depth_state = msg_id_id(
		renderer.device,
		sel_registerName("newDepthStencilStateWithDescriptor:"),
		ui_depth_descriptor,
	)
	return renderer.mesh_pipeline != nil &&
		renderer.line_pipeline != nil &&
		renderer.resolve_pipeline != nil &&
		renderer.depth_state != nil &&
		renderer.ui_depth_state != nil
}

renderer_build_marker :: proc(renderer: ^Renderer) -> bool {
	STACKS :: 12
	SLICES :: 16
	vertices := make([dynamic]Mesh_Vertex, 0, STACKS*SLICES*6, context.temp_allocator)
	sphere_pt :: proc(stack, slice: int) -> Vec3 {
		phi := math.PI*f64(stack)/f64(STACKS)
		theta := 2*math.PI*f64(slice)/f64(SLICES)
		sin_phi := math.sin(phi)
		return {f32(sin_phi*math.cos(theta)), f32(sin_phi*math.sin(theta)), f32(math.cos(phi))}
	}
	for s in 0..<STACKS {
		for k in 0..<SLICES {
			p00 := sphere_pt(s, k)
			p10 := sphere_pt(s+1, k)
			p11 := sphere_pt(s+1, k+1)
			p01 := sphere_pt(s, k+1)
			append(&vertices,
				Mesh_Vertex{p00, p00}, Mesh_Vertex{p10, p10}, Mesh_Vertex{p11, p11},
				Mesh_Vertex{p00, p00}, Mesh_Vertex{p11, p11}, Mesh_Vertex{p01, p01},
			)
		}
	}
	renderer.marker_buffer = msg_id_ptr_u_u(
		renderer.device,
		sel_registerName("newBufferWithBytes:length:options:"),
		raw_data(vertices[:]),
		uint(len(vertices))*size_of(Mesh_Vertex),
		0,
	)
	renderer.marker_vertex_count = len(vertices)
	return renderer.marker_buffer != nil
}

renderer_set_mesh :: proc(renderer: ^Renderer, mesh: ^Mesh) -> bool {
	if mesh == nil || len(mesh.vertices) == 0 {return false}
	next := msg_id_ptr_u_u(
		renderer.device,
		sel_registerName("newBufferWithBytes:length:options:"),
		raw_data(mesh.vertices[:]),
		uint(len(mesh.vertices))*size_of(Mesh_Vertex),
		0,
	)
	if next == nil {return false}
	if renderer.mesh_buffer != nil {
		msg_void(renderer.mesh_buffer, sel_registerName("release"))
	}
	renderer.mesh_buffer = next
	renderer.mesh_vertex_count = len(mesh.vertices)
	return true
}

// Uploads compact `Gpu_Bead` records into a ping-pong pair of shared Metal buffers
// so live slider edits never stall or race an in-flight GPU frame.
renderer_set_beads :: proc(renderer: ^Renderer, beads: []Gpu_Bead) -> bool {
	count := len(beads)
	if count == 0 {
		renderer.bead_count = 0
		return true
	}
	slot := (renderer.bead_slot+1)&1
	if renderer.bead_buffers[slot] == nil || count > renderer.bead_capacities[slot] {
		new_cap := max(count, count*5/4)
		new_buf := transmute(proc "c" (Id, Sel, uint, uint) -> Id)objc_send_address
		next := new_buf(
			renderer.device,
			sel_registerName("newBufferWithLength:options:"),
			uint(new_cap)*size_of(Gpu_Bead),
			0,
		)
		if next == nil {return false}
		if renderer.bead_buffers[slot] != nil {
			msg_void(renderer.bead_buffers[slot], sel_registerName("release"))
		}
		renderer.bead_buffers[slot] = next
		renderer.bead_capacities[slot] = new_cap
	}
	get_contents := transmute(proc "c" (Id, Sel) -> rawptr)objc_send_address
	dst := get_contents(renderer.bead_buffers[slot], sel_registerName("contents"))
	if dst == nil {return false}
	mem.copy(dst, raw_data(beads), count*size_of(Gpu_Bead))
	renderer.bead_slot = slot
	renderer.bead_buffer = renderer.bead_buffers[slot]
	renderer.bead_count = count
	return true
}

// Draws `finished_beads` from `renderer.bead_buffer` (36 vertices per bead expanded on GPU),
// plus optional growing `partial_bead`, with optional active-layer highlight range.
renderer_draw_beads :: proc(
	renderer: ^Renderer,
	encoder: Id,
	finished_beads: int,
	has_partial: bool,
	partial_bead: Gpu_Bead,
	uniforms: ^Scene_Uniforms = nil,
	highlight_start_bead := -1,
	highlight_color := COLOR_SECTION,
) {
	assert(finished_beads >= 0 && finished_beads <= renderer.bead_count)
	use_highlight := uniforms != nil && highlight_start_bead >= 0 && highlight_start_bead <= finished_beads
	if !use_highlight {
		if finished_beads > 0 {
			verts := finished_beads*BEAD_VERTICES
			msg_void_u_u_u(encoder, sel_registerName("drawPrimitives:vertexStart:vertexCount:"), 3, 0, uint(verts))
			renderer.last_draw_calls += 1
			renderer.last_triangles += verts/3
		}
		if !has_partial {return}
		pb := partial_bead
		msg_void_ptr_u_u(encoder, sel_registerName("setVertexBytes:length:atIndex:"), &pb, size_of(Gpu_Bead), 0)
		msg_void_u_u_u(encoder, sel_registerName("drawPrimitives:vertexStart:vertexCount:"), 3, 0, BEAD_VERTICES)
		renderer.last_draw_calls += 1
		renderer.last_triangles += BEAD_VERTICES/3
		msg_void_id_u_u(encoder, sel_registerName("setVertexBuffer:offset:atIndex:"), renderer.bead_buffer, 0, 0)
		return
	}
	if highlight_start_bead > 0 {
		verts := highlight_start_bead*BEAD_VERTICES
		msg_void_u_u_u(encoder, sel_registerName("drawPrimitives:vertexStart:vertexCount:"), 3, 0, uint(verts))
		renderer.last_draw_calls += 1
		renderer.last_triangles += verts/3
	}
	active_uniforms := uniforms^
	active_uniforms.color = highlight_color
	active_uniforms.arc_color = {}
	active_uniforms.camera.w = -1
	msg_void_ptr_u_u(encoder, sel_registerName("setVertexBytes:length:atIndex:"), &active_uniforms, size_of(Scene_Uniforms), 1)
	msg_void_ptr_u_u(encoder, sel_registerName("setFragmentBytes:length:atIndex:"), &active_uniforms, size_of(Scene_Uniforms), 1)
	active_beads := finished_beads-highlight_start_bead
	if active_beads > 0 {
		msg_void_u_u_u(encoder, sel_registerName("drawPrimitives:vertexStart:vertexCount:"), 3, uint(highlight_start_bead*BEAD_VERTICES), uint(active_beads*BEAD_VERTICES))
		renderer.last_draw_calls += 1
		renderer.last_triangles += active_beads*BEAD_VERTICES/3
	}
	if has_partial {
		pb := partial_bead
		msg_void_ptr_u_u(encoder, sel_registerName("setVertexBytes:length:atIndex:"), &pb, size_of(Gpu_Bead), 0)
		msg_void_u_u_u(encoder, sel_registerName("drawPrimitives:vertexStart:vertexCount:"), 3, 0, BEAD_VERTICES)
		renderer.last_draw_calls += 1
		renderer.last_triangles += BEAD_VERTICES/3
		msg_void_id_u_u(encoder, sel_registerName("setVertexBuffer:offset:atIndex:"), renderer.bead_buffer, 0, 0)
	}
	msg_void_ptr_u_u(encoder, sel_registerName("setVertexBytes:length:atIndex:"), uniforms, size_of(Scene_Uniforms), 1)
	msg_void_ptr_u_u(encoder, sel_registerName("setFragmentBytes:length:atIndex:"), uniforms, size_of(Scene_Uniforms), 1)
}

renderer_set_colored_beads :: proc(renderer: ^Renderer, beads: []Gpu_Colored_Bead) -> bool {
	count := len(beads)
	if count == 0 {
		renderer.colored_bead_count = 0
		return true
	}
	if renderer.colored_bead_buffer == nil || count > renderer.colored_bead_capacity {
		cap := max(count, renderer.colored_bead_capacity * 2)
		new_buf := transmute(proc "c" (Id, Sel, uint, uint) -> Id)objc_send_address
		next := new_buf(
			renderer.device,
			sel_registerName("newBufferWithLength:options:"),
			uint(cap * size_of(Gpu_Colored_Bead)),
			0,
		)
		if next == nil {return false}
		if renderer.colored_bead_buffer != nil {
			msg_void(renderer.colored_bead_buffer, sel_registerName("release"))
		}
		renderer.colored_bead_buffer = next
		renderer.colored_bead_capacity = cap
	}
	get_contents := transmute(proc "c" (Id, Sel) -> rawptr)objc_send_address
	dst := get_contents(renderer.colored_bead_buffer, sel_registerName("contents"))
	if dst == nil {return false}
	mem.copy(dst, raw_data(beads), count * size_of(Gpu_Colored_Bead))
	renderer.colored_bead_count = count
	return true
}

renderer_set_section :: proc(renderer: ^Renderer, vertices: []Mesh_Vertex) -> bool {
	next: Id
	if len(vertices) > 0 {
		next = msg_id_ptr_u_u(
			renderer.device,
			sel_registerName("newBufferWithBytes:length:options:"),
			raw_data(vertices),
			uint(len(vertices))*size_of(Mesh_Vertex),
			0,
		)
		if next == nil {return false}
	}
	if renderer.section_buffer != nil {
		msg_void(renderer.section_buffer, sel_registerName("release"))
	}
	renderer.section_buffer = next
	renderer.section_vertex_count = len(vertices)
	return true
}

renderer_ensure_capture_texture :: proc(
	renderer: ^Renderer,
	width, height: uint,
) -> Id {
	if renderer.capture_texture != nil &&
	   renderer.capture_width == width &&
	   renderer.capture_height == height {
		return renderer.capture_texture
	}
	descriptor := msg_id_u_u_u_bool(
		objc_getClass("MTLTextureDescriptor"),
		sel_registerName(
			"texture2DDescriptorWithPixelFormat:width:height:mipmapped:",
		),
		80,
		width,
		height,
		false,
	)
	msg_void_u(descriptor, sel_registerName("setStorageMode:"), 0)
	msg_void_u(descriptor, sel_registerName("setUsage:"), 5)
	next := msg_id_id(
		renderer.device,
		sel_registerName("newTextureWithDescriptor:"),
		descriptor,
	)
	if next == nil {return nil}
	if renderer.capture_texture != nil {
		msg_void(renderer.capture_texture, sel_registerName("release"))
	}
	renderer.capture_texture = next
	renderer.capture_width = width
	renderer.capture_height = height
	return next
}

renderer_ensure_depth :: proc(
	renderer: ^Renderer,
	width, height, vp_w, vp_h: uint,
) -> bool {
	vp_w := max(uint(1), vp_w)
	vp_h := max(uint(1), vp_h)
	if renderer.depth_texture != nil &&
	   renderer.screen_depth_texture != nil &&
	   renderer.scene_msaa != nil &&
	   renderer.depth_width == width &&
	   renderer.depth_height == height &&
	   renderer.ss_width == vp_w &&
	   renderer.ss_height == vp_h {
		return true
	}
	screen_desc := msg_id_u_u_u_bool(
		objc_getClass("MTLTextureDescriptor"),
		sel_registerName(
			"texture2DDescriptorWithPixelFormat:width:height:mipmapped:",
		),
		252,
		width,
		height,
		false,
	)
	msg_void_u(screen_desc, sel_registerName("setStorageMode:"), 2)
	msg_void_u(screen_desc, sel_registerName("setUsage:"), 4)
	screen_depth := msg_id_id(
		renderer.device,
		sel_registerName("newTextureWithDescriptor:"),
		screen_desc,
	)
	if screen_depth == nil {return false}
	msaa_depth_desc := msg_id_u_u_u_bool(
		objc_getClass("MTLTextureDescriptor"),
		sel_registerName(
			"texture2DDescriptorWithPixelFormat:width:height:mipmapped:",
		),
		252,
		vp_w,
		vp_h,
		false,
	)
	msg_void_u(msaa_depth_desc, sel_registerName("setTextureType:"), 4) // 2DMultisample
	msg_void_u(msaa_depth_desc, sel_registerName("setSampleCount:"), 4)
	msg_void_u(msaa_depth_desc, sel_registerName("setStorageMode:"), 2)
	msg_void_u(msaa_depth_desc, sel_registerName("setUsage:"), 4)
	next := msg_id_id(
		renderer.device,
		sel_registerName("newTextureWithDescriptor:"),
		msaa_depth_desc,
	)
	if next == nil {msg_void(screen_depth, sel_registerName("release")); return false}
	ao_desc := msg_id_u_u_u_bool(
		objc_getClass("MTLTextureDescriptor"),
		sel_registerName(
			"texture2DDescriptorWithPixelFormat:width:height:mipmapped:",
		),
		252,
		vp_w,
		vp_h,
		false,
	)
	msg_void_u(ao_desc, sel_registerName("setStorageMode:"), 2)
	msg_void_u(ao_desc, sel_registerName("setUsage:"), 5)
	ao_depth := msg_id_id(renderer.device, sel_registerName("newTextureWithDescriptor:"), ao_desc)
	if ao_depth == nil {
		msg_void(screen_depth, sel_registerName("release"))
		msg_void(next, sel_registerName("release"))
		return false
	}
	msaa_color_desc := msg_id_u_u_u_bool(objc_getClass("MTLTextureDescriptor"), sel_registerName("texture2DDescriptorWithPixelFormat:width:height:mipmapped:"), 80, vp_w, vp_h, false)
	msg_void_u(msaa_color_desc, sel_registerName("setTextureType:"), 4) // 2DMultisample
	msg_void_u(msaa_color_desc, sel_registerName("setSampleCount:"), 4)
	msg_void_u(msaa_color_desc, sel_registerName("setStorageMode:"), 2)
	msg_void_u(msaa_color_desc, sel_registerName("setUsage:"), 4)
	scene_msaa := msg_id_id(renderer.device, sel_registerName("newTextureWithDescriptor:"), msaa_color_desc)
	if scene_msaa == nil {
		msg_void(screen_depth, sel_registerName("release"))
		msg_void(next, sel_registerName("release"))
		msg_void(ao_depth, sel_registerName("release"))
		return false
	}
	color_descriptor := msg_id_u_u_u_bool(objc_getClass("MTLTextureDescriptor"), sel_registerName("texture2DDescriptorWithPixelFormat:width:height:mipmapped:"), 80, vp_w, vp_h, false)
	msg_void_u(color_descriptor, sel_registerName("setStorageMode:"), 2)
	msg_void_u(color_descriptor, sel_registerName("setUsage:"), 5)
	scene_texture := msg_id_id(renderer.device, sel_registerName("newTextureWithDescriptor:"), color_descriptor)
	if scene_texture == nil {
		msg_void(screen_depth, sel_registerName("release"))
		msg_void(next, sel_registerName("release"))
		msg_void(ao_depth, sel_registerName("release"))
		msg_void(scene_msaa, sel_registerName("release"))
		return false
	}
	if renderer.screen_depth_texture != nil {msg_void(renderer.screen_depth_texture, sel_registerName("release"))}
	if renderer.depth_texture != nil {msg_void(renderer.depth_texture, sel_registerName("release"))}
	if renderer.ao_depth != nil {msg_void(renderer.ao_depth, sel_registerName("release"))}
	if renderer.scene_msaa != nil {msg_void(renderer.scene_msaa, sel_registerName("release"))}
	if renderer.scene_texture != nil {msg_void(renderer.scene_texture, sel_registerName("release"))}
	renderer.screen_depth_texture = screen_depth
	renderer.ao_depth = ao_depth
	renderer.scene_msaa = scene_msaa
	renderer.scene_texture = scene_texture
	renderer.depth_texture = next
	renderer.depth_width = width
	renderer.depth_height = height
	renderer.ss_width = vp_w
	renderer.ss_height = vp_h
	return true
}

// Draws the first `count` uploaded mesh vertices, then `partial` from bytes.
// G2/G3 arc shading is handled in-shader via `uniforms.arc_color` so the full base mesh draws
// in a single draw call; when `highlight_start >= 0`, the active layer `[highlight_start..<count)`
// and `partial` draw in a second call with `highlight_color`.
renderer_draw_mesh :: proc(
	renderer: ^Renderer,
	encoder: Id,
	count: int,
	partial: []Mesh_Vertex,
	uniforms: ^Scene_Uniforms = nil,
	highlight_start := -1,
	highlight_color := COLOR_SECTION,
) {
	assert(count >= 0 && count <= renderer.mesh_vertex_count)
	assert(len(partial)*size_of(Mesh_Vertex) <= 4096)
	use_highlight := uniforms != nil && highlight_start >= 0 && highlight_start <= count
	if !use_highlight {
		if count > 0 {
			msg_void_u_u_u(encoder, sel_registerName("drawPrimitives:vertexStart:vertexCount:"), 3, 0, uint(count))
			renderer.last_draw_calls += 1
			renderer.last_triangles += count/3
		}
		if len(partial) == 0 {return}
		msg_void_ptr_u_u(encoder, sel_registerName("setVertexBytes:length:atIndex:"), raw_data(partial), uint(len(partial)*size_of(Mesh_Vertex)), 0)
		msg_void_u_u_u(encoder, sel_registerName("drawPrimitives:vertexStart:vertexCount:"), 3, 0, uint(len(partial)))
		renderer.last_draw_calls += 1
		renderer.last_triangles += len(partial)/3
		msg_void_id_u_u(encoder, sel_registerName("setVertexBuffer:offset:atIndex:"), renderer.mesh_buffer, 0, 0)
		return
	}
	if highlight_start > 0 {
		msg_void_u_u_u(encoder, sel_registerName("drawPrimitives:vertexStart:vertexCount:"), 3, 0, uint(highlight_start))
		renderer.last_draw_calls += 1
		renderer.last_triangles += highlight_start/3
	}
	active_uniforms := uniforms^
	active_uniforms.color = highlight_color
	active_uniforms.arc_color = {}
	msg_void_ptr_u_u(encoder, sel_registerName("setVertexBytes:length:atIndex:"), &active_uniforms, size_of(Scene_Uniforms), 1)
	msg_void_ptr_u_u(encoder, sel_registerName("setFragmentBytes:length:atIndex:"), &active_uniforms, size_of(Scene_Uniforms), 1)
	active_count := count-highlight_start
	if active_count > 0 {
		msg_void_u_u_u(encoder, sel_registerName("drawPrimitives:vertexStart:vertexCount:"), 3, uint(highlight_start), uint(active_count))
		renderer.last_draw_calls += 1
		renderer.last_triangles += active_count/3
	}
	if len(partial) > 0 {
		msg_void_ptr_u_u(encoder, sel_registerName("setVertexBytes:length:atIndex:"), raw_data(partial), uint(len(partial)*size_of(Mesh_Vertex)), 0)
		msg_void_u_u_u(encoder, sel_registerName("drawPrimitives:vertexStart:vertexCount:"), 3, 0, uint(len(partial)))
		renderer.last_draw_calls += 1
		renderer.last_triangles += len(partial)/3
		msg_void_id_u_u(encoder, sel_registerName("setVertexBuffer:offset:atIndex:"), renderer.mesh_buffer, 0, 0)
	}
	msg_void_ptr_u_u(encoder, sel_registerName("setVertexBytes:length:atIndex:"), uniforms, size_of(Scene_Uniforms), 1)
	msg_void_ptr_u_u(encoder, sel_registerName("setFragmentBytes:length:atIndex:"), uniforms, size_of(Scene_Uniforms), 1)
}

renderer_draw_marker :: proc(
	renderer: ^Renderer,
	encoder: Id,
	base_uniforms: ^Scene_Uniforms,
	projection, view, model: Mat4,
	pos: Vec3,
	radius: f32,
	color: Vec4,
) {
	if renderer.marker_buffer == nil || renderer.marker_vertex_count == 0 {return}
	local := Mat4{
		radius, 0, 0, 0,
		0, radius, 0, 0,
		0, 0, radius, 0,
		pos.x, pos.y, pos.z, 1,
	}
	marker_model := mat4_mul(model, local)
	marker_uniforms := base_uniforms^
	marker_uniforms.model = marker_model
	marker_uniforms.mvp = mat4_mul(projection, mat4_mul(view, marker_model))
	marker_uniforms.color = color
	marker_uniforms.arc_color = {}
	msg_void_id_u_u(encoder, sel_registerName("setVertexBuffer:offset:atIndex:"), renderer.marker_buffer, 0, 0)
	msg_void_ptr_u_u(encoder, sel_registerName("setVertexBytes:length:atIndex:"), &marker_uniforms, size_of(Scene_Uniforms), 1)
	msg_void_ptr_u_u(encoder, sel_registerName("setFragmentBytes:length:atIndex:"), &marker_uniforms, size_of(Scene_Uniforms), 1)
	msg_void_u_u_u(encoder, sel_registerName("drawPrimitives:vertexStart:vertexCount:"), 3, 0, uint(renderer.marker_vertex_count))
	msg_void_id_u_u(encoder, sel_registerName("setVertexBuffer:offset:atIndex:"), renderer.mesh_buffer, 0, 0)
	msg_void_ptr_u_u(encoder, sel_registerName("setVertexBytes:length:atIndex:"), base_uniforms, size_of(Scene_Uniforms), 1)
	msg_void_ptr_u_u(encoder, sel_registerName("setFragmentBytes:length:atIndex:"), base_uniforms, size_of(Scene_Uniforms), 1)
}

Render_Result :: enum u8 {
	Presented,
	Captured,
	Capture_Failed,
	No_Layer,
	Empty_Viewport,
	No_Depth_Texture,
	No_Drawable,
	No_Command_Buffer,
	No_Encoder,
	No_Capture_Texture,
}

render_result_text :: proc(result: Render_Result) -> string {
	switch result {
	case .Presented:          return "presented"
	case .Captured:           return "captured"
	case .Capture_Failed:     return "capture write failed"
	case .No_Layer:           return "no metal layer"
	case .Empty_Viewport:     return "empty viewport"
	case .No_Depth_Texture:   return "no depth texture"
	case .No_Drawable:        return "no drawable"
	case .No_Command_Buffer:  return "no command buffer"
	case .No_Encoder:         return "no render encoder"
	case .No_Capture_Texture: return "no capture texture"
	}
	return "unknown"
}

renderer_draw :: proc(
	renderer: ^Renderer,
	mesh: ^Mesh,
	placement: Model_Placement,
	face_hover: int,
	camera: Camera,
	viewport: UI_Rect,
	theme: Theme,
	wireframe: bool,
	show_arcs: bool,
	visual: Design_Visual,
	ui_list: ^gpu.Draw_List,
	width, height, scale: f64,
) -> Render_Result {
	if renderer.layer == nil {return .No_Layer}
	if width <= 0 || height <= 0 {return .Empty_Viewport}
	renderer.last_draw_calls = 0
	renderer.last_triangles = 0
	pixel_width := uint(max(1, width*scale))
	pixel_height := uint(max(1, height*scale))
	vp_w := uint(max(1, viewport.w*scale))
	vp_h := uint(max(1, viewport.h*scale))
	if !renderer_ensure_depth(renderer, pixel_width, pixel_height, vp_w, vp_h) {
		return .No_Depth_Texture
	}
	capture := len(renderer.capture_path) > 0 && !renderer.capture_written
	drawable: Id
	texture: Id
	if capture {
		texture = renderer_ensure_capture_texture(
			renderer,
			pixel_width,
			pixel_height,
		)
		if texture == nil {return .No_Capture_Texture}
	} else {
		drawable = msg_id(renderer.layer, sel_registerName("nextDrawable"))
		if drawable == nil {return .No_Drawable}
		texture = msg_id(drawable, sel_registerName("texture"))
	}
	command_buffer := msg_id(renderer.queue, sel_registerName("commandBuffer"))
	if command_buffer == nil {return .No_Command_Buffer}
	pass := msg_id(
		objc_getClass("MTLRenderPassDescriptor"),
		sel_registerName("renderPassDescriptor"),
	)
	color_attachments := msg_id(pass, sel_registerName("colorAttachments"))
	color_attachment := msg_id_index(
		color_attachments,
		sel_registerName("objectAtIndexedSubscript:"),
		0,
	)
	msg_void_id(color_attachment, sel_registerName("setTexture:"), texture)
	msg_void_u(color_attachment, sel_registerName("setLoadAction:"), 2)
	msg_void_u(color_attachment, sel_registerName("setStoreAction:"), 1)
	msg_void_clear_color(
		color_attachment,
		sel_registerName("setClearColor:"),
		{
			f64(theme.canvas.x),
			f64(theme.canvas.y),
			f64(theme.canvas.z),
			1,
		},
	)
	depth_attachment := msg_id(pass, sel_registerName("depthAttachment"))
	msg_void_id(
		depth_attachment,
		sel_registerName("setTexture:"),
		renderer.depth_texture,
	)
	msg_void_u(depth_attachment, sel_registerName("setLoadAction:"), 2)
	msg_void_u(depth_attachment, sel_registerName("setStoreAction:"), 0)
	msg_void_f64(depth_attachment, sel_registerName("setClearDepth:"), 1)
	size := mesh_size(placement.bounds)
	model := placement.transform
	eye := app_camera_eye(camera)
	view := mat4_look_at(eye, camera.target, {0, 0, 1})
	near_z := max(0.01, camera.distance*0.001)
	far_z := max(1000.0, camera.distance*20+vec3_length(size))
	projection := mat4_perspective(
		0.78,
		f32(max(0.01, viewport.w/viewport.h)),
		near_z,
		far_z,
	)
	mesh_uniforms := Scene_Uniforms{
		mvp = mat4_mul(projection, mat4_mul(view, model)),
		model = model,
		color = theme.bead,
		arc_color = theme.arc if show_arcs else Vec4{},
		selected_color = theme.accent,
		camera = {eye.x, eye.y, eye.z, f32(visual.selected_junction) if visual.is_design else -1},
		view_projection = mat4_mul(projection, view),
		params = {near_z, far_z, max(f32(0.1), vec3_length(size)*0.025), 0 if wireframe else 1},
		viewport = {0, 0, 1, 1},
		sh = renderer.harmonics,
	}
	cull_back := (visual.is_design || visual.is_gcode_preview) && !wireframe
	gcode_uniforms := mesh_uniforms
	gcode_uniforms.model = mat4_identity()
	gcode_uniforms.mvp = mat4_mul(projection, view)
	ao_vp := MTL_Viewport{0, 0, f64(vp_w), f64(vp_h), 0, 1}
	ss_vp := MTL_Viewport{0, 0, f64(renderer.ss_width), f64(renderer.ss_height), 0, 1}

	// Pass 1 (1x viewport): depth prepass into `ao_depth` for screen-space AO and floor reflections.
	msg_void_id(color_attachment, sel_registerName("setTexture:"), nil)
	msg_void_u(color_attachment, sel_registerName("setLoadAction:"), 0) // DontCare
	msg_void_u(color_attachment, sel_registerName("setStoreAction:"), 0) // DontCare
	msg_void_id(depth_attachment, sel_registerName("setTexture:"), renderer.ao_depth)
	msg_void_u(depth_attachment, sel_registerName("setLoadAction:"), 2) // Clear
	msg_void_u(depth_attachment, sel_registerName("setStoreAction:"), 1) // Store
	prepass := msg_id_id(command_buffer, sel_registerName("renderCommandEncoderWithDescriptor:"), pass)
	if prepass == nil {return .No_Encoder}
	msg_void_viewport(prepass, sel_registerName("setViewport:"), ao_vp)
	msg_void_id(prepass, sel_registerName("setDepthStencilState:"), renderer.depth_state)
	if cull_back {
		msg_void_u(prepass, sel_registerName("setFrontFacingWinding:"), 1) // CCW
		msg_void_u(prepass, sel_registerName("setCullMode:"), 2) // Back
	}
	if visual.is_design {
		msg_void_id(prepass, sel_registerName("setRenderPipelineState:"), renderer.bead_depth_pipeline)
		msg_void_id_u_u(prepass, sel_registerName("setVertexBuffer:offset:atIndex:"), renderer.bead_buffer, 0, 0)
		msg_void_ptr_u_u(prepass, sel_registerName("setVertexBytes:length:atIndex:"), &mesh_uniforms, size_of(Scene_Uniforms), 1)
		renderer_draw_beads(renderer, prepass, visual.finished_beads, visual.has_partial, visual.partial_bead)
	} else if visual.is_gcode_preview && renderer.colored_bead_count > 0 && visual.gcode_bead_count > 0 {
		start_b := clamp(visual.gcode_bead_start, 0, renderer.colored_bead_count)
		cnt_b := min(visual.gcode_bead_count, renderer.colored_bead_count - start_b)
		if cnt_b > 0 {
			msg_void_id(prepass, sel_registerName("setRenderPipelineState:"), renderer.colored_bead_depth_pipeline)
			msg_void_id_u_u(prepass, sel_registerName("setVertexBuffer:offset:atIndex:"), renderer.colored_bead_buffer, 0, 0)
			msg_void_ptr_u_u(prepass, sel_registerName("setVertexBytes:length:atIndex:"), &gcode_uniforms, size_of(Scene_Uniforms), 1)
			msg_void_u_u_u(prepass, sel_registerName("drawPrimitives:vertexStart:vertexCount:"), 3, uint(start_b*36), uint(cnt_b*36))
		}
	} else {
		msg_void_id(prepass, sel_registerName("setRenderPipelineState:"), renderer.depth_pipeline)
		msg_void_id_u_u(prepass, sel_registerName("setVertexBuffer:offset:atIndex:"), renderer.mesh_buffer, 0, 0)
		msg_void_ptr_u_u(prepass, sel_registerName("setVertexBytes:length:atIndex:"), &mesh_uniforms, size_of(Scene_Uniforms), 1)
		renderer_draw_mesh(renderer, prepass, visual.finished_vertices, visual.partial)
	}
	msg_void(prepass, sel_registerName("endEncoding"))

	// Pass 2 (4x MSAA): shade mesh into on-tile `scene_msaa` and hardware-resolve into `scene_texture`.
	msg_void_id(depth_attachment, sel_registerName("setTexture:"), renderer.depth_texture)
	msg_void_u(depth_attachment, sel_registerName("setLoadAction:"), 2) // Clear
	msg_void_u(depth_attachment, sel_registerName("setStoreAction:"), 0) // DontCare
	msg_void_id(color_attachment, sel_registerName("setTexture:"), renderer.scene_msaa)
	msg_void_id(color_attachment, sel_registerName("setResolveTexture:"), renderer.scene_texture)
	msg_void_u(color_attachment, sel_registerName("setLoadAction:"), 2) // Clear
	msg_void_u(color_attachment, sel_registerName("setStoreAction:"), 2) // MultisampleResolve
	msg_void_clear_color(color_attachment, sel_registerName("setClearColor:"), {f64(theme.canvas.x), f64(theme.canvas.y), f64(theme.canvas.z), 0})
	scene_encoder := msg_id_id(command_buffer, sel_registerName("renderCommandEncoderWithDescriptor:"), pass)
	if scene_encoder == nil {return .No_Encoder}
	msg_void_viewport(scene_encoder, sel_registerName("setViewport:"), ss_vp)
	msg_void_id(scene_encoder, sel_registerName("setDepthStencilState:"), renderer.depth_state)
	if cull_back {
		msg_void_u(scene_encoder, sel_registerName("setFrontFacingWinding:"), 1) // CCW
		msg_void_u(scene_encoder, sel_registerName("setCullMode:"), 2) // Back
	}
	msg_void_u(scene_encoder, sel_registerName("setTriangleFillMode:"), 1 if wireframe else 0)
	if visual.is_design {
		msg_void_id(scene_encoder, sel_registerName("setRenderPipelineState:"), renderer.bead_pipeline)
		msg_void_id_u_u(scene_encoder, sel_registerName("setVertexBuffer:offset:atIndex:"), renderer.bead_buffer, 0, 0)
		msg_void_ptr_u_u(scene_encoder, sel_registerName("setVertexBytes:length:atIndex:"), &mesh_uniforms, size_of(Scene_Uniforms), 1)
		msg_void_ptr_u_u(scene_encoder, sel_registerName("setFragmentBytes:length:atIndex:"), &mesh_uniforms, size_of(Scene_Uniforms), 1)
		msg_void_id_u(scene_encoder, sel_registerName("setFragmentTexture:atIndex:"), renderer.environment, 0)
		msg_void_id_u(scene_encoder, sel_registerName("setFragmentTexture:atIndex:"), renderer.ao_depth, 1)
		renderer_draw_beads(renderer, scene_encoder, visual.finished_beads, visual.has_partial, visual.partial_bead, &mesh_uniforms, visual.highlight_start_bead, theme.accent)
	} else if visual.is_gcode_preview && renderer.colored_bead_count > 0 && visual.gcode_bead_count > 0 {
		start_b := clamp(visual.gcode_bead_start, 0, renderer.colored_bead_count)
		cnt_b := min(visual.gcode_bead_count, renderer.colored_bead_count - start_b)
		if cnt_b > 0 {
			msg_void_id(scene_encoder, sel_registerName("setRenderPipelineState:"), renderer.colored_bead_pipeline)
			msg_void_id_u_u(scene_encoder, sel_registerName("setVertexBuffer:offset:atIndex:"), renderer.colored_bead_buffer, 0, 0)
			msg_void_ptr_u_u(scene_encoder, sel_registerName("setVertexBytes:length:atIndex:"), &gcode_uniforms, size_of(Scene_Uniforms), 1)
			msg_void_ptr_u_u(scene_encoder, sel_registerName("setFragmentBytes:length:atIndex:"), &gcode_uniforms, size_of(Scene_Uniforms), 1)
			msg_void_id_u(scene_encoder, sel_registerName("setFragmentTexture:atIndex:"), renderer.environment, 0)
			msg_void_id_u(scene_encoder, sel_registerName("setFragmentTexture:atIndex:"), renderer.ao_depth, 1)
			msg_void_u_u_u(scene_encoder, sel_registerName("drawPrimitives:vertexStart:vertexCount:"), 3, uint(start_b*36), uint(cnt_b*36))
			renderer.last_draw_calls += 1
			renderer.last_triangles += cnt_b * 12
		}
	} else {
		msg_void_id(scene_encoder, sel_registerName("setRenderPipelineState:"), renderer.mesh_pipeline)
		msg_void_id_u_u(scene_encoder, sel_registerName("setVertexBuffer:offset:atIndex:"), renderer.mesh_buffer, 0, 0)
		msg_void_ptr_u_u(scene_encoder, sel_registerName("setVertexBytes:length:atIndex:"), &mesh_uniforms, size_of(Scene_Uniforms), 1)
		msg_void_ptr_u_u(scene_encoder, sel_registerName("setFragmentBytes:length:atIndex:"), &mesh_uniforms, size_of(Scene_Uniforms), 1)
		msg_void_id_u(scene_encoder, sel_registerName("setFragmentTexture:atIndex:"), renderer.environment, 0)
		msg_void_id_u(scene_encoder, sel_registerName("setFragmentTexture:atIndex:"), renderer.ao_depth, 1)
		renderer_draw_mesh(renderer, scene_encoder, visual.finished_vertices, visual.partial, &mesh_uniforms, visual.highlight_start, theme.accent)
	}
	if visual.marker_active {
		msg_void_u(scene_encoder, sel_registerName("setCullMode:"), 0)
		msg_void_id(scene_encoder, sel_registerName("setRenderPipelineState:"), renderer.mesh_pipeline)
		msg_void_id(scene_encoder, sel_registerName("setDepthStencilState:"), renderer.depth_state)
		renderer_draw_marker(renderer, scene_encoder, &mesh_uniforms, projection, view, model, visual.marker_pos, visual.marker_radius, theme.marker)
	}
	msg_void(scene_encoder, sel_registerName("endEncoding"))

	// Pass 3 (1x drawable): draw floor + grid, then composite the 2x2 Tent AA resolve over them.
	msg_void_id(color_attachment, sel_registerName("setResolveTexture:"), nil)
	msg_void_id(color_attachment, sel_registerName("setTexture:"), texture)
	msg_void_u(color_attachment, sel_registerName("setLoadAction:"), 2) // Clear
	msg_void_u(color_attachment, sel_registerName("setStoreAction:"), 1) // Store
	msg_void_clear_color(color_attachment, sel_registerName("setClearColor:"), {f64(theme.canvas.x), f64(theme.canvas.y), f64(theme.canvas.z), 1})
	msg_void_id(depth_attachment, sel_registerName("setTexture:"), renderer.screen_depth_texture)
	msg_void_u(depth_attachment, sel_registerName("setLoadAction:"), 2) // Clear
	msg_void_u(depth_attachment, sel_registerName("setStoreAction:"), 0) // DontCare
	encoder := msg_id_id(
		command_buffer,
		sel_registerName("renderCommandEncoderWithDescriptor:"),
		pass,
	)
	if encoder == nil {return .No_Encoder}

	mesh_viewport := MTL_Viewport{
		viewport.x*scale,
		viewport.y*scale,
		viewport.w*scale,
		viewport.h*scale,
		0,
		1,
	}
	msg_void_viewport(
		encoder,
		sel_registerName("setViewport:"),
		mesh_viewport,
	)
	msg_void_id(
		encoder,
		sel_registerName("setDepthStencilState:"),
		renderer.depth_state,
	)
	msg_void_u(encoder, sel_registerName("setCullMode:"), 0)
	msg_void_id_u(encoder, sel_registerName("setFragmentTexture:atIndex:"), renderer.ao_depth, 1)

	{
		plate := f32(BUILD_PLATE_HALF_EXTENT + 2.0)
		floor_vertices := [6]Mesh_Vertex{
			{{-plate, -plate, -0.01}, {0, 0, 1}},
			{{ plate, -plate, -0.01}, {0, 0, 1}},
			{{ plate,  plate, -0.01}, {0, 0, 1}},
			{{-plate, -plate, -0.01}, {0, 0, 1}},
			{{ plate,  plate, -0.01}, {0, 0, 1}},
			{{-plate,  plate, -0.01}, {0, 0, 1}},
		}
		floor_uniforms := mesh_uniforms
		floor_uniforms.model = mat4_identity()
		floor_uniforms.mvp = mesh_uniforms.view_projection
		floor_uniforms.color = {theme.canvas.x, theme.canvas.y, theme.canvas.z, 1}
		floor_uniforms.arc_color = {theme.muted.x, theme.muted.y, theme.muted.z, 1}
		msg_void_u(encoder, sel_registerName("setTriangleFillMode:"), 0)
		msg_void_id(encoder, sel_registerName("setRenderPipelineState:"), renderer.floor_pipeline)
		msg_void_ptr_u_u(encoder, sel_registerName("setVertexBytes:length:atIndex:"), raw_data(floor_vertices[:]), size_of(floor_vertices), 0)
		msg_void_ptr_u_u(encoder, sel_registerName("setVertexBytes:length:atIndex:"), &floor_uniforms, size_of(Scene_Uniforms), 1)
		msg_void_ptr_u_u(encoder, sel_registerName("setFragmentBytes:length:atIndex:"), &floor_uniforms, size_of(Scene_Uniforms), 1)
		msg_void_id_u(encoder, sel_registerName("setFragmentTexture:atIndex:"), renderer.scene_texture, 2)
		msg_void_u_u_u(encoder, sel_registerName("drawPrimitives:vertexStart:vertexCount:"), 3, 0, 6)
	}

	// Composite the 2x2 Tent AA resolved 3D scene over the floor and grid.
	msg_void_id(encoder, sel_registerName("setDepthStencilState:"), renderer.ui_depth_state)
	msg_void_id(encoder, sel_registerName("setRenderPipelineState:"), renderer.resolve_pipeline)
	msg_void_ptr_u_u(encoder, sel_registerName("setVertexBytes:length:atIndex:"), &mesh_uniforms, size_of(Scene_Uniforms), 1)
	msg_void_ptr_u_u(encoder, sel_registerName("setFragmentBytes:length:atIndex:"), &mesh_uniforms, size_of(Scene_Uniforms), 1)
	msg_void_id_u(encoder, sel_registerName("setFragmentTexture:atIndex:"), renderer.ao_depth, 1)
	msg_void_id_u(encoder, sel_registerName("setFragmentTexture:atIndex:"), renderer.scene_texture, 2)
	msg_void_u_u_u(encoder, sel_registerName("drawPrimitives:vertexStart:vertexCount:"), 3, 0, 6)

	if face_hover >= 0 {
		msg_void_id_u_u(encoder, sel_registerName("setVertexBuffer:offset:atIndex:"), renderer.mesh_buffer, 0, 0)
		msg_void_id(encoder, sel_registerName("setRenderPipelineState:"), renderer.line_pipeline)
		a := mesh.vertices[face_hover*3].position
		n := vec3_normalize(vec3_cross(vec3_sub(mesh.vertices[face_hover*3+1].position,a), vec3_sub(mesh.vertices[face_hover*3+2].position,a)))
		tolerance := max(f32(0.00001),vec3_length(mesh_size(mesh.bounds))*0.000001)
		highlight := mesh_uniforms
		highlight.color = theme.accent
		depth_bias := transmute(proc "c" (Id, Sel, f32, f32, f32))objc_send_address
		depth_bias(encoder, sel_registerName("setDepthBias:slopeScale:clamp:"), -1, -1, 0)
		msg_void_u(encoder, sel_registerName("setTriangleFillMode:"), 0)
		msg_void_ptr_u_u(encoder, sel_registerName("setVertexBytes:length:atIndex:"), &highlight, size_of(Scene_Uniforms), 1)
		run_start := -1
		for triangle in 0..<int(mesh.triangle_count) {
			coplanar := true
			for corner in 0..<3 {
				if abs(vec3_dot(n,vec3_sub(mesh.vertices[triangle*3+corner].position,a))) > tolerance {coplanar = false}
			}
			if coplanar && run_start < 0 {run_start = triangle}
			if !coplanar && run_start >= 0 {
				msg_void_u_u_u(encoder, sel_registerName("drawPrimitives:vertexStart:vertexCount:"),
				                  3, uint(run_start*3), uint((triangle-run_start)*3))
				run_start = -1
			}
		}
		if run_start >= 0 {
			msg_void_u_u_u(encoder, sel_registerName("drawPrimitives:vertexStart:vertexCount:"),
			                  3, uint(run_start*3), uint((int(mesh.triangle_count)-run_start)*3))
		}
		depth_bias(encoder, sel_registerName("setDepthBias:slopeScale:clamp:"), 0, 0, 0)
	}

	if renderer.section_vertex_count > 0 {
		base_mvp := mat4_mul(projection, view)
		px_x := f32(2.0 / max(1.0, mesh_viewport.width))
		px_y := f32(2.0 / max(1.0, mesh_viewport.height))
		msg_void_id(
			encoder,
			sel_registerName("setDepthStencilState:"),
			renderer.ui_depth_state,
		)
		msg_void_id(
			encoder,
			sel_registerName("setRenderPipelineState:"),
			renderer.line_pipeline,
		)
		msg_void_id_u_u(
			encoder,
			sel_registerName("setVertexBuffer:offset:atIndex:"),
			renderer.section_buffer,
			0,
			0,
		)
		for oy in -1..=1 {
			for ox in -1..=1 {
				dx := f32(ox) * px_x
				dy := f32(oy) * px_y
				shifted := base_mvp
				shifted[0]  += dx * base_mvp[3]
				shifted[4]  += dx * base_mvp[7]
				shifted[8]  += dx * base_mvp[11]
				shifted[12] += dx * base_mvp[15]
				shifted[1]  += dy * base_mvp[3]
				shifted[5]  += dy * base_mvp[7]
				shifted[9]  += dy * base_mvp[11]
				shifted[13] += dy * base_mvp[15]
				section_uniforms := Scene_Uniforms{
					mvp   = shifted,
					model = mat4_identity(),
					color = {0.06, 0.08, 0.11, 1.0},
				}
				msg_void_ptr_u_u(
					encoder,
					sel_registerName("setVertexBytes:length:atIndex:"),
					&section_uniforms,
					size_of(Scene_Uniforms),
					1,
				)
				msg_void_u_u_u(
					encoder,
					sel_registerName("drawPrimitives:vertexStart:vertexCount:"),
					1,
					0,
					uint(renderer.section_vertex_count),
				)
			}
		}
	}

	msg_void(encoder, sel_registerName("endEncoding"))
	gpu.renderer_encode(
		&renderer.ui_renderer,
		(^MTL.CommandBuffer)(command_buffer),
		(^MTL.Texture)(texture),
		ui_list,
		nil,
	)
	if capture {
		msg_void(command_buffer, sel_registerName("commit"))
		msg_void(command_buffer, sel_registerName("waitUntilCompleted"))
		bytes := make([]u8, int(pixel_width*pixel_height*4))
		defer delete(bytes)
		region := MTL_Region{
			origin = {0, 0, 0},
			size = {pixel_width, pixel_height, 1},
		}
		msg_void_read_region(
			texture,
			sel_registerName(
				"getBytes:bytesPerRow:fromRegion:mipmapLevel:",
			),
			raw_data(bytes),
			pixel_width*4,
			region,
			0,
		)
		if !bmp_write(renderer.capture_path, bytes, pixel_width, pixel_height) {
			return .Capture_Failed
		}
		renderer.capture_written = true
		return .Captured
	}
	msg_void_id(
		command_buffer,
		sel_registerName("presentDrawable:"),
		drawable,
	)
	msg_void(command_buffer, sel_registerName("commit"))
	if renderer.bench_sync {
		msg_void(command_buffer, sel_registerName("waitUntilCompleted"))
	}
	return .Presented
}

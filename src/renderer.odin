package main

import "core:fmt"

foreign import metal "system:Metal.framework"
foreign metal {
	MTLCreateSystemDefaultDevice :: proc "c" () -> Id ---
}

Scene_Uniforms :: struct {
	mvp:       Mat4,
	model:     Mat4,
	color:     Vec4,
	light_dir: Vec4,
	camera:    Vec4,
}

Solid_Vertex :: struct {
	position: Vec2,
	padding:  Vec2,
	color:    Vec4,
}

Texture_Vertex :: struct {
	position: Vec2,
	uv:       Vec2,
}

Renderer :: struct {
	layer:            Id,
	device:           Id,
	queue:            Id,
	mesh_pipeline:    Id,
	line_pipeline:    Id,
	solid_pipeline:   Id,
	texture_pipeline: Id,
	depth_state:      Id,
	ui_depth_state:   Id,
	mesh_buffer:      Id,
	section_buffer:   Id,
	grid_buffer:      Id,
	capture_texture:  Id,
	capture_path:     string,
	capture_written:  bool,
	capture_width:    uint,
	capture_height:   uint,
	text_texture:     Id,
	depth_texture:    Id,
	mesh_vertex_count: int,
	section_vertex_count: int,
	grid_vertex_count: int,
	texture_width:    uint,
	texture_height:   uint,
	depth_width:      uint,
	depth_height:     uint,
}

METAL_SOURCE :: `
#include <metal_stdlib>
using namespace metal;

struct MeshVertex {
    packed_float3 position;
    packed_float3 normal;
};

struct SceneUniforms {
    float4x4 mvp;
    float4x4 model;
    float4 color;
    float4 light_dir;
    float4 camera;
};

struct MeshOut {
    float4 position [[position]];
    float3 normal;
    float4 color;
    float3 light_dir;
    float3 world;
    float3 camera;
};

vertex MeshOut mesh_vertex(
    uint id [[vertex_id]],
    device const MeshVertex *vertices [[buffer(0)]],
    constant SceneUniforms &scene [[buffer(1)]]
) {
    MeshVertex source = vertices[id];
    MeshOut out;
    out.position = scene.mvp * float4(source.position, 1.0);
    out.normal = normalize((scene.model * float4(source.normal, 0.0)).xyz);
    out.color = scene.color;
    out.light_dir = scene.light_dir.xyz;
    out.world = (scene.model * float4(source.position, 1.0)).xyz;
    out.camera = scene.camera.xyz;
    return out;
}

// Adapted from hw_delta_support/shaders/charger3d.metal.
static float2 environment_brdf(float roughness, float n_dot_v) {
    const float4 c0 = float4(-1.0, -0.0275, -0.572, 0.022);
    const float4 c1 = float4(1.0, 0.0425, 1.04, -0.04);
    float4 r = roughness * c0 + c1;
    float a004 = min(r.x * r.x, exp2(-9.28 * n_dot_v)) * r.x + r.y;
    return float2(-1.04, 1.04) * a004 + r.zw;
}

static float3 tone_map(float3 x) {
    return saturate((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14));
}

fragment float4 mesh_fragment(MeshOut in [[stage_in]]) {
    float3 normal = normalize(in.normal);
    float3 view = normalize(in.camera - in.world);
    if (dot(normal, view) < 0.0) {normal = -normal;}
    float n_dot_v = max(dot(normal, view), 1e-3);
    float3 light = normalize(in.light_dir);
    float3 fill = normalize(float3(0.6, 0.3, 0.5));
    float3 albedo = pow(in.color.rgb, float3(2.2));
    float diffuse = 0.32 + 0.75 * max(dot(normal, light), 0.0)
        + 0.28 * max(dot(normal, fill), 0.0);
    float3 reflected = reflect(-view, normal);
    float studio = 0.22 + 1.8 * pow(max(dot(reflected, light), 0.0), 12.0)
        + 0.6 * pow(max(dot(reflected, fill), 0.0), 6.0);
    float2 brdf = environment_brdf(0.48, n_dot_v);
    float3 specular = studio * (float3(0.04) * brdf.x + brdf.y);
    float3 color = tone_map((albedo * diffuse + specular) * 1.35);
    return float4(pow(color, float3(1.0 / 2.2)), in.color.a);
}

fragment float4 line_fragment(MeshOut in [[stage_in]]) {
    return in.color;
}

struct SolidVertex {
    float2 position;
    float4 color;
};

struct SolidOut {
    float4 position [[position]];
    float4 color;
};

// Project code emits UI vertices in Metal clip space.
vertex SolidOut solid_vertex(
    uint id [[vertex_id]],
    device const SolidVertex *vertices [[buffer(0)]]
) {
    SolidOut out;
    out.position = float4(vertices[id].position, 0.0, 1.0);
    out.color = vertices[id].color;
    return out;
}

fragment float4 solid_fragment(SolidOut in [[stage_in]]) {
    return in.color;
}

struct TextureVertex {
    float2 position;
    float2 uv;
};

struct TextureOut {
    float4 position [[position]];
    float2 uv;
};

vertex TextureOut texture_vertex(
    uint id [[vertex_id]],
    device const TextureVertex *vertices [[buffer(0)]]
) {
    TextureOut out;
    out.position = float4(vertices[id].position, 0.0, 1.0);
    out.uv = vertices[id].uv;
    return out;
}

fragment float4 texture_fragment(
    TextureOut in [[stage_in]],
    texture2d<float> source [[texture(0)]]
) {
    constexpr sampler texture_sampler(
        mag_filter::linear,
        min_filter::linear
    );
    return source.sample(texture_sampler, in.uv);
}
`

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
	return renderer_build_grid(renderer)
}

renderer_shutdown :: proc(renderer: ^Renderer) {
	objects := [14]Id{
		renderer.depth_texture,
		renderer.text_texture,
		renderer.capture_texture,
		renderer.grid_buffer,
		renderer.section_buffer,
		renderer.mesh_buffer,
		renderer.ui_depth_state,
		renderer.depth_state,
		renderer.texture_pipeline,
		renderer.solid_pipeline,
		renderer.line_pipeline,
		renderer.mesh_pipeline,
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
) -> Id {
	vertex := msg_id_id(
		library,
		sel_registerName("newFunctionWithName:"),
		nsstring(vertex_name),
	)
	fragment := msg_id_id(
		library,
		sel_registerName("newFunctionWithName:"),
		nsstring(fragment_name),
	)
	if vertex == nil || fragment == nil {return nil}
	defer msg_void(vertex, sel_registerName("release"))
	defer msg_void(fragment, sel_registerName("release"))

	descriptor := msg_id(
		msg_id(objc_getClass("MTLRenderPipelineDescriptor"), sel_registerName("alloc")),
		sel_registerName("init"),
	)
	if descriptor == nil {return nil}
	defer msg_void(descriptor, sel_registerName("release"))
	msg_void_id(descriptor, sel_registerName("setVertexFunction:"), vertex)
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
	if depth {
		msg_void_u(
			descriptor,
			sel_registerName("setDepthAttachmentPixelFormat:"),
			252,
		)
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
	error: Id
	library := msg_id_id_id_error(
		renderer.device,
		sel_registerName("newLibraryWithSource:options:error:"),
		nsstring(METAL_SOURCE),
		nil,
		&error,
	)
	if library == nil {
		fmt.eprintf("Metal shader compilation failed: %s\n", ns_error_text(error))
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
	)
	renderer.line_pipeline = renderer_build_pipeline(
		renderer,
		library,
		"mesh_vertex",
		"line_fragment",
		true,
		true,
		false,
	)
	renderer.solid_pipeline = renderer_build_pipeline(
		renderer,
		library,
		"solid_vertex",
		"solid_fragment",
		true,
		true,
		false,
	)
	renderer.texture_pipeline = renderer_build_pipeline(
		renderer,
		library,
		"texture_vertex",
		"texture_fragment",
		true,
		true,
		true,
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
		renderer.solid_pipeline != nil &&
		renderer.texture_pipeline != nil &&
		renderer.depth_state != nil &&
		renderer.ui_depth_state != nil
}

renderer_build_grid :: proc(renderer: ^Renderer) -> bool {
	vertices := make([dynamic]Mesh_Vertex, context.temp_allocator)
	normal := Vec3{0, 0, 1}
	for index in -11..=11 {
		position := f32(index*10)
		append(&vertices, Mesh_Vertex{{position, -110, 0}, normal})
		append(&vertices, Mesh_Vertex{{position, 110, 0}, normal})
		append(&vertices, Mesh_Vertex{{-110, position, 0}, normal})
		append(&vertices, Mesh_Vertex{{110, position, 0}, normal})
	}
	renderer.grid_buffer = msg_id_ptr_u_u(
		renderer.device,
		sel_registerName("newBufferWithBytes:length:options:"),
		raw_data(vertices[:]),
		uint(len(vertices))*size_of(Mesh_Vertex),
		0,
	)
	renderer.grid_vertex_count = len(vertices)
	return renderer.grid_buffer != nil
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
	width, height: uint,
) -> bool {
	if renderer.depth_texture != nil &&
	   renderer.depth_width == width &&
	   renderer.depth_height == height {
		return true
	}
	descriptor := msg_id_u_u_u_bool(
		objc_getClass("MTLTextureDescriptor"),
		sel_registerName(
			"texture2DDescriptorWithPixelFormat:width:height:mipmapped:",
		),
		252,
		width,
		height,
		false,
	)
	msg_void_u(descriptor, sel_registerName("setStorageMode:"), 2)
	msg_void_u(descriptor, sel_registerName("setUsage:"), 4)
	next := msg_id_id(
		renderer.device,
		sel_registerName("newTextureWithDescriptor:"),
		descriptor,
	)
	if next == nil {return false}
	if renderer.depth_texture != nil {
		msg_void(renderer.depth_texture, sel_registerName("release"))
	}
	renderer.depth_texture = next
	renderer.depth_width = width
	renderer.depth_height = height
	return true
}

renderer_ensure_text_texture :: proc(
	renderer: ^Renderer,
	width, height: uint,
) -> bool {
	if renderer.text_texture != nil &&
	   renderer.texture_width == width &&
	   renderer.texture_height == height {
		return true
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
	next := msg_id_id(
		renderer.device,
		sel_registerName("newTextureWithDescriptor:"),
		descriptor,
	)
	if next == nil {return false}
	if renderer.text_texture != nil {
		msg_void(renderer.text_texture, sel_registerName("release"))
	}
	renderer.text_texture = next
	renderer.texture_width = width
	renderer.texture_height = height
	return true
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
	solids: []Solid_Vertex,
	text_pixels: []u8,
	width, height, scale: f64,
) -> Render_Result {
	if renderer.layer == nil {return .No_Layer}
	if width <= 0 || height <= 0 {return .Empty_Viewport}
	pixel_width := uint(max(1, width*scale))
	pixel_height := uint(max(1, height*scale))
	if !renderer_ensure_depth(renderer, pixel_width, pixel_height) {
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
		color = COLOR_COFFEE,
		light_dir = {-0.35, -0.45, 0.82, 0},
		camera = {eye.x, eye.y, eye.z, 1},
	}
	msg_void_id(
		encoder,
		sel_registerName("setDepthStencilState:"),
		renderer.depth_state,
	)
	msg_void_u(encoder, sel_registerName("setCullMode:"), 0)
	msg_void_u(
		encoder,
		sel_registerName("setTriangleFillMode:"),
		1 if wireframe else 0,
	)
	msg_void_id(
		encoder,
		sel_registerName("setRenderPipelineState:"),
		renderer.mesh_pipeline,
	)
	msg_void_id_u_u(
		encoder,
		sel_registerName("setVertexBuffer:offset:atIndex:"),
		renderer.mesh_buffer,
		0,
		0,
	)
	msg_void_ptr_u_u(
		encoder,
		sel_registerName("setVertexBytes:length:atIndex:"),
		&mesh_uniforms,
		size_of(Scene_Uniforms),
		1,
	)
	msg_void_u_u_u(
		encoder,
		sel_registerName("drawPrimitives:vertexStart:vertexCount:"),
		3,
		0,
		uint(renderer.mesh_vertex_count),
	)

	if face_hover >= 0 {
		a := mesh.vertices[face_hover*3].position
		n := vec3_normalize(vec3_cross(vec3_sub(mesh.vertices[face_hover*3+1].position,a), vec3_sub(mesh.vertices[face_hover*3+2].position,a)))
		tolerance := max(f32(0.00001),vec3_length(mesh_size(mesh.bounds))*0.000001)
		highlight := mesh_uniforms
		highlight.color = COLOR_SECTION
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
	grid_uniforms := Scene_Uniforms{
		mvp = mat4_mul(projection, view),
		model = mat4_identity(),
		color = Vec4{
			theme.muted.x,
			theme.muted.y,
			theme.muted.z,
			0.62,
		},
		light_dir = {0, 0, 1, 0},
	}
	msg_void_id(
		encoder,
		sel_registerName("setRenderPipelineState:"),
		renderer.line_pipeline,
	)
	msg_void_id_u_u(
		encoder,
		sel_registerName("setVertexBuffer:offset:atIndex:"),
		renderer.grid_buffer,
		0,
		0,
	)
	msg_void_ptr_u_u(
		encoder,
		sel_registerName("setVertexBytes:length:atIndex:"),
		&grid_uniforms,
		size_of(Scene_Uniforms),
		1,
	)
	msg_void_u_u_u(
		encoder,
		sel_registerName("drawPrimitives:vertexStart:vertexCount:"),
		1,
		0,
		uint(renderer.grid_vertex_count),
	)

	if renderer.section_vertex_count > 0 {
		section_uniforms := Scene_Uniforms{
			mvp = mat4_mul(projection, view),
			model = mat4_identity(),
			color = COLOR_SECTION,
			light_dir = {0, 0, 1, 0},
		}
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

	msg_void_viewport(
		encoder,
		sel_registerName("setViewport:"),
		{0, 0, f64(pixel_width), f64(pixel_height), 0, 1},
	)
	msg_void_id(
		encoder,
		sel_registerName("setDepthStencilState:"),
		renderer.ui_depth_state,
	)
	msg_void_id(
		encoder,
		sel_registerName("setRenderPipelineState:"),
		renderer.solid_pipeline,
	)
	max_vertices := 111
	for start := 0; start < len(solids); start += max_vertices {
		count := min(max_vertices, len(solids)-start)
		batch := solids[start:start+count]
		msg_void_ptr_u_u(
			encoder,
			sel_registerName("setVertexBytes:length:atIndex:"),
			raw_data(batch),
			uint(len(batch))*size_of(Solid_Vertex),
			0,
		)
		msg_void_u_u_u(
			encoder,
			sel_registerName("drawPrimitives:vertexStart:vertexCount:"),
			3,
			0,
			uint(len(batch)),
		)
	}

	if renderer_ensure_text_texture(renderer, pixel_width, pixel_height) &&
	   len(text_pixels) == int(pixel_width*pixel_height*4) {
		msg_void_region(
			renderer.text_texture,
			sel_registerName(
				"replaceRegion:mipmapLevel:withBytes:bytesPerRow:",
			),
			{{0, 0, 0}, {pixel_width, pixel_height, 1}},
			0,
			raw_data(text_pixels),
			pixel_width*4,
		)
		texture_vertices := [6]Texture_Vertex{
			{{-1, 1}, {0, 0}},
			{{1, 1}, {1, 0}},
			{{1, -1}, {1, 1}},
			{{-1, 1}, {0, 0}},
			{{1, -1}, {1, 1}},
			{{-1, -1}, {0, 1}},
		}
		msg_void_id(
			encoder,
			sel_registerName("setRenderPipelineState:"),
			renderer.texture_pipeline,
		)
		msg_void_ptr_u_u(
			encoder,
			sel_registerName("setVertexBytes:length:atIndex:"),
			raw_data(texture_vertices[:]),
			size_of(texture_vertices),
			0,
		)
		msg_void_id_u(
			encoder,
			sel_registerName("setFragmentTexture:atIndex:"),
			renderer.text_texture,
			0,
		)
		msg_void_u_u_u(
			encoder,
			sel_registerName("drawPrimitives:vertexStart:vertexCount:"),
			3,
			0,
			6,
		)
	}
	msg_void(encoder, sel_registerName("endEncoding"))
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
	return .Presented
}

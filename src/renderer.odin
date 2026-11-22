package main

import "core:fmt"
import "core:math"
import MTL "vendor:darwin/Metal"
import "rune:gpu"
import "rune:text"

foreign import metal "system:Metal.framework"
foreign metal {
	MTLCreateSystemDefaultDevice :: proc "c" () -> Id ---
}

Scene_Uniforms :: struct {
	mvp:             Mat4,
	model:           Mat4,
	color:           Vec4,
	arc_color:       Vec4, // a > 0 shades vertices with |normal| > 1.5 as G2/G3 arcs
	camera:          Vec4,
	view_projection: Mat4,
	params:          Vec4,
	viewport:        Vec4,
	sh:              [9]Vec4,
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
	mesh_pipeline:    Id,
	depth_pipeline: Id,
	line_pipeline:    Id,
	depth_state:       Id,
	ui_depth_state:    Id,
	mesh_buffer:      Id,
	section_buffer:   Id,
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
    float4 arc_color;
    float4 camera;
    float4x4 view_projection;
    float4 params;
    float4 viewport;
    float4 sh[9];
};

struct MeshOut {
    float4 position [[position]];
    float3 normal;
    float4 color;
    float3 world;
    float3 camera;
};

vertex MeshOut mesh_vertex(
    uint id [[vertex_id]],
    device const MeshVertex *vertices [[buffer(0)]],
    constant SceneUniforms &scene [[buffer(1)]]
) {
    MeshVertex source = vertices[id];
    float3 raw_n = float3(source.normal);
    bool is_arc = dot(raw_n, raw_n) > 2.25;
    MeshOut out;
    out.position = scene.mvp * float4(source.position, 1.0);
    out.normal = normalize((scene.model * float4(raw_n, 0.0)).xyz);
    out.color = (is_arc && scene.arc_color.a > 0.0) ? scene.arc_color : scene.color;
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

constexpr sampler environment_sampler(filter::linear, mip_filter::linear, s_address::repeat, t_address::clamp_to_edge);

static float3 environment_sample(texture2d<float> environment, float3 direction, float lod) {
	float2 uv = float2(atan2(direction.z, direction.x) * 0.15915494 + 0.5, acos(clamp(direction.y, -1.0, 1.0)) * 0.31830989);
	return environment.sample(environment_sampler, uv, level(lod)).rgb;
}

static float3 harmonics_irradiance(constant float4 *sh, float3 n) {
	return sh[0].xyz * 0.282095
		+ sh[1].xyz * (0.488603 * n.y) + sh[2].xyz * (0.488603 * n.z) + sh[3].xyz * (0.488603 * n.x)
		+ sh[4].xyz * (1.092548 * n.x * n.y) + sh[5].xyz * (1.092548 * n.y * n.z)
		+ sh[6].xyz * (0.315392 * (3.0 * n.z * n.z - 1.0)) + sh[7].xyz * (1.092548 * n.x * n.z)
		+ sh[8].xyz * (0.546274 * (n.x * n.x - n.y * n.y));
}

static float ambient_occlusion(MeshOut in, float3 normal, constant SceneUniforms &scene, depth2d<float> depth, int taps) {
    constexpr sampler nearest(filter::nearest, address::clamp_to_edge);
    float3 helper = abs(normal.z) < 0.99 ? float3(0,0,1) : float3(1,0,0);
    float3 tangent = normalize(cross(helper, normal));
    float3 bitangent = cross(normal, tangent);
    float radius = scene.params.z;
    float blocked = 0.0;
    float4 surface = scene.view_projection * float4(in.world, 1.0);
    float4 t_clip = scene.view_projection * float4(tangent * radius, 0.0);
    float4 b_clip = scene.view_projection * float4(bitangent * radius, 0.0);
    float4 n_clip = scene.view_projection * float4(normal * radius, 0.0);
    float near_z = scene.params.x, far_z = scene.params.y;
    float nf = near_z * far_z, fn = far_z - near_z;
    float phase = fract(dot(floor(in.position.xy), float2(0.75487766, 0.56984029))) * 6.2831853;
    float inv_taps = 1.0 / float(taps);
    for (int i = 0; i < taps; i++) {
        float step = (float(i) + 0.5) * inv_taps;
        float azimuth = float(i) * 2.39996 + phase;
        float lift = 0.14 + 0.86 * fract(step * 5.0);
        float flat = sqrt(1.0 - lift * lift);
        float scale = 0.2 + 0.8 * step;
        float4 clip = surface + (t_clip * (cos(azimuth) * flat) + b_clip * (sin(azimuth) * flat) + n_clip * lift) * scale;
        if (clip.w <= 0.0) {continue;}
        float2 local = float2(clip.x / clip.w * 0.5 + 0.5, 0.5 - clip.y / clip.w * 0.5);
        if (any(local < 0.0) || any(local >= 1.0)) {continue;}
        float2 uv = scene.viewport.xy + local * scene.viewport.zw;
        float stored = depth.sample(nearest, uv);
        if (stored >= 1.0) {continue;}
        float stored_distance = nf / (far_z - stored * fn);
        float gap = clip.w - stored_distance;
        float range = saturate(radius / max(abs(surface.w - stored_distance), 1e-3));
        blocked += (gap > radius * 0.04 ? 1.0 : 0.0) * range;
    }
    return 1.0 - 0.75 * blocked * inv_taps;
}

fragment float4 mesh_fragment(MeshOut in [[stage_in]],
    constant SceneUniforms &scene [[buffer(1)]],
    texture2d<float> environment [[texture(0)]],
    depth2d<float> depth [[texture(1)]]) {
    float3 normal = normalize(in.normal);
    float3 view = normalize(in.camera - in.world);
    if (dot(normal, view) < 0.0) {normal = -normal;}
    float n_dot_v = max(dot(normal, view), 1e-3);
    float3 albedo = in.color.rgb * in.color.rgb;
    // The source environment uses Y up; the slicer uses Z up.
    float3 environment_normal = normal.xzy;
    float3 reflected = reflect(-view, normal).xzy;
    float3 diffuse = albedo * max(harmonics_irradiance(scene.sh, environment_normal), 0.0);
    float roughness = 0.48;
    float levels = float(environment.get_num_mip_levels() - 1);
    float3 prefiltered = environment_sample(environment, reflected, roughness * min(levels, 6.0));
    prefiltered = mix(prefiltered, max(harmonics_irradiance(scene.sh, reflected), 0.0), smoothstep(0.1, 0.7, roughness));
    float2 brdf = environment_brdf(roughness, n_dot_v);
    float3 specular = prefiltered * (float3(0.04) * brdf.x + brdf.y);
    float3 color = tone_map(diffuse + specular);
    return float4(sqrt(color), in.color.a);
}

static float grid_line(float2 coord, float2 fw_world, float spacing, float width_px) {
    float2 p = coord / spacing;
    float2 fw = max(fw_world / spacing, float2(1e-4));
    float2 dist = abs(fract(p - 0.5) - 0.5);
    float2 half_w = fw * (width_px * 0.5);
    float2 cov = 1.0 - smoothstep(half_w - fw * 0.5, half_w + fw * 0.5, dist);
    float2 nyquist = saturate(1.0 - smoothstep(0.18, 0.55, fw));
    cov *= nyquist;
    return max(cov.x, cov.y);
}

fragment float4 floor_fragment(MeshOut in [[stage_in]],
    constant SceneUniforms &scene [[buffer(1)]],
    depth2d<float> depth [[texture(1)]],
    texture2d<float> scene_color [[texture(2)]]) {
    constexpr sampler nearest(filter::nearest, address::clamp_to_edge);
    constexpr sampler linear_sampler(filter::linear, address::clamp_to_edge);
    float2 fw_world = fwidth(in.world.xy);
    float4 surf = scene.view_projection * float4(in.world, 1.0);
    float2 surf_uv = float2(surf.x / surf.w * 0.5 + 0.5, 0.5 - surf.y / surf.w * 0.5);
    float2 d_tex = float2(1.0 / float(depth.get_width()), 1.0 / float(depth.get_height()));
    if (depth.sample(nearest, surf_uv) < in.position.z &&
        depth.sample(nearest, surf_uv + float2( d_tex.x, 0.0)) < in.position.z &&
        depth.sample(nearest, surf_uv + float2(-d_tex.x, 0.0)) < in.position.z &&
        depth.sample(nearest, surf_uv + float2(0.0,  d_tex.y)) < in.position.z &&
        depth.sample(nearest, surf_uv + float2(0.0, -d_tex.y)) < in.position.z) {
        return float4(in.color.rgb, 1.0);
    }
    float3 normal = float3(0, 0, 1);
    float shade = in.camera.z > 0.0 ? ambient_occlusion(in, normal, scene, depth, 8) : 1.0;
    float3 color = in.color.rgb * shade;

    // Analytic screen-space-derivative build-plate grid: 10 mm minor, 50 mm major, 220x220 mm border.
    float2 fw_safe = max(fw_world, float2(1e-4));
    float2 abs_xy = abs(in.world.xy);
    float2 inside_xy = 1.0 - smoothstep(float2(110.0) - fw_safe * 0.5, float2(110.0) + fw_safe * 0.5, abs_xy);
    float inside = inside_xy.x * inside_xy.y;
    float minor_g = grid_line(in.world.xy, fw_world, 10.0, 1.35) * inside;
    float major_g = grid_line(in.world.xy, fw_world, 50.0, 1.85) * inside;
    float2 b_dist = abs(abs_xy - float2(110.0));
    float2 b_half = fw_safe * 0.95;
    float2 b_cov = (1.0 - smoothstep(b_half - fw_safe * 0.5, b_half + fw_safe * 0.5, b_dist)) *
        (1.0 - smoothstep(float2(110.0), float2(110.0) + fw_safe * 1.5, abs_xy.yx));
    float border_g = max(b_cov.x, b_cov.y);
    float grid_alpha = max(max(minor_g * 0.22, major_g * 0.42), border_g * 0.52);
    color = mix(color, scene.arc_color.rgb * shade, grid_alpha);

    if (in.camera.z > 0.0) {
        float3 direction = reflect(normalize(in.world - in.camera), normal);
        float radius = scene.params.z;
        for (int i = 1; i <= 48; i++) {
            float distance = radius * 0.5 * float(i);
            float4 clip = scene.view_projection * float4(in.world + direction * distance, 1.0);
            if (clip.w <= 0.0) {break;}
            float2 local = float2(clip.x / clip.w * 0.5 + 0.5, 0.5 - clip.y / clip.w * 0.5);
            if (any(local < 0.0) || any(local >= 1.0)) {break;}
            float2 uv = scene.viewport.xy + local * scene.viewport.zw;
            float stored = depth.sample(nearest, uv);
            if (stored >= 1.0) {continue;}
            float near_z = scene.params.x, far_z = scene.params.y;
            float surface_distance = near_z * far_z / (far_z - stored * (far_z - near_z));
            float gap = clip.w - surface_distance;
            float thickness = radius * 0.65;
            if (gap > 0.0 && gap < thickness) {
                float edge = saturate(min(min(local.x, local.y), min(1.0-local.x, 1.0-local.y)) * 8.0);
                float fade = edge * (1.0 - float(i) / 48.0) * 0.24;
                color = mix(color, scene_color.sample(linear_sampler, uv).rgb, fade);
                break;
            }
        }
    }
    return float4(color, 1.0);
}

fragment float4 line_fragment(MeshOut in [[stage_in]]) {
    return in.color;
}

struct ResolveOut {
    float4 position [[position]];
    float2 uv;
};

vertex ResolveOut resolve_vertex(
    uint id [[vertex_id]],
    constant SceneUniforms &scene [[buffer(1)]]
) {
    const float2 corners[6] = {
        float2(0.0, 0.0), float2(1.0, 0.0), float2(1.0, 1.0),
        float2(0.0, 0.0), float2(1.0, 1.0), float2(0.0, 1.0),
    };
    float2 c = corners[id];
    ResolveOut out;
    out.position = float4(c.x * 2.0 - 1.0, 1.0 - c.y * 2.0, 0.0, 1.0);
    out.uv = scene.viewport.xy + c * scene.viewport.zw;
    return out;
}

// 2x2 Tent AA resolve over the 4x MSAA-resolved scene texture: four symmetric bilinear taps
// at +/-0.25 texels evaluate the exact 2x2 pixel tent kernel ([1/8, 6/8, 1/8] separable) in
// linear light, suppressing parallel print-line moire while preserving crisp silhouettes.
// Screen-space AO is applied once per display pixel from the 1x ao_depth buffer.
fragment float4 resolve_fragment(
    ResolveOut in [[stage_in]],
    constant SceneUniforms &scene [[buffer(1)]],
    depth2d<float> depth [[texture(1)]],
    texture2d<float> scene_color [[texture(2)]]
) {
    constexpr sampler nearest(filter::nearest, address::clamp_to_edge);
    constexpr sampler linear_s(filter::linear, address::clamp_to_edge);
    float w = float(scene_color.get_width());
    float h = float(scene_color.get_height());
    float2 texel = float2(1.0 / w, 1.0 / h);
    float2 o = texel * 0.25;
    float4 s0 = scene_color.sample(linear_s, in.uv + float2(-o.x, -o.y));
    float4 s1 = scene_color.sample(linear_s, in.uv + float2( o.x, -o.y));
    float4 s2 = scene_color.sample(linear_s, in.uv + float2(-o.x,  o.y));
    float4 s3 = scene_color.sample(linear_s, in.uv + float2( o.x,  o.y));
    float a_sum = s0.a + s1.a + s2.a + s3.a;
    if (a_sum <= 1e-4) { return float4(0.0); }
    float3 lin =
        (s0.rgb * s0.rgb) * s0.a +
        (s1.rgb * s1.rgb) * s1.a +
        (s2.rgb * s2.rgb) * s2.a +
        (s3.rgb * s3.rgb) * s3.a;
    float shade = 1.0;
    if (scene.params.w > 0.0) {
        float d0 = depth.sample(nearest, in.uv);
        if (d0 < 1.0) {
            float near_z = scene.params.x, far_z = scene.params.y, radius = scene.params.z;
            float nf = near_z * far_z, fn = far_z - near_z;
            float z0 = nf / (far_z - d0 * fn);
            float r_uv = clamp(radius / max(z0, 1e-3) * 1.15, 0.002, 0.04);
            float2 r_xy = float2(r_uv * (h / w), r_uv);
            float phase = fract(dot(floor(in.position.xy), float2(0.75487766, 0.56984029))) * 6.2831853;
            float blocked = 0.0;
            for (int i = 0; i < 8; i++) {
                float step = (float(i) + 0.5) / 8.0;
                float angle = float(i) * 2.39996 + phase;
                float2 uv_s = in.uv + float2(cos(angle), sin(angle)) * r_xy * (0.2 + 0.8 * step);
                float ds = depth.sample(nearest, uv_s);
                if (ds >= 1.0) {continue;}
                float zs = nf / (far_z - ds * fn);
                float diff = z0 - zs;
                float range = saturate(radius / max(abs(diff), 1e-3));
                blocked += (diff > radius * 0.04 ? 1.0 : 0.0) * range;
            }
            shade = 1.0 - 0.55 * blocked / 8.0;
        }
    }
    float3 rgb = sqrt((lin / a_sum) * shade);
    return float4(rgb, a_sum * 0.25);
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
		renderer.ao_depth,
		renderer.depth_texture,
		renderer.capture_texture,
		renderer.marker_buffer,
		renderer.section_buffer,
		renderer.mesh_buffer,
		renderer.ui_depth_state,
		renderer.depth_state,
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
		4,
	)
	renderer.floor_pipeline = renderer_build_pipeline(renderer, library, "mesh_vertex", "floor_fragment", true, false)
	if renderer.floor_pipeline == nil {return false}
	renderer.resolve_pipeline = renderer_build_pipeline(renderer, library, "resolve_vertex", "resolve_fragment", true, true, false)
	if renderer.resolve_pipeline == nil {return false}
	renderer.depth_pipeline = renderer_build_pipeline(renderer, library, "mesh_vertex", "", true, false)
	if renderer.depth_pipeline == nil {return false}
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
		color = COLOR_COFFEE,
		arc_color = COLOR_ARC if show_arcs else Vec4{},
		camera = {eye.x, eye.y, eye.z, 1},
		view_projection = mat4_mul(projection, view),
		params = {near_z, far_z, max(f32(0.1), vec3_length(size)*0.025), 0 if wireframe else 1},
		viewport = {0, 0, 1, 1},
		sh = renderer.harmonics,
	}
	cull_back := visual.is_design && !wireframe
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
	msg_void_id(prepass, sel_registerName("setRenderPipelineState:"), renderer.depth_pipeline)
	msg_void_id_u_u(prepass, sel_registerName("setVertexBuffer:offset:atIndex:"), renderer.mesh_buffer, 0, 0)
	msg_void_ptr_u_u(prepass, sel_registerName("setVertexBytes:length:atIndex:"), &mesh_uniforms, size_of(Scene_Uniforms), 1)
	renderer_draw_mesh(renderer, prepass, visual.finished_vertices, visual.partial)
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
	msg_void_id(scene_encoder, sel_registerName("setRenderPipelineState:"), renderer.mesh_pipeline)
	msg_void_id_u_u(scene_encoder, sel_registerName("setVertexBuffer:offset:atIndex:"), renderer.mesh_buffer, 0, 0)
	msg_void_ptr_u_u(scene_encoder, sel_registerName("setVertexBytes:length:atIndex:"), &mesh_uniforms, size_of(Scene_Uniforms), 1)
	msg_void_ptr_u_u(scene_encoder, sel_registerName("setFragmentBytes:length:atIndex:"), &mesh_uniforms, size_of(Scene_Uniforms), 1)
	msg_void_id_u(scene_encoder, sel_registerName("setFragmentTexture:atIndex:"), renderer.environment, 0)
	msg_void_id_u(scene_encoder, sel_registerName("setFragmentTexture:atIndex:"), renderer.ao_depth, 1)
	renderer_draw_mesh(renderer, scene_encoder, visual.finished_vertices, visual.partial, &mesh_uniforms, visual.highlight_start, COLOR_SECTION)
	if visual.marker_active {
		msg_void_u(scene_encoder, sel_registerName("setCullMode:"), 0)
		msg_void_id(scene_encoder, sel_registerName("setDepthStencilState:"), renderer.depth_state)
		renderer_draw_marker(renderer, scene_encoder, &mesh_uniforms, projection, view, model, visual.marker_pos, visual.marker_radius, COLOR_NOZZLE_MARKER)
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

	if renderer.section_vertex_count > 0 {
		section_uniforms := Scene_Uniforms{
			mvp = mat4_mul(projection, view),
			model = mat4_identity(),
			color = COLOR_SECTION,
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

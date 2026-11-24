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
    float4 selected_color;
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
    float n_len2 = dot(raw_n, raw_n);
    bool is_selected = n_len2 > 6.25;
    bool is_arc = !is_selected && n_len2 > 2.25;
    MeshOut out;
    out.position = scene.mvp * float4(source.position, 1.0);
    out.normal = normalize((scene.model * float4(raw_n, 0.0)).xyz);
    out.color = is_selected ? scene.selected_color : ((is_arc && scene.arc_color.a > 0.0) ? scene.arc_color : scene.color);
    out.world = (scene.model * float4(source.position, 1.0)).xyz;
    out.camera = scene.camera.xyz;
    return out;
}

struct GpuBead {
    float4 a;    // xyz = start, w = width
    float4 b;    // xyz = end,   w = height
    float4 meta; // x = fraction, y = is_arc, z = junction, w = unused
};

vertex MeshOut bead_vertex(
    uint id [[vertex_id]],
    device const GpuBead *beads [[buffer(0)]],
    constant SceneUniforms &scene [[buffer(1)]]
) {
    uint bead_idx = id / 36;
    uint local_id = id % 36;
    uint side_idx = local_id / 6;
    uint tri_v    = local_id % 6;

    GpuBead bead = beads[bead_idx];
    float3 a = bead.a.xyz;
    float3 b_pos = bead.b.xyz;
    float width = bead.a.w;
    float height = bead.b.w;
    float fraction = bead.meta.x;

    float3 end_p = a + (b_pos - a) * fraction;
    float3 along = float3(b_pos.x - a.x, b_pos.y - a.y, 0.0);
    float len = length(along);
    float3 dir = len > 1e-6 ? (along / len) : float3(1.0, 0.0, 0.0);
    float3 side = float3(-dir.y, dir.x, 0.0);
    float half_w = width * 0.5;
    float3 start_p = a - dir * half_w;
    float3 stop_p  = end_p + dir * half_w;
    float rnd = min(height * 0.42, half_w);

    const float2 profile[6] = {
        float2(-half_w + rnd, 0.0),
        float2( half_w - rnd, 0.0),
        float2( half_w,       height * 0.5),
        float2( half_w - rnd, height),
        float2(-half_w + rnd, height),
        float2(-half_w,       height * 0.5),
    };
    float2 p = profile[side_idx];
    float2 q = profile[(side_idx + 1) % 6];
    float2 mid = (p + q) * 0.5 - float2(0.0, height * 0.5);
    float3 raw_n = normalize(float3(side.x * mid.x, side.y * mid.x, -mid.y));

    bool use_stop = (tri_v == 1 || tri_v == 2 || tri_v == 4);
    bool use_q    = (tri_v == 2 || tri_v == 4 || tri_v == 5);
    float3 origin = use_stop ? stop_p : start_p;
    float2 prof   = use_q ? q : p;
    float3 pos    = float3(origin.x + side.x * prof.x, origin.y + side.y * prof.x, origin.z - prof.y);

    bool is_selected = (scene.camera.w >= 0.0 && abs(bead.meta.z - scene.camera.w) < 0.25);
    bool is_arc      = (!is_selected && bead.meta.y > 0.5);

    MeshOut out;
    out.position = scene.mvp * float4(pos, 1.0);
    out.normal   = normalize((scene.model * float4(raw_n, 0.0)).xyz);
    out.color    = is_selected ? scene.selected_color : ((is_arc && scene.arc_color.a > 0.0) ? scene.arc_color : scene.color);
    out.world    = (scene.model * float4(pos, 1.0)).xyz;
    out.camera   = scene.camera.xyz;
    return out;
}

struct ColoredBead {
    float4 a;     // xyz = start, w = width
    float4 b;     // xyz = end,   w = height
    float4 color; // rgba linear/srgb color for G-code preview modes
};

vertex MeshOut colored_bead_vertex(
    uint id [[vertex_id]],
    device const ColoredBead *beads [[buffer(0)]],
    constant SceneUniforms &scene [[buffer(1)]]
) {
    uint bead_idx = id / 36;
    uint local_id = id % 36;
    uint side_idx = local_id / 6;
    uint tri_v    = local_id % 6;

    ColoredBead bead = beads[bead_idx];
    float3 a = bead.a.xyz;
    float3 b_pos = bead.b.xyz;
    float width = bead.a.w;
    float height = bead.b.w;

    float3 along = float3(b_pos.x - a.x, b_pos.y - a.y, 0.0);
    float len = length(along);
    float3 dir = len > 1e-6 ? (along / len) : float3(1.0, 0.0, 0.0);
    float3 side = float3(-dir.y, dir.x, 0.0);
    float half_w = width * 0.5;
    float3 start_p = a - dir * half_w;
    float3 stop_p  = b_pos + dir * half_w;
    float rnd = min(height * 0.42, half_w);

    const float2 profile[6] = {
        float2(-half_w + rnd, 0.0),
        float2( half_w - rnd, 0.0),
        float2( half_w,       height * 0.5),
        float2( half_w - rnd, height),
        float2(-half_w + rnd, height),
        float2(-half_w,       height * 0.5),
    };
    float2 p = profile[side_idx];
    float2 q = profile[(side_idx + 1) % 6];
    float2 mid = (p + q) * 0.5 - float2(0.0, height * 0.5);
    float3 raw_n = normalize(float3(side.x * mid.x, side.y * mid.x, -mid.y));

    bool use_stop = (tri_v == 1 || tri_v == 2 || tri_v == 4);
    bool use_q    = (tri_v == 2 || tri_v == 4 || tri_v == 5);
    float3 origin = use_stop ? stop_p : start_p;
    float2 prof   = use_q ? q : p;
    float3 pos    = float3(origin.x + side.x * prof.x, origin.y + side.y * prof.x, origin.z - prof.y);

    MeshOut out;
    out.position = scene.mvp * float4(pos, 1.0);
    out.normal   = normalize((scene.model * float4(raw_n, 0.0)).xyz);
    out.color    = bead.color;
    out.world    = (scene.model * float4(pos, 1.0)).xyz;
    out.camera   = scene.camera.xyz;
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

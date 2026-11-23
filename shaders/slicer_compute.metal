#include <metal_stdlib>
using namespace metal;

struct PolyEdge {
    int64_t ax;
    int64_t ay;
    int64_t bx;
    int64_t by;
};

struct LayerEdgeRange {
    uint32_t offset;
    uint32_t count;
};

struct PointQuery {
    int64_t  x2;       // doubled micrometre X coordinate (matches bridge_polygon_contains_twice)
    int64_t  y2;       // doubled micrometre Y coordinate
    uint32_t layer_idx;
    uint32_t _pad;
};

// Exact integer winding-number / even-odd point-in-polygon kernel matching bridge_polygon_contains_twice.
// One GPU thread per query point.
kernel void batch_point_in_polygon(
    device const PolyEdge*       edges        [[buffer(0)]],
    device const LayerEdgeRange* layer_ranges [[buffer(1)]],
    device const PointQuery*     queries      [[buffer(2)]],
    device uint8_t*              results      [[buffer(3)]],
    constant uint32_t&           query_count  [[buffer(4)]],
    uint tid [[thread_position_in_grid]]
) {
    if (tid >= query_count) return;

    PointQuery q = queries[tid];
    LayerEdgeRange rng = layer_ranges[q.layer_idx];
    if (rng.count == 0) {
        results[tid] = 0;
        return;
    }

    int64_t px = q.x2;
    int64_t py = q.y2;
    int winding = 0;
    bool on_boundary = false;

    uint32_t end = rng.offset + rng.count;
    for (uint32_t i = rng.offset; i < end; i++) {
        PolyEdge e = edges[i];
        int64_t ax = e.ax * 2;
        int64_t ay = e.ay * 2;
        int64_t bx = e.bx * 2;
        int64_t by = e.by * 2;

        // Fast Y-band reject.
        int64_t min_y = min(ay, by);
        int64_t max_y = max(ay, by);
        if (py < min_y || py > max_y) continue;

        // Exact 64-bit integer cross product (coordinates are < 2^22 um, product < 2^44 << 2^63).
        int64_t dx = bx - ax;
        int64_t dy = by - ay;
        int64_t qx = px - ax;
        int64_t qy = py - ay;
        int64_t cross = dx * qy - dy * qx;

        if (cross == 0) {
            int64_t min_x = min(ax, bx);
            int64_t max_x = max(ax, bx);
            if (px >= min_x && px <= max_x) {
                on_boundary = true;
                break;
            }
        }

        if (ay <= py) {
            if (by > py && cross > 0) {
                winding += 1;
            }
        } else {
            if (by <= py && cross < 0) {
                winding -= 1;
            }
        }
    }

    results[tid] = (on_boundary || winding != 0) ? 1 : 0;
}

struct SlicePair {
    uint32_t tri_idx;
    uint32_t layer_idx;
};

struct SliceTriangle {
    float ax, ay, az;
    float bx, by, bz;
    float cx, cy, cz;
};

struct SliceSegOut {
    float    x0, y0;
    float    x1, y1;
    uint32_t valid;
    uint32_t _pad;
};

// Parallel triangle-plane intersection kernel: one GPU thread per (triangle, layer) candidate pair.
kernel void batch_triangle_plane_intersect(
    device const SliceTriangle* tris       [[buffer(0)]],
    device const float*         layer_z_mm [[buffer(1)]],
    device const SlicePair*     pairs      [[buffer(2)]],
    device SliceSegOut*         out_segs   [[buffer(3)]],
    constant uint32_t&          pair_count [[buffer(4)]],
    uint tid [[thread_position_in_grid]]
) {
    if (tid >= pair_count) return;
    SlicePair p = pairs[tid];
    SliceTriangle t = tris[p.tri_idx];
    float z = layer_z_mm[p.layer_idx];

    float3 v[3] = {
        float3(t.ax, t.ay, t.az),
        float3(t.bx, t.by, t.bz),
        float3(t.cx, t.cy, t.cz)
    };
    float2 hits[3];
    int hit_count = 0;

    for (int i = 0; i < 3; i++) {
        float3 a = v[i];
        float3 b = v[(i + 1) % 3];
        if ((a.z < z && b.z >= z) || (b.z < z && a.z >= z)) {
            float denom = b.z - a.z;
            if (fabs(denom) > 1e-9f) {
                float u = (z - a.z) / denom;
                hits[hit_count++] = float2(a.x + u * (b.x - a.x), a.y + u * (b.y - a.y));
            }
        }
    }

    if (hit_count == 2) {
        out_segs[tid] = {hits[0].x, hits[0].y, hits[1].x, hits[1].y, 1u, 0u};
    } else {
        out_segs[tid] = {0.0f, 0.0f, 0.0f, 0.0f, 0u, 0u};
    }
}

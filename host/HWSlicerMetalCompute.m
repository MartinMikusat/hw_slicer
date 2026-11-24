#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <os/lock.h>
#include <stdint.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>

typedef struct {
    int64_t ax, ay, bx, by;
} HWMetalPolyEdge;

typedef struct {
    uint32_t offset;
    uint32_t count;
} HWMetalLayerEdgeRange;

typedef struct {
    int64_t  x2;
    int64_t  y2;
    uint32_t layer_idx;
    uint32_t _pad;
} HWMetalPointQuery;

typedef struct {
    uint32_t tri_idx;
    uint32_t layer_idx;
} HWMetalSlicePair;

typedef struct {
    float ax, ay, az;
    float bx, by, bz;
    float cx, cy, cz;
} HWMetalSliceTriangle;

typedef struct {
    float    x0, y0, x1, y1;
    uint32_t valid;
    uint32_t _pad;
} HWMetalSliceSegOut;

typedef struct {
    int64_t  ax, ay;
    int64_t  bx, by;
    uint32_t layer_idx;
    uint32_t _pad;
} HWMetalTravelQuery;

static id<MTLDevice> g_device = nil;
static id<MTLCommandQueue> g_queue = nil;
static id<MTLComputePipelineState> g_pip_pso = nil;
static id<MTLComputePipelineState> g_tri_pso = nil;
static id<MTLComputePipelineState> g_trv_pso = nil;
static dispatch_once_t g_init_once = 0;

// Guarded by g_compute_lock.
static os_unfair_lock g_compute_lock = OS_UNFAIR_LOCK_INIT;
static id<MTLBuffer> g_buf_edges = nil;
static id<MTLBuffer> g_buf_ranges = nil;
static id<MTLBuffer> g_buf_pip_q = nil;
static id<MTLBuffer> g_buf_pip_out = nil;
static id<MTLBuffer> g_buf_trv_q = nil;
static id<MTLBuffer> g_buf_trv_out = nil;
static id<MTLBuffer> g_buf_tris = nil;
static id<MTLBuffer> g_buf_z = nil;
static id<MTLBuffer> g_buf_pairs = nil;
static id<MTLBuffer> g_buf_segs = nil;

static id<MTLBuffer> hw_metal_ensure_buffer(id<MTLBuffer> __strong *slot, size_t bytes) {
    if (bytes < 64) bytes = 64;
    if (*slot != nil && [*slot length] >= bytes) {
        return *slot;
    }
    size_t cap = bytes;
    if (*slot != nil) {
        size_t doubled = [*slot length] * 2;
        if (doubled > cap) cap = doubled;
    }
    *slot = [g_device newBufferWithLength:cap options:MTLResourceStorageModeShared];
    return *slot;
}

bool hw_metal_compute_init(const void *library, size_t library_length) {
    dispatch_once(&g_init_once, ^{
        @autoreleasepool {
            g_device = MTLCreateSystemDefaultDevice();
            if (!g_device) return;
            g_queue = [g_device newCommandQueue];
            if (!g_queue) return;

            if (!library || library_length == 0) return;
            dispatch_data_t data = dispatch_data_create(library, library_length, NULL,
                                                        DISPATCH_DATA_DESTRUCTOR_DEFAULT);
            NSError *err = nil;
            id<MTLLibrary> lib = [g_device newLibraryWithData:data error:&err];
            if (!lib) {
                fprintf(stderr, "[metal] shader library load failed: %s\n",
                        err ? err.localizedDescription.UTF8String : "unknown error");
                return;
            }
            id<MTLFunction> fn_pip = [lib newFunctionWithName:@"batch_point_in_polygon"];
            id<MTLFunction> fn_tri = [lib newFunctionWithName:@"batch_triangle_plane_intersect"];
            id<MTLFunction> fn_trv = [lib newFunctionWithName:@"batch_travel_crosses_exterior"];
            if (fn_pip) {
                g_pip_pso = [g_device newComputePipelineStateWithFunction:fn_pip error:&err];
                if (!g_pip_pso) {
                    fprintf(stderr, "[metal] pip PSO failed: %s\n",
                            err ? err.localizedDescription.UTF8String : "unknown error");
                }
            }
            if (fn_tri) {
                g_tri_pso = [g_device newComputePipelineStateWithFunction:fn_tri error:&err];
                if (!g_tri_pso) {
                    fprintf(stderr, "[metal] tri PSO failed: %s\n",
                            err ? err.localizedDescription.UTF8String : "unknown error");
                }
            }
            if (fn_trv) {
                g_trv_pso = [g_device newComputePipelineStateWithFunction:fn_trv error:&err];
                if (!g_trv_pso) {
                    fprintf(stderr, "[metal] trv PSO failed: %s\n",
                            err ? err.localizedDescription.UTF8String : "unknown error");
                }
            }
        }
    });
    return (g_device != nil && g_queue != nil &&
            g_pip_pso != nil && g_tri_pso != nil && g_trv_pso != nil);
}

// Starts hw_metal_compute_init on a background queue and returns at once. Creating the Metal
// device takes ~29 ms per process; a later init call waits on the same dispatch_once instead of
// paying it again. The library bytes must stay valid for the process (they are embedded).
void hw_metal_compute_warm_up(const void *library, size_t library_length) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        (void)hw_metal_compute_init(library, library_length);
    });
}

bool hw_metal_batch_point_in_polygon(
    const HWMetalPolyEdge *edges,
    uint32_t edge_count,
    const HWMetalLayerEdgeRange *layer_ranges,
    uint32_t layer_count,
    const HWMetalPointQuery *queries,
    uint32_t query_count,
    uint8_t *out_results
) {
    if (!g_device || !g_queue || !g_pip_pso || query_count == 0 || layer_count == 0) {
        return false;
    }
    os_unfair_lock_lock(&g_compute_lock);
    bool ok = false;
    @autoreleasepool {
        size_t edge_bytes = (size_t)(edge_count > 0 ? edge_count : 1) * sizeof(HWMetalPolyEdge);
        size_t range_bytes = (size_t)layer_count * sizeof(HWMetalLayerEdgeRange);
        size_t query_bytes = (size_t)query_count * sizeof(HWMetalPointQuery);
        size_t out_bytes = (size_t)query_count * sizeof(uint8_t);

        id<MTLBuffer> b_edges = hw_metal_ensure_buffer(&g_buf_edges, edge_bytes);
        id<MTLBuffer> b_ranges = hw_metal_ensure_buffer(&g_buf_ranges, range_bytes);
        id<MTLBuffer> b_queries = hw_metal_ensure_buffer(&g_buf_pip_q, query_bytes);
        id<MTLBuffer> b_out = hw_metal_ensure_buffer(&g_buf_pip_out, out_bytes);

        if (b_edges && b_ranges && b_queries && b_out) {
            if (edge_count > 0) memcpy([b_edges contents], edges, edge_bytes);
            memcpy([b_ranges contents], layer_ranges, range_bytes);
            memcpy([b_queries contents], queries, query_bytes);

            id<MTLCommandBuffer> cmd = [g_queue commandBuffer];
            id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
            [enc setComputePipelineState:g_pip_pso];
            [enc setBuffer:b_edges offset:0 atIndex:0];
            [enc setBuffer:b_ranges offset:0 atIndex:1];
            [enc setBuffer:b_queries offset:0 atIndex:2];
            [enc setBuffer:b_out offset:0 atIndex:3];
            [enc setBytes:&query_count length:sizeof(uint32_t) atIndex:4];

            NSUInteger tg_w = g_pip_pso.maxTotalThreadsPerThreadgroup;
            if (tg_w > 256) tg_w = 256;
            [enc dispatchThreads:MTLSizeMake(query_count, 1, 1) threadsPerThreadgroup:MTLSizeMake(tg_w, 1, 1)];
            [enc endEncoding];

            [cmd commit];
            [cmd waitUntilCompleted];
            if (cmd.status == MTLCommandBufferStatusCompleted) {
                memcpy(out_results, [b_out contents], out_bytes);
                ok = true;
            }
        }
    }
    os_unfair_lock_unlock(&g_compute_lock);
    return ok;
}

bool hw_metal_batch_triangle_plane_intersect(
    const HWMetalSliceTriangle *tris,
    uint32_t tri_count,
    const float *layer_z_mm,
    uint32_t layer_count,
    const HWMetalSlicePair *pairs,
    uint32_t pair_count,
    HWMetalSliceSegOut *out_segs
) {
    if (!g_device || !g_queue || !g_tri_pso || pair_count == 0 || tri_count == 0 || layer_count == 0) {
        return false;
    }
    os_unfair_lock_lock(&g_compute_lock);
    bool ok = false;
    @autoreleasepool {
        size_t tri_bytes = (size_t)tri_count * sizeof(HWMetalSliceTriangle);
        size_t z_bytes = (size_t)layer_count * sizeof(float);
        size_t pair_bytes = (size_t)pair_count * sizeof(HWMetalSlicePair);
        size_t out_bytes = (size_t)pair_count * sizeof(HWMetalSliceSegOut);

        id<MTLBuffer> b_tris = hw_metal_ensure_buffer(&g_buf_tris, tri_bytes);
        id<MTLBuffer> b_z = hw_metal_ensure_buffer(&g_buf_z, z_bytes);
        id<MTLBuffer> b_pairs = hw_metal_ensure_buffer(&g_buf_pairs, pair_bytes);
        id<MTLBuffer> b_out = hw_metal_ensure_buffer(&g_buf_segs, out_bytes);

        if (b_tris && b_z && b_pairs && b_out) {
            memcpy([b_tris contents], tris, tri_bytes);
            memcpy([b_z contents], layer_z_mm, z_bytes);
            memcpy([b_pairs contents], pairs, pair_bytes);

            id<MTLCommandBuffer> cmd = [g_queue commandBuffer];
            id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
            [enc setComputePipelineState:g_tri_pso];
            [enc setBuffer:b_tris offset:0 atIndex:0];
            [enc setBuffer:b_z offset:0 atIndex:1];
            [enc setBuffer:b_pairs offset:0 atIndex:2];
            [enc setBuffer:b_out offset:0 atIndex:3];
            [enc setBytes:&pair_count length:sizeof(uint32_t) atIndex:4];

            NSUInteger tg_w = g_tri_pso.maxTotalThreadsPerThreadgroup;
            if (tg_w > 256) tg_w = 256;
            [enc dispatchThreads:MTLSizeMake(pair_count, 1, 1) threadsPerThreadgroup:MTLSizeMake(tg_w, 1, 1)];
            [enc endEncoding];

            [cmd commit];
            [cmd waitUntilCompleted];
            if (cmd.status == MTLCommandBufferStatusCompleted) {
                memcpy(out_segs, [b_out contents], out_bytes);
                ok = true;
            }
        }
    }
    os_unfair_lock_unlock(&g_compute_lock);
    return ok;
}

bool hw_metal_batch_travel_crosses_exterior(
    const HWMetalPolyEdge *edges,
    uint32_t edge_count,
    const HWMetalLayerEdgeRange *layer_ranges,
    uint32_t layer_count,
    const HWMetalTravelQuery *queries,
    uint32_t query_count,
    uint8_t *out_results
) {
    if (!g_device || !g_queue || !g_trv_pso || query_count == 0 || layer_count == 0) {
        return false;
    }
    os_unfair_lock_lock(&g_compute_lock);
    bool ok = false;
    @autoreleasepool {
        size_t edge_bytes = (size_t)(edge_count > 0 ? edge_count : 1) * sizeof(HWMetalPolyEdge);
        size_t range_bytes = (size_t)layer_count * sizeof(HWMetalLayerEdgeRange);
        size_t query_bytes = (size_t)query_count * sizeof(HWMetalTravelQuery);
        size_t out_bytes = (size_t)query_count;

        id<MTLBuffer> b_edges = hw_metal_ensure_buffer(&g_buf_edges, edge_bytes);
        id<MTLBuffer> b_ranges = hw_metal_ensure_buffer(&g_buf_ranges, range_bytes);
        id<MTLBuffer> b_queries = hw_metal_ensure_buffer(&g_buf_trv_q, query_bytes);
        id<MTLBuffer> b_out = hw_metal_ensure_buffer(&g_buf_trv_out, out_bytes);

        if (b_edges && b_ranges && b_queries && b_out) {
            if (edge_count > 0) memcpy([b_edges contents], edges, edge_bytes);
            memcpy([b_ranges contents], layer_ranges, range_bytes);
            memcpy([b_queries contents], queries, query_bytes);

            id<MTLCommandBuffer> cmd = [g_queue commandBuffer];
            id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
            [enc setComputePipelineState:g_trv_pso];
            [enc setBuffer:b_edges offset:0 atIndex:0];
            [enc setBuffer:b_ranges offset:0 atIndex:1];
            [enc setBuffer:b_queries offset:0 atIndex:2];
            [enc setBuffer:b_out offset:0 atIndex:3];
            [enc setBytes:&query_count length:sizeof(uint32_t) atIndex:4];

            NSUInteger tg_w = g_trv_pso.maxTotalThreadsPerThreadgroup;
            if (tg_w > 256) tg_w = 256;
            [enc dispatchThreads:MTLSizeMake(query_count, 1, 1) threadsPerThreadgroup:MTLSizeMake(tg_w, 1, 1)];
            [enc endEncoding];

            [cmd commit];
            [cmd waitUntilCompleted];
            if (cmd.status == MTLCommandBufferStatusCompleted) {
                memcpy(out_results, [b_out contents], out_bytes);
                ok = true;
            }
        }
    }
    os_unfair_lock_unlock(&g_compute_lock);
    return ok;
}

// Runs both overhang point-in-polygon and travel exterior-crossing queries in one command buffer,
// uploading the shared polygon edges and layer ranges once.
bool hw_metal_batch_motion_queries(
    const HWMetalPolyEdge *edges,
    uint32_t edge_count,
    const HWMetalLayerEdgeRange *layer_ranges,
    uint32_t layer_count,
    const HWMetalPointQuery *pip_queries,
    uint32_t pip_count,
    uint8_t *pip_out,
    const HWMetalTravelQuery *trv_queries,
    uint32_t trv_count,
    uint8_t *trv_out
) {
    if (!g_device || !g_queue || !g_pip_pso || !g_trv_pso || layer_count == 0) {
        return false;
    }
    if (pip_count == 0 && trv_count == 0) {
        return true;
    }
    os_unfair_lock_lock(&g_compute_lock);
    bool ok = false;
    @autoreleasepool {
        size_t edge_bytes = (size_t)(edge_count > 0 ? edge_count : 1) * sizeof(HWMetalPolyEdge);
        size_t range_bytes = (size_t)layer_count * sizeof(HWMetalLayerEdgeRange);
        id<MTLBuffer> b_edges = hw_metal_ensure_buffer(&g_buf_edges, edge_bytes);
        id<MTLBuffer> b_ranges = hw_metal_ensure_buffer(&g_buf_ranges, range_bytes);

        id<MTLBuffer> b_pip_q = nil, b_pip_out = nil;
        if (pip_count > 0) {
            b_pip_q = hw_metal_ensure_buffer(&g_buf_pip_q, (size_t)pip_count * sizeof(HWMetalPointQuery));
            b_pip_out = hw_metal_ensure_buffer(&g_buf_pip_out, (size_t)pip_count);
        }
        id<MTLBuffer> b_trv_q = nil, b_trv_out = nil;
        if (trv_count > 0) {
            b_trv_q = hw_metal_ensure_buffer(&g_buf_trv_q, (size_t)trv_count * sizeof(HWMetalTravelQuery));
            b_trv_out = hw_metal_ensure_buffer(&g_buf_trv_out, (size_t)trv_count);
        }

        bool bufs_ok = (b_edges != nil && b_ranges != nil) &&
                       (pip_count == 0 || (b_pip_q != nil && b_pip_out != nil)) &&
                       (trv_count == 0 || (b_trv_q != nil && b_trv_out != nil));
        if (bufs_ok) {
            if (edge_count > 0) memcpy([b_edges contents], edges, edge_bytes);
            memcpy([b_ranges contents], layer_ranges, range_bytes);
            if (pip_count > 0) memcpy([b_pip_q contents], pip_queries, (size_t)pip_count * sizeof(HWMetalPointQuery));
            if (trv_count > 0) memcpy([b_trv_q contents], trv_queries, (size_t)trv_count * sizeof(HWMetalTravelQuery));

            id<MTLCommandBuffer> cmd = [g_queue commandBuffer];
            id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
            if (pip_count > 0) {
                [enc setComputePipelineState:g_pip_pso];
                [enc setBuffer:b_edges offset:0 atIndex:0];
                [enc setBuffer:b_ranges offset:0 atIndex:1];
                [enc setBuffer:b_pip_q offset:0 atIndex:2];
                [enc setBuffer:b_pip_out offset:0 atIndex:3];
                [enc setBytes:&pip_count length:sizeof(uint32_t) atIndex:4];
                NSUInteger tg_w = g_pip_pso.maxTotalThreadsPerThreadgroup;
                if (tg_w > 256) tg_w = 256;
                [enc dispatchThreads:MTLSizeMake(pip_count, 1, 1) threadsPerThreadgroup:MTLSizeMake(tg_w, 1, 1)];
            }
            if (trv_count > 0) {
                [enc setComputePipelineState:g_trv_pso];
                [enc setBuffer:b_edges offset:0 atIndex:0];
                [enc setBuffer:b_ranges offset:0 atIndex:1];
                [enc setBuffer:b_trv_q offset:0 atIndex:2];
                [enc setBuffer:b_trv_out offset:0 atIndex:3];
                [enc setBytes:&trv_count length:sizeof(uint32_t) atIndex:4];
                NSUInteger tg_w = g_trv_pso.maxTotalThreadsPerThreadgroup;
                if (tg_w > 256) tg_w = 256;
                [enc dispatchThreads:MTLSizeMake(trv_count, 1, 1) threadsPerThreadgroup:MTLSizeMake(tg_w, 1, 1)];
            }
            [enc endEncoding];

            [cmd commit];
            [cmd waitUntilCompleted];
            if (cmd.status == MTLCommandBufferStatusCompleted) {
                if (pip_count > 0) memcpy(pip_out, [b_pip_out contents], (size_t)pip_count);
                if (trv_count > 0) memcpy(trv_out, [b_trv_out contents], (size_t)trv_count);
                ok = true;
            }
        }
    }
    os_unfair_lock_unlock(&g_compute_lock);
    return ok;
}

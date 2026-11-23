#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <stdint.h>
#include <stdbool.h>
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

static id<MTLDevice> g_device = nil;
static id<MTLCommandQueue> g_queue = nil;
static id<MTLComputePipelineState> g_pip_pso = nil;
static id<MTLComputePipelineState> g_tri_pso = nil;
static bool g_initialized = false;

bool hw_metal_compute_init(const char *shader_source) {
    if (g_initialized) return (g_device != nil && g_pip_pso != nil);
    g_initialized = true;
    @autoreleasepool {
        g_device = MTLCreateSystemDefaultDevice();
        if (!g_device) return false;
        g_queue = [g_device newCommandQueue];
        if (!g_queue) return false;

        NSString *src = [NSString stringWithUTF8String:shader_source];
        NSError *err = nil;
        id<MTLLibrary> lib = [g_device newLibraryWithSource:src options:nil error:&err];
        if (!lib) {
            return false;
        }
        id<MTLFunction> fn_pip = [lib newFunctionWithName:@"batch_point_in_polygon"];
        id<MTLFunction> fn_tri = [lib newFunctionWithName:@"batch_triangle_plane_intersect"];
        if (fn_pip) {
            g_pip_pso = [g_device newComputePipelineStateWithFunction:fn_pip error:&err];
        }
        if (fn_tri) {
            g_tri_pso = [g_device newComputePipelineStateWithFunction:fn_tri error:&err];
        }
        return (g_pip_pso != nil);
    }
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
    @autoreleasepool {
        size_t edge_bytes = (size_t)(edge_count > 0 ? edge_count : 1) * sizeof(HWMetalPolyEdge);
        size_t range_bytes = (size_t)layer_count * sizeof(HWMetalLayerEdgeRange);
        size_t query_bytes = (size_t)query_count * sizeof(HWMetalPointQuery);
        size_t out_bytes = (size_t)query_count * sizeof(uint8_t);

        id<MTLBuffer> b_edges = edge_count > 0
            ? [g_device newBufferWithBytes:edges length:edge_bytes options:MTLResourceStorageModeShared]
            : [g_device newBufferWithLength:edge_bytes options:MTLResourceStorageModeShared];
        id<MTLBuffer> b_ranges = [g_device newBufferWithBytes:layer_ranges length:range_bytes options:MTLResourceStorageModeShared];
        id<MTLBuffer> b_queries = [g_device newBufferWithBytes:queries length:query_bytes options:MTLResourceStorageModeShared];
        id<MTLBuffer> b_out = [g_device newBufferWithLength:out_bytes options:MTLResourceStorageModeShared];

        if (!b_edges || !b_ranges || !b_queries || !b_out) return false;

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
        MTLSize grid = MTLSizeMake(query_count, 1, 1);
        MTLSize tg = MTLSizeMake(tg_w, 1, 1);
        [enc dispatchThreads:grid threadsPerThreadgroup:tg];
        [enc endEncoding];

        [cmd commit];
        [cmd waitUntilCompleted];
        if (cmd.status != MTLCommandBufferStatusCompleted) return false;

        memcpy(out_results, [b_out contents], out_bytes);
        return true;
    }
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
    @autoreleasepool {
        id<MTLBuffer> b_tris = [g_device newBufferWithBytes:tris length:(size_t)tri_count * sizeof(HWMetalSliceTriangle) options:MTLResourceStorageModeShared];
        id<MTLBuffer> b_z = [g_device newBufferWithBytes:layer_z_mm length:(size_t)layer_count * sizeof(float) options:MTLResourceStorageModeShared];
        id<MTLBuffer> b_pairs = [g_device newBufferWithBytes:pairs length:(size_t)pair_count * sizeof(HWMetalSlicePair) options:MTLResourceStorageModeShared];
        id<MTLBuffer> b_out = [g_device newBufferWithLength:(size_t)pair_count * sizeof(HWMetalSliceSegOut) options:MTLResourceStorageModeShared];

        if (!b_tris || !b_z || !b_pairs || !b_out) return false;

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
        if (cmd.status != MTLCommandBufferStatusCompleted) return false;

        memcpy(out_segs, [b_out contents], (size_t)pair_count * sizeof(HWMetalSliceSegOut));
        return true;
    }
}

# GPU-Accelerated Slicing Research

This note surveys published GPU-based 3D printing slicing, offsetting, distance
transform, and polygon-clipping methods, and evaluates what is usable in
`hw_slicer` on Apple Silicon (Metal).

## Synthesis and applicability to `hw_slicer`

Published GPU slicing work clusters into four paradigms:

1. **Ray-representation / dexel / A-buffer / LDNI slicing** — IceSL
   [@lefebvre2013icesl], Layered Depth-Normal Images [@wang2010ldni], chained
   segment offsetting [@martinez2015chained], and morphological enclosure
   sweeps [@hornus2015tight]. The GPU rasterizes or depth-peels the solid into
   per-pixel depth intervals and executes Booleans and inward/outward offsets
   as image-space morphological operations.
2. **Rasterization / stencil-buffer / reverse ray-tracing slicing** — continuous
   projection slicing [@wang2017towards] and stencil/depth-buffer + Marching
   Squares pipelines [@lai2021slicing]. Designed primarily for bitmap/DLP
   printers or large-scale AM where pixel grids are native output.
3. **GPU Euclidean distance transforms (EDT) for raster offsetting and medial
   axis** — Jump Flooding [@rong2006jump] and the exact Parallel Banding
   Algorithm [@cao2010parallel]. Compute 2D/3D distance fields on a pixel/voxel
   grid in milliseconds, turning offsetting into a threshold (`d <= r`) and
   exposing an integer medial axis.
4. **GPU exact vector polygon clipping** — CUDA edge-pair intersection in
   Greiner–Hormann [@zuo2025parallel]. Parallelizes the geometric intersection
   search while leaving linked-list topology reconstruction serial.

### What does NOT fit `hw_slicer`'s core FFF pipeline

- **Replacing the exact micrometre vector slicer with raster/ray-rep/LDNI GPU
  slicing.** `hw_slicer` operates on exact `i64` micrometre coordinates with
  deterministic pure-Odin Vatti Booleans and bit-exact G-code across
  `--threads=1`, 10 cores, and `--no-gpu`. At 1 µm resolution, a 300×300 mm
  build plate is 300,000×300,000 pixels (infeasible); even at 25–50 µm pixel
  pitch (6,000²–12,000²), rasterizing every slice, running Marching Squares,
  and applying topology-preserving contour simplification [@livesu2017from]
  introduces quantization error, thin-feature dropout, and higher memory
  traffic than `hw_slicer`'s current 10-core CPU vector stages (`20 ms`
  Intersections, `10 ms` Topology, `5 ms` Regions on Stanford bunny).
- **Offloading per-layer vector polygon clipping to Metal.** FFF layers
  typically contain 50–2,000 vertices per region—orders of magnitude smaller
  than GIS polygons where CUDA Greiner–Hormann [@zuo2025parallel] pays off.
  Greiner–Hormann also lacks Vatti's integer snap-rounding guarantees for
  coincident and self-intersecting offset rings.
- **Offloading triangle-plane intersection, solid scanlines, or Gyroid clipping
  to Metal.** Direct benchmarks in `docs/optimization-ledger.md` (`OPT-37`,
  `OPT-38`, `OPT-39`) confirmed that MSL's lack of native `f64`/`i128` breaks
  exact predicates or requires costly emulation, and 10 Apple Silicon CPU cores
  already reduce the raw compute below GPU dispatch/readback amortization.

### What IS potentially usable in `hw_slicer`

| Technique | Target feature in `hw_slicer` | Why it fits | Constraints |
|---|---|---|---|
| **Exact GPU EDT (`PBA`) + downward morphological sweep** [@cao2010parallel; @hornus2015tight] | **Supports & build-orientation / overhang optimization** | Support volumes and orientation scoring do not require 1 µm dimensional accuracy. A 100–200 µm grid on a 300 mm bed is 1500×1500–3000×3000 pixels, where Metal `PBA` runs in sub-millisecond time per layer and handles arbitrary concave overhangs without Vatti blowup. | Keep extracted support contours deterministic (fixed grid origin and resolution) or convert back to `i64` contours with documented tolerance. |
| **Ray-rep / GPU slice preview** [@lefebvre2013icesl; @martinez2015chained] | **Interactive CAD / CSG / Toolpath Design viewport preview** | Lets the UI preview boolean/offset edits and overhang heatmaps interactively on Metal while the exact CPU vector pipeline generates final G-code. | Preview-only; never the authority for G-code coordinates. |
| **Large flat batch queries (already shipped as `OPT-21`)** | **Whole-model motion queries (≥300k moves)** | Uniform, branch-free per-move workloads across 1M+ items amortize one Metal command buffer cleanly on unified memory. | Retain CPU fallback below the 300k-move threshold and keep `--no-gpu` byte-identical. |

---

<a id="lefebvre-2013-icesl-gpu-slicer"></a>
## Lefebvre 2013: IceSL GPU-accelerated CSG modeler and slicer

**Observed fact.** IceSL accepts CSG descriptions mixing meshes and analytic
primitives, converts them on the fly into a GPU ray-based representation
(bottom-up dexel/A-buffer), extracts slices directly on the GPU, and prepares
FFF toolpaths via image-space erosion; the same GPU code path powers both
interactive preview and slicing [@lefebvre2013icesl].

**Interpretation.** IceSL proves that a full production FFF slicer can run
predominantly on the GPU if the entire representation shifts from exact vector
polygons to sampled ray/image buffers. The trade-off is fixed spatial sampling
resolution and pixel-stepped contours that must be vectorized and simplified.

**Project use.** Background architecture reference. Do not replace `hw_slicer`'s
exact micrometre vector pipeline with image-space erosion; consider the shared
GPU preview paradigm only for interactive non-authoritative viewport feedback.

**Open check.** If `hw_slicer` adds CSG or implicit primitives in Toolpath
Design, evaluate whether GPU ray-casting preview is needed alongside CPU exact
evaluation.

<a id="wang-chen-2010-ldni-gpu-solid-modeling"></a>
## Wang and Chen 2010: Layered Depth-Normal Images on the GPU

**Observed fact.** Solids are represented by three orthogonal Layered
Depth-Normal Images (LDNIs) sampled via GPU depth peeling, storing depth and
surface normal at every ray-surface intersection; Boolean operations and
offsetting operate directly on the 1D ray intervals without mesh
self-intersection failures [@wang2010ldni].

**Interpretation.** LDNIs solve robustness problems for dirty or CSG meshes by
trading exact boundary representation for sampled ray intersections. For FFF
slicing, sampling resolution dictates thin-wall survival and memory footprint,
which scales with surface area and grid density.

**Project use.** Rejected as the core slicing representation because `hw_slicer`
requires exact `i64` micrometre vector contours and already repairs meshes in
`stage_model` (`OPT-18`). Useful background if a future feature requires robust
CSG Booleans on heavily self-intersecting input meshes.

**Open check.** None for the core FFF vector pipeline.

<a id="martinez-et-al-2015-chained-segment-offsetting"></a>
## Martínez et al. 2015: chained segment offsetting for ray-based solids

**Observed fact.** Morphological dilation and erosion of a solid are decomposed
into a sequence of 1D segment operations (forming a zonotope approximation of
the Euclidean ball with bounded error) executed directly on a GPU ray-based
solid representation without reconstructing an intermediate boundary mesh
[@martinez2015chained].

**Interpretation.** Chaining 1D segment offsets maps cleanly to GPU compute and
supports arbitrary opening/closing sequences (hollowing, molds, shell
thickness). However, the structuring element is a zonotope rather than an exact
Euclidean circle/sphere, and the output remains a sampled ray-rep.

**Project use.** Background for 3D hollowing or mold/shell generation. Not
suitable for exact 2D FFF perimeter offsetting where exact circular/mitered
joins at 1 µm precision are required.

**Open check.** Revisit only if 3D volumetric hollowing or morphological mesh
cleaning is added to the model preparation stage.

<a id="hornus-et-al-2015-tight-printable-enclosures"></a>
## Hornus et al. 2015: tight printable enclosures and support structures

**Observed fact.** A top-down slice-by-slice sweep computes minimal
self-supporting enclosures and support volumes using planar morphological
dilation and erosion between adjacent layers (`W|z ↓ r ⊂ W|z0` for overhang
angle `θ` and `r = Δz tan θ`) [@hornus2015tight].

**Interpretation.** Because the algorithm depends only on 2D slice erosion,
dilation, and union—and support geometry tolerates 100–200 µm discretization—it
is one of the few FFF slicing sub-problems that maps naturally to a GPU raster
or exact EDT (`PBA`) pass without compromising part dimensional accuracy.

**Project use.** Candidate algorithm for future support-structure generation
and build-orientation overhang volume estimation.

**Open check.** Benchmark Metal `PBA`-based downward sweep against CPU Vatti
offsetting once full support generation is prioritized.

<a id="rong-tan-2006-jump-flooding-gpu"></a>
## Rong and Tan 2006: Jump Flooding Algorithm on the GPU

**Observed fact.** Jump Flooding (JFA) computes approximate 2D Voronoi diagrams
and Euclidean distance transforms on the GPU in `O(log N)` passes with constant
work per pixel per pass by halving neighbor step sizes from `N/2` down to `1`
[@rong2006jump].

**Interpretation.** JFA is simple to implement in a Metal compute shader and
fast for approximate distance fields and Voronoi infills, but it can leave
localized exactness errors on a small fraction of pixels.

**Project use.** Background only; prefer the exact Parallel Banding Algorithm
[@cao2010parallel] over JFA whenever a GPU distance transform is used for
geometry that feeds toolpaths or supports.

**Open check.** None.

<a id="cao-et-al-2010-parallel-banding-gpu-dt"></a>
## Cao et al. 2010: Parallel Banding Algorithm for exact GPU EDT

**Observed fact.** The Parallel Banding Algorithm (PBA) computes the exact
Euclidean Distance Transform (EDT) of a 2D or 3D binary grid on the GPU in
optimal linear total work by partitioning rows/columns into bands, computing
local proximate sites, and merging concurrently; it is both exact and faster
than JFA in experiments, and supports integer medial-axis extraction and
morphological operations [@cao2010parallel].

**Interpretation.** PBA removes JFA's approximation errors while keeping GPU
speed. On Apple Silicon unified memory, a Metal PBA kernel can compute exact
discrete offsets and integer medial axes for coarse-grid tasks (supports,
overhangs, thin-wall heuristics) in under a millisecond per slice.

**Project use.** Candidate GPU primitive for coarse-grid support sweeps
[@hornus2015tight] or interactive overhang/medial-axis overlays. Not adopted
for exact 1 µm perimeter offsetting.

**Open check.** Prototype a Metal PBA shader only when a coarse-grid feature
(such as morphological supports or interactive thin-wall visualization) enters
active development.

<a id="livesu-et-al-2017-3d-printing-pipeline"></a>
## Livesu et al. 2017: processing pipeline overview for 3D printing

**Observed fact.** This Eurographics state-of-the-art report surveys the full
additive manufacturing process-planning pipeline, explicitly contrasting mesh
slicing against GPU ray-rep/dexel/LDNI slicing (Section 3.4.2.2) and
documenting that ray-rep contours contain dense pixel-stepped segments
requiring topology-preserving simplification, with memory scaling with surface
area and grid resolution [@livesu2017from].

**Interpretation.** Confirms from a broad literature synthesis why industrial
exact-tolerance FFF slicers remain vector-based while GPU ray-reps excel at
CSG Booleans, dirty-mesh regulation, volumetric hollowing, and GPU orientation
scoring.

**Project use.** Background reference governing architectural boundaries
between exact CPU vector stages and optional GPU raster/batch stages.

**Open check.** None.

<a id="wang-et-al-2017-gpu-continuous-slicing"></a>
## Wang et al. 2017: GPU-enabled slicing for continuous 3D printing

**Observed fact.** Decomposes image-mask-projection continuous 3D printing
(DLP/CLIP) slicing into ray-triangle intersection, per-pixel trunk sorting, and
layer bitmap extraction, proposing Pixelwise Parallel Slicing (PPS, one thread
per pixel using shared memory) and Fully Parallel Slicing (FPS, fine-grained
concurrency with atomics) [@wang2017towards].

**Interpretation.** Demonstrates large GPU speedups when the printer natively
consumes 2D pixel masks (SLA/DLP/CLIP). Those speedups do not transfer directly
to vector FFF slicing because FFF requires closed, simplified, exact-coordinate
polylines rather than projection bitmaps.

**Project use.** Rejected for `hw_slicer`'s FFF pipeline (no bitmap projection
output).

**Open check.** None.

<a id="lai-wei-2021-gpu-slicing-partition-scanning"></a>
## Lai and Wei 2021: GPU parallel slicing and partition scanning

**Observed fact.** Uses GPU projection matrices, stencil/depth buffers, and
reverse ray tracing to acquire per-layer voxel slices in parallel, extracts
contours via Marching Squares, fits NURBS curves, and partitions scan areas for
large-scale additive manufacturing (such as EBAM) [@lai2021slicing].

**Interpretation.** Illustrates the standard GPU raster-to-contour pattern
(stencil buffer + Marching Squares + curve fitting). Every step introduces
sampling and fitting approximation, which is acceptable for raster/beam scan
partitioning at coarse tolerances but conflicts with `hw_slicer`'s exact
integer FFF contract.

**Project use.** Rejected for `hw_slicer`'s core slicing stages.

**Open check.** None.

<a id="zuo-et-al-2025-cuda-greiner-hormann-clipping"></a>
## Zuo et al. 2025: CUDA parallel Greiner–Hormann polygon clipping

**Observed fact.** Parallelizes the edge-edge intersection calculation step of
the Greiner–Hormann 2D polygon clipping algorithm on CUDA by mapping edge pairs
to GPU threads, reporting substantial speedups on large polygonal datasets
[@zuo2025parallel].

**Interpretation.** Shows that even in vector polygon clipping, only the
broad-phase/pairwise intersection stage parallelizes cleanly on GPUs, while
linked-list topology traversal remains sequential. For FFF layers (50–2,000
vertices per region, already processed concurrently across 10 CPU cores by
`hw_slicer`'s Vatti kernel), per-polygon vertex counts are too small to
amortize GPU launch/readback, and Greiner–Hormann lacks integer snap-rounding
for degenerate/coincident FFF offset edges.

**Project use.** Rejected for `hw_slicer`'s polygon kernel. Retain multi-core
per-layer CPU Vatti (`OPT-10`, `OPT-31`).

**Open check.** None.

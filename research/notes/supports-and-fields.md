# Supports and Fields

This note tracks grid transforms, overhang analysis, and disposable support
geometry. Printer limits remain calibrated inputs, not universal constants.

<a id="felzenszwalb-huttenlocher-2012-distance-transforms"></a>
## Felzenszwalb and Huttenlocher 2012: distance transforms

**Observed fact.** The squared Euclidean transform executes as separable
one-dimensional lower-envelope passes [@felzenszwalb2012distance].

**Interpretation.** Rows and columns can use independent work ranges. The output
stores exact squared grid distances under the sampled model.

**Project use.** Use this method as the CPU oracle for infill distance, clearance,
and support influence fields.

**Open check.** Bound geometric error from conservative rasterization and grid
resolution before comparing CPU and Metal outputs.

<a id="meijster-2000-linear-distance-transform"></a>
## Meijster, Roerdink, and Hesselink 2000: linear distance transform

**Observed fact.** The algorithm performs a vertical scan and a horizontal
lower-envelope phase in linear time [@meijster2000general].

**Interpretation.** Its phases map to structure-of-arrays storage. A GPU version
must still pay for strided access or transposition.

**Project use.** Benchmark this formulation beside the Felzenszwalb–Huttenlocher
method under one input and output contract.

**Open check.** Measure transpose traffic, threadgroup occupancy, and integer
range on representative layer grids.

<a id="dumas-2014-bridging-the-gap"></a>
## Dumas, Hergel, and Lefebvre 2014: bridge scaffolds

**Observed fact.** The method connects pillars with printable bridges and checks
stability during intermediate print states [@dumas2014bridging].

**Interpretation.** A support planner must process the printed prefix. Final
model connectivity cannot prove intermediate stability.

**Project use.** Retain this as the bridge-aware support candidate after a
vertical-support baseline passes physical calibration.

**Open check.** Print bridge-length, speed, temperature, and cooling fixtures for
each supported printer profile.

<a id="vanek-2014-clever-support"></a>
## Vanek, Galicia, and Benes 2014: tree supports

**Observed fact.** The method samples overhangs, builds feasible support cones,
and greedily merges branches [@vanek2014clever].

**Interpretation.** The cone converts a printer angle constraint into a geometric
feasibility test. The merge remains heuristic.

**Project use.** Adopt support cones and parameter calibration. Benchmark the
greedy tree against vertical and bridge-aware supports.

**Open check.** Measure material, time, failure rate, removal effort, and surface
damage. A single material metric cannot select the method.

<a id="hu-2015-support-slimming"></a>
## Hu, Jin, and Wang 2015: support slimming

**Observed fact.** The optimization changes orientation and local model geometry
to reduce support demand [@hu2015support].

**Interpretation.** The method belongs to design assistance because it changes
the imported shape.

**Project use.** Use its objective terms for orientation research. Do not deform
production inputs without an explicit user operation.

**Open check.** Define acceptable geometric deviation before any design-assist
prototype begins.

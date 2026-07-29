# Geometry and Topology

This note tracks numerical and topological methods that can change the sliced
result. Each method needs a deterministic contract and an executable oracle.

<a id="shewchuk-1997-adaptive-predicates"></a>
## Shewchuk 1997: adaptive predicates

**Observed fact.** The method evaluates a floating-point predicate, calculates
an error bound, and escalates uncertain signs to floating-point expansions
[@shewchuk1997adaptive].

**Interpretation.** Most triangle-plane and segment predicates can remain on a
fast path. Near-degenerate cases pay for additional precision.

**Project use.** Implement orientation and classification predicates behind one
CPU API. Record every escalation by operation and input class.

**Open check.** Compare scalar Odin, NEON-assisted arithmetic, and a known
reference implementation on adversarial coordinates.

<a id="vatti-1992-polygon-clipping"></a>
## Vatti 1992: polygon clipping

**Observed fact.** The algorithm advances a scanbeam through ordered edge events
and updates winding state to construct arbitrary polygon results
[@vatti1992generic].

**Interpretation.** One event model can support union, intersection, difference,
and xor. Coincident events still need a project-specific ordering rule.

**Project use.** Build a small prototype against the same contour corpus as an
arrangement-based reference. Compare topology, runtime, and implementation size.

**Open check.** Define horizontal-edge, touching-vertex, duplicate-edge, and
zero-area output policies before selecting the production kernel.

<a id="campen-kobbelt-2010-self-intersections"></a>
## Campen and Kobbelt 2010: mesh self-intersections

**Observed fact.** An adaptive octree localizes intersections. Plane-based BSP
operations then execute only in critical cells [@campen2010exact].

**Interpretation.** The project can separate cheap detection from expensive
repair. This keeps clean meshes on a short path.

**Project use.** Adopt localization, critical-cell reporting, and precision
bounds. Defer the full BSP repair stage.

**Open check.** Measure how coordinate quantization changes layer contours at
the target printer resolution.

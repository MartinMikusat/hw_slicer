# Parallelism and Apple Silicon

This note tracks parallel construction, compaction, CPU coordination, ABI rules,
and Metal execution on Apple Silicon.

<a id="karras-2012-parallel-bvh"></a>
## Karras 2012: parallel hierarchy construction

**Observed fact.** Each internal radix-tree node derives its range and children
from sorted Morton codes without processing tree levels in sequence
[@karras2012maximizing].

**Interpretation.** Construction exposes broad parallelism. Morton ordering also
sets the output layout and influences traversal locality.

**Project use.** Prototype this method for a layer acceleration structure. Keep
simple z-interval buckets as the baseline.

**Open check.** Compare complete build-plus-query time on representative meshes.
Do not select a hierarchy from construction time alone.

<a id="merrill-garland-2016-prefix-scan"></a>
## Merrill and Garland 2016: decoupled look-back scan

**Observed fact.** The scan performs bounded redundant work to avoid a separate
global prefix pass [@merrill2016singlepass].

**Interpretation.** One pass reduces external memory traffic. Publication state
and forward progress become part of correctness.

**Project use.** Establish a two-pass Metal scan first. Port decoupled look-back
only after the baseline exposes a material bottleneck.

**Open check.** Prove state transitions against Metal atomics and test all
supported Apple GPU families.

<a id="michael-scott-1996-concurrent-queues"></a>
## Michael and Scott 1996: concurrent queues

**Observed fact.** The paper presents a compare-and-swap queue and a two-lock
queue with concurrent enqueue and dequeue [@michael1996queues].

**Interpretation.** Pointer transitions, progress, memory reclamation, and memory
ordering form one contract.

**Project use.** Prefer bounded ownership queues for the first job system. Use
this paper to audit any later non-blocking design.

**Open check.** Map each atomic edge to ARM64 acquire-release operations and
validate with stress tests on Apple Silicon.

<a id="arm-aapcs64-release-2025q4"></a>
## Arm AAPCS64 release asset

**Observed fact.** AAPCS64 defines AArch64 register roles, stack alignment,
aggregate layout, and call boundaries [@arm2025aapcs64].

**Interpretation.** Odin, C, Objective-C, and hand-written assembly exchange
values through this contract.

**Project use.** Review every assembly helper and callback trampoline against the
standard. Keep register assignments visible beside the boundary code.

**Source discrepancy.** The 2025Q4 release asset is labeled 2025Q1 internally.
The repository source identifies 2025Q4. Keep both facts in release records.

<a id="apple-metal-shading-language-4-1"></a>
## Metal Shading Language 4.1

**Observed fact.** The specification defines address spaces, atomics, barriers,
resource types, and compute-kernel attributes [@apple2026msl41].

**Interpretation.** A kernel's memory transitions must match its buffer bindings
and barrier scopes. A barrier cannot repair an incorrect ownership model.

**Project use.** Treat this document as the language authority. Build CPU oracles
for every topology-changing kernel.

**Open check.** Record compiler, language version, GPU family, and pipeline
options with each benchmark.

<a id="apple-metal-feature-tables-2026-05-21"></a>
## Metal feature tables, May 21, 2026

**Observed fact.** The tables map features and limits to Metal programming models
and Apple GPU families [@apple2026metalfeatures].

**Interpretation.** Dispatch width, atomics, limits, and fallback selection must
derive from the active device.

**Project use.** Generate a compact runtime capability record and attach it to
benchmark and failure artifacts.

**Open check.** Compare the reviewed checksum with Apple's current PDF during
each toolchain update.

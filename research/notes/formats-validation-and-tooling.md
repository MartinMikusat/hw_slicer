# Formats, Validation, and Tooling

This note tracks file contracts, output languages, test generation, failure
reduction, implementation tools, and distribution.

<a id="claessen-hughes-2000-quickcheck"></a>
## Claessen and Hughes 2000: property-based testing

**Observed fact.** QuickCheck combines executable properties with generated
structured inputs and reduced counterexamples [@claessen2000quickcheck].

**Interpretation.** A generator encodes valid structure. A property checks a
behavior that should hold across many generated cases.

**Project use.** Build deterministic generators and shrinkers for meshes, 3MF
packages, contours, schedules, and G-code blocks.

**Open check.** Store the seed, generator version, toolchain, and minimized input
with every failure.

<a id="zeller-hildebrandt-2002-delta-debugging"></a>
## Zeller and Hildebrandt 2002: delta debugging

**Observed fact.** Delta debugging partitions input and retains subsets or
differences that preserve a stable failure [@zeller2002simplifying].

**Interpretation.** The test oracle must distinguish pass, fail, and unresolved.
Non-deterministic failures require stabilization first.

**Project use.** Reduce package entries, mesh components, layer ranges, contour
sets, and G-code command ranges.

**Open check.** Preserve structural validity during reduction when a raw byte
reducer would destroy the parser path under test.

<a id="kramer-2000-rs274ngc"></a>
## NISTIR 6556: RS274/NGC

**Observed fact.** The interpreter parses blocks, updates modal state, and emits
canonical machining functions [@kramer2000rs274ngc].

**Interpretation.** Syntax, modal evaluation, and machine action can use separate
stages with explicit data contracts.

**Project use.** Define a G-code intermediate representation and layer
firmware-specific FFF commands over it.

**Open check.** Build dialect profiles from printer firmware documentation and
golden output, not from one assumed universal G-code language.

<a id="3mf-core-1-3-0"></a>
## 3MF Core 1.3.0

**Observed fact.** The specification defines ZIP package relationships, XML
resources, components, meshes, units, transforms, and conformance
[@threeMF2021core].

**Interpretation.** The reader must resolve package and resource graphs before it
emits triangles.

**Project use.** Implement 1.3.0 as the first versioned parser contract. Reject
unsafe paths, expansion limits, unresolved references, and component cycles.

**Open check.** Audit the 1.4.0 source revision and record every parser change
before claiming support for that version.

<a id="odin-project-documentation"></a>
## Odin project documentation

**Observed fact.** The live documentation defines the language, packages,
allocators, foreign imports, and build behavior [@odin2026documentation].

**Interpretation.** Documentation describes intent. The pinned compiler and
automated tests determine actual project behavior.

**Project use.** Keep allocators and lifetimes explicit. Verify each FFI boundary
against its platform ABI and framework ownership rules.

**Open check.** Record the compiler revision beside language-dependent decisions.

<a id="apple-notarization-documentation"></a>
## Apple notarization documentation

**Observed fact.** Apple's flow signs the complete artifact, submits it, waits
for acceptance, staples the ticket, and validates distribution behavior
[@apple2026notarization].

**Interpretation.** Signing an intermediate build cannot validate the delivered
archive.

**Project use.** Apply this source when the shared release system is implemented.
Keep credentials outside the repository.

**Open check.** Record tool versions, submission identifiers, stapling results,
and Gatekeeper assessment for each release.

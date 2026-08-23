# HW Slicer evidence bundle contract

This note records the first `.hwsdebug` bundle contract for
[`hw_slicer`](../README.md). It does not select unresolved product
policy.

The project plan already selects two container forms:

- Use a directory during development.
- Use a ZIP package for transfer.

The root schema, deterministic ZIP writer, package encoder, package validator,
and development-directory publisher are implemented.

## Observed implementation

The engine has validated topology, region, and path-plan stage manifests and
replay primitives. It also has a canonical path-plan layer SVG. The standalone
validators replay all three stages without the source model.

[`bounded_zip.odin`](../src/formats/bounded_zip.odin) already checks
these ZIP properties:

- Source, entry, path, total byte, and compression-ratio limits.
- Traversal, absolute, duplicate, invalid UTF-8, and control-character paths.
- Local and central record agreement.
- Overlapping local records.
- Supported flags and compression methods.
- CRC-32 after extraction.
- Multi-disk and ZIP64 rejection.

[`bundle.odin`](../src/evidence/bundle.odin) implements root bundle
manifest schema 1. It binds the request, source root, ordered stage manifests,
aggregate summary, and every payload descriptor. It requires each stage
manifest and payload to use its `stages/NN-name/` directory.

[`stored_zip_writer.odin`](../src/formats/stored_zip_writer.odin)
writes deterministic stored ZIP data.

[`bundle_package.odin`](../src/evidence/bundle_package.odin) binds
content to root descriptors, validates stage identity and ownership, writes the
root manifest, and packages the complete bundle. Its inverse validator rejects
unlisted or missing entries and verifies every byte count and SHA-256 before it
checks stage-manifest semantics. It also decodes and verifies declared
topology, region, and path-plan primitives.

[`bundle_directory.odin`](../src/evidence/bundle_directory.odin)
writes descriptor-backed content beneath a private sibling staging directory.
It validates the exact staged tree, synchronizes each file and directory, and
uses `RENAME_EXCL` to publish only to an absent destination.

## Implemented directory layout

Use root-relative paths in all manifests.

```text
capture.hwsdebug/
  manifest.json
  summary.json
  stages/
    07-reconstruct-topology/
      manifest.json
      primitives/
        topology.bin
    08-calculate-regions/
      manifest.json
      primitives/
        regions.bin
    10-plan-paths/
      manifest.json
      primitives/
        path-plan.bin
      renders/
        layer-000538.svg
```

Use the two-digit pipeline ordinal to preserve stage order. Keep the stage name
in the directory for direct inspection.

The region artifact follows the topology artifact because regions reference
topology path indexes.

## Implemented root manifest

Schema version 1 stores these root fields:

- Bundle schema version.
- Slice request hash.
- Source root stable ID.
- Ordered stage descriptors.
- Root-relative stage manifest paths.
- Byte count and SHA-256 for each stage manifest.
- Root-relative path, format, schema, byte count, and SHA-256 for every file.
- Aggregate summary path, byte count, and SHA-256.

Do not store a wall-clock timestamp in the canonical root record. A timestamp
changes capture bytes without changing slice semantics.

Do not store the ZIP package hash inside the package. The package cannot contain
its own complete hash. Report the final package hash beside the file.

Treat `summary.json` as a derived index. Stage manifests remain authoritative
for their stage counters and invariants.

Summary schema version 1 stores the request hash, source root ID, stage count,
and file count. The package encoder and validator require these values to match
the root manifest. This check prevents another JSON schema from being relabeled
as the bundle summary.

## Validation order

Validate a directory or ZIP bundle in this order:

1. Apply the package byte limit before allocation.
2. Validate every container path before extraction.
3. Reject duplicate paths and unreferenced files.
4. Read no more than 1 MiB for `manifest.json`.
5. Validate the root schema and request identity.
6. Validate the summary schema, identity, and root counts.
7. Read each declared stage manifest with a 1 MiB limit.
8. Validate stage order, stage identity, provider identity, and manifest hash.
9. Validate every declared artifact byte count and SHA-256 before decoding.
10. Decode each primitive through its schema-specific bounded reader.
11. Compare decoded counters, hashes, bounds, and provenance with the manifest.
12. Load renders only after their descriptors pass.

Keep ZIP entries in memory or stream them to bounded decoders. Do not extract a
transfer package into the filesystem during inspection.

The package validator implements steps 1 through 11 for topology, region, and
path-plan primitives. The application does not implement step 12.

SHA-256 proves content integrity against the manifest. It does not prove who
created the bundle. Add signing only after an authenticity requirement exists.

## Bundle limits

Use these hard limits for schema version 1:

| Item | Limit |
| --- | ---: |
| Package source | 1 GiB |
| ZIP entries | 1,000 |
| Entry path | 512 bytes |
| One entry | 256 MiB |
| Total expanded data | 1 GiB |
| Compression ratio | 200:1 |
| Root manifest | 1 MiB |
| Root summary | 1 MiB |
| One stage manifest | 1 MiB |

The capture request can apply lower item and byte budgets. It cannot raise a
hard bundle limit.

## Canonical ZIP writer

Write schema version 1 transfer packages with these rules:

- Sort entries by their UTF-8 path bytes.
- Use stored entries without compression.
- Set the UTF-8 name flag.
- Set the minimum ZIP version to 2.0.
- Set the DOS timestamp to 1980-01-01 00:00:00.
- Write no extra fields, comments, directory entries, or data descriptors.
- Write CRC-32 and sizes in both local and central records.
- Reject ZIP64 instead of crossing the 1 GiB package limit.

Stored entries make package bytes independent from a compressor version. A
golden two-entry archive and a complete synthetic bundle pin their SHA-256
values. The shared reader continues to accept bounded deflate.

The Stanford Bunny fixture produces a 47,928,741-byte package with SHA-256
`1fab0f11792b7bdf3b01533992475cde4e3faa4f7318ed87cbb572a8f2dad31e`.
The standalone validator replays topology, regions, and path planning without
the STL. It rejects a changed package byte.

## Implemented publication sequence

The development publisher builds a capture in a new sibling staging directory.
It writes and validates all content before it publishes the final directory
name.

Write a transfer package to a new sibling temporary file. Validate the complete
file, then rename it to the selected destination.

Do not replace an existing destination unless the user explicitly confirms the
replacement through the operating-system save workflow.

## Implemented directory publisher

The development publisher accepts a validated manifest and content map. It
requires an existing parent directory and an absent destination.

Use this sequence:

1. Create a unique sibling directory with an application-owned prefix.
2. Create each declared subdirectory without following package paths outside
   the staging root.
3. Write every payload with exclusive creation.
4. Write `summary.json`, each stage manifest, and `manifest.json`.
5. Read the staging directory through the same descriptor validator.
6. Synchronize each file and the staging directory.
7. Rename the staging directory to the absent destination.
8. Synchronize the parent directory after the rename.

The publisher removes its staging directory after a normal write, validation,
or injected failure. Startup cleanup of stale siblings remains open. That
cleanup must match the exact application-owned prefix and must not scan or
remove another temporary directory.

The transfer publisher must write one sibling temporary file. It must validate
the complete package before it renames the file to an absent destination.

The tests cover these cases:

- Reject aliased output paths in the probe and reserved staging destinations.
- Reject an existing destination before the first write.
- Reject traversal through manifest validation, duplicate and missing content,
  unlisted files, changed bytes, and symbolic links.
- Inject a failure after each file write and before the rename.
- Leave no published destination after an injected failure.
- Preserve an existing destination byte for byte.
- Produce identical directory content from equivalent content orders.
- Replay valid topology, region, and path-plan stages.
- Reject semantically corrupt stages before publication.

The Stanford Bunny fixture publishes an eight-file directory with `0700`
directories and `0600` files. The standalone directory validator accepts it
without the STL. Its path-plan artifact is byte-identical to the standalone
replay artifact. Its region artifact binds the decoded topology graph and
matches the pinned region hash.

## Open decisions

- Decide whether an optional source model can enter a bundle. Exclude it by
  default for size and privacy.
- Define log redaction before logs enter a transferable bundle.
- Define the canonical PNG renderer and its OS-version identity.
- Decide whether a detached signature is required for shared diagnostic
  captures.

## Implementation order

1. Load the validated records in the application evidence inspector.

Completion requires corruption, traversal, duplicate, hidden-file, oversized,
and interrupted-publication tests. The final gate must replay without the source
model.

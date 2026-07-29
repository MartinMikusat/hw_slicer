# HW Slicer Research

This directory stores verified source metadata, engineering notes, and reviewed
PDF snapshots for the HW Slicer plan.

## AI-assisted development disclosure

Models used:

- **gpt-5.6-sol**

The research library currently contains 20 records and 15 local PDF snapshots.
The catalog separates source claims, project interpretations, limitations, and
use decisions.

## Directory map

- `catalog.json` is the website and validation source of truth.
- `catalog.schema.json` defines the machine-readable record contract.
- `references.bib` stores the matching BibLaTeX records.
- `CITATION_GUIDE.md` defines citation and update procedures.
- `notes/` groups research findings by engineering domain.
- `papers/` stores reviewed PDF snapshots and their asset register.
- `audits/` records citation corrections and verification results.
- `scripts/verify-research.mjs` validates cross-file integrity and checksums.

## PDF policy

Store a PDF only from a publisher, standards body, author site, institutional
repository, or documented academic archive. Do not bypass access controls.

The local PDF is a reviewed snapshot. The canonical citation remains the DOI or
official publication page.

The research website does not publish these PDF files. It links to each recorded
source URL and reports whether a local snapshot exists.

## Review states

`adopted` records an active project dependency. `candidate` requires a benchmark
or implementation decision. `background` constrains reasoning without defining
the current build.

`rejected` records a declined method. `unreviewed` identifies metadata that still
needs an engineering assessment.

## Verification

Run this command from the project root:

```sh
node research/scripts/verify-research.mjs
```

The script validates identifiers, note anchors, bibliography keys, PDF headers,
SHA-256 values, and undeclared files.

The script does not prove that a paper's method is correct. Each implementation
must reproduce the relevant claim under the project's workload.

## Third-party assets

The complete source, version, checksum, and rights location for every stored PDF
appear in [`papers/LICENSES.md`](papers/LICENSES.md).

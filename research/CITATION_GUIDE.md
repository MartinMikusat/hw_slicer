# Citation Guide

Use one stable citation key for each source. The key appears in
`catalog.json`, `references.bib`, and the research notes.

Write citations in Pandoc form:

```text
The orientation predicate escalates only when the fast result is uncertain
[@shewchuk1997adaptive].
```

Use the DOI as the canonical link when a DOI exists. Use the official
publication page for reports, specifications, and live documentation.

The PDF checksum identifies the exact file reviewed by the project. It does not
replace the publication citation.

## Add a source

1. Verify the title, authors, publication, year, pages, and DOI.
2. Prefer the publisher, standards body, author site, or institutional archive.
3. Add the complete record to `catalog.json`.
4. Add the matching citation key to `references.bib`.
5. Add a note with findings, limits, and the project use decision.
6. Store a PDF only when a legitimate public copy is available.
7. Record the source URL, retrieval date, provenance, access note, and SHA-256.
8. Run `node research/scripts/verify-research.mjs` from the project root.

## Update a live document

Create a new record when a versioned specification changes its technical
contract. Update an existing record only when its cited version stays the same.

For unversioned documentation, update the retrieval date and note the reviewed
behavior. Keep implementation tests as the authority for toolchain behavior.

## Evidence labels

- `high` means the metadata and relevant claim were checked against a primary
  source.
- `medium` means a primary source exists, but the claim needs implementation
  testing or a version pin.
- `low` means the evidence is incomplete or conflicting.

## Use decisions

- `adopted` means the project plan currently depends on the source.
- `candidate` means an implementation or benchmark must select the method.
- `background` means the source constrains reasoning but not the current build.
- `rejected` means the project evaluated and declined the method.
- `unreviewed` means the record exists, but no engineering decision exists.

Do not convert `candidate` or `background` into a settled requirement without
recording the decision and its verification result.

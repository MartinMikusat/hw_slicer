# Citation Audit: 2026-07-29

The initial research seed contains 20 records. Metadata was checked against DOI
registries, official publication pages, author pages, or standards bodies.

## Corrected plan entry

The plan listed “Least Cost Paths for 3D Printing Support Structures” by Hu and
coauthors with DOI `10.1145/2816795.2817810`.

The DOI registry returned no record, and searches found no primary publication
with that title. The entry was unsupported.

The plan now cites the verified paper “Support Slimming for Single Material
Based Additive Manufacturing” with DOI
[`10.1016/j.cad.2015.03.001`](https://doi.org/10.1016/j.cad.2015.03.001).

## Version discrepancies

The official Arm `2025Q4` release asset for AAPCS64 has the expected published
SHA-256. Its first page identifies the document as `2025Q1`.

The catalog records both labels. Implementation work must inspect the current
source revision before relying on text changed after `2025Q1`.

The archived 3MF PDF is version `1.3.0`. The consortium identifies `1.4.0` as
the latest revision. Version `1.4.0` needs a separate delta review.

## Verification boundary

The audit verifies citation identity and snapshot provenance. It does not
reproduce each paper's experiment or establish implementation suitability.

Each `candidate` method still requires the benchmark or prototype recorded in
its catalog entry.

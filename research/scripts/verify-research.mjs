import { createHash } from "node:crypto";
import { readdir, readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const researchRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const catalogPath = path.join(researchRoot, "catalog.json");
const bibliographyPath = path.join(researchRoot, "references.bib");
const catalog = JSON.parse(await readFile(catalogPath, "utf8"));
const bibliography = await readFile(bibliographyPath, "utf8");
const errors = [];
const ids = new Set();
const citationKeys = new Set();
const declaredPdfs = new Set();

if (catalog.schemaVersion !== 1) {
  errors.push(`Unsupported schema version: ${catalog.schemaVersion}`);
}

for (const source of catalog.sources ?? []) {
  if (!/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(source.id)) {
    errors.push(`Invalid source id: ${source.id}`);
  }
  if (ids.has(source.id)) {
    errors.push(`Duplicate source id: ${source.id}`);
  }
  ids.add(source.id);

  if (!/^[A-Za-z][A-Za-z0-9]+$/.test(source.citationKey)) {
    errors.push(`Invalid citation key: ${source.citationKey}`);
  }
  if (citationKeys.has(source.citationKey)) {
    errors.push(`Duplicate citation key: ${source.citationKey}`);
  }
  citationKeys.add(source.citationKey);

  const bibPattern = new RegExp(`@[A-Za-z]+\\{${source.citationKey},`);
  if (!bibPattern.test(bibliography)) {
    errors.push(`Missing bibliography entry: ${source.citationKey}`);
  }

  if (source.doi && !/^10\.[0-9]{4,9}\/\S+$/.test(source.doi)) {
    errors.push(`Invalid DOI syntax for ${source.id}: ${source.doi}`);
  }

  if (!Array.isArray(source.authors) || source.authors.length === 0) {
    errors.push(`Missing authors: ${source.id}`);
  }
  if (!Array.isArray(source.keyFindings) || source.keyFindings.length === 0) {
    errors.push(`Missing findings: ${source.id}`);
  }
  if (!Array.isArray(source.limitations) || source.limitations.length === 0) {
    errors.push(`Missing limitations: ${source.id}`);
  }
  if (!source.usage?.decision || !source.usage?.targets?.length) {
    errors.push(`Missing use decision: ${source.id}`);
  }

  const [relativeNotePath, anchor] = source.notePath.split("#");
  try {
    const note = await readFile(path.join(researchRoot, relativeNotePath), "utf8");
    if (!note.includes(`id="${anchor}"`)) {
      errors.push(`Missing note anchor for ${source.id}: ${source.notePath}`);
    }
  } catch {
    errors.push(`Missing note for ${source.id}: ${relativeNotePath}`);
  }

  if (!source.pdf) {
    continue;
  }

  declaredPdfs.add(source.pdf.path);
  try {
    const bytes = await readFile(path.join(researchRoot, source.pdf.path));
    if (bytes.subarray(0, 5).toString("ascii") !== "%PDF-") {
      errors.push(`Invalid PDF header: ${source.pdf.path}`);
    }
    const checksum = createHash("sha256").update(bytes).digest("hex");
    if (checksum !== source.pdf.sha256) {
      errors.push(`Checksum mismatch: ${source.pdf.path}`);
    }
  } catch {
    errors.push(`Missing PDF: ${source.pdf.path}`);
  }
}

const paperEntries = await readdir(path.join(researchRoot, "papers"), {
  withFileTypes: true
});
for (const entry of paperEntries) {
  if (!entry.isFile() || !entry.name.endsWith(".pdf")) {
    continue;
  }
  const relativePath = `papers/${entry.name}`;
  if (!declaredPdfs.has(relativePath)) {
    errors.push(`Undeclared PDF: ${relativePath}`);
  }
}

if (errors.length > 0) {
  console.error(errors.join("\n"));
  process.exitCode = 1;
} else {
  console.log(
    `Verified ${catalog.sources.length} sources, ${citationKeys.size} citations, and ${declaredPdfs.size} PDF snapshots.`
  );
}

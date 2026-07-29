import { execFile } from "node:child_process";
import { cp, mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { promisify } from "node:util";
import { fileURLToPath } from "node:url";

const siteRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const researchRoot = path.resolve(siteRoot, "..", "research");
const staticRoot = path.join(siteRoot, "static");
const run = promisify(execFile);

await run(process.execPath, [path.join(researchRoot, "scripts", "verify-research.mjs")]);
await mkdir(staticRoot, { recursive: true });
const catalog = await readFile(path.join(researchRoot, "catalog.json"), "utf8");
await writeFile(path.join(staticRoot, "research-index.json"), catalog);
await cp(path.join(researchRoot, "references.bib"), path.join(staticRoot, "references.bib"), {
  force: true
});

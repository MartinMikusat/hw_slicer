import { access, readFile, stat } from "node:fs/promises";

await access("dist/server/index.js");
await access("dist/static/index.html");
await access("dist/static/og.png");
await access("dist/static/fonts/Iosevka-Regular.woff2");
await access("dist/static/licenses/iosevka-34.8.0-OFL-1.1.md");
const catalog = JSON.parse(await readFile("dist/static/research-index.json", "utf8"));
if (!Array.isArray(catalog.sources) || catalog.sources.length === 0) {
  throw new Error("The production research index is empty.");
}
try {
  await stat("dist/static/papers");
  throw new Error("Research PDF snapshots must not be published in the site bundle.");
} catch (error) {
  if (error instanceof Error && !("code" in error && error.code === "ENOENT")) {
    throw error;
  }
}
console.log(
  `Verified ${catalog.sources.length} research records, the social preview, and the font license in the production bundle.`
);

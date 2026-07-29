import { access, readFile, stat } from "node:fs/promises";

await access("build/index.html");
await access("build/og.png");
await access("build/fonts/Iosevka-Regular.woff2");
await access("build/licenses/iosevka-34.8.0-OFL-1.1.md");
const catalog = JSON.parse(await readFile("build/research-index.json", "utf8"));
if (!Array.isArray(catalog.sources) || catalog.sources.length === 0) {
  throw new Error("The local research index is empty.");
}
try {
  await stat("build/papers");
  throw new Error("Research PDF snapshots must not be copied into the site build.");
} catch (error) {
  if (error instanceof Error && !("code" in error && error.code === "ENOENT")) {
    throw error;
  }
}
console.log(
  `Verified ${catalog.sources.length} research records, the social preview, and the font license in the local build.`
);

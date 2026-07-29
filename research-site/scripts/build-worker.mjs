import { cp, mkdir, writeFile } from "node:fs/promises";

await mkdir("dist/server", { recursive: true });
await cp("build", "dist/static", { recursive: true, force: true });
await writeFile(
  "dist/server/index.js",
  `export default {
  async fetch(request, env) {
    return env.ASSETS.fetch(request);
  }
};
`
);

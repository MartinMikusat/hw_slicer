# HW Slicer Research Site

This SvelteKit site presents the verified HW Slicer research catalog through
search, filters, summaries, limitations, and explicit use decisions.

## AI-assisted development disclosure

Models used:

- **gpt-5.6-sol**
- **gpt-image-2**

## Commands

```sh
npm run dev
npm run check
npm test
npm run build
npm run verify
```

Run `npm run dev`, then open `http://localhost:5173`.

`npm run build` validates `../research/catalog.json` before it creates a local
static build in `build/`. The build includes catalog metadata and external
source links. It does not copy the research PDF snapshots.

## Third-party assets

| Asset | Version | Source | SHA-256 | License |
| --- | --- | --- | --- | --- |
| `static/og.png` | Generated 2026-07-29 | Built-in image generation with `gpt-image-2` | `592691483d318d10275fc9c2e81c7d7b09ba239dd61d1541753766f74f685eca` | Project-generated asset. |

The social preview prompt requested a 1200×630 editorial evidence pipeline. It
uses the project palette, research papers, mesh contours, and a GPU thread grid.
It contains the exact title `HW SLICER / RESEARCH`.

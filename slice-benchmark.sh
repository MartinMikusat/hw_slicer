#!/usr/bin/env bash
set -euo pipefail

# End-to-end slicing benchmark runner for hw_slicer.
# Benchmarks the 3 core reference models (PLA / 0.20-standard) and all 155 official Voron 2.4
# printed parts (ABS / voron-2.4-standard, with voron-2.4-high-stress for high-stress parts).
#
# Usage:
#   ./slice-benchmark.sh [--suite=all|core|voron2.4] [--runs=1] [--threads=0] [--out-json=path]

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

SUITE="all"
RUNS=1
THREADS=""
OUT_JSON=""

for arg in "$@"; do
  case "$arg" in
    --suite=*) SUITE="${arg#--suite=}" ;;
    --runs=*) RUNS="${arg#--runs=}" ;;
    --threads=*) THREADS="${arg#--threads=}" ;;
    --out-json=*) OUT_JSON="${arg#--out-json=}" ;;
    -h|--help)
      echo "Usage: $0 [--suite=all|core|voron2.4] [--runs=N] [--threads=N] [--out-json=PATH]"
      exit 0
      ;;
    *)
      echo "Unknown option: $arg" >&2
      exit 2
      ;;
  esac
done

./build.sh cli-release >&2
CLI="$ROOT/build/release/hw-slicer-cli"

python3 - "$ROOT" "$CLI" "$SUITE" "$RUNS" "$THREADS" "$OUT_JSON" <<'PY'
import glob, json, os, re, subprocess, sys, tempfile, time

root, cli, suite, runs_s, threads, out_json = sys.argv[1:7]
runs = max(1, int(runs_s))

HIGH_STRESS_PREFIXES = (
    "xy_topbrace_",
    "front_idler_",
    "idler_frame_",
)

cases = []
if suite in ("all", "core"):
    for name in ("benchy.stl", "all-in-one-test.stl", "stanford-bunny.stl"):
        path = os.path.join(root, "resources/models", name)
        if os.path.exists(path):
            cases.append({
                "suite": "core",
                "name": name,
                "path": path,
                "printer": "vcore3",
                "material": "pla",
                "process": "0.20-standard",
            })

if suite in ("all", "voron2.4"):
    voron_root = os.path.join(root, "resources/models/voron-2.4")
    voron_files = []
    for dirpath, _, filenames in os.walk(voron_root):
        for fn in filenames:
            if fn.lower().endswith(".stl"):
                voron_files.append(os.path.join(dirpath, fn))
    voron_files.sort()
    for path in voron_files:
        rel = os.path.relpath(path, voron_root)
        base = os.path.basename(path).lower()
        proc = "voron-2.4-high-stress" if any(base.startswith(p) for p in HIGH_STRESS_PREFIXES) else "voron-2.4-standard"
        cases.append({
            "suite": "voron2.4",
            "name": f"voron-2.4/{rel}",
            "path": path,
            "printer": "vcore3",
            "material": "abs",
            "process": proc,
        })

if not cases:
    print(f"[slice-benchmark] no models matched suite={suite}", file=sys.stderr)
    sys.exit(1)

results = []
failures = []
total_wall_ms = 0.0
suite_wall_ms = {}
suite_counts = {}

with tempfile.TemporaryDirectory(prefix="hw-slicer-bench-") as tmpdir:
    out_gcode = os.path.join(tmpdir, "out.gcode")
    for idx, c in enumerate(cases, 1):
        cmd = [
            cli,
            f"--input={c['path']}",
            f"--printer={c['printer']}",
            f"--material={c['material']}",
            f"--process={c['process']}",
            f"--out={out_gcode}",
        ]
        if threads:
            cmd.append(f"--threads={threads}")

        best_ms = None
        best_stdout = ""
        err_text = ""
        ok = True
        for _ in range(runs):
            t0 = time.perf_counter()
            p = subprocess.run(cmd, capture_output=True, text=True)
            dt_ms = (time.perf_counter() - t0) * 1000.0
            if p.returncode != 0:
                ok = False
                err_text = (p.stderr or p.stdout).strip().splitlines()[-1] if (p.stderr or p.stdout).strip() else f"exit {p.returncode}"
                break
            if best_ms is None or dt_ms < best_ms:
                best_ms = dt_ms
                best_stdout = p.stdout

        rec = {
            "suite": c["suite"],
            "name": c["name"],
            "material": c["material"],
            "process": c["process"],
            "ok": ok,
            "wall_ms": round(best_ms, 2) if best_ms is not None else None,
        }
        if ok:
            m = re.search(r"tris=(\d+)\s+layers=(\d+)\s+repairs=(\d+)\s+extrude=(\d+)\s+travel=(\d+)\s+filament=([0-9.]+)\s+mm\s+est_time=([0-9:]+)\s+gcode=(\d+)\s+bytes", best_stdout)
            if m:
                rec.update({
                    "tris": int(m.group(1)),
                    "layers": int(m.group(2)),
                    "repairs": int(m.group(3)),
                    "extrude_moves": int(m.group(4)),
                    "travel_moves": int(m.group(5)),
                    "filament_mm": float(m.group(6)),
                    "est_time": m.group(7),
                    "gcode_bytes": int(m.group(8)),
                })
            total_wall_ms += best_ms
            suite_wall_ms[c["suite"]] = suite_wall_ms.get(c["suite"], 0.0) + best_ms
            suite_counts[c["suite"]] = suite_counts.get(c["suite"], 0) + 1
            print(f"[{idx:3d}/{len(cases)}] OK   {best_ms:7.1f} ms  {c['process']:22s}  {c['name']}", flush=True)
        else:
            rec["error"] = err_text
            failures.append(rec)
            print(f"[{idx:3d}/{len(cases)}] FAIL            {c['process']:22s}  {c['name']}  ({err_text})", flush=True)
        results.append(rec)

summary = {
    "suite": suite,
    "runs_per_model": runs,
    "threads": threads or "default",
    "total_models": len(cases),
    "passed": len(cases) - len(failures),
    "failed": len(failures),
    "total_wall_ms": round(total_wall_ms, 2),
    "suite_wall_ms": {k: round(v, 2) for k, v in suite_wall_ms.items()},
    "suite_passed": suite_counts,
    "results": results,
}

print("\n=== SUMMARY ===")
print(f"Suite: {suite} | Passed: {summary['passed']}/{summary['total_models']} | Total wall: {total_wall_ms:.1f} ms ({total_wall_ms/1000.0:.2f} s)")
for k, v in sorted(suite_wall_ms.items()):
    cnt = suite_counts[k]
    print(f"  {k:10s}: {cnt:3d} models  {v:8.1f} ms total  ({v/cnt:6.1f} ms avg)")

if out_json:
    os.makedirs(os.path.dirname(os.path.abspath(out_json)), exist_ok=True)
    with open(out_json, "w") as f:
        json.dump(summary, f, indent=2)
    print(f"Wrote JSON report: {out_json}")

if failures:
    print("\n=== FAILURES ===")
    for f in failures:
        print(f"  {f['name']}: {f['error']}")
    sys.exit(1)
PY

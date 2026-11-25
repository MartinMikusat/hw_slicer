#!/usr/bin/env bash
set -euo pipefail

# End-to-end slicing benchmark runner for hw_slicer, with optional head-to-head OrcaSlicer CLI
# comparison using matched machine, filament, and process settings.
#
# Usage:
#   ./slice-benchmark.sh [--suite=all|core|voron2.4] [--runs=1] [--threads=0] \
#                        [--compare-orca] [--out-json=PATH] [--out-md=PATH] \
#                        [--save-baseline=DIR] [--verify-determinism] [--stage-diff=DIR]

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

SUITE="all"
RUNS=1
THREADS=""
COMPARE_ORCA=0
OUT_JSON=""
OUT_MD=""
SAVE_BASELINE=""
VERIFY_DET=0
STAGE_DIFF=""

for arg in "$@"; do
  case "$arg" in
    --suite=*) SUITE="${arg#--suite=}" ;;
    --runs=*) RUNS="${arg#--runs=}" ;;
    --threads=*) THREADS="${arg#--threads=}" ;;
    --compare-orca) COMPARE_ORCA=1 ;;
    --out-json=*) OUT_JSON="${arg#--out-json=}" ;;
    --out-md=*) OUT_MD="${arg#--out-md=}" ;;
    --save-baseline=*) SAVE_BASELINE="${arg#--save-baseline=}" ;;
    --verify-determinism) VERIFY_DET=1 ;;
    --verify-determinism=*) VERIFY_DET=1; STAGE_DIFF="${STAGE_DIFF:-${arg#--verify-determinism=}}" ;;
    --stage-diff=*) STAGE_DIFF="${arg#--stage-diff=}" ;;
    -h|--help)
      echo "Usage: $0 [--suite=all|core|voron2.4] [--runs=N] [--threads=N] [--compare-orca] [--out-json=PATH] [--out-md=PATH] [--save-baseline=DIR] [--verify-determinism[=DIR]] [--stage-diff=DIR]"
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
ORCA_BIN="/Applications/OrcaSlicer.app/Contents/MacOS/OrcaSlicer"

if [ "$COMPARE_ORCA" = "1" ] && [ ! -x "$ORCA_BIN" ]; then
  echo "[slice-benchmark] OrcaSlicer binary not found at $ORCA_BIN" >&2
  exit 1
fi

python3 - "$ROOT" "$CLI" "$ORCA_BIN" "$SUITE" "$RUNS" "$THREADS" "$COMPARE_ORCA" "$OUT_JSON" "$OUT_MD" "$SAVE_BASELINE" "$VERIFY_DET" "$STAGE_DIFF" <<'PY'
import hashlib, json, math, os, re, statistics, subprocess, sys, tempfile, time

root, cli, orca_bin, suite, runs_s, threads, cmp_orca_s, out_json, out_md, save_baseline, verify_det_s, stage_diff = sys.argv[1:13]
runs = max(1, int(runs_s))
compare_orca = cmp_orca_s == "1"
verify_det = verify_det_s == "1"
want_stages = bool(save_baseline or stage_diff)

def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()

baseline_data = {}
if stage_diff:
    bp = os.path.join(stage_diff, "baseline.json") if os.path.isdir(stage_diff) else stage_diff
    if not os.path.exists(bp):
        print(f"[slice-benchmark] baseline file not found: {bp}", file=sys.stderr)
        sys.exit(1)
    with open(bp) as f:
        raw_base = json.load(f)
    baseline_data = {r["name"]: r for r in raw_base.get("results", [])}

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

def write_orca_profiles(tmpdir):
    machine = {
        "type": "machine",
        "name": "HW Slicer Benchmark Klipper 350",
        "from": "User",
        "gcode_flavor": "klipper",
        "printable_area": ["0x0", "350x0", "350x350", "0x350"],
        "printable_height": "350",
        "nozzle_diameter": ["0.4"],
        "machine_max_acceleration_x": ["6000"],
        "machine_max_acceleration_y": ["6000"],
        "machine_max_acceleration_z": ["500"],
        "machine_max_acceleration_e": ["5000"],
        "machine_max_speed_x": ["300"],
        "machine_max_speed_y": ["300"],
        "machine_max_speed_z": ["20"],
        "machine_max_speed_e": ["100"],
        "retraction_length": ["0.8"],
        "retraction_speed": ["40"],
        "deretraction_speed": ["40"],
        "z_hop": ["0.4"],
    }
    def make_proc(name, lw, walls, top_b, top_mm, infill_pct):
        return {
            "type": "process",
            "name": name,
            "from": "User",
            "layer_height": "0.2",
            "initial_layer_print_height": "0.2",
            "line_width": lw,
            "initial_layer_line_width": lw,
            "outer_wall_line_width": lw,
            "inner_wall_line_width": lw,
            "top_surface_line_width": lw,
            "sparse_infill_line_width": lw,
            "internal_solid_infill_line_width": lw,
            "wall_loops": str(walls),
            "top_shell_layers": str(top_b),
            "top_shell_thickness": top_mm,
            "bottom_shell_layers": str(top_b),
            "bottom_shell_thickness": top_mm,
            "sparse_infill_density": f"{infill_pct}%",
            "sparse_infill_pattern": "gyroid",
            "enable_support": "0",
            "enable_arc_fitting": "1",
            "skirt_loops": "1",
            "brim_width": "0",
            "elefant_foot_compensation": "0.15",
            "outer_wall_speed": "80",
            "inner_wall_speed": "80",
            "top_surface_speed": "90",
            "internal_solid_infill_speed": "90",
            "sparse_infill_speed": "120",
            "gap_infill_speed": "60",
            "bridge_speed": "35",
            "travel_speed": "200",
        }
    fil_pla = {
        "type": "filament",
        "name": "Benchmark PLA",
        "from": "User",
        "filament_type": ["PLA"],
        "filament_diameter": ["1.75"],
        "filament_density": ["1.24"],
        "nozzle_temperature": ["210"],
        "nozzle_temperature_initial_layer": ["210"],
        "hot_plate_temp": ["60"],
        "hot_plate_temp_initial_layer": ["60"],
        "fan_min_speed": ["100"],
        "fan_max_speed": ["100"],
        "overhang_fan_speed": ["100"],
        "filament_max_volumetric_speed": ["20"],
    }
    fil_abs = {
        "type": "filament",
        "name": "Benchmark ABS",
        "from": "User",
        "filament_type": ["ABS"],
        "filament_diameter": ["1.75"],
        "filament_density": ["1.04"],
        "nozzle_temperature": ["250"],
        "nozzle_temperature_initial_layer": ["250"],
        "hot_plate_temp": ["105"],
        "hot_plate_temp_initial_layer": ["105"],
        "fan_min_speed": ["25"],
        "fan_max_speed": ["35"],
        "overhang_fan_speed": ["35"],
        "filament_max_volumetric_speed": ["18"],
    }
    paths = {}
    for key, obj in [
        ("machine", machine),
        ("0.20-standard", make_proc("0.20-standard", "0.42", 3, 4, "0.8", 15)),
        ("voron-2.4-standard", make_proc("voron-2.4-standard", "0.4", 4, 5, "1.0", 40)),
        ("voron-2.4-high-stress", make_proc("voron-2.4-high-stress", "0.4", 5, 8, "1.6", 50)),
        ("pla", fil_pla),
        ("abs", fil_abs),
    ]:
        p = os.path.join(tmpdir, f"orca_{key}.json")
        with open(p, "w") as f:
            json.dump(obj, f)
        paths[key] = p
    return paths

results = []
failures = []
total_wall_ms = 0.0
total_orca_ms = 0.0
suite_wall_ms = {}
suite_orca_ms = {}
suite_counts = {}
orca_paired_hw_ms = 0.0
orca_paired_orca_ms = 0.0
ratios = []
hw_faster_count = 0

with tempfile.TemporaryDirectory(prefix="hw-slicer-bench-") as tmpdir:
    out_gcode = os.path.join(tmpdir, "out.gcode")
    trace_json = os.path.join(tmpdir, "trace.json")
    det_gcode = os.path.join(tmpdir, "det.gcode")
    orca_out_dir = os.path.join(tmpdir, "orca_out")
    os.makedirs(orca_out_dir, exist_ok=True)
    orca_profiles = write_orca_profiles(tmpdir) if compare_orca else {}

    for idx, c in enumerate(cases, 1):
        cmd = [
            cli,
            f"--input={c['path']}",
            f"--printer={c['printer']}",
            f"--material={c['material']}",
            f"--process={c['process']}",
            f"--out={out_gcode}",
        ]
        if want_stages:
            cmd.append(f"--trace-json={trace_json}")
        if threads:
            cmd.append(f"--threads={threads}")

        best_ms = None
        best_stdout = ""
        err_text = ""
        ok = True
        stage_samples = {}
        stage_order = []
        gcode_sha = None
        for run_idx in range(runs):
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
            if run_idx == 0 and (verify_det or save_baseline):
                gcode_sha = sha256_file(out_gcode)
            if want_stages and os.path.exists(trace_json):
                with open(trace_json) as tf:
                    td = json.load(tf)
                for st in td.get("stages", []):
                    sn = st["name"]
                    if sn not in stage_samples:
                        stage_samples[sn] = []
                        stage_order.append(sn)
                    stage_samples[sn].append(float(st["duration_ms"]))

        det_status = None
        if ok and verify_det:
            det_ok = True
            for label, extra_flag in (("threads=1", "--threads=1"), ("no-gpu", "--no-gpu")):
                dcmd = [
                    cli,
                    f"--input={c['path']}",
                    f"--printer={c['printer']}",
                    f"--material={c['material']}",
                    f"--process={c['process']}",
                    extra_flag,
                    f"--out={det_gcode}",
                ]
                dp = subprocess.run(dcmd, capture_output=True, text=True)
                if dp.returncode != 0:
                    ok = False
                    det_ok = False
                    err_text = f"determinism {label} failed (exit {dp.returncode})"
                    break
                dsha = sha256_file(det_gcode)
                if dsha != gcode_sha:
                    ok = False
                    det_ok = False
                    err_text = f"determinism mismatch ({label}: {dsha[:12]} != {gcode_sha[:12]})"
                    break
            if det_ok and c["name"] in baseline_data and baseline_data[c["name"]].get("gcode_sha256"):
                bsha = baseline_data[c["name"]]["gcode_sha256"]
                if gcode_sha != bsha:
                    ok = False
                    det_ok = False
                    err_text = f"baseline hash mismatch ({gcode_sha[:12]} != {bsha[:12]})"
            det_status = "3-way exact" if det_ok else err_text

        rec = {
            "suite": c["suite"],
            "name": c["name"],
            "material": c["material"],
            "process": c["process"],
            "ok": ok,
            "wall_ms": round(best_ms, 2) if best_ms is not None else None,
        }
        if gcode_sha is not None:
            rec["gcode_sha256"] = gcode_sha
        if det_status is not None:
            rec["determinism"] = det_status
        if stage_samples:
            rec["stages"] = {
                sn: {
                    "min_ms": round(min(stage_samples[sn]), 2),
                    "median_ms": round(statistics.median(stage_samples[sn]), 2),
                }
                for sn in stage_order
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

        if compare_orca:
            orca_cmd = [
                orca_bin,
                "--slice", "0",
                "--arrange", "1",
                "--load-settings", f"{orca_profiles['machine']};{orca_profiles[c['process']]}",
                "--load-filaments", orca_profiles[c["material"]],
                "--outputdir", orca_out_dir,
                c["path"],
            ]
            best_orca = None
            orca_ok = True
            orca_err = ""
            for _ in range(runs):
                t0 = time.perf_counter()
                op = subprocess.run(orca_cmd, cwd=orca_out_dir, capture_output=True, text=True)
                odt = (time.perf_counter() - t0) * 1000.0
                if op.returncode != 0:
                    orca_ok = False
                    orca_err = (op.stderr or op.stdout).strip().splitlines()[-1] if (op.stderr or op.stdout).strip() else f"exit {op.returncode}"
                    break
                if best_orca is None or odt < best_orca:
                    best_orca = odt
            rec["orca_ok"] = orca_ok
            rec["orca_ms"] = round(best_orca, 2) if best_orca is not None else None
            if orca_ok:
                total_orca_ms += best_orca
                suite_orca_ms[c["suite"]] = suite_orca_ms.get(c["suite"], 0.0) + best_orca
                if ok and best_ms > 0:
                    ratio = best_orca / best_ms
                    rec["speedup_vs_orca"] = round(ratio, 2)
                    orca_paired_hw_ms += best_ms
                    orca_paired_orca_ms += best_orca
                    ratios.append(ratio)
                    if ratio >= 1.0:
                        hw_faster_count += 1
            else:
                rec["orca_error"] = orca_err

        if ok:
            if compare_orca and rec.get("orca_ok"):
                print(f"[{idx:3d}/{len(cases)}] OK   hw={best_ms:6.1f} ms  orca={rec['orca_ms']:7.1f} ms  ({rec['speedup_vs_orca']:5.2f}x)  {c['name']}", flush=True)
            elif compare_orca:
                print(f"[{idx:3d}/{len(cases)}] OK   hw={best_ms:6.1f} ms  orca=FAIL             {c['name']}", flush=True)
            else:
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
    "compare_orca": compare_orca,
    "total_models": len(cases),
    "passed": len(cases) - len(failures),
    "failed": len(failures),
    "total_wall_ms": round(total_wall_ms, 2),
    "suite_wall_ms": {k: round(v, 2) for k, v in suite_wall_ms.items()},
    "suite_passed": suite_counts,
    "results": results,
}
if compare_orca:
    geomean = math.exp(sum(math.log(r) for r in ratios) / len(ratios)) if ratios else 0.0
    summary["orca_total_ms"] = round(total_orca_ms, 2)
    summary["overall_speedup"] = round(orca_paired_orca_ms / orca_paired_hw_ms, 2) if orca_paired_hw_ms > 0 else 0.0
    summary["geomean_speedup"] = round(geomean, 2)
    summary["median_speedup"] = round(statistics.median(ratios), 2) if ratios else 0.0
    summary["hw_faster_count"] = hw_faster_count
    summary["paired_count"] = len(ratios)

print("\n=== SUMMARY ===")
print(f"Suite: {suite} | Passed: {summary['passed']}/{summary['total_models']} | Total hw_slicer wall: {total_wall_ms:.1f} ms ({total_wall_ms/1000.0:.2f} s)")
if compare_orca and ratios:
    print(f"OrcaSlicer 2.5.1 total wall: {total_orca_ms:.1f} ms ({total_orca_ms/1000.0:.2f} s)")
    print(f"Overall speedup: {summary['overall_speedup']:.2f}x | Geomean: {summary['geomean_speedup']:.2f}x | Median: {summary['median_speedup']:.2f}x | hw_slicer faster on {hw_faster_count}/{len(ratios)} parts")
for k, v in sorted(suite_wall_ms.items()):
    cnt = suite_counts[k]
    if compare_orca and k in suite_orca_ms:
        ov = suite_orca_ms[k]
        print(f"  {k:10s}: {cnt:3d} models  hw={v:8.1f} ms ({v/cnt:5.1f} avg)  orca={ov:8.1f} ms ({ov/cnt:5.1f} avg)  speedup={ov/v:.2f}x")
    else:
        print(f"  {k:10s}: {cnt:3d} models  {v:8.1f} ms total  ({v/cnt:6.1f} ms avg)")

if save_baseline:
    os.makedirs(save_baseline, exist_ok=True)
    bp = os.path.join(save_baseline, "baseline.json")
    with open(bp, "w") as f:
        json.dump(summary, f, indent=2)
    print(f"Saved baseline (hashes + stage timings): {bp}")

if stage_diff and baseline_data:
    print("\n=== STAGE DIFF (min_ms / median_ms vs baseline) ===")
    for r in results:
        b = baseline_data.get(r["name"])
        if not b or not r.get("ok") or "stages" not in r or "stages" not in b:
            continue
        bw = b.get("wall_ms") or 0.0
        cw = r.get("wall_ms") or 0.0
        dw = cw - bw
        pct = (dw / bw * 100.0) if bw > 0 else 0.0
        print(f"\n  {r['name']}  wall: {bw:.1f} -> {cw:.1f} ms ({dw:+.1f} ms, {pct:+.1f}%)")
        for sn, cur_st in r["stages"].items():
            bst = b["stages"].get(sn)
            if not bst:
                continue
            bmin, cmin = bst["min_ms"], cur_st["min_ms"]
            bmed, cmed = bst["median_ms"], cur_st["median_ms"]
            dmin = cmin - bmin
            if abs(dmin) < 0.25 and bmin < 1.0 and cmin < 1.0:
                continue
            spct = (dmin / bmin * 100.0) if bmin > 0 else 0.0
            print(f"    {sn:24s} min {bmin:6.2f} -> {cmin:6.2f} ms ({dmin:+6.2f}, {spct:+5.1f}%) | med {bmed:6.2f} -> {cmed:6.2f} ms")

if out_json:
    os.makedirs(os.path.dirname(os.path.abspath(out_json)), exist_ok=True)
    with open(out_json, "w") as f:
        json.dump(summary, f, indent=2)
    print(f"Wrote JSON report: {out_json}")

if out_md:
    os.makedirs(os.path.dirname(os.path.abspath(out_md)), exist_ok=True)
    with open(out_md, "w") as f:
        f.write("# Voron 2.4 Full-Printer Slicing Benchmark (`hw_slicer` vs. OrcaSlicer 2.5.1)\n\n")
        f.write(f"End-to-end CLI wall-clock timings for all {summary['total_models']} models in suite `{suite}` (`runs={runs}`, matched Klipper 350 mm machine, ABS filament, `voron-2.4-standard` 0.20 mm / 0.40 mm / 4 walls / 5 top & bottom / 40% gyroid, and `voron-2.4-high-stress` 5 walls / 8 top & bottom / 50% gyroid for front idlers).\n\n")
        if compare_orca and ratios:
            f.write("## Summary\n\n")
            f.write("| Metric | Value |\n|---|---:|\n")
            f.write(f"| Models sliced | {summary['passed']}/{summary['total_models']} |\n")
            f.write(f"| `hw_slicer` total wall time | **{total_wall_ms/1000.0:.2f} s** ({total_wall_ms/len(ratios):.1f} ms avg) |\n")
            f.write(f"| OrcaSlicer 2.5.1 total wall time | **{total_orca_ms/1000.0:.2f} s** ({total_orca_ms/len(ratios):.1f} ms avg) |\n")
            f.write(f"| Overall wall-time speedup (`Orca / hw`) | **{summary['overall_speedup']:.2f}×** |\n")
            f.write(f"| Geometric mean speedup | **{summary['geomean_speedup']:.2f}×** |\n")
            f.write(f"| Median speedup | **{summary['median_speedup']:.2f}×** |\n")
            f.write(f"| Parts where `hw_slicer` is faster | **{hw_faster_count}/{len(ratios)}** |\n\n")
            f.write("## Per-Part Comparison\n\n")
            f.write("| # | Part | Profile | Tris | Layers | `hw_slicer` (ms) | OrcaSlicer 2.5.1 (ms) | Speedup (`Orca / hw`) |\n")
            f.write("|---:|---|---|---:|---:|---:|---:|---:|\n")
            for i, r in enumerate(results, 1):
                hw_s = f"{r['wall_ms']:.1f}" if r.get("ok") else "FAIL"
                or_s = f"{r['orca_ms']:.1f}" if r.get("orca_ok") else "FAIL"
                sp_s = f"**{r['speedup_vs_orca']:.2f}×**" if r.get("speedup_vs_orca") is not None else "—"
                f.write(f"| {i} | `{r['name']}` | `{r['process']}` | {r.get('tris', 0)} | {r.get('layers', 0)} | {hw_s} | {or_s} | {sp_s} |\n")
    print(f"Wrote Markdown report: {out_md}")

if failures:
    print("\n=== FAILURES ===")
    for f in failures:
        print(f"  {f['name']}: {f['error']}")
    sys.exit(1)
PY

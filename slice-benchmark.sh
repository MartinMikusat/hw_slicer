#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

python3 -B - "$@" <<'PY'
import argparse
import hashlib, importlib.util, json, math, os, re, statistics, subprocess, sys, tempfile, time

root = os.getcwd()
cli = os.path.join(root, "build/release/hw-slicer-cli")
spec = importlib.util.spec_from_file_location("orca_compare", os.path.join(root, "scripts", "orca-compare.py"))
orca_cmp_mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(orca_cmp_mod)
orca_bin = orca_cmp_mod.ORCA_BIN
scenarios = orca_cmp_mod.SCENARIOS

def key_value(value):
    key, separator, _ = value.partition("=")
    if not separator or not key:
        raise argparse.ArgumentTypeError("expected KEY=VALUE")
    return value

parser = argparse.ArgumentParser(
    prog="./slice-benchmark.sh",
    description="Measure end-to-end slicing with optional baseline and OrcaSlicer comparisons.",
    allow_abbrev=False,
)
parser.add_argument("--suite", choices=("all", "core", "voron2.4"), default="all")
parser.add_argument("--model", action="append", default=[], help="Select a model by its name in the suite. Repeat to select more.")
parser.add_argument("--runs", type=int, default=1)
parser.add_argument("--threads", default="")
parser.add_argument("--scenario", action="append", default=[], choices=[*scenarios, "all"], help="Run each selected model with this preset. Repeat to select more.")
parser.add_argument("--scenarios", action="store_true", help="Run all feature presets.")
parser.add_argument("--hw-set", action="append", default=[], type=key_value, metavar="KEY=VALUE", help="Override a process setting on both hw_slicer builds. Repeat to set more.")
parser.add_argument("--orca-set", action="append", default=[], type=key_value, metavar="KEY=VALUE", help="Override an OrcaSlicer process setting. Repeat to set more.")
parser.add_argument("--compare-orca", action="store_true")
parser.add_argument("--out-json", default="", metavar="PATH")
parser.add_argument("--out-md", default="", metavar="PATH")
parser.add_argument("--save-baseline", default="", metavar="DIR")
parser.add_argument("--verify-determinism", nargs="?", const="", metavar="BASELINE")
parser.add_argument("--stage-diff", default="", metavar="BASELINE")
parser.add_argument("--ab", default="", metavar="BASELINE_CLI", help="Alternate the candidate with a saved CLI binary.")
args = parser.parse_args()
suite = args.suite
runs = max(1, args.runs)
threads = args.threads
compare_orca = args.compare_orca
out_json, out_md = args.out_json, args.out_md
save_baseline = args.save_baseline
verify_det = args.verify_determinism is not None
stage_diff = args.stage_diff or args.verify_determinism or ""
ab_base = args.ab
want_stages = bool(save_baseline or stage_diff or ab_base)
if args.scenarios or "all" in args.scenario:
    scenario_names = list(scenarios)
else:
    scenario_names = list(dict.fromkeys(args.scenario)) or ["default"]
hw_overrides = {
    name: [*scenarios[name]["hw_set"], *args.hw_set]
    for name in scenario_names
}
orca_extra = dict(setting.split("=", 1) for setting in args.orca_set)
orca_overrides = {
    name: {**scenarios[name]["orca_set"], **orca_extra}
    for name in scenario_names
}
if args.orca_set and not compare_orca:
    parser.error("--orca-set requires --compare-orca")
if ab_base:
    if not (os.path.isfile(ab_base) and os.access(ab_base, os.X_OK)):
        parser.error(f"baseline CLI binary not found or not executable: {ab_base}")
    if os.path.isfile(cli) and os.path.samefile(ab_base, cli):
        parser.error("--ab requires a saved CLI binary outside the candidate build path")
    ab_base = os.path.abspath(ab_base)
if compare_orca and not os.access(orca_bin, os.X_OK):
    parser.error(f"OrcaSlicer binary not found or not executable: {orca_bin}")

def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()

def baseline_key(record):
    return (
        record["name"],
        record["material"],
        record["process"],
        record.get("scenario", "default"),
        tuple(record.get("hw_set", [])),
    )

baseline_data = {}
if stage_diff:
    bp = os.path.join(stage_diff, "baseline.json") if os.path.isdir(stage_diff) else stage_diff
    if not os.path.exists(bp):
        print(f"[slice-benchmark] baseline file not found: {bp}", file=sys.stderr)
        sys.exit(1)
    with open(bp) as f:
        raw_base = json.load(f)
    baseline_data = {baseline_key(r): r for r in raw_base.get("results", [])}

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

if args.model:
    unknown_models = set(args.model) - {case["name"] for case in cases}
    if unknown_models:
        parser.error(f"unknown model in suite {suite}: {', '.join(sorted(unknown_models))}")
    cases = [case for case in cases if case["name"] in args.model]
if not cases:
    parser.error(f"no models matched suite={suite}")

model_count = len(cases)
cases = [
    {**model, "scenario": scenario, "hw_set": hw_overrides[scenario]}
    for scenario in scenario_names
    for model in cases
]

def case_label(record):
    name, scenario = record["name"], record["scenario"]
    return f"{name} [{scenario}]" if scenario != "default" or len(scenario_names) > 1 else name

build = subprocess.run(["./build.sh", "cli-release"], stdout=sys.stderr)
if build.returncode:
    sys.exit(build.returncode)

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
        ("pla", fil_pla),
        ("abs", fil_abs),
    ]:
        p = os.path.join(tmpdir, f"orca_{key}.json")
        with open(p, "w") as f:
            json.dump(obj, f)
        paths[key] = p
    processes = {
        "0.20-standard": make_proc("0.20-standard", "0.42", 3, 4, "0.8", 15),
        "voron-2.4-standard": make_proc("voron-2.4-standard", "0.4", 4, 5, "1.0", 40),
        "voron-2.4-high-stress": make_proc("voron-2.4-high-stress", "0.4", 5, 8, "1.6", 50),
    }
    for process_name, scenario in dict.fromkeys((case["process"], case["scenario"]) for case in cases):
        process = {**processes[process_name], **orca_overrides[scenario]}
        path = os.path.join(tmpdir, f"orca_{process_name}_{scenario}.json")
        with open(path, "w") as f:
            json.dump(process, f)
        paths[process_name, scenario] = path
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
ab_total_base_ms = 0.0
ab_total_cand_ms = 0.0
ab_exact_count = 0
ab_paired_count = 0

with tempfile.TemporaryDirectory(prefix="hw-slicer-bench-") as tmpdir:
    out_gcode = os.path.join(tmpdir, "out.gcode")
    trace_json = os.path.join(tmpdir, "trace.json")
    ab_base_gcode = os.path.join(tmpdir, "ab_base.gcode")
    ab_base_trace = os.path.join(tmpdir, "ab_base_trace.json")
    det_gcode = os.path.join(tmpdir, "det.gcode")
    orca_out_dir = os.path.join(tmpdir, "orca_out")
    os.makedirs(orca_out_dir, exist_ok=True)
    orca_profiles = write_orca_profiles(tmpdir) if compare_orca else {}

    for idx, c in enumerate(cases, 1):
        label = case_label(c)
        scenario = c["scenario"]
        slice_args = [
            f"--input={c['path']}",
            f"--printer={c['printer']}",
            f"--material={c['material']}",
            f"--process={c['process']}",
            *(f"--set={setting}" for setting in c["hw_set"]),
        ]
        cmd = [cli, *slice_args, f"--out={out_gcode}"]
        if want_stages:
            cmd.append(f"--trace-json={trace_json}")
        if threads:
            cmd.append(f"--threads={threads}")

        ab_base_cmd = None
        if ab_base:
            ab_base_cmd = [
                ab_base,
                *slice_args,
                f"--out={ab_base_gcode}",
                f"--trace-json={ab_base_trace}",
            ]
            if threads:
                ab_base_cmd.append(f"--threads={threads}")

        best_ms = None
        best_stdout = ""
        err_text = ""
        ok = True
        cand_samples = []
        base_samples = []
        stage_samples = {}
        stage_order = []
        base_stage_samples = {}
        gcode_sha = None
        base_gcode_sha = None

        def run_one(run_cmd, t_json_path, s_samples, s_order):
            t0 = time.perf_counter()
            p = subprocess.run(run_cmd, capture_output=True, text=True)
            dt_ms = (time.perf_counter() - t0) * 1000.0
            if p.returncode != 0:
                msg = (p.stderr or p.stdout).strip().splitlines()[-1] if (p.stderr or p.stdout).strip() else f"exit {p.returncode}"
                return False, dt_ms, p.stdout, msg
            if want_stages and t_json_path and os.path.exists(t_json_path):
                with open(t_json_path) as tf:
                    td = json.load(tf)
                for st in td.get("stages", []):
                    sn = st["name"]
                    if sn not in s_samples:
                        s_samples[sn] = []
                        if s_order is not None:
                            s_order.append(sn)
                    s_samples[sn].append(float(st["duration_ms"]))
            return True, dt_ms, p.stdout, ""

        for run_idx in range(runs):
            order = ("base", "cand") if (ab_base and run_idx % 2 == 0) else (("cand", "base") if ab_base else ("cand",))
            for which in order:
                if which == "base":
                    rok, dt_ms, _, rerr = run_one(ab_base_cmd, ab_base_trace, base_stage_samples, None)
                    if not rok:
                        ok = False
                        err_text = f"baseline failed: {rerr}"
                        break
                    base_samples.append(dt_ms)
                    if run_idx == 0:
                        base_gcode_sha = sha256_file(ab_base_gcode)
                else:
                    rok, dt_ms, rstdout, rerr = run_one(cmd, trace_json, stage_samples, stage_order)
                    if not rok:
                        ok = False
                        err_text = rerr
                        break
                    cand_samples.append(dt_ms)
                    if best_ms is None or dt_ms < best_ms:
                        best_ms = dt_ms
                        best_stdout = rstdout
                    if run_idx == 0 and (verify_det or save_baseline or ab_base):
                        gcode_sha = sha256_file(out_gcode)
            if not ok:
                break

        ab_gcode_exact = (gcode_sha == base_gcode_sha) if (ok and ab_base and gcode_sha and base_gcode_sha) else None

        det_status = None
        if ok and verify_det:
            det_ok = True
            for variant, extra_flag in (("threads=1", "--threads=1"), ("no-gpu", "--no-gpu")):
                dcmd = [cli, *slice_args, extra_flag, f"--out={det_gcode}"]
                dp = subprocess.run(dcmd, capture_output=True, text=True)
                if dp.returncode != 0:
                    ok = False
                    det_ok = False
                    err_text = f"determinism {variant} failed (exit {dp.returncode})"
                    break
                dsha = sha256_file(det_gcode)
                if dsha != gcode_sha:
                    ok = False
                    det_ok = False
                    err_text = f"determinism mismatch ({variant}: {dsha[:12]} != {gcode_sha[:12]})"
                    break
            bsha = baseline_data.get(baseline_key(c), {}).get("gcode_sha256")
            if det_ok and bsha:
                if gcode_sha != bsha:
                    ok = False
                    det_ok = False
                    err_text = f"baseline hash mismatch ({gcode_sha[:12]} != {bsha[:12]})"
            if det_ok and ab_base and ab_gcode_exact is False:
                ok = False
                det_ok = False
                err_text = f"ab hash mismatch ({gcode_sha[:12]} != {base_gcode_sha[:12]})"
            det_status = "3-way exact" if det_ok else err_text

        rec = {
            "suite": c["suite"],
            "name": c["name"],
            "scenario": scenario,
            "hw_set": c["hw_set"],
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
        if ok and ab_base and base_samples and cand_samples:
            bmed = statistics.median(base_samples)
            cmed = statistics.median(cand_samples)
            dmed = cmed - bmed
            dpct = (dmed / bmed * 100.0) if bmed > 0 else 0.0
            rec["ab"] = {
                "base_median_ms": round(bmed, 2),
                "cand_median_ms": round(cmed, 2),
                "base_min_ms": round(min(base_samples), 2),
                "cand_min_ms": round(min(cand_samples), 2),
                "delta_ms": round(dmed, 2),
                "delta_pct": round(dpct, 2),
                "gcode_exact": ab_gcode_exact,
                "stages": {
                    sn: {
                        "base_median_ms": round(statistics.median(base_stage_samples[sn]), 2),
                        "cand_median_ms": round(statistics.median(stage_samples[sn]), 2),
                        "delta_ms": round(statistics.median(stage_samples[sn]) - statistics.median(base_stage_samples[sn]), 2),
                    }
                    for sn in stage_order
                    if sn in base_stage_samples and base_stage_samples[sn]
                },
            }
            ab_total_base_ms += bmed
            ab_total_cand_ms += cmed
            ab_paired_count += 1
            if ab_gcode_exact:
                ab_exact_count += 1
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
            rec["orca_set"] = orca_overrides[scenario]
            orca_process = orca_profiles[c["process"], scenario]
            orca_cmd = [
                orca_bin,
                "--slice", "0",
                "--arrange", "1",
                "--load-settings", f"{orca_profiles['machine']};{orca_process}",
                "--load-filaments", orca_profiles[c["material"]],
                "--outputdir", orca_out_dir,
                c["path"],
            ]
            best_orca = None
            orca_ok = True
            orca_err = ""
            for _ in range(runs):
                for old_gf in os.listdir(orca_out_dir):
                    if old_gf.endswith(".gcode"):
                        os.unlink(os.path.join(orca_out_dir, old_gf))
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
                if ok and os.path.exists(out_gcode):
                    gfiles = sorted(f for f in os.listdir(orca_out_dir) if f.endswith(".gcode"))
                    if gfiles:
                        hw_g = orca_cmp_mod.parse_gcode(out_gcode)
                        or_g = orca_cmp_mod.parse_gcode(os.path.join(orca_out_dir, gfiles[0]))
                        rec["orca_compare"] = orca_cmp_mod.compare_parsed(
                            hw_g, or_g, orca_cmp_mod.parse_hw_time_seconds(best_stdout),
                            relaxed_geometry=scenarios[scenario]["relaxed_geometry"],
                        )
            else:
                rec["orca_error"] = orca_err

        if ok:
            if ab_base and "ab" in rec:
                ab = rec["ab"]
                hstr = "exact" if ab["gcode_exact"] else "DIFF "
                print(f"[{idx:3d}/{len(cases)}] OK   base={ab['base_median_ms']:7.1f} ms  cand={ab['cand_median_ms']:7.1f} ms  ({ab['delta_ms']:+6.1f} ms, {ab['delta_pct']:+5.1f}%)  hash={hstr}  {label}", flush=True)
            elif compare_orca and rec.get("orca_ok"):
                print(f"[{idx:3d}/{len(cases)}] OK   hw={best_ms:6.1f} ms  orca={rec['orca_ms']:7.1f} ms  ({rec['speedup_vs_orca']:5.2f}x)  {label}", flush=True)
            elif compare_orca:
                print(f"[{idx:3d}/{len(cases)}] OK   hw={best_ms:6.1f} ms  orca=FAIL             {label}", flush=True)
            else:
                print(f"[{idx:3d}/{len(cases)}] OK   {best_ms:7.1f} ms  {c['process']:22s}  {label}", flush=True)
        else:
            rec["error"] = err_text
            failures.append(rec)
            print(f"[{idx:3d}/{len(cases)}] FAIL            {c['process']:22s}  {label}  ({err_text})", flush=True)
        results.append(rec)

summary = {
    "suite": suite,
    "scenarios": scenario_names,
    "hw_set": args.hw_set,
    "orca_set": args.orca_set,
    "runs_per_model": runs,
    "threads": threads or "default",
    "compare_orca": compare_orca,
    "total_models": model_count,
    "total_cases": len(cases),
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

if ab_base and ab_paired_count > 0:
    ab_delta_ms = ab_total_cand_ms - ab_total_base_ms
    ab_delta_pct = (ab_delta_ms / ab_total_base_ms * 100.0) if ab_total_base_ms > 0 else 0.0
    summary["ab"] = {
        "baseline_binary": ab_base,
        "candidate_binary": cli,
        "paired_count": ab_paired_count,
        "gcode_exact_count": ab_exact_count,
        "base_total_median_ms": round(ab_total_base_ms, 2),
        "cand_total_median_ms": round(ab_total_cand_ms, 2),
        "delta_ms": round(ab_delta_ms, 2),
        "delta_pct": round(ab_delta_pct, 2),
    }

print("\n=== SUMMARY ===")
print(f"Suite: {suite} | Passed: {summary['passed']}/{len(cases)} | Total hw_slicer wall: {total_wall_ms:.1f} ms ({total_wall_ms/1000.0:.2f} s)")
if scenario_names != ["default"] or args.hw_set or args.orca_set:
    print(f"Scenarios: {', '.join(scenario_names)} across {model_count} model(s)")
    if args.hw_set:
        print(f"hw_slicer overrides: {', '.join(args.hw_set)}")
    if args.orca_set:
        print(f"OrcaSlicer overrides: {', '.join(args.orca_set)}")
if compare_orca and ratios:
    print(f"OrcaSlicer 2.5.1 total wall: {total_orca_ms:.1f} ms ({total_orca_ms/1000.0:.2f} s)")
    print(f"Overall speedup: {summary['overall_speedup']:.2f}x | Geomean: {summary['geomean_speedup']:.2f}x | Median: {summary['median_speedup']:.2f}x | hw_slicer faster on {hw_faster_count}/{len(ratios)} parts")
for k, v in sorted(suite_wall_ms.items()):
    cnt = suite_counts[k]
    if compare_orca and k in suite_orca_ms:
        ov = suite_orca_ms[k]
        print(f"  {k:10s}: {cnt:3d} cases  hw={v:8.1f} ms ({v/cnt:5.1f} avg)  orca={ov:8.1f} ms ({ov/cnt:5.1f} avg)  speedup={ov/v:.2f}x")
    else:
        print(f"  {k:10s}: {cnt:3d} cases  {v:8.1f} ms total  ({v/cnt:6.1f} ms avg)")

if ab_base and ab_paired_count > 0:
    ab_s = summary["ab"]
    print(f"\n=== A/B COMPARISON (interleaved, median of {runs} run{'s' if runs != 1 else ''}) ===")
    print(f"Baseline:  {ab_base}")
    print(f"Candidate: {cli}")
    print(f"Combined median wall: {ab_s['base_total_median_ms']:.1f} -> {ab_s['cand_total_median_ms']:.1f} ms ({ab_s['delta_ms']:+.1f} ms, {ab_s['delta_pct']:+.1f}%) | G-code exact: {ab_exact_count}/{ab_paired_count}")
    for r in results:
        if not r.get("ok") or "ab" not in r:
            continue
        st_diffs = [
            (sn, st)
            for sn, st in r["ab"].get("stages", {}).items()
            if abs(st["delta_ms"]) >= 0.5
        ]
        if st_diffs:
            print(f"  {case_label(r)} stage medians:")
            for sn, st in st_diffs:
                bm, cm, dm = st["base_median_ms"], st["cand_median_ms"], st["delta_ms"]
                spct = (dm / bm * 100.0) if bm > 0 else 0.0
                print(f"    {sn:24s} {bm:6.2f} -> {cm:6.2f} ms ({dm:+6.2f}, {spct:+5.1f}%)")

if compare_orca:
    cmp_rows = [r for r in results if "orca_compare" in r]
    if cmp_rows:
        print("\n=== ORCASLICER RESULT COMPARISON (G-code geometry, filament, motion) ===")
        for r in cmp_rows:
            orca_cmp_mod.print_comparison(case_label(r), r["orca_compare"])

if save_baseline:
    os.makedirs(save_baseline, exist_ok=True)
    bp = os.path.join(save_baseline, "baseline.json")
    with open(bp, "w") as f:
        json.dump(summary, f, indent=2)
    print(f"Saved baseline (hashes + stage timings): {bp}")

if stage_diff and baseline_data:
    print("\n=== STAGE DIFF (min_ms / median_ms vs baseline) ===")
    for r in results:
        b = baseline_data.get(baseline_key(r))
        if not b or not r.get("ok") or "stages" not in r or "stages" not in b:
            continue
        bw = b.get("wall_ms") or 0.0
        cw = r.get("wall_ms") or 0.0
        dw = cw - bw
        pct = (dw / bw * 100.0) if bw > 0 else 0.0
        print(f"\n  {case_label(r)}  wall: {bw:.1f} -> {cw:.1f} ms ({dw:+.1f} ms, {pct:+.1f}%)")
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
        f.write("# End-to-end slicing benchmark\n\n")
        f.write(f"Suite `{suite}` covered {model_count} models and {len(cases)} cases with {runs} runs per case.\n\n")
        f.write("Scenarios " + ", ".join(f"`{name}`" for name in scenario_names) + ".\n\n")
        for name, overrides in (("hw_slicer", args.hw_set), ("OrcaSlicer", args.orca_set)):
            if overrides:
                f.write(f"{name} overrides " + ", ".join(f"`{value}`" for value in overrides) + ".\n\n")
        if ab_base:
            f.write("## A/B comparison\n\n")
            f.write("| Case | Baseline median (ms) | Candidate median (ms) | Delta (%) | G-code |\n")
            f.write("|---|---:|---:|---:|---|\n")
            for r in results:
                ab = r.get("ab")
                if ab:
                    exact = "Identical" if ab["gcode_exact"] else "Different"
                    f.write(f"| `{case_label(r)}` | {ab['base_median_ms']:.1f} | {ab['cand_median_ms']:.1f} | {ab['delta_pct']:+.1f} | {exact} |\n")
                else:
                    f.write(f"| `{case_label(r)}` | — | — | — | Failed |\n")
            f.write("\n")
        if compare_orca and ratios:
            f.write("## Summary\n\n")
            f.write("| Metric | Value |\n|---|---:|\n")
            f.write(f"| Cases sliced | {summary['passed']}/{len(cases)} |\n")
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
                f.write(f"| {i} | `{case_label(r)}` | `{r['process']}` | {r.get('tris', 0)} | {r.get('layers', 0)} | {hw_s} | {or_s} | {sp_s} |\n")
    print(f"Wrote Markdown report: {out_md}")

if failures:
    print("\n=== FAILURES ===")
    for f in failures:
        print(f"  {case_label(f)}: {f['error']}")
    sys.exit(1)
PY

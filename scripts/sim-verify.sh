#!/usr/bin/env bash
set -euo pipefail

# Closed-loop verification: slice a mesh with hw-slicer-cli and execute the resulting
# Klipper G-code end-to-end through hw-printer + hw-printer-sim (local pseudo-terminal only;
# never connects to physical hardware).

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PRINTER_DIR="${HW_PRINTER_DIR:-$ROOT_DIR/../hw_printer}"
SLICER_BIN="$ROOT_DIR/build/release/hw-slicer-cli"
if [ ! -x "$SLICER_BIN" ]; then
  SLICER_BIN="$ROOT_DIR/build/hw-slicer-cli"
fi
SIM_BIN="$PRINTER_DIR/build/darwin_arm64-debug/hw-printer-sim"
HOST_BIN="$PRINTER_DIR/build/darwin_arm64-debug/hw-printer"

OUT_DIR="$ROOT_DIR/build/test-out/sim-verify"
mkdir -p "$OUT_DIR"

MODEL="${1:-}"
shift || true

if [ -z "$MODEL" ]; then
  MODEL="$OUT_DIR/sim-pad.obj"
  cat > "$MODEL" <<'EOF'
v 0 0 0
v 12 0 0
v 12 12 0
v 0 12 0
v 0 0 1.2
v 12 0 1.2
v 12 12 1.2
v 0 12 1.2
f 1 3 2
f 1 4 3
f 5 6 7
f 5 7 8
f 1 2 6
f 1 6 5
f 2 3 7
f 2 7 6
f 3 4 8
f 3 8 7
f 4 1 5
f 4 5 8
EOF
fi

if [ ! -x "$SLICER_BIN" ]; then
  echo "error: hw-slicer-cli not found; run ./build.sh cli-release or ./build.sh debug" >&2
  exit 1
fi
if [ ! -x "$SIM_BIN" ] || [ ! -x "$HOST_BIN" ]; then
  echo "error: hw-printer / hw-printer-sim not found in $PRINTER_DIR/build/darwin_arm64-debug" >&2
  exit 1
fi

GCODE="$OUT_DIR/job.gcode"
STEPS="$OUT_DIR/job.steps"
SIM_LOG="$OUT_DIR/sim.log"
HOST_LOG="$OUT_DIR/host.log"
PTY_LINK="/tmp/hw-slicer-verify-$$"

cleanup() {
  if [ -n "${SIM_PID:-}" ]; then
    kill "$SIM_PID" 2>/dev/null || true
    wait "$SIM_PID" 2>/dev/null || true
  fi
  rm -f "$PTY_LINK"
}
trap cleanup EXIT

echo "==> Slicing $MODEL"
"$SLICER_BIN" "$MODEL" \
  --printer=vcore3 \
  --material=pla \
  --process=0.28-draft \
  --arcs \
  --zhop=0.4 \
  "$@" \
  -o "$GCODE"

echo "==> Starting local hw-printer-sim on $PTY_LINK"
"$SIM_BIN" --link="$PTY_LINK" --steps="$STEPS" >"$SIM_LOG" 2>&1 &
SIM_PID=$!

for _ in $(seq 1 50); do
  [ -e "$PTY_LINK" ] && break
  sleep 0.1
done

echo "==> Running hw-printer against $GCODE (--skip-heat)"
"$HOST_BIN" --serial="$PTY_LINK" --gcode="$GCODE" --skip-heat >"$HOST_LOG" 2>&1

echo "==> Closed-loop print completed with exit code 0"
echo "    Total step pulses: $(wc -l < "$STEPS" | tr -d ' ')"
awk '{c[$1]++} END {for (k in c) printf "    pin %-4s : %d steps\n", k, c[k]}' "$STEPS" | sort
tail -n 3 "$HOST_LOG"

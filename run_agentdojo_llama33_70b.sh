#!/usr/bin/env bash
# DRIFT x AgentDojo benchmark on Llama-3.3-70B-Instruct.
# Reuses the already-running vLLM server on port 18083 (tensor-parallel-size 8,
# started by the tool_filter experiment) instead of spinning up a second 70B instance,
# since all 8 GPUs are already saturated by that server.
#
# Runs two phases sequentially, each with the 4 suites in parallel:
#   1. none                  -> benign utility (no attack)
#   2. important_instructions -> utility/security under attack
#
# Results land in DRIFT/runs/Llama-3.3-70B-Instruct/<suite>/... (same layout the
# AgentDojo scoring code expects: user_task_X/none/none.json or
# user_task_X/important_instructions/injection_task_Y.json).

set -uo pipefail

# Portable: resolves relative to this script, and only fills in defaults for
# anything you haven't already exported/overridden (so on a different machine
# you can just `export OPENAI_BASE_URL=...` etc. before calling this script).
DRIFT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY="${DRIFT_PYTHON:-python3}"
LOGROOT="${LOGROOT:-$DRIFT_DIR/runs_eval_logs/drift-eval-llama33-70b-$(date +%Y%m%d)}"
mkdir -p "$LOGROOT"

export OPENAI_BASE_URL="${OPENAI_BASE_URL:-http://127.0.0.1:18083/v1}"
export OPENAI_COMPATIBLE_BASE_URL="${OPENAI_COMPATIBLE_BASE_URL:-$OPENAI_BASE_URL}"
export OPENAI_API_KEY="${OPENAI_API_KEY:-EMPTY}"
export OPENAI_COMPATIBLE_API_KEY="${OPENAI_COMPATIBLE_API_KEY:-$OPENAI_API_KEY}"
export PYTHONUNBUFFERED=1

MODEL="${DRIFT_MODEL:-Llama-3.3-70B-Instruct}"
SUITES=(banking slack travel workspace)

cd "$DRIFT_DIR"

log() { printf '%s %s\n' "$(date -Is)" "$*" | tee -a "$LOGROOT/queue.log"; }

run_phase() {
  local phase="$1"; shift
  local extra_args=("$@")
  local pids=()
  log "phase=$phase starting (suites: ${SUITES[*]})"
  for suite in "${SUITES[@]}"; do
    local out="$LOGROOT/${phase}-${suite}.log"
    nohup "$PY" pipeline_main.py \
      --model "$MODEL" \
      --suites "$suite" \
      --benchmark_version v1.2.2 \
      --build_constraints --injection_isolation --dynamic_validation \
      "${extra_args[@]}" \
      > "$out" 2>&1 &
    local pid=$!
    echo "$pid" > "$LOGROOT/${phase}-${suite}.pid"
    pids+=("$pid")
    log "phase=$phase suite=$suite pid=$pid log=$out"
  done
  local failed=0
  for pid in "${pids[@]}"; do
    if ! wait "$pid"; then
      failed=1
    fi
  done
  log "phase=$phase finished failed=$failed"
  return "$failed"
}

log "queue started (model=$MODEL, server=$OPENAI_BASE_URL)"
run_phase none || true
run_phase important_instructions --do_attack --attack_type important_instructions || true
log "queue finished"

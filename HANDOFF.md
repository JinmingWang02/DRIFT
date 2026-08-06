# Handoff: continuing the DRIFT x AgentDojo (Llama-3.3-70B-Instruct) run

This repo is a fork of [SaFo-Lab/DRIFT](https://github.com/SaFo-Lab/DRIFT) with two
small patches on top (see `git log`) plus the partial results already produced.
You do **not** need our original server, our Python venv, or our chat template —
`agentdojo` is a plain PyPI package (`agentdojo==0.1.35`), pinned in
`requirements.txt`. Everything DRIFT needs is in this repo.

## 1. Environment

```bash
python3.11 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
# two deps missing from requirements.txt that DRIFT actually needs:
pip install numpy json_repair
```

## 2. Point DRIFT at a model

DRIFT talks to the model purely as plain OpenAI-compatible chat completions — it
never sends a `tools=` parameter. It embeds tool definitions as text in the system
prompt and parses a custom `<function_call>[...]</function_call>` tag format out of
the plain response text itself (see `prompts.py` / `DRIFTLLM.py::_parse_model_output`).
**This means you do NOT need vLLM's `--enable-auto-tool-choice`, a `--tool-call-parser`,
or any special tool-calling chat template** — that machinery is irrelevant here since
DRIFT never triggers it. A completely default chat template is fine.

Two options, pick whichever is easier on your box:

### Option A — self-host with vLLM (matches how we produced the existing results)

```bash
vllm serve /path/to/Llama-3.3-70B-Instruct \
  --served-model-name Llama-3.3-70B-Instruct \
  --host 127.0.0.1 --port 8000 \
  --tensor-parallel-size <N_GPUS> \
  --gpu-memory-utilization 0.90 \
  --max-model-len 32768
```

No custom `--chat-template` needed — just the model's default one. You need
weights for Llama-3.3-70B-Instruct locally (~140GB in bf16) and enough GPU memory
to hold them (we used 8x GPUs w/ tensor-parallel-size 8; fewer/smaller GPUs work
with a quantized checkpoint, e.g. AWQ/GPTQ, but that's a different model file and
will likely shift the numbers slightly vs. our bf16 results — mention it if you go
that route).

```bash
export OPENAI_BASE_URL=http://127.0.0.1:8000/v1
export OPENAI_API_KEY=EMPTY
```

### Option B — hosted API (no local GPU serving needed)

Any OpenAI-compatible hosted provider that serves Llama-3.3-70B-Instruct works
(OpenRouter, Together, Fireworks, etc.). Point the same env vars at it:

```bash
export OPENAI_BASE_URL=https://openrouter.ai/api/v1   # or your provider's base URL
export OPENAI_API_KEY=<your-provider-api-key>
```

Caveat: a hosted provider's decoding defaults/quantization may differ from our
local bf16 vLLM serve, so ASR/utility numbers could shift slightly vs. the numbers
already in `runs/Llama-3.3-70B-Instruct/`. Worth noting in the write-up if you mix
sources.

(`client.py` also reads `OPENAI_COMPATIBLE_BASE_URL` / `OPENAI_COMPATIBLE_API_KEY`
as aliases for the two vars above, in case you're reusing scripts that already set
those names.)

## 3. Resume the run

Progress so far (attack phase, `--attack_type important_instructions`):

| Suite | Done |
|---|---|
| banking | 143 / 144 |
| slack | 105 / 105 (complete) |
| travel | 107 / 140 |
| workspace | 176 / 560 |

Benign utility (no-attack phase) is fully complete for all 4 suites.

`pipeline_main.py` skips any (user_task, injection_task) pair whose result file
already exists under `runs/Llama-3.3-70B-Instruct/<suite>/...`, so you can just
rerun the same queue script and it will continue exactly where we stopped —
nothing gets recomputed.

Edit `run_agentdojo_llama33_70b.sh` if your model name/served name differs from
`Llama-3.3-70B-Instruct`, then:

```bash
export OPENAI_BASE_URL=...      # from step 2
export OPENAI_API_KEY=...
./run_agentdojo_llama33_70b.sh
```

It runs the no-attack phase first (will skip everything instantly since it's
already done), then the important_instructions attack phase across all 4 suites
in parallel, picking up from the counts above. `workspace` is the long pole
(560 pairs total) — budget several hours to a day depending on your GPU/provider
throughput.

## 4. Known quirk worth knowing about

`DRIFTLLM.py`'s `fix_function_calls` helper does a naive comma-split on the raw
`<function_call>...</function_call>` text, which can occasionally mangle a string
argument that contains a bare word right next to a comma (e.g. turns
`..., France, from...` into `..., France(), from...`), corrupting that argument
and causing a spurious "not aligned with checklist" rejection downstream. This is
upstream DRIFT behavior (not something we introduced) and shows up more with
verbose Llama output than terser GPT-4o-mini output. Not worth chasing unless you
see a suspiciously high rejection rate for a particular suite.

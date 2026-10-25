# cosmos3-brev-runner

> **Status: GPU-validated at commit `7ebbe8f`.** Same launchable, same scene (seed 0): L4 `g2-standard-8` ran out of CUDA memory (`RESULT=FAIL reason=server-exited-before-ready`, exit 1); RTX PRO 6000 Blackwell `g7e.2xlarge` rendered the clip (`RESULT=PASS`, model load 180 s, render 369 s, about 24 min from create to done). Both workspaces were deleted; total GPU cost was about $2.66.

Render one image-to-video clip **with sound** using NVIDIA Cosmos3-Nano on a [Brev](https://brev.nvidia.com) GPU, driven entirely from a machine with no GPU and no shell on the GPU VM: no `brev ssh`, no `brev exec`, no copy, port-forward or tunnel. Only Brev's control plane (create, status, logs API, delete).

- Model: `nvidia/Cosmos3-Nano` (revision `e59a53c25979a090fa8706c9acc0c254a6e89b92`), served by vLLM-Omni (`vllm/vllm-omni@sha256:86fb713bf73e118e537a55fa013dcdbdf2468ed61b98f4f2e7934a9482181dc1`).
- Output: 1280x720, 189 frames at 24 fps, generated sound (7.875 s).
- GPU: a 96 GB-class GPU such as RTX PRO 6000 Blackwell (e.g. Brev `g7e.2xlarge`). A 24 GB L4 ran out of memory in the prototype run.
- **Guardrails are off:** the server runs with `--no-guardrails`, because the guardrail model `nvidia/Cosmos-1.0-Guardrail` is gated and fails to load without a Hugging Face token. You are responsible for the prompts and inputs you use.
- No secrets reach the VM: the model weights are public, so no Hugging Face or NGC token is needed. Only your `BREV_API_KEY` is used, on your own machine.

## Use with an agent

Give this repo to your coding agent with a prompt like: **"Reproduce the Cosmos3 runner from this repo: dry-run first, then an L4 run (expected out of memory), then RTX PRO 6000, cap $6 total, and clean up."** The agent can follow the "Agent handoff" section below step by step: preflight, repo/ref validation, `--dry-run`, the expected L4 failure and its diagnosis from the logs, the success run, hash/preview validation, cleanup and an evidence report.

Boundaries for the agent: no `brev ssh`/`shell`/`exec`/`copy`/`port-forward`; never write `BREV_API_KEY` or any credential to files, logs or launch parameters; never launch before the human confirms the cost cap; one workspace at a time; always delete and verify absent.

Human-only steps:
1. Create a Brev API key and export it as `BREV_API_KEY` (outside the repo).
2. Push this repo to a public URL and pick the commit (`--ref`).
3. Create the launchable once in the Brev console (settings in step 2 of "Exact steps").
4. Choose the cost cap.
5. Review the Cosmos3-Nano model terms (`openmdw1.1-license`); no token is needed.

## Agent handoff

### Goal
Produce one Cosmos3-Nano image-to-video clip with sound in `media/current/`, using only Brev's control plane, then leave no workspace running.

### Prerequisites
- A machine with Python 3.9+, `git`, and the Brev CLI on `PATH` (no GPU needed).
- A Brev account/org you can bill to, and its API key exported as `BREV_API_KEY` from your own secret store. Never echo it.
- This repo pushed to a **public** git URL you control (the GPU VM clones it), and a 40-char commit sha.
- Access to a 96 GB-class GPU type on Brev (e.g. RTX PRO 6000 Blackwell); check names and prices with `brev search`.

### Configurable inputs (none have personal defaults)
| Input | Where | Notes |
|---|---|---|
| `--launchable` | `run.py` | ID of the launchable **you** create in step 2 (required) |
| `--repo`, `--ref` | `run.py` | your public repo URL and pinned 40-char commit (required) |
| `--name` | `run.py` | workspace name, lowercase/digits/dashes (required) |
| `--type`, `--price`, `--cap-min` | `run.py` | instance type, USD/hr for the ledger, hard cap in minutes (required) |
| `BREV_API_KEY` | env | your key (required) |
| `scene/prompt.json`, `scene/scene.env` | repo | prompt; `SCENE_NAME`, `INPUT_IMAGE_URL`, `INPUT_IMAGE_SHA256`, `SEED` |
| `--param NAME=value` | `run.py` | optional non-secret overrides: `INPUT_IMAGE_URL`, `INPUT_IMAGE_SHA256`, `SCENE_NAME`, `SEED`, `DEADLINE_S` |

### Exact steps
1. Push this repo to your public URL; record `REF=$(git rev-parse HEAD)`.
2. In the Brev console create a launchable: VM mode, your 96 GB-class GPU, ~300 GB disk, setup script = contents of `launchable/setup.sh`, text parameters `REPO`, `REF`, `BOOTSTRAP` (+ optional `INPUT_IMAGE_URL`, `INPUT_IMAGE_SHA256`, `SCENE_NAME`, `SEED`, `DEADLINE_S`). No credential parameters. Record its `env-…` ID.
3. Preflight (never calls Brev):
   `python3 run.py --launchable <env-id> --repo <url> --ref <sha> --name <ws> --type <instance> --price <usd/hr> --cap-min 45 --dry-run`
   Expect `[preflight] OK` and the full `brev create …` command.
4. Run the same command without `--dry-run`.

### Expected signals
- Progress: `[brev] t+…m … RUNNING …` lines with a running cost, then `[c3] …` lines as the setup log streams in. The runner stops polling only on the bootstrap's final `[c3] … done` line or a `[launchable] … RESULT=FAIL` line; a setup that dies without either is caught by `--cap-min`.
- **Success:** a `RESULT=PASS reason=rendered scene=… render_s=… sha256=…` line, then `[run] returned <scene>_preview.mp4 … MATCH`, exit code 0.
- **Failure:** `RESULT=FAIL reason=<slug>` (e.g. `server-exited-before-ready` with `[c3] err|` out-of-memory lines on a too-small GPU, `input-image-sha-mismatch`, `weights-rev-changed`, `ready-timeout`), exit code 1. Exit 2 = preflight error, 3 = hard cap hit or workspace not found.

### Verification
- `media/current/<scene>_preview.mp4` exists and its sha256 matches the `B64BEGIN` line (the driver prints `MATCH`).
- The `[c3] start` line's `prompt_sha256` matches the one `run.py` printed in preflight (the VM renders `scene/` as committed at `--ref`).

### Cleanup
`run.py` always runs `brev delete <ws>` and polls `brev ls --json` until the name is gone, even after errors or the hard cap. Confirm with `brev ls --json`; if `[run] WARNING` appears, delete manually.

### Known limitations
- Validated on one L4 (expected failure) and one RTX PRO 6000 run at `7ebbe8f`; other GPU types and later commits are untested.
- Runs with `--no-guardrails` (the guardrail model is gated).
- The clip returns as a compressed preview; full resolution only if under 1.5 MB.
- Editing a Brev launchable is console-only; change behaviour by pushing a commit and relaunching with a new `--ref`.
- A 24 GB L4 is expected to run out of memory.
- The default input image is URL-only; its standalone redistribution terms are unverified.

## How it works
```
run.py ──brev create──► thin launchable (launchable/setup.sh)
   │                       clone REPO at pinned REF ─► scripts/brev-bootstrap.sh
   │                         validate scene ─► fetch + hash-check input image ─► pull pinned image
   │                         ─► download public weights ─► vllm serve --omni --no-guardrails
   │                         ─► one /v1/videos/sync render ─► RESULT=PASS|FAIL ─► clip as base64 in the log
   ├─poll brev ls + logs API, decode clip, verify sha256 ─► media/current/
   └─brev delete ─► verify absent (always)
```
The Brev setup log is capped near 5 MB, so the clip comes back as a **compressed preview** (H.264 crf 28, AAC 96k). The full-resolution file is returned only if it is under 1.5 MB; otherwise only its sha256 is logged.

## Layout
| Path | What |
|---|---|
| `launchable/setup.sh` | Thin launchable setup script: clone `REPO` at a pinned 40-char `REF`, run one repo-relative `BOOTSTRAP` |
| `scripts/brev-bootstrap.sh` | The workload: one image-to-video render, one `RESULT=` line, clip transport through the log |
| `scene/prompt.json`, `scene/scene.env` | The scene: prompt file and non-secret config (`SCENE_NAME`, `INPUT_IMAGE_URL`, `INPUT_IMAGE_SHA256`, `SEED`) |
| `run.py` | Driver: preflight / dry-run, create, poll, logs, decode + verify, delete + verify absent, cost ledger |
| `media/current/` | Generated output (not committed) |

## Swap the scene
Edit `scene/prompt.json` and `scene/scene.env`, commit, and run with the new `--ref`. Or override `INPUT_IMAGE_URL` / `INPUT_IMAGE_SHA256` / `SEED` / `SCENE_NAME` at launch with `--param NAME=value` (non-secret names only; anything else is rejected). Nothing else changes.

## Input image
The default image is referenced **by URL only**: https://huggingface.co/nvidia/Cosmos3-Nano/resolve/main/assets/example_i2v_input.jpg (sha256 `1de51eb5c6d51ec97aa3351a6685717b0253e36073eb9cdd3ef65affa115a4e2`). The model repository declares `license_name: openmdw1.1-license` (https://openmdw.ai/license/1-1/); the image has no separate license or provenance note, so its standalone redistribution terms are unverified and it is not included here. Use an image you are allowed to use.

## Cost
Track `elapsed time × hourly price` (printed while polling and written to `media/current/cost_ledger.txt`). `--cap-min` is a hard cap: the workspace is deleted when it is reached. Check current prices with `brev search`.

## Provenance
A prototype with the same image digest, model revision, server flags and request fields rendered two clips successfully on an RTX PRO 6000 Blackwell and ran out of memory on an L4. This repo is a cleaned-up single-scene version of that workload (scene from files, input-image hash check, exact weights-revision check, thin clone-and-bootstrap launch). This runner was then validated on its own at `7ebbe8f` (see Status above).

## License
Code in this repository: Apache License 2.0 (`LICENSE`). Third-party models, images and containers are under their own terms: see `NOTICE.md`.

#!/bin/bash
# Recommended Cosmos3-Nano workload: ONE image-to-video scene, 1280x720, 189 frames, 24 fps, with sound.
# Run by launchable/setup.sh (thin clone-and-bootstrap) from the repo root:
#   BOOTSTRAP=scripts/brev-bootstrap.sh (the default)
# Status: recommended canonical runner, pending first GPU validation.
# Settings (pinned vLLM-Omni image, Cosmos3-Nano revision, --no-guardrails,
# request fields, log transport) match an earlier verified two-clip prototype run.
# Prints [c3] lines and exactly one RESULT=PASS|FAIL line. Needs no secrets.
set -uo pipefail
set +x

HERE="$(cd "$(dirname "$0")" && pwd)"
SCENE_DIR="${SCENE_DIR:-$HERE/../scene}"
DEADLINE_S="${DEADLINE_S:-3000}"
IMAGE="vllm/vllm-omni@sha256:86fb713bf73e118e537a55fa013dcdbdf2468ed61b98f4f2e7934a9482181dc1"
MODEL=nvidia/Cosmos3-Nano
REV=e59a53c25979a090fa8706c9acc0c254a6e89b92
W=/opt/cosmos3
T_SCRIPT=$(date +%s)
log()  { echo "[c3] $(date -u +%FT%TZ) $*"; }
left() { echo $(( DEADLINE_S - ($(date +%s) - T_SCRIPT) )); }
finish() { log "$*"; log "done"; exit 0; }

# --- scene config: scene.env defaults, launch params (same names) win ---
scene_val() { grep -E "^$1=" "$SCENE_DIR/scene.env" 2>/dev/null | tail -1 | cut -d= -f2-; }
SCENE_NAME="${SCENE_NAME:-$(scene_val SCENE_NAME)}"
if [ -n "${INPUT_IMAGE_URL:-}" ]; then
  INPUT_IMAGE_SHA256="${INPUT_IMAGE_SHA256:-}"   # URL overridden at launch: only a launch-time hash applies
else
  INPUT_IMAGE_URL="$(scene_val INPUT_IMAGE_URL)"
  INPUT_IMAGE_SHA256="${INPUT_IMAGE_SHA256:-$(scene_val INPUT_IMAGE_SHA256)}"
fi
SEED="${SEED:-$(scene_val SEED)}"; SEED="${SEED:-0}"
PROMPT="$SCENE_DIR/prompt.json"
[[ "$SCENE_NAME" =~ ^[a-z0-9_-]{1,40}$ ]] || finish "RESULT=FAIL reason=bad-scene-name"
[[ "$SEED" =~ ^[0-9]+$ ]] || finish "RESULT=FAIL reason=bad-seed"
[[ "$INPUT_IMAGE_URL" =~ ^https:// ]] || finish "RESULT=FAIL reason=input-image-url-must-be-https"
python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$PROMPT" 2>/dev/null || finish "RESULT=FAIL reason=prompt-json-invalid"
log "start scene=${SCENE_NAME} seed=${SEED} prompt_sha256=$(sha256sum "$PROMPT" | cut -c1-16) image_url=${INPUT_IMAGE_URL} deadline_s=${DEADLINE_S}"

sudo mkdir -p "$W/hf" "$W/out" "$W/in" && sudo chown -R "$(id -u):$(id -g)" "$W" && chmod 1777 "$W/hf"
log "disk $(df -h / | tail -1 | awk '{print "size="$2" avail="$4}') ram=$(free -g | awk '/Mem/{print $2"G"}') cpus=$(nproc)"

# --- input image ---
IMG="$W/in/input"
curl -sfL -m 120 -o "$IMG" "$INPUT_IMAGE_URL" || finish "RESULT=FAIL reason=input-image-download"
IMG_SHA=$(sha256sum "$IMG" | cut -c1-64)
log "input image bytes=$(stat -c %s "$IMG") sha256=${IMG_SHA}"
if [ -n "$INPUT_IMAGE_SHA256" ] && [ "$IMG_SHA" != "$INPUT_IMAGE_SHA256" ]; then
  finish "RESULT=FAIL reason=input-image-sha-mismatch expected=${INPUT_IMAGE_SHA256}"
fi
case "$(head -c 4 "$IMG" | od -An -tx1 | tr -d ' \n')" in
  ffd8ff*) mv "$IMG" "$IMG.jpg"; IMG="$IMG.jpg" ;;
  89504e47) mv "$IMG" "$IMG.png"; IMG="$IMG.png" ;;
  *) finish "RESULT=FAIL reason=input-image-not-jpg-or-png" ;;
esac

# --- GPU ---
command -v nvidia-smi >/dev/null || finish "RESULT=FAIL reason=no-nvidia-smi"
GPU=$(nvidia-smi --query-gpu=name,compute_cap,memory.total,driver_version --format=csv,noheader | head -1)
log "gpu ${GPU}"
DRV_MAJOR=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1 | cut -d. -f1)
COMPAT=()
if [ "${DRV_MAJOR:-0}" -lt 580 ]; then COMPAT=(-e VLLM_ENABLE_CUDA_COMPATIBILITY=1); log "driver ${DRV_MAJOR} < 580 (image is CUDA 13.0): enabling CUDA forward-compat"; fi

DOCKER="docker"; docker info >/dev/null 2>&1 || DOCKER="sudo docker"
(sudo apt-get -qq update >/dev/null 2>&1; sudo DEBIAN_FRONTEND=noninteractive apt-get -qq install -y ffmpeg >/dev/null 2>&1; echo "[c3] $(date -u +%FT%TZ) ffmpeg install rc=$?") &

log "pull ${IMAGE}"
T0=$(date +%s)
timeout 1200 $DOCKER pull -q "$IMAGE" >/dev/null || finish "RESULT=FAIL reason=pull-failed"
log "pull ok seconds=$(( $(date +%s) - T0 ))"

log "download ${MODEL} weights (public, no token; expect rev ${REV})"
T0=$(date +%s)
timeout 1500 $DOCKER run --rm -v "$W/hf:/root/.cache/huggingface" "$IMAGE" python3 -c "
from huggingface_hub import snapshot_download
p = snapshot_download('$MODEL', revision='main', ignore_patterns=['images/*','assets/*.mp4','assets/*.png','assets/*.jpg'])
print('[c3] snapshot', p.rsplit('/',1)[-1])
" 2>&1 | grep '^\[c3\]' || finish "RESULT=FAIL reason=weights-download-failed"
SNAP=$(ls "$W/hf/hub/models--nvidia--Cosmos3-Nano/snapshots/" 2>/dev/null | head -1)
[ "$SNAP" = "$REV" ] || finish "RESULT=FAIL reason=weights-rev-changed got=${SNAP:-none} expected=${REV}"
SNAP_DIR="$W/hf/hub/models--nvidia--Cosmos3-Nano/snapshots/$SNAP"
log "weights ok rev=${SNAP} seconds=$(( $(date +%s) - T0 ))"
NEG="$SNAP_DIR/assets/negative_prompt.json"
if [ -f "$NEG" ]; then cp -L "$NEG" "$W/neg.json"; else echo "" > "$W/neg.json"; log "no negative_prompt.json"; fi

log "serve: vllm serve ${MODEL} --omni --no-guardrails (DISCLOSURE: guardrail model nvidia/Cosmos-1.0-Guardrail is gated, so guardrails are off)"
$DOCKER rm -f c3 >/dev/null 2>&1
$DOCKER run -d --name c3 --gpus all --ipc=host -p 8000:8000 "${COMPAT[@]}" \
  -v "$W/hf:/root/.cache/huggingface" "$IMAGE" \
  vllm serve "$MODEL" --omni --no-guardrails --host 0.0.0.0 --port 8000 --init-timeout 1800 >/dev/null \
  || finish "RESULT=FAIL reason=docker-run-failed"
T0=$(date +%s); LAST=0; READY_S=0
while true; do
  if curl -sf -m 5 http://localhost:8000/health >/dev/null 2>&1; then READY_S=$(( $(date +%s) - T0 )); break; fi
  if [ "$($DOCKER inspect -f '{{.State.Running}}' c3 2>/dev/null)" != "true" ]; then
    log "server exited before ready (exit=$($DOCKER inspect -f '{{.State.ExitCode}}' c3)) after $(( $(date +%s) - T0 ))s"
    $DOCKER logs c3 2>&1 | grep -iE "out of memory|OutOfMemory|CUDA error|insufficient|not enough|Tried to allocate|RuntimeError|Error" | tail -25 | sed 's/^/[c3] err| /'
    $DOCKER logs --tail 40 c3 2>&1 | sed 's/^/[c3] srv| /'
    nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader | sed 's/^/[c3] vram| /'
    finish "RESULT=FAIL reason=server-exited-before-ready gpu='${GPU}'"
  fi
  NOW=$(date +%s)
  if [ $(( NOW - LAST )) -ge 120 ]; then LAST=$NOW; log "waiting ready elapsed=$(( NOW - T0 ))s vram=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader)"; $DOCKER logs --tail 2 c3 2>&1 | cut -c1-220 | sed 's/^/[c3] srv| /'; fi
  if [ "$(left)" -lt 420 ]; then $DOCKER logs --tail 40 c3 2>&1 | sed 's/^/[c3] srv| /'; finish "RESULT=FAIL reason=ready-timeout"; fi
  sleep 10
done
log "server ready load_s=${READY_S} vram_used=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader)"
wait  # ffmpeg install

# --- one render ---
OUT="$W/out/${SCENE_NAME}.mp4"
log "render ${SCENE_NAME} start (1280x720, 189 frames, 24 fps, sound, seed ${SEED})"
T0=$(date +%s)
HTTP=$(curl -s -m "$(( $(left) - 240 ))" -o "$OUT" -w '%{http_code}' -H 'Accept: video/mp4' \
  -F "prompt=<${PROMPT}" -F "negative_prompt=<$W/neg.json" -F size=1280x720 -F num_frames=189 -F fps=24 \
  -F num_inference_steps=35 -F guidance_scale=6.0 -F max_sequence_length=4096 -F generate_sound=true -F sound_duration=7.875 \
  -F flow_shift=10.0 -F "seed=${SEED}" \
  --form-string 'extra_params={"use_resolution_template": false, "use_duration_template": false, "guardrails": false}' \
  -F "input_reference=@${IMG}" http://localhost:8000/v1/videos/sync)
RENDER_S=$(( $(date +%s) - T0 ))
if [ "$HTTP" != "200" ] || [ "$(stat -c %s "$OUT" 2>/dev/null || echo 0)" -le 10000 ]; then
  log "render http=${HTTP} render_s=${RENDER_S}"; head -c 800 "$OUT" 2>/dev/null | tr -cd '[:print:]\n' | sed 's/^/[c3] resp| /'; echo
  $DOCKER logs --tail 15 c3 2>&1 | cut -c1-300 | sed 's/^/[c3] srv| /'
  finish "RESULT=FAIL reason=render-failed http=${HTTP} gpu='${GPU}'"
fi
SHA=$(sha256sum "$OUT" | cut -c1-64)
command -v ffprobe >/dev/null && ffprobe -v error -show_entries stream=codec_type,codec_name,width,height,sample_rate,channels:format=duration -of compact "$OUT" | sed 's/^/[c3] probe| /'
log "RESULT=PASS reason=rendered scene=${SCENE_NAME} gpu='${GPU}' load_s=${READY_S} render_s=${RENDER_S} bytes=$(stat -c %s "$OUT") sha256=${SHA}"

# --- transport through the Brev log (capped near 5 MB): compressed preview always, full-res only if small ---
PREVIEW="$W/out/${SCENE_NAME}_preview.mp4"
if command -v ffmpeg >/dev/null && ffmpeg -loglevel error -y -i "$OUT" -c:v libx264 -crf 28 -preset veryfast -c:a aac -b:a 96k "$PREVIEW"; then
  echo "B64BEGIN $(basename "$PREVIEW") $(sha256sum "$PREVIEW" | cut -c1-64)"; base64 -w 200 "$PREVIEW"; echo "B64END"
else log "preview not produced (no ffmpeg)"; fi
if [ "$(stat -c %s "$OUT")" -lt 1500000 ]; then
  echo "B64BEGIN $(basename "$OUT") ${SHA}"; base64 -w 200 "$OUT"; echo "B64END"
else log "full-res $(basename "$OUT") not emitted (log cap); sha256=${SHA}"; fi
finish "emit complete"

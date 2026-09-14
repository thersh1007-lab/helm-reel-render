#!/usr/bin/env bash
# Dedicated MCC reel render worker (runs as a Render cron, triggered per reel).
# Runs the ffmpeg render pipeline DIRECTLY (no LLM, no Bash-tool timeout, no autodeploy
# collision) so long renders finish reliably. Pulls footage from R2, uploads the finished mp4.
#
# Required env: REEL (e.g. c4_flip100k), GITHUB_TOKEN, R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY,
#               R2_ENDPOINT, R2_BUCKET.
set -euo pipefail

REEL="${REEL:?set REEL env, e.g. c4_flip100k}"
WORK="${RENDER_WORK:-/app/render}"
MCC="$WORK/mcc"
mkdir -p "$WORK"

echo "== render worker: REEL=$REEL =="
df -h "$WORK" | tail -1

# Sparse clone: only social/ (proof_prospect + logos + fonts + _tx_cache). The repo's bloated
# history and unrelated dirs are skipped, so the checkout stays small on the cron's ephemeral disk.
if [ ! -d "$MCC/.git" ]; then
  git clone --depth 1 --filter=blob:none --sparse \
    "https://x-access-token:${GITHUB_TOKEN}@github.com/thersh1007-lab/Monument-City-Capital.git" "$MCC"
  git -C "$MCC" sparse-checkout set social
else
  git -C "$MCC" fetch --depth 1 origin main && git -C "$MCC" reset --hard origin/main
fi
cd "$MCC"

# Footage from R2 (only the clips this render references)
python3 social/r2_footage.py download-lean

# Render
python3 social/proof_prospect.py "$REEL"

# proof_prospect writes into a versioned subfolder (out-erica/prospect-vN/), so search recursively
OUT="$(find social/aug-assets/out-erica -name "${REEL}*_9x16.mp4" -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)"
if [ -z "$OUT" ]; then echo "ERROR: no ${REEL}*_9x16.mp4 found under out-erica"; find social/aug-assets/out-erica -name '*.mp4'; exit 1; fi
echo "RENDERED: $OUT"
ffprobe -v error -select_streams v:0 \
  -show_entries stream=width,height,r_frame_rate,nb_frames \
  -show_entries format=duration,size -of default=noprint_wrappers=1 "$OUT"

# Upload the finished reel to R2 for pickup/delivery
export RCLONE_CONFIG_MCCR2_TYPE=s3 RCLONE_CONFIG_MCCR2_PROVIDER=Cloudflare \
       RCLONE_CONFIG_MCCR2_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID" \
       RCLONE_CONFIG_MCCR2_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY" \
       RCLONE_CONFIG_MCCR2_ENDPOINT="$R2_ENDPOINT" RCLONE_CONFIG_MCCR2_REGION=auto
rclone copy "$OUT" "mccr2:${R2_BUCKET}/_cloud_renders/" --s3-no-check-bucket
echo "UPLOADED: mccr2:${R2_BUCKET}/_cloud_renders/$(basename "$OUT")"
echo "== render worker done =="

#!/usr/bin/env bash
# Dedicated MCC reel render worker (runs as a Render cron, triggered per reel or per batch).
# Runs the ffmpeg render pipeline DIRECTLY (no LLM, no Bash-tool timeout, no autodeploy
# collision) so long renders finish reliably. Pulls footage from R2 once, then renders each
# reel in REELS and uploads every finished mp4.
#
# Env: REELS (space-separated list, e.g. "c2_fastisnt_v3 c3_drive_v3") OR REEL (single).
#      GITHUB_TOKEN, R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY, R2_ENDPOINT, R2_BUCKET.
set -uo pipefail   # deliberately NOT -e: one bad reel must not abort the whole batch

REELS="${REELS:-${REEL:-}}"
[ -z "$REELS" ] && { echo "ERROR: set REELS (space-separated) or REEL"; exit 1; }
WORK="${RENDER_WORK:-/app/render}"
MCC="$WORK/mcc"
mkdir -p "$WORK"

echo "== render worker: REELS=[$REELS] =="
df -h "$WORK" | tail -1

# Sparse clone: only social/ (proof_prospect + logos + fonts + _tx_cache).
if [ ! -d "$MCC/.git" ]; then
  git clone --depth 1 --filter=blob:none --sparse \
    "https://x-access-token:${GITHUB_TOKEN}@github.com/thersh1007-lab/Monument-City-Capital.git" "$MCC"
  git -C "$MCC" sparse-checkout set social
else
  git -C "$MCC" fetch --depth 1 origin main && git -C "$MCC" reset --hard origin/main
fi
cd "$MCC"

# Footage from R2 once (the lean set covers every reel)
python3 social/r2_footage.py download-lean

export RCLONE_CONFIG_MCCR2_TYPE=s3 RCLONE_CONFIG_MCCR2_PROVIDER=Cloudflare \
       RCLONE_CONFIG_MCCR2_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID" \
       RCLONE_CONFIG_MCCR2_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY" \
       RCLONE_CONFIG_MCCR2_ENDPOINT="$R2_ENDPOINT" RCLONE_CONFIG_MCCR2_REGION=auto

ok=0; fail=0; failed_list=""
for R in $REELS; do
  echo "==================== RENDER $R ===================="
  if python3 social/proof_prospect.py "$R"; then
    OUT="$(find social/aug-assets/out-erica -name "${R}*_9x16.mp4" -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)"
    if [ -n "$OUT" ]; then
      echo "RENDERED $R: $OUT"
      ffprobe -v error -select_streams v:0 -show_entries stream=width,height \
        -show_entries format=duration,size -of default=noprint_wrappers=1 "$OUT"
      if rclone copy "$OUT" "mccr2:${R2_BUCKET}/_cloud_renders/" --s3-no-check-bucket; then
        echo "UPLOADED $R -> $(basename "$OUT")"; ok=$((ok+1))
      else
        echo "UPLOAD FAILED for $R"; fail=$((fail+1)); failed_list="$failed_list $R(upload)"
      fi
    else
      echo "NO OUTPUT for $R"; fail=$((fail+1)); failed_list="$failed_list $R(nooutput)"
    fi
  else
    echo "RENDER FAILED for $R"; fail=$((fail+1)); failed_list="$failed_list $R(render)"
  fi
done

echo "== batch done: $ok ok, $fail failed ==${failed_list:+  FAILED:$failed_list}"
[ "$fail" -gt 0 ] && exit 1 || exit 0

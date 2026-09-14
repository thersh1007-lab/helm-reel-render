#!/usr/bin/env bash
# Dedicated MCC reel render worker (Render cron, manual trigger). Renders the ffmpeg pipeline
# DIRECTLY (no LLM, no Bash-tool timeout, no autodeploy collision), then self-delivers:
# posts each finished reel to the Helm Ops "Proof ready" list + emails Tim (deliver.py).
#
# Reel list: env REELS (space-separated) -> committed /app/reels.txt -> env REEL.
# Env: GITHUB_TOKEN, R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY, R2_ENDPOINT, R2_BUCKET.
# Delivery (optional): TRELLO_KEY, TRELLO_TOKEN, HELM_PROOF_LIST, GMAIL_CLIENT_ID,
#   GMAIL_CLIENT_SECRET, GMAIL_REFRESH_TOKEN, EMAIL_TO. Set DELIVER=0 to skip delivery.
set -uo pipefail   # deliberately NOT -e: one bad reel must not abort the batch

REELS="${REELS:-}"
if [ -z "$REELS" ] && [ -f /app/reels.txt ]; then
  REELS="$(grep -vE '^\s*(#|$)' /app/reels.txt | tr '\n' ' ')"
fi
[ -z "$REELS" ] && REELS="${REEL:-}"
[ -z "$REELS" ] && { echo "ERROR: no reels (set REELS env, /app/reels.txt, or REEL)"; exit 1; }

WORK="${RENDER_WORK:-/app/render}"; MCC="$WORK/mcc"; mkdir -p "$WORK"
MANIFEST=/tmp/manifest.txt; : > "$MANIFEST"

echo "== render worker: REELS=[$REELS] =="
df -h "$WORK" | tail -1

if [ ! -d "$MCC/.git" ]; then
  git clone --depth 1 --filter=blob:none --sparse \
    "https://x-access-token:${GITHUB_TOKEN}@github.com/thersh1007-lab/Monument-City-Capital.git" "$MCC"
  git -C "$MCC" sparse-checkout set social
else
  git -C "$MCC" fetch --depth 1 origin main && git -C "$MCC" reset --hard origin/main
fi
cd "$MCC"

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
      BN="$(basename "$OUT")"
      if rclone copy "$OUT" "mccr2:${R2_BUCKET}/_cloud_renders/" --s3-no-check-bucket; then
        echo "UPLOADED $R -> $BN"; ok=$((ok+1))
        echo "${R}|${OUT}|_cloud_renders/${BN}" >> "$MANIFEST"
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

echo "== render done: $ok ok, $fail failed ==${failed_list:+  FAILED:$failed_list}"

# Self-deliver: Proof-ready Trello cards + summary email
if [ "${DELIVER:-1}" = "1" ] && [ "$ok" -gt 0 ] && [ -s "$MANIFEST" ]; then
  echo "== delivering $ok reel(s) to Helm Proof ready + email =="
  python3 /app/deliver.py "$MANIFEST" || echo "deliver.py returned nonzero"
else
  echo "== delivery skipped (DELIVER=${DELIVER:-1}, ok=$ok) =="
fi

[ "$fail" -gt 0 ] && exit 1 || exit 0

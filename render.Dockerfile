# Lean MCC reel render image (dedicated render worker, run as a Render cron).
# Only what the ffmpeg reel pipeline needs: python + numpy/pillow, ffmpeg, rclone, git, fonts.
# No claude-code, no wrangler, no browsers -> small + fast to build vs the helm-builder image.
FROM python:3.12-slim-bookworm

RUN apt-get update && apt-get install -y --no-install-recommends \
      git curl ca-certificates ffmpeg fontconfig fonts-dejavu-core unzip \
  && curl -fsSL https://rclone.org/install.sh | bash \
  && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir numpy pillow requests

COPY render_reel.sh /app/render_reel.sh
COPY reels.txt /app/reels.txt
COPY deliver.py /app/deliver.py
COPY reels_meta.json /app/reels_meta.json
RUN chmod +x /app/render_reel.sh

WORKDIR /app
CMD ["bash", "/app/render_reel.sh"]

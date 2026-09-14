# helm-reel-render

Dedicated, minimal render worker for MCC reels. Deployed as a Render Docker cron
(`helm-reel-render`, manual-trigger only). Kept in its own tiny repo so Render's build
clone is instant, the ATJ repo is too large to clone per job.

- `render_reel.sh` sparse-clones the MCC `social/` tree, pulls lean footage from R2,
  renders `$REEL` with ffmpeg via `proof_prospect.py`, uploads the mp4 to R2 `_cloud_renders/`.
- `render.Dockerfile` is a slim python + ffmpeg + rclone image.

Env required on the cron: `REEL`, `GITHUB_TOKEN`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`,
`R2_ENDPOINT`, `R2_BUCKET`.

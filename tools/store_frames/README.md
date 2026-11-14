# Store screenshot frames

1. `tools/store_shots.sh` — raw iPhone screenshots (demo TV, 8 languages) → `build/store_shots/`.
2. `node tools/store_frames/render.js build/store_shots out` (Playwright) — framed images with
   captions from `captions.json`: `out/apple/<lang>/` 1320×2868 and `out/play/<lang>/` 1080×1920.
3. Converted to JPEG in `docs/store/screenshots/{apple,play}/<lang>/`.

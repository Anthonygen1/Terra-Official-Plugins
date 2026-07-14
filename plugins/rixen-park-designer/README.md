# Rixen Park Designer

Workload plugin serving an interactive WebGL 3D model of the Ski Rixen USA
cable wake park (Quiet Waters Park, Deerfield Beach, FL). Lake geometry is
traced from OpenStreetMap survey data; the 4-tower rectangular cable loop,
riders, and wake obstacles are modeled in Three.js (inlined — no CDN or
external requests at runtime).

## What it does

- Serves the single-file app with a ~60-line stdlib Python server on a stock
  `python:3.12-alpine` image. No custom image build required.
- Drag the ramp and rail on the water to design obstacle layouts; Q/E or the
  on-screen buttons rotate the selected obstacle.
- Every edit is debounced and POSTed to `api/layout`, which writes
  `/data/layout.json` atomically. That path is a PVC (`storageClass` picker,
  `storageSize` default 2Gi), so layouts survive pod restarts and are shared
  by everyone who opens the workload.
- Browser localStorage acts as an offline fallback; the server copy wins on
  load.
- `publicAccess` (default off) removes Hubble authentication from the
  ingress — anyone who can reach the cluster can open the app. Use only in
  trusted network environments.

## Routes

| Path | Purpose |
| --- | --- |
| `/rixen/<name>/` | the app |
| `/rixen/<name>/api/layout` | GET current layout JSON / POST new layout |

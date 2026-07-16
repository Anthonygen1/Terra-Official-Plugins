# Rixen Park Designer

Workload plugin serving an interactive WebGL 3D model of the Ski Rixen USA
cable wake park (Quiet Waters Park, Deerfield Beach, FL): a stylized
rectangular lake with the 4-tower rectangular cable loop, riders, and wake
obstacles modeled in Three.js (inlined — no CDN or external requests at
runtime).

The app is baked into a container image built from the private
`rixen-park-builder` repo by GitHub Actions and published to
`ghcr.io/anthonygen1/rixen-park-builder` (private). To pull it, create a
docker-registry Secret in the project namespace (PAT with
`read:packages`) and set the `pull_secret` field to its name:

```sh
kubectl -n <project-namespace> create secret docker-registry ghcr-pull \
  --docker-server=ghcr.io \
  --docker-username=<github-username> \
  --docker-password=<PAT>
```

## What it does

- Serves the single-file app with a ~60-line stdlib Python server
  (`python:3.12-alpine` base). The `latest` tag deploys with
  `imagePullPolicy: Always` — restart the pod to pick up a new build;
  version tags pull once.
- Drag the ramp and rail on the water to design obstacle layouts; Q/E or the
  on-screen buttons rotate the selected obstacle.
- Every edit is debounced and POSTed to `api/layout`, which writes
  `/data/layout.json` atomically. That path is a PVC (`storageClass` picker,
  `storageSize` default 2Gi), so layouts survive pod restarts and are shared
  by everyone who opens the workload.
- Browser localStorage acts as an offline fallback; the server copy wins on
  load.
- "Export video" records a 20-second top-POV pass above the cable — tower
  1 to 2, hard cut, tower 3 to 4 — facing the direction of travel with no
  camera rotation, via `canvas.captureStream` + `MediaRecorder`. MP4 where
  supported (Chrome/Safari), WebM fallback, delivered through a Download
  button (auto-download gets blocked by Chrome). Presets: 1920x1080 for
  web, 1080x1920 for Instagram reels/stories.
- `publicAccess` (default off) removes Hubble authentication from the
  ingress — anyone who can reach the cluster can open the app. Use only in
  trusted network environments.

## Routes

| Path | Purpose |
| --- | --- |
| `/rixen/<name>/` | the app |
| `/rixen/<name>/api/layout` | GET current layout JSON / POST new layout |

# Homelable

![Homelable](https://raw.githubusercontent.com/Anthonygen1/Terra-Official-Plugins/refs/heads/dev/plugins/homelable/assets/logo.png)

**Category:** Infrastructure
**Type:** Cluster Service
**Tags:** `homelab` · `networking` · `monitoring` · `documentation` · `mcp` · `cluster-level`

---

## Overview

[Homelable](https://github.com/Pouzor/homelable) is a self-hosted homelab visualizer. It draws an interactive diagram of your network, discovers hosts with an nmap scanner, tracks live up/down status on the canvas, holds rack layouts and markdown documentation, and can import inventories from Proxmox, Unraid, Zigbee2MQTT and Z-Wave. An optional MCP server lets AI clients such as Claude Code query your infrastructure.

---

## How It Works

**Cluster Service** — Installed once per cluster by an administrator. Terra creates a dedicated `homelable` namespace and deploys a single pod with:

- `backend` — FastAPI API, nmap scanner and status checker, SQLite database on a PersistentVolumeClaim
- `frontend` — React UI served by nginx, which proxies `/api` to the backend on loopback
- `mcp` *(optional, `enable_mcp`)* — MCP server on port 8001 at `/mcp`

One Service exposes the UI (port 80) and, when enabled, the MCP server (port 8001). Its type follows `service_type`:

| `service_type` | Reach the UI at | Notes |
|----------------|-----------------|-------|
| `LoadBalancer` (default) | `http://<external-ip>/` | Stable LAN IP from MetalLB (or another LB provider). Set `loadbalancer_ip` to pin it. |
| `NodePort` | `http://<any-node-ip>:<nodeport>/` | Find the port with `kubectl -n homelable get svc`. |
| `Ingress` | `https://<host>/` | Dedicated hostname through the nginx ingress controller. Needs a DNS record for `host`. |

The database and uploaded floor plans live on the PVC and survive pod restarts and upgrades.

---

## Prerequisites

- Cluster administrator access in Terra
- A default StorageClass (or one you name in `storage_class`) able to provision a `ReadWriteOnce` volume
- For `service_type: LoadBalancer` — a load-balancer provider such as the **MetalLB** plugin
- For `service_type: Ingress` — an nginx ingress controller and a DNS record pointing `host` at it

---

## Installation

1. Open **Terra** and navigate to the **Plugin Marketplace**
2. Search for **"Homelable"**
3. Click **Install**
4. Fill in the configuration fields below
5. Click **Confirm** to deploy

Once the pod is running, open the UI at the address for your `service_type` and log in with `admin_username` / `admin_password`.

---

## Configuration

### Install-Time Fields

| Field | Details |
|-------|---------|
| `service_type` | **select** · Required · Default: `LoadBalancer`<br>How the UI is exposed: `LoadBalancer`, `NodePort` or `Ingress`. See the table above. |
| `loadbalancer_ip` | **string** · Optional<br>Fixed IP to request for the LoadBalancer (e.g. `192.168.1.60`). Must be inside your LB address pool. Ignored for other service types. |
| `host` | **string** · Optional<br>Dedicated hostname for the UI (e.g. `homelable.example.com`). Only used when `service_type` is `Ingress`. |
| `admin_username` | **string** · Required · Default: `admin`<br>Web UI login username. |
| `admin_password` | **string** · Required<br>Web UI login password. Stored in a Kubernetes Secret; bcrypt-hashed inside the backend container at start. |
| `scanner_ranges` | **string** · Required · Default: `192.168.1.0/24`<br>Comma-separated CIDR ranges the scanner sweeps. Must be routable from the cluster nodes. |
| `status_checker_interval` | **int** · Required · Default: `60`<br>Seconds between reachability checks of discovered hosts. |
| `enable_mcp` | **boolean** · Required · Default: `false`<br>Run the MCP server container and expose port 8001. |
| `mcp_api_key` | **string** · Optional<br>Bearer key AI clients present to the MCP server. Required when `enable_mcp` is on. |
| `expose_api_docs` | **boolean** · Required · Default: `false`<br>Serve `/docs`, `/redoc` and `/openapi.json`. Upstream leaves these outside login, so they are hidden by default. |
| `image_tag` | **string** · Required · Default: `3.6.0`<br>Tag for the `ghcr.io/pouzor/homelable-*` images. |
| `storage_size` | **string** · Required · Default: `2Gi`<br>Size of the data PVC (SQLite database and uploads). |
| `storage_class` | **string** · Optional<br>StorageClass for the data PVC. Leave empty for the cluster default. |

---

## Using the MCP Server

With `enable_mcp` on, the server listens on port 8001 at `/mcp`:

- `LoadBalancer` / `NodePort`: `http://<ip>:8001/mcp` (NodePort: the port mapped to 8001)
- `Ingress`: `https://<host>/mcp`

Claude Code configuration (`~/.claude.json`):

```json
{
  "mcpServers": {
    "homelable": {
      "type": "http",
      "url": "http://192.168.1.60:8001/mcp",
      "headers": { "Authorization": "Bearer <mcp_api_key>" }
    }
  }
}
```

---

## Notes

- **Why no path under the Genesis host:** the frontend bakes its base path into the build (`VITE_BASE_PATH`), and the prebuilt images only serve from `/`. That is why the UI gets its own IP or hostname instead of `/homelable/` on the Genesis host, and why the Genesis auth gate is not used — Homelable's own login protects the UI and API.
- **MAC addresses:** the backend has `NET_RAW` so nmap can run ARP/SYN scans, but from the pod network every LAN host sits behind the node's gateway, so MACs are not visible (same limitation as upstream's Docker bridge mode). Hosts, ports and services are still discovered; devices are matched by IP.
- **Scanner reach:** `scanner_ranges` must be reachable from the cluster nodes. Pod traffic is NATed to the node IP, so the LAN sees scans coming from the node.
- **Sessions:** the token-signing key is derived from the release name and `admin_password`, so it stays stable across ArgoCD syncs. Changing the password logs everyone out, which is intended.
- **Integrations** (Proxmox, Unraid, Zigbee2MQTT, Z-Wave, OIDC) are configured upstream via environment variables and are not exposed as fields yet. Open an issue if you need one.
- **Single replica:** SQLite on a ReadWriteOnce volume, so the Deployment runs one pod with a `Recreate` strategy. Expect a short outage during upgrades.
- Changing fields after install (plugin is `editable`) rolls the pod with the new values.
- **Uninstall** removes the `homelable` namespace and its PVC — export your data from the UI first if you want to keep it.
- Homelable is free and open-source (MIT).

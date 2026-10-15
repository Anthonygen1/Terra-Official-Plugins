# Pi-hole

![Pi-hole](https://github.com/juno-fx/Terra-Official-Plugins/blob/main/plugins/pi-hole/assets/logo.png?raw=true)

**Category:** Infrastructure
**Type:** Network Service
**Tags:** `dns` · `ad-blocking` · `networking` · `privacy` · `web-interface`

---

## Overview

[Pi-hole](https://pi-hole.net/) is a DNS sinkhole that blocks ads, trackers and malware domains for every device on a network — no per-client software required. Queries for blocked domains are answered with an unroutable address; everything else is forwarded to the upstream resolvers you choose. A web dashboard shows live query statistics, lets you manage allow/deny lists and blocklists (gravity), and configure the resolver.

---

## How It Works

**Network Service** — Terra deploys a single Pi-hole (v6, FTL) pod into the project namespace. Two Services are created:

- `<release>` — ClusterIP for the web dashboard, reached through an nginx Ingress authenticated via Genesis
- `<release>-dns` — the DNS resolver on port 53 (TCP + UDP), exposed as `LoadBalancer`, `NodePort` or `ClusterIP` per the `dns_service_type` field

Pi-hole configuration, the gravity blocklist database and query logs are persisted to the sub-directory you choose on the shared install volume, so they survive pod restarts and upgrades.

---

## Prerequisites

- A shared volume (PVC) available in the project to persist Pi-hole data
- A DNS record pointing `host` to your cluster's ingress controller
- An nginx ingress controller in the cluster
- For `dns_service_type: LoadBalancer` — a load-balancer provider such as the **MetalLB** plugin (bare metal) or a cloud LB

---

## Installation

1. Open **Terra** and navigate to the **Plugin Marketplace**
2. Search for **"Pi-hole"**
3. Click **Install**
4. Fill in the configuration fields below
5. Click **Confirm** to deploy

Once the pod is running, open `https://<host><prefix>/admin/` and log in with `admin_password`.

---

## Configuration

### Install-Time Fields

| Field | Details |
|-------|---------|
| `host` | **string** · Required<br>Hostname for the admin dashboard (e.g. `pihole.example.com`). A DNS record pointing to your cluster's ingress must exist. |
| `prefix` | **string** · Optional · Default: `/`<br>URL prefix to serve the dashboard under (e.g. `/pihole`). The dashboard is at `<prefix>/admin/`. |
| `admin_password` | **string** · Required<br>Password for the Pi-hole dashboard login. Stored in a Kubernetes Secret in the project namespace. |
| `upstream_dns` | **string** · Required · Default: `1.1.1.1;1.0.0.1`<br>Semicolon-separated upstream resolvers, optionally with `#port` (e.g. `10.0.0.2#5335`). |
| `timezone` | **string** · Required · Default: `UTC`<br>Timezone for query logs and statistics (e.g. `America/New_York`). |
| `dns_service_type` | **select** · Required · Default: `LoadBalancer`<br>How port 53 is exposed: `LoadBalancer` (stable external IP, needs an LB provider), `NodePort` (high port on every node) or `ClusterIP` (in-cluster only). |
| `loadbalancer_ip` | **string** · Optional<br>Fixed IP to request for the DNS LoadBalancer (e.g. `192.168.1.53`). Must be within your LB address pool. Ignored for other service types. |
| `install_volume` | **shared-volume** · Required<br>Volume used to persist Pi-hole configuration, gravity database and query logs. |
| `destination` | **string** · Required · Default: `pi-hole`<br>Sub-directory on the install volume for Pi-hole data. No leading slash. |

---

## Notes

- **Pointing clients at Pi-hole:** with `LoadBalancer`, use the external IP of the `<release>-dns` Service as the DNS server on your router or devices. With `NodePort`, use any node IP plus the assigned port (`kubectl get svc <release>-dns`) — note most clients cannot use a non-standard DNS port, so `LoadBalancer` is strongly preferred for LAN use.
- **Client IPs in the dashboard:** the LoadBalancer Service uses `externalTrafficPolicy: Local` so Pi-hole sees real client addresses rather than node IPs. Traffic only reaches nodes where the pod is scheduled; MetalLB handles this automatically in layer2 mode.
- **Single replica:** Pi-hole stores state in an on-disk SQLite database, so the Deployment runs one replica with a `Recreate` strategy. Expect a brief DNS outage during upgrades.
- **Dashboard access** is gated by Genesis authentication in addition to Pi-hole's own password login.
- **DHCP and NTP** are not exposed by this plugin. The DNS resolver does not run as the cluster's internal DNS — it is intended for LAN / device use.
- Changing `upstream_dns`, `timezone` or `admin_password` after install (plugin is `editable`) restarts the pod with the new values. Settings changed in the Pi-hole UI that are also set here will be overridden by the install-time values on restart, as they are pinned via `FTLCONF_*` environment variables.
- Pi-hole is free and open-source (EUPL-1.2).

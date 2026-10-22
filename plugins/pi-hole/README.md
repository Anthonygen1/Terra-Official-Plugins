# Pi-hole

![Pi-hole](https://raw.githubusercontent.com/Anthonygen1/Terra-Official-Plugins/refs/heads/dev/plugins/pi-hole/assets/logo.png)

**Category:** Infrastructure
**Type:** Cluster Service · Dashboard
**Tags:** `dns` · `ad-blocking` · `networking` · `privacy` · `cluster-level` · `dashboard`

---

## Overview

[Pi-hole](https://pi-hole.net/) is a DNS sinkhole that blocks ads, trackers and malware domains for every device on a network — no per-client software required. Queries for blocked domains are answered with an unroutable address; everything else is forwarded to the upstream resolvers you choose. The web dashboard shows live query statistics, lets you manage allow/deny lists and blocklists (gravity), and configure the resolver.

---

## How It Works

**Cluster Service** — Installed once per cluster by an administrator. Terra creates a dedicated `pi-hole` namespace and deploys a single Pi-hole (v6, FTL) pod into it, backed by its own PersistentVolumeClaim. Two Services are created:

- `<release>` — ClusterIP for the web dashboard, served on your Genesis host under `prefix` and embedded directly in the Genesis UI (admin users only)
- `<release>-dns` — the DNS resolver on port 53 (TCP + UDP), exposed as `LoadBalancer`, `NodePort` or `ClusterIP` per the `dns_service_type` field

Pi-hole configuration, the gravity blocklist database and query logs are persisted to the PVC, so they survive pod restarts and upgrades.

---

## Prerequisites

- Cluster administrator access in Terra
- A default StorageClass (or one you name in `storage_class`) able to provision a `ReadWriteOnce` volume
- An nginx ingress controller in the cluster serving the Genesis host
- For `dns_service_type: LoadBalancer` — a load-balancer provider: the **MetalLB** plugin (bare metal), a cloud LB, or k3s's built-in ServiceLB (works, with caveats — see Notes)

---

## Installation

1. Open **Terra** and navigate to the **Plugin Marketplace**
2. Search for **"Pi-hole"**
3. Click **Install**
4. Fill in the configuration fields below
5. Click **Confirm** to deploy

Once the pod is running, the dashboard appears in Genesis for admin users, or directly at `https://<host><prefix>/admin/`. Log in with `admin_password`.

---

## Configuration

### Install-Time Fields

| Field | Details |
|-------|---------|
| `host` | **string** · Required<br>The DNS name of your Genesis host. The dashboard is served from this host. |
| `prefix` | **string** · Optional · Default: `/pihole`<br>URL prefix to serve the dashboard under. The dashboard is at `<prefix>/admin/`. Rarely needs changing. |
| `admin_password` | **string** · Required<br>Password for the Pi-hole dashboard login. Stored in a Kubernetes Secret in the `pi-hole` namespace. |
| `upstream_dns` | **string** · Required · Default: `1.1.1.1;1.0.0.1`<br>Semicolon-separated upstream resolvers, optionally with `#port` (e.g. `10.0.0.2#5335`). |
| `timezone` | **string** · Required · Default: `UTC`<br>Timezone for query logs and statistics (e.g. `America/New_York`). |
| `dns_service_type` | **select** · Required · Default: `LoadBalancer`<br>How port 53 is exposed: `LoadBalancer` (stable external IP, needs an LB provider), `NodePort` (high port on every node) or `ClusterIP` (in-cluster only). |
| `loadbalancer_ip` | **string** · Optional<br>Fixed IP to request for the DNS LoadBalancer (e.g. `192.168.1.53`). Must be within your LB address pool. Ignored for other service types. |
| `external_traffic_policy` | **select** · Required · Default: `Local`<br>`Local` preserves client IPs in the dashboard but only publishes nodes running the pod; `Cluster` publishes every node and survives the pod moving, but clients show as node IPs. LoadBalancer only. |
| `storage_size` | **string** · Required · Default: `2Gi`<br>Size of the PVC holding Pi-hole configuration, gravity database and query logs. |
| `storage_class` | **string** · Optional<br>StorageClass for the data PVC. Leave empty for the cluster default. |

---

## Notes

- **Pointing clients at Pi-hole:** with `LoadBalancer`, use the external IP of the `<release>-dns` Service in the `pi-hole` namespace as the DNS server on your router or devices. With `NodePort`, use any node IP plus the assigned port (`kubectl -n pi-hole get svc`) — most clients cannot use a non-standard DNS port, so `LoadBalancer` is strongly preferred for LAN use.
- **k3s ServiceLB (klipper) and port 53:** k3s's built-in LoadBalancer implements Services by opening the port as a hostPort on every node. For port 53 the CNI portmap rules DNAT the node's own loopback resolver (`127.0.0.53`, systemd-resolved) into the cluster, so once the Service exists **all node DNS flows through Pi-hole**. If that happens before the pod is Ready the node loses DNS and cannot pull the Pi-hole image, so the DNS Service carries `argocd.argoproj.io/sync-wave: "1"` and is only created after the Deployment is Healthy. Remaining caveat: while the pod is down (upgrade with `Recreate`, node move) those nodes have no DNS, and a new image cannot be pulled on a node that lacks it. For production prefer MetalLB (`--disable=servicelb` on k3s) with a fixed `loadbalancer_ip`.
- **Client IPs in the dashboard:** the LoadBalancer Service uses `externalTrafficPolicy: Local` so Pi-hole sees real client addresses rather than node IPs. Traffic only reaches nodes where the pod is scheduled; MetalLB handles this automatically in layer2 mode.
- **Embedded dashboard:** Pi-hole ships with `X-Frame-Options: DENY`. This plugin relaxes it to `SAMEORIGIN` (and CSP `frame-ancestors 'self'`) so the dashboard can be embedded in Genesis, which is served from the same host. It is still protected by Genesis authentication and the admin permission, plus Pi-hole's own login.
- **Single replica:** Pi-hole stores state in an on-disk SQLite database, so the Deployment runs one replica with a `Recreate` strategy. Expect a brief DNS outage during upgrades.
- **DHCP and NTP** are not exposed by this plugin. The DNS resolver does not replace the cluster's internal DNS — it is intended for LAN / device use.
- Changing `upstream_dns`, `timezone` or `admin_password` after install (plugin is `editable`) restarts the pod with the new values. Settings also pinned here via `FTLCONF_*` environment variables cannot be changed from the Pi-hole UI while the variable is set.
- **Uninstall** removes the `pi-hole` namespace and its PVC — back up `/etc/pihole` (Teleporter export in the dashboard) first if you want to keep lists and settings.
- Pi-hole is free and open-source (EUPL-1.2).

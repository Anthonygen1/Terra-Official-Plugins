# Open OnDemand

![Open OnDemand](https://raw.githubusercontent.com/juno-fx/Terra-Official-Plugins/refs/heads/main/plugins/open-ondemand/assets/logo.png)

**Category:** Compute
**Type:** Workload Template
**Tags:** `slurm` `hpc` `portal` `batch` `jupyter` `cluster-level` `workload`

---

## Overview

[Open OnDemand](https://openondemand.org) is a web portal for HPC clusters. This template points it at a Slurm
cluster deployed by the [Slinky](../slinky/README.md) plugin. Each user launches their own portal from Hubble and
gets, in the browser:

- **Files** — browse, upload, download and edit files in their home directory
- **Job Composer** — write and submit batch jobs from templates
- **Active Jobs** — watch and cancel queued and running jobs
- **Shell** — a terminal on the Slurm login node
- **Interactive apps** — JupyterLab (bundled) and, optionally, a remote desktop, each running as a Slurm job on a
  compute node and proxied back through the portal

Administrators install this plugin and configure the template in Genesis; end users launch it from Hubble.

---

## How It Works

Upstream Open OnDemand is one shared portal that logs many users in. Here it is turned inside out: **one portal pod
per user**, launched on demand like any other workload.

```
namespace: <user's project>                    namespace: slurm

  browser ──▶ Ingress ──▶ [Open OnDemand pod] ──ssh──▶ [LoginSet pod]
              (Hubble auth)   Apache                    sbatch / squeue / scancel
                              └─ per-user nginx                 │
                                 (runs as the user)             ▼
                                        │                 [slurmctld] ──▶ [slurmd × N]
                                        └────── http ──────────────────────▶ Jupyter / desktop job
```

- **Authentication is Hubble's.** The ingress checks every request with Hubble, exactly as for other workloads.
  Open OnDemand's own login (Dex, OIDC, LDAP) is not used and needs no configuration. Inside the pod every request is
  mapped to the user who launched it, and the portal's apps run under that user's uid.
- **No Slurm software or credentials in the pod.** Open OnDemand runs in `submit_host` mode: every `sbatch`, `squeue`
  and `scancel` is executed over SSH on the Slinky login node, which already holds `slurm.conf` and the cluster auth
  key. `slurm.key` never leaves the Slurm namespace, and the portal does not have to track the Slurm version.
- **SSH is passwordless, with a key the pod generates.** Open OnDemand runs Slurm commands non-interactively, so it
  cannot answer a password prompt. On first start the pod creates `~/.ssh/id_ed25519_ondemand` and adds it to
  `~/.ssh/authorized_keys`. This is why the shared home directory is a hard requirement — see
  [Prerequisites](#prerequisites).
- **Interactive apps connect by pod IP.** A Jupyter or desktop job reports its compute pod's IP and port; the portal
  reverse-proxies the browser to it. Nothing is exposed outside the cluster.
- **Open OnDemand is installed when the pod starts.** There is no official container image, so the default is a stock
  Rocky Linux image plus an install from OSC's package repository. See [Start-up time](#start-up-time).

### Serving under a path

Open OnDemand is built to own a whole hostname. This template serves it under
`/<namespace>/ondemand/<workload name>/` instead, so many portals can share the platform's hostname. All of
Open OnDemand's URL roots are configured beneath that path; the few it hardcodes are rewritten by Apache on the way
out and patched in its precompiled assets at start. No rewriting happens at the ingress.

---

## Prerequisites

- **Slinky plugin** installed, with a working directory (`sssd_secret`) so the login node knows your users
- **A shared home directory, mounted in three places.** The same storage must be mounted at `/home` on the Slurm login
  node and compute nodes (the Slinky plugin's `home_pvc`) **and** in this workload, so that `/home/<user>` is the same
  directory everywhere. Without it nothing beyond the dashboard works:
  - the SSH key the portal authorises would not be seen by the login node, so job submission fails
  - the Job Composer and interactive apps stage their scripts under `~/ondemand`, which the compute nodes must read
  - interactive apps write their connection details back to the same place for the portal to read

  A PersistentVolumeClaim cannot be mounted across namespaces, so this means two claims — one in the Slurm namespace,
  one in the project namespace — backed by the same export (for example the same NFS path). Attach the project-side
  one to the workload template in Genesis, mounted at `/home`.
- **Matching uid and gid.** The uid/gid the platform launches the workload with must equal the ones the login node
  resolves for the same username through SSSD. If they differ, files written from one side are not readable from the
  other and SSH key authentication is refused
- **Outbound internet access** from the project namespace to `yum.osc.edu`, the Rocky Linux mirrors and EPEL — only
  when using the default image, which installs Open OnDemand at start
- Network connectivity from the project namespace to the Slurm namespace: TCP 22 to the login node, and arbitrary
  high ports to compute pods for interactive apps. A cluster-wide NetworkPolicy that blocks this breaks them

---

## Installation

Administrators install the plugin once:

1. Open **Terra** and navigate to the **Plugin Marketplace**
2. Search for **"Open OnDemand"**
3. Click **Install**

The template then appears in **Genesis** for configuration — attach the shared home volume there — and users launch
portals from **Hubble**.

---

## Configuration

### Install-Time Fields

No install-time configuration is required for this plugin.

### Workload Launch Fields

| Field | Details |
|-------|---------|
| `slurmNamespace` | **string** · Required · Default: `slurm`<br>Namespace the Slurm cluster runs in. Only change this if you run more than one Slurm cluster — the login node's name is fixed, so the namespace is the only thing that distinguishes them |
| `registry` | **string** · Required · Default: `docker.io`<br>Registry for the base image |
| `repo` | **string** · Required · Default: `rockylinux/rockylinux`<br>Repository for the base image. Point this at an image with Open OnDemand preinstalled to skip the install at start |
| `tag` | **string** · Required · Default: `9`<br>Tag for the base image |
| `oodVersion` | **string** · Required · Default: `4.2`<br>Open OnDemand release (major.minor) installed at start. Ignored when the image already contains Open OnDemand |
| `jupyterApp` | **boolean** · Required · Default: `true`<br>Offer the bundled Jupyter interactive app |
| `desktopApp` | **boolean** · Required · Default: `false`<br>Offer the remote desktop interactive app. Needs TurboVNC, websockify and Xfce on the compute image — the stock Slinky image has none of them |
| `ingressNamespace` | **string** · Required · Default: `ingress-nginx`<br>Namespace of the ingress controller, used by the NetworkPolicy |

### Custom Environment Variables

Genesis lets you add arbitrary environment variables to the workload at launch time. These are commonly useful for
Open OnDemand:

| Variable | Description |
|----------|-------------|
| `OOD_DASHBOARD_TITLE` | Title shown in the portal's navigation bar and browser tab. Defaults to "Open OnDemand" |
| `OOD_CLUSTER_TITLE` | Display name of the Slurm cluster inside the portal. Defaults to "Slurm" |
| `PACKAGES` | Space-separated list of extra RPM packages to install into the portal pod at start, e.g. `git vim` |
| `OOD_SCHEME` | Scheme users reach the platform with. Defaults to `https`; set to `http` only if the platform is served without TLS, otherwise forms and the shell are rejected |

---

## Where It Connects

Always `slurm-login-slinky.<slurmNamespace>.svc.cluster.local:22`.

The Slinky plugin pins `fullnameOverride: slurm` on the Slurm chart, so the login node's name never inherits the
Terra release name. There is no service-name field to fill in or get wrong.

## Interactive Apps

### Jupyter

Bundled with this template. The launch form asks for hours, partition, CPU cores, memory and optional setup commands,
then submits a Slurm job that starts JupyterLab on a compute node.

The stock Slinky compute image does not ship Jupyter. If no `jupyter` command is on the `PATH`, the job creates a
virtual environment at `~/ondemand/jupyter-venv` with the node's `python3` and installs JupyterLab into it. That
happens once per user and needs internet access from the compute nodes; later launches reuse it. To use your own
environment instead, activate it in the form's **Setup commands** box (`module load ...`, `source ~/env/bin/activate`),
or bake JupyterLab into the compute image.

### Desktop

Open OnDemand's own desktop app, off by default. It runs a VNC desktop as a Slurm job, so the compute image needs
TurboVNC (under `/opt/TurboVNC`), `websockify` and Xfce. Enable `desktopApp` only once those are installed; otherwise
the app appears and every launch fails on the compute node.

---

## Start-up time

With the default image a new portal takes **about three minutes** to become ready: the pod downloads and installs
Open OnDemand and its Ruby, Node and Apache dependencies before it can serve anything. The start-up probe allows 20
minutes for slow mirrors. Until then Hubble shows the workload as starting.

The install lives in the container's filesystem, so it is repeated whenever the pod is recreated.

To avoid both the wait and the internet dependency, build an image with Open OnDemand already installed and set
`registry`/`repo`/`tag` to it. The start-up script detects the existing install and skips straight to configuration:

```dockerfile
FROM rockylinux/rockylinux:9
RUN dnf -y install epel-release dnf-plugins-core \
 && dnf config-manager --set-enabled crb \
 && dnf -y install https://yum.osc.edu/ondemand/4.2/ondemand-release-web-4.2-1.el9.noarch.rpm \
 && dnf -y module enable ruby:3.3 nodejs:22 \
 && dnf -y install ondemand openssh-clients \
 && dnf clean all
```

---

## Notes

- **The ingress is always authenticated via Hubble, and there is deliberately no option to disable it.** Open
  OnDemand's own login is switched off, so anyone who reaches the portal acts as the launching user — including a
  shell on the Slurm login node
- For the same reason a NetworkPolicy admits connections from the ingress controller's namespace only. Another pod in
  the project cannot bypass Hubble by connecting to the portal directly. Egress is left open, because the pod must
  reach package mirrors, the login node, and compute pods on ports chosen at job time
- **The container runs as root, by design.** Open OnDemand's Apache front end starts the per-user web server through
  `sudo`, which needs a setuid transition, and the default image installs packages at start. Capabilities are reduced
  to the set that requires (`CHOWN`, `DAC_OVERRIDE`, `FOWNER`, `FSETID`, `SETUID`, `SETGID`, `SETFCAP`, `KILL`,
  `AUDIT_WRITE`), no ServiceAccount token is mounted, and everything the user interacts with — dashboard, file
  browser, shell — runs as their own uid
- The login node's SSH host key is not pinned. It is an in-cluster Service whose keys are regenerated when its pod is
  replaced, so pinning would lock users out after every login-node restart
- The generated SSH key (`~/.ssh/id_ed25519_ondemand`) lives in the shared home and is reused by every portal the user
  launches. Removing its line from `~/.ssh/authorized_keys` revokes the portal's access; it is re-added at next start
- The portal is stateless apart from the home directory. Job Composer history, interactive session records and
  per-user settings live under `~/ondemand`, so they survive restarts as long as the home volume is attached
- "Log Out" in the navigation bar only shows Open OnDemand's logged-out page. The session belongs to Hubble; sign out
  there
- Job accounting views need accounting enabled in the Slinky plugin (`accounting_enabled`)

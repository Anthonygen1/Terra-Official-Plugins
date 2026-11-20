#!/bin/bash
# Open OnDemand, as a single-user portal for whoever launched this workload.
#
# Upstream Open OnDemand is a shared, multi-user portal: Apache authenticates
# each visitor and hands them to their own per-user nginx (the "PUN"). Here the
# platform has already authenticated the visitor at the ingress (Hubble), and
# the pod belongs to exactly one person, so Apache maps every request to that
# one user and starts a single PUN running as them.
#
# No Slurm software or Slurm credential lives in this pod. Jobs are submitted
# over SSH on the Slurm login node (Open OnDemand's "submit_host" mode), which
# already holds slurm.conf and the cluster auth key.
set -euo pipefail

log() { echo "[open-ondemand] $*"; }

: "${USER:?USER must be set}"
: "${PUID:?PUID must be set}"
: "${PGID:?PGID must be set}"
: "${PREFIX:?PREFIX must be set}"
: "${OOD_HOST:?OOD_HOST must be set}"
: "${SLURM_LOGIN_HOST:?SLURM_LOGIN_HOST must be set}"

# The ingress never rewrites the path, so every URL Open OnDemand serves or
# generates has to sit under this prefix. No trailing slash.
# Kept under its own name and unset: Open OnDemand's own tooling reads PREFIX
# as an install root and would write its files beneath it.
OOD_PREFIX="${PREFIX%/}"
unset PREFIX
HOME_DIR="/home/${USER}"
OOD_VERSION="${OOD_VERSION:-4.2}"
SLURM_LOGIN_PORT="${SLURM_LOGIN_PORT:-22}"
CLUSTER_TITLE="${OOD_CLUSTER_TITLE:-Slurm}"
PORT=8080

# ---------------------------------------------------------------------------
# 1. Install — skipped when the image already carries Open OnDemand
# ---------------------------------------------------------------------------
if [ ! -x /opt/ood/nginx_stage/sbin/nginx_stage ]; then
  log "Open OnDemand not found in the image - installing ${OOD_VERSION} (takes a few minutes)"
  EL="$(rpm -E %rhel)"
  dnf -y -q install epel-release dnf-plugins-core
  dnf config-manager --set-enabled crb
  dnf -y -q install "https://yum.osc.edu/ondemand/${OOD_VERSION}/ondemand-release-web-${OOD_VERSION}-1.el${EL}.noarch.rpm"
  # EL8/EL9 ship older Ruby and Node by default; newer releases need no module streams.
  if [ "${EL}" -le 9 ]; then
    dnf -y -q module enable ruby:3.3 nodejs:22 || dnf -y -q module enable ruby:3.3 nodejs:20
  fi
  dnf -y -q install ondemand
  log "installed $(rpm -q ondemand)"
fi
command -v ssh >/dev/null 2>&1 || dnf -y -q install openssh-clients
if [ -n "${PACKAGES:-}" ]; then
  # shellcheck disable=SC2086
  dnf -y -q install ${PACKAGES}
fi

# ---------------------------------------------------------------------------
# 2. The launching user
# ---------------------------------------------------------------------------
# uid and gid come from the platform and must equal the ones the Slurm login
# node resolves for this user, or files written on the shared home from either
# side will not be readable from the other.
if ! getent group "${PGID}" >/dev/null; then
  groupadd -g "${PGID}" "${GROUP:-$USER}" 2>/dev/null || groupadd -g "${PGID}" "ood-${PGID}"
fi
if ! getent passwd "${USER}" >/dev/null; then
  # -o: a base image may already own this uid under another name.
  useradd -o -M -u "${PUID}" -g "${PGID}" -d "${HOME_DIR}" -s /bin/bash "${USER}"
fi
if [ ! -d "${HOME_DIR}" ]; then
  mkdir -p "${HOME_DIR}"
  chown "${PUID}:${PGID}" "${HOME_DIR}"
fi

as_user() { runuser -u "${USER}" -- "$@"; }

# ---------------------------------------------------------------------------
# 3. Passwordless SSH to the Slurm login node
# ---------------------------------------------------------------------------
# Open OnDemand runs sbatch/squeue/scancel non-interactively (BatchMode), so it
# cannot answer a password prompt. A dedicated key is generated in the user's
# home and authorised there. That only works when this home directory is the
# same storage the login node mounts at /home - see the README.
KEY="${HOME_DIR}/.ssh/id_ed25519_ondemand"
if as_user test -w "${HOME_DIR}"; then
  as_user mkdir -p "${HOME_DIR}/.ssh"
  as_user chmod 700 "${HOME_DIR}/.ssh"
  if ! as_user test -f "${KEY}"; then
    as_user ssh-keygen -q -t ed25519 -N "" -C "open-ondemand" -f "${KEY}"
    log "generated ${KEY}"
  fi
  PUB="$(as_user cat "${KEY}.pub")"
  as_user touch "${HOME_DIR}/.ssh/authorized_keys"
  as_user chmod 600 "${HOME_DIR}/.ssh/authorized_keys"
  if ! as_user grep -qxF "${PUB}" "${HOME_DIR}/.ssh/authorized_keys"; then
    echo "${PUB}" | as_user tee -a "${HOME_DIR}/.ssh/authorized_keys" >/dev/null
  fi
else
  log "WARNING: ${HOME_DIR} is not writable by ${USER} - job submission will not work"
fi

mkdir -p /etc/ssh/ssh_config.d
cat > /etc/ssh/ssh_config.d/10-open-ondemand.conf <<EOF
# The login node is an in-cluster Service whose host keys are regenerated when
# its pod is replaced. Pinning them would lock users out after every restart,
# so they are not recorded - for this one host only.
Host ${SLURM_LOGIN_HOST}
  Port ${SLURM_LOGIN_PORT}
  IdentityFile ${KEY}
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
  LogLevel ERROR
EOF

# ---------------------------------------------------------------------------
# 4. Apache front end
# ---------------------------------------------------------------------------
# Open OnDemand hardcodes a handful of root-relative URLs (/pun/sys/<app>,
# /nginx/stop, /logout, and noVNC's websocket path). Apache rewrites those in
# redirects and in HTML on the way out so they stay under the prefix.
ROOTS='pun|nginx|node|rnode|public|logout'
cat > /etc/ood/config/ood_portal.yml <<EOF
---
listen_addr_port:
  - "${PORT}"
port: "${PORT}"
servername: "${OOD_HOST}"
proxy_server: "${OOD_HOST}"
# Probes and the ingress reach this pod by IP; never redirect them to a hostname.
use_rewrites: false
use_maintenance: false
# Hubble embeds workloads in a frame served from the platform host.
security_csp_frame_ancestors: "https://${OOD_HOST} http://${OOD_HOST}"

# The ingress has already authenticated the visitor through Hubble. Every
# request is mapped to the one user this pod belongs to.
user_env: "JUNO_OOD_USER"
user_map_match: ".*"
auth:
  - "Require all granted"

root_uri: "${OOD_PREFIX}/pun/sys/dashboard"
public_uri: "${OOD_PREFIX}/public"
pun_uri: "${OOD_PREFIX}/pun"
nginx_uri: "${OOD_PREFIX}/nginx"
node_uri: "${OOD_PREFIX}/node"
rnode_uri: "${OOD_PREFIX}/rnode"
logout_uri: "${OOD_PREFIX}/logout"
logout_redirect: "${OOD_PREFIX}/pun/sys/dashboard/logout"
# Interactive apps report their compute node by pod IP.
host_regex: '[\w.-]+'

custom_vhost_directives:
  - 'SetEnvIf Request_URI ".*" JUNO_OOD_USER=${USER}'
  # Apache's own redirects are absolute and would use http, because TLS ends at
  # the ingress. Build them from the scheme the ingress reports instead.
  - 'RewriteEngine On'
  - 'RewriteCond %{HTTP:X-Forwarded-Proto} ^(https?)\$'
  - 'RewriteRule "^${OOD_PREFIX}/?\$" "%1://%{HTTP_HOST}${OOD_PREFIX}/pun/sys/dashboard" [R=302,L]'
  - 'RewriteRule "^${OOD_PREFIX}/?\$" "${OOD_PREFIX}/pun/sys/dashboard" [R=302,L]'
  - 'RewriteCond %{HTTP:X-Forwarded-Proto} ^(https?)\$'
  - 'RewriteRule "^${OOD_PREFIX}/logout\$" "%1://%{HTTP_HOST}${OOD_PREFIX}/pun/sys/dashboard/logout" [R=302,L]'
  # Redirects coming back from the apps are made relative for the same reason.
  - 'Header always edit Location "^https?://[^/]+" ""'
  - 'Header edit Location "^https?://[^/]+" ""'
  - 'Header always edit Location "^/(${ROOTS})(/|\$|\?)" "${OOD_PREFIX}/\$1\$2"'
  - 'Header edit Location "^/(${ROOTS})(/|\$|\?)" "${OOD_PREFIX}/\$1\$2"'
  # Substitute needs the upstream body uncompressed.
  - 'RequestHeader unset Accept-Encoding'
  - 'AddOutputFilterByType SUBSTITUTE text/html'
  - 'SubstituteMaxLineLength 10m'
  - 'Substitute "s#(href|src|action)=(\x22|\x27)/(${ROOTS})(/|\x22|\x27|\?)#\$1=\$2${OOD_PREFIX}/\$3\$4#"'
  - 'Substitute "s#redir=/(${ROOTS})/#redir=${OOD_PREFIX}/\$1/#"'
  - 'Substitute "s#(path=|value=\x22)rnode/#\$1${OOD_PREFIX#/}/rnode/#"'
EOF

# The stock ssl.conf refers to a certificate that does not exist in a container.
rm -f /etc/httpd/conf.d/ssl.conf
# Apache's stock config also listens on port 80, which this container is not
# permitted to bind. The portal's own vhost declares the port it needs.
sed -i -E 's/^Listen[[:space:]]+80[[:space:]]*$/# &/' /etc/httpd/conf/httpd.conf
echo "ServerName ${OOD_HOST}" > /etc/httpd/conf.d/00-servername.conf
/opt/ood/ood-portal-generator/sbin/update_ood_portal --force >/dev/null

# ---------------------------------------------------------------------------
# 5. Per-user nginx (PUN)
# ---------------------------------------------------------------------------
MIN_UID=1000
[ "${PUID}" -lt "${MIN_UID}" ] && MIN_UID="${PUID}"
cat > /etc/ood/config/nginx_stage.yml <<EOF
---
min_uid: ${MIN_UID}
pun_custom_env:
  OOD_DASHBOARD_TITLE: "${OOD_DASHBOARD_TITLE:-Open OnDemand}"
  OOD_DASHBOARD_URL: "${OOD_PREFIX}/pun/sys/dashboard"
  OOD_SHELL_URL: "${OOD_PREFIX}/pun/sys/shell"
  OOD_FILES_URL: "${OOD_PREFIX}/pun/sys/dashboard/files"
  OOD_EDITOR_URL: "${OOD_PREFIX}/pun/sys/dashboard/files"
  OOD_PUBLIC_URL: "${OOD_PREFIX}/public"
  JUNO_OOD_PREFIX: "${OOD_PREFIX}"
EOF

# ---------------------------------------------------------------------------
# 6. Cluster definition
# ---------------------------------------------------------------------------
mkdir -p /etc/ood/config/clusters.d
cat > /etc/ood/config/clusters.d/slurm.yml <<EOF
---
v2:
  metadata:
    title: "${CLUSTER_TITLE}"
  login:
    host: "${SLURM_LOGIN_HOST}"
  job:
    adapter: "slurm"
    # Slurm commands run on the login node over SSH, never in this pod.
    submit_host: "${SLURM_LOGIN_HOST}"
    strict_host_checking: false
  batch_connect:
    # Compute nodes are pods; their hostnames do not resolve from another
    # namespace, so interactive apps advertise the pod IP instead.
    basic:
      script_wrapper: |
        %s
      set_host: "host=\$(hostname -i | awk '{print \$1}')"
    vnc:
      script_wrapper: |
        export PATH="/opt/TurboVNC/bin:\$PATH"
        export WEBSOCKIFY_CMD="\${WEBSOCKIFY_CMD:-websockify}"
        %s
      set_host: "host=\$(hostname -i | awk '{print \$1}')"
EOF

# ---------------------------------------------------------------------------
# 7. Apps
# ---------------------------------------------------------------------------
mkdir -p /etc/ood/config/apps/shell
cat > /etc/ood/config/apps/shell/env <<EOF
OOD_SSHHOST_ALLOWLIST="${SLURM_LOGIN_HOST}"
OOD_SHELL_ORIGIN_CHECK="${OOD_SHELL_ORIGIN_CHECK:-https://${OOD_HOST}}"
EOF

# Bundled Jupyter interactive app.
if [ "${OOD_JUPYTER_APP:-true}" = "true" ] && [ -d /opt/juno/apps/jupyter ]; then
  APP=/var/www/ood/apps/sys/jupyter
  rm -rf "${APP}"
  mkdir -p "${APP}/template"
  for f in /opt/juno/apps/jupyter/*; do
    name="$(basename "$f")"
    case "${name}" in
      template__*) cp -L "$f" "${APP}/template/${name#template__}" ;;
      *)           cp -L "$f" "${APP}/${name}" ;;
    esac
  done
  chmod 755 "${APP}/template/"*.sh.erb 2>/dev/null || true
fi

# The desktop app ships with Open OnDemand but stays hidden until it is given a
# cluster. It needs TurboVNC, websockify and a desktop on the compute nodes.
mkdir -p /etc/ood/config/apps/bc_desktop
if [ "${OOD_DESKTOP_APP:-false}" = "true" ]; then
  cat > /etc/ood/config/apps/bc_desktop/slurm.yml <<EOF
---
title: "Desktop"
cluster: "slurm"
attributes:
  desktop: "${OOD_DESKTOP:-xfce}"
EOF
else
  rm -f /etc/ood/config/apps/bc_desktop/slurm.yml
fi

# The apps ship precompiled CSS and JavaScript with /pun/sys/<app> baked in
# (icon fonts, client-side routes). Those are static files, so they are patched
# on disk once rather than filtered on every request. Undo-then-apply keeps
# this safe to repeat when the container restarts.
grep -rl --include='*.css' --include='*.js' '/pun/sys/' /var/www/ood/apps/sys/*/public 2>/dev/null \
  | while IFS= read -r asset; do
      sed -i -e "s#${OOD_PREFIX}/pun/sys/#/pun/sys/#g" -e "s#/pun/sys/#${OOD_PREFIX}/pun/sys/#g" "${asset}"
      # A pre-compressed copy would still carry the old paths.
      rm -f "${asset}.gz" "${asset}.br"
    done

# Stage every system app now, so the first visit lands on the dashboard rather
# than on Open OnDemand's "Initialize App" page.
for app in /var/www/ood/apps/sys/*/; do
  /opt/ood/nginx_stage/sbin/nginx_stage app --user="${USER}" --sub-uri="${OOD_PREFIX}/pun" \
    --sub-request="/sys/$(basename "$app")" --skip-nginx >/dev/null 2>&1 || true
done

# ---------------------------------------------------------------------------
# 8. Run
# ---------------------------------------------------------------------------
mkdir -p /run/httpd /var/run/ondemand-nginx
rm -f /run/httpd/httpd.pid

shutdown() {
  log "stopping"
  /opt/ood/nginx_stage/sbin/nginx_stage nginx --user="${USER}" --signal=stop >/dev/null 2>&1 || true
  kill -TERM "${HTTPD_PID}" 2>/dev/null || true
  wait "${HTTPD_PID}" 2>/dev/null || true
  exit 0
}
trap shutdown TERM INT

log "serving ${USER} at ${OOD_PREFIX}/ - jobs submit through ${SLURM_LOGIN_HOST}:${SLURM_LOGIN_PORT}"
/usr/sbin/httpd -DFOREGROUND &
HTTPD_PID=$!
wait "${HTTPD_PID}"

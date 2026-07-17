#!/usr/bin/env bash
# =============================================================================
# Seed /etc/vps/*.env for high-frequency cron jobs from 1Password.
#
# Cron jobs that run at high frequency (e.g. every minute) must NOT call `op`
# per invocation — 1Password rate-limits that frequency and silently kills the
# job (this is exactly what happened to the pg-health liveness monitor). This
# script materializes each cron/*.env.tpl into a plaintext env file once, so
# the cron job sources it directly with zero 1Password calls at runtime.
#
# Re-run this after rotating any secret referenced by a cron/*.env.tpl.
#
# Injects to a temp file first (not directly to /etc/vps) because `op inject`
# would otherwise run under `sudo`, which drops the invoking user's
# OP_SERVICE_ACCOUNT_TOKEN — `op` would then have no way to authenticate.
# =============================================================================
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DEST_DIR="/etc/vps"

shopt -s nullglob
templates=("${REPO_DIR}"/cron/*.env.tpl)
shopt -u nullglob

if [[ ${#templates[@]} -eq 0 ]]; then
  echo "No cron/*.env.tpl templates found — nothing to seed."
  exit 0
fi

# Own the destination dir explicitly rather than letting `install -D` create it
# — that would default to 755 root:root and drift from what setup.sh provisions
# on a fresh server. 750 root:jkrumm: cron (as jkrumm) can traverse, nobody else.
sudo mkdir -p "${DEST_DIR}"
sudo chown "root:jkrumm" "${DEST_DIR}"
sudo chmod 750 "${DEST_DIR}"

for tpl in "${templates[@]}"; do
  name="$(basename "${tpl}" .env.tpl)"
  dest="${DEST_DIR}/${name}.env"

  tmp="$(mktemp)"
  trap 'rm -f "${tmp}"' EXIT

  op --account tkrumm inject -i "${tpl}" -o "${tmp}" -f
  sudo install -D -m 600 -o jkrumm -g jkrumm "${tmp}" "${dest}"
  rm -f "${tmp}"
  trap - EXIT

  echo "Seeded ${dest}"
done

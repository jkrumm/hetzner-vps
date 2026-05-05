#!/usr/bin/env bash
# =============================================================================
# Sync wildcard *.${DOMAIN} certificate from Traefik's acme.json to
# apps/fpp/certs/{cert.pem,key.pem} so MariaDB can serve TLS to Vercel.
# On change: FLUSH SSL inside the running mariadb container (no restart needed).
#
# Idempotent — exits cleanly if certificate is unchanged. Run via cron every 6h.
#
# Required env vars: DOMAIN, MARIADB_ROOT_PASSWORD
# =============================================================================
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
ACME_JSON="${REPO_DIR}/traefik/acme.json"
CERTS_DIR="${REPO_DIR}/apps/fpp/certs"

: "${DOMAIN:?DOMAIN env var required}"

mkdir -p "${CERTS_DIR}"

if [[ ! -s "${ACME_JSON}" ]]; then
  echo "ERROR: ${ACME_JSON} missing or empty — Traefik hasn't issued certs yet." >&2
  echo "Run 'make networking-up' first and wait for cert provisioning." >&2
  exit 1
fi

# Traefik can store the wildcard cert as either the main domain or as a SAN
# under another cert (e.g. main=jkrumm.com, sans=["*.jkrumm.com"]). Match both.
JQ_SELECT='.letsencrypt.Certificates[] | select(([.domain.main] + (.domain.sans // [])) | index($d))'
cert_b64=$(jq -r --arg d "*.${DOMAIN}" "${JQ_SELECT} | .certificate" "${ACME_JSON}")
key_b64=$(jq -r --arg d "*.${DOMAIN}" "${JQ_SELECT} | .key"         "${ACME_JSON}")

if [[ -z "${cert_b64}" || "${cert_b64}" == "null" ]]; then
  echo "ERROR: wildcard certificate for *.${DOMAIN} not found in ${ACME_JSON}." >&2
  echo "Check Traefik logs and ensure the wildcard router has TLS enabled." >&2
  exit 1
fi

new_cert=$(echo "${cert_b64}" | base64 -d)
new_key=$(echo "${key_b64}"  | base64 -d)

old_cert=""
[[ -f "${CERTS_DIR}/cert.pem" ]] && old_cert=$(cat "${CERTS_DIR}/cert.pem")

if [[ "${new_cert}" == "${old_cert}" ]]; then
  echo "Certificate unchanged — nothing to do."
  exit 0
fi

echo "Certificate changed — writing cert.pem and key.pem..."
umask 022
printf '%s\n' "${new_cert}" > "${CERTS_DIR}/cert.pem"
printf '%s\n' "${new_key}"  > "${CERTS_DIR}/key.pem"
# 644 on both: host filesystem is single-user; mariadb container's mysql user (uid 999)
# must be able to read these via the bind mount. Threat model is network attackers,
# not local users (jkrumm has root via sudo anyway).
chmod 644 "${CERTS_DIR}/cert.pem" "${CERTS_DIR}/key.pem"

if docker ps --format '{{.Names}}' | grep -q '^mariadb$'; then
  echo "Reloading TLS in running mariadb container (FLUSH SSL)..."
  docker exec -i \
    -e MYSQL_PWD="${MARIADB_ROOT_PASSWORD:-}" \
    mariadb mariadb -u root -e 'FLUSH SSL;'
  echo "TLS reloaded."
else
  echo "MariaDB container not running — certs written, will be picked up on next start."
fi

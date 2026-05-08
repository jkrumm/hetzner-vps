#!/usr/bin/env bash
# Seed the registry with :initial bun-email-api image so RollHook has a
# running container to authorize OIDC deploys against. Run once per fresh
# server before the first GitHub Actions deploy succeeds.
#
# Idempotent — re-running just rebuilds and re-pushes.
#
# Run via:  make bun-email-api-bootstrap-image
# Requires: ZOT_PASSWORD in env (provided by op run via the Make target).

set -euo pipefail

: "${ZOT_PASSWORD:?ZOT_PASSWORD not set — run via 'make bun-email-api-bootstrap-image'}"

REGISTRY="rollhook.jkrumm.com"
SRC_DIR="${BEA_SRC_DIR:-/tmp/bun-email-api-bootstrap}"
REPO_URL="https://github.com/jkrumm/bun-email-api"

if [ ! -d "${SRC_DIR}/.git" ]; then
  echo "[1/4] Cloning ${REPO_URL} → ${SRC_DIR}"
  rm -rf "${SRC_DIR}"
  git clone --depth=1 "${REPO_URL}" "${SRC_DIR}"
else
  echo "[1/4] Updating ${SRC_DIR}"
  git -C "${SRC_DIR}" fetch --depth=1 origin master
  git -C "${SRC_DIR}" reset --hard origin/master
fi

echo "[2/4] docker login ${REGISTRY}"
echo "${ZOT_PASSWORD}" | docker login "${REGISTRY}" -u rollhook --password-stdin

echo "[3/4] Build ${REGISTRY}/bun-email-api:initial"
docker build \
  -t "${REGISTRY}/bun-email-api:initial" \
  -t "${REGISTRY}/bun-email-api:latest" \
  -f "${SRC_DIR}/Dockerfile" \
  "${SRC_DIR}"

echo "[4/4] Push ${REGISTRY}/bun-email-api:{initial,latest}"
docker push "${REGISTRY}/bun-email-api:initial"
docker push "${REGISTRY}/bun-email-api:latest"

echo "Done. Now run:  make bun-email-api-env && make bun-email-api-up"

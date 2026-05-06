#!/usr/bin/env bash
# Seed the registry with :initial images for fpp-server and fpp-analytics so
# RollHook has running containers to authorize OIDC deploys against. Run once
# per fresh server before the first GitHub Actions deploy.
#
# Idempotent — re-running just rebuilds and re-pushes :initial.
#
# Run via:  make fpp-bootstrap-images
# Requires: ROLLHOOK_SECRET in env (provided by op run via the Make target).

set -euo pipefail

: "${ROLLHOOK_SECRET:?ROLLHOOK_SECRET not set — run via 'make fpp-bootstrap-images'}"

REGISTRY="rollhook.jkrumm.com"
SRC_DIR="${FPP_SRC_DIR:-/tmp/fpp-bootstrap}"
REPO_URL="https://github.com/jkrumm/free-planning-poker"

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
echo "${ROLLHOOK_SECRET}" | docker login "${REGISTRY}" -u rollhook --password-stdin

echo "[3/4] Build + push ${REGISTRY}/fpp-server:initial"
docker build \
  -t "${REGISTRY}/fpp-server:initial" \
  -t "${REGISTRY}/fpp-server:latest" \
  -f "${SRC_DIR}/fpp-server/Dockerfile" \
  "${SRC_DIR}/fpp-server"
docker push "${REGISTRY}/fpp-server:initial"
docker push "${REGISTRY}/fpp-server:latest"

echo "[4/4] Build + push ${REGISTRY}/fpp-analytics(:initial|:latest) and fpp-analytics-updater"
# fpp-analytics and fpp-analytics-updater are the same image content under two
# names. RollHook's container discovery matches by bare image name, so giving
# the updater its own name keeps it from being picked up when the analytics
# service is deployed.
docker build \
  -t "${REGISTRY}/fpp-analytics:initial" \
  -t "${REGISTRY}/fpp-analytics:latest" \
  -t "${REGISTRY}/fpp-analytics-updater:initial" \
  -t "${REGISTRY}/fpp-analytics-updater:latest" \
  -f "${SRC_DIR}/fpp-analytics/Dockerfile" \
  "${SRC_DIR}/fpp-analytics"
docker push "${REGISTRY}/fpp-analytics:initial"
docker push "${REGISTRY}/fpp-analytics:latest"
docker push "${REGISTRY}/fpp-analytics-updater:initial"
docker push "${REGISTRY}/fpp-analytics-updater:latest"

echo "Done. Now run:  make fpp-up"

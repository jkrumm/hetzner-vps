#!/usr/bin/env bash
# Seed the registry with :initial audio-gateway image so RollHook has a
# running container to authorize OIDC deploys against. Run once per fresh
# server before the first GitHub Actions deploy succeeds.
#
# Idempotent — re-running just rebuilds and re-pushes.
#
# Run via:  make audio-gateway-bootstrap-image
# Requires: ROLLHOOK_SECRET in env (provided by op run via the Make target).

set -euo pipefail

: "${ROLLHOOK_SECRET:?ROLLHOOK_SECRET not set — run via 'make audio-gateway-bootstrap-image'}"

REGISTRY="rollhook.jkrumm.com"
SRC_DIR="${AUDIO_GATEWAY_SRC_DIR:-/tmp/audio-gateway-bootstrap}"
REPO_URL="https://github.com/jkrumm/audio-gateway"

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

echo "[3/4] Build ${REGISTRY}/audio-gateway:initial"
docker build \
  -t "${REGISTRY}/audio-gateway:initial" \
  -t "${REGISTRY}/audio-gateway:latest" \
  "${SRC_DIR}"

echo "[4/4] Push images"
docker push "${REGISTRY}/audio-gateway:initial"
docker push "${REGISTRY}/audio-gateway:latest"

echo
echo "Done. Now:"
echo "  1. make audio-gateway-env"
echo "  2. make audio-gateway-up"

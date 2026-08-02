#!/usr/bin/env bash
# Seed the registry with :initial research-gateway image so RollHook has a
# running container to authorize OIDC deploys against. Run once per fresh
# server before the first GitHub Actions deploy succeeds.
#
# Idempotent — re-running just rebuilds and re-pushes.
#
# Run via:  make research-gateway-bootstrap-image
# Requires: ROLLHOOK_SECRET in env (provided by op run via the Make target).

set -euo pipefail

: "${ROLLHOOK_SECRET:?ROLLHOOK_SECRET not set — run via 'make research-gateway-bootstrap-image'}"

REGISTRY="rollhook.jkrumm.com"
SRC_DIR="${RESEARCH_GATEWAY_SRC_DIR:-/tmp/research-gateway-bootstrap}"
REPO_URL="https://github.com/jkrumm/research-gateway"

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

echo "[3/5] Build ${REGISTRY}/research-gateway:initial"
docker build \
  -t "${REGISTRY}/research-gateway:initial" \
  -t "${REGISTRY}/research-gateway:latest" \
  -f "${SRC_DIR}/Dockerfile" \
  "${SRC_DIR}"

# The JavaScript-rendering sidecar. Seeded here for the same reason as the gateway image and
# one more: RollHook tags by git SHA and never moves :latest, so CI alone never produces the
# :latest tag that compose.yml defaults to. Until this has run once, `research-gateway-up`
# has no sidecar image to start and the deploy-lightpanda.yml workflow has no container to
# authorize against.
echo "[4/5] Build ${REGISTRY}/research-gateway-lightpanda:initial"
docker build \
  -t "${REGISTRY}/research-gateway-lightpanda:initial" \
  -t "${REGISTRY}/research-gateway-lightpanda:latest" \
  -f "${SRC_DIR}/lightpanda/Dockerfile" \
  "${SRC_DIR}/lightpanda"

echo "[5/5] Push images"
docker push "${REGISTRY}/research-gateway:initial"
docker push "${REGISTRY}/research-gateway:latest"
docker push "${REGISTRY}/research-gateway-lightpanda:initial"
docker push "${REGISTRY}/research-gateway-lightpanda:latest"

echo
echo "Done. Now:"
echo "  1. make research-gateway-env"
echo "  2. make research-gateway-up"

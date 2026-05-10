#!/usr/bin/env bash
# Seed the registry with :initial argo-{api,dashboard} images so RollHook has
# running containers to authorize OIDC deploys against. Run once per fresh
# server before the first GitHub Actions deploy succeeds.
#
# Idempotent — re-running just rebuilds and re-pushes.
#
# Run via:  make argo-bootstrap-image
# Requires: ROLLHOOK_SECRET in env (provided by op run via the Make target).

set -euo pipefail

: "${ROLLHOOK_SECRET:?ROLLHOOK_SECRET not set — run via 'make argo-bootstrap-image'}"

REGISTRY="rollhook.jkrumm.com"
SRC_DIR="${ARGO_SRC_DIR:-/tmp/argo-bootstrap}"
REPO_URL="https://github.com/jkrumm/argo"

if [ ! -d "${SRC_DIR}/.git" ]; then
  echo "[1/5] Cloning ${REPO_URL} → ${SRC_DIR}"
  rm -rf "${SRC_DIR}"
  git clone --depth=1 "${REPO_URL}" "${SRC_DIR}"
else
  echo "[1/5] Updating ${SRC_DIR}"
  git -C "${SRC_DIR}" fetch --depth=1 origin master
  git -C "${SRC_DIR}" reset --hard origin/master
fi

echo "[2/5] docker login ${REGISTRY}"
echo "${ROLLHOOK_SECRET}" | docker login "${REGISTRY}" -u rollhook --password-stdin

echo "[3/5] Build ${REGISTRY}/argo-api:initial"
docker build \
  -t "${REGISTRY}/argo-api:initial" \
  -t "${REGISTRY}/argo-api:latest" \
  -f "${SRC_DIR}/packages/api/Dockerfile" \
  "${SRC_DIR}"

echo "[4/5] Build ${REGISTRY}/argo-dashboard:initial"
docker build \
  --build-arg "VITE_API_URL=https://argo.jkrumm.com/api" \
  -t "${REGISTRY}/argo-dashboard:initial" \
  -t "${REGISTRY}/argo-dashboard:latest" \
  -f "${SRC_DIR}/packages/dashboard/Dockerfile" \
  "${SRC_DIR}"

echo "[5/5] Push images"
docker push "${REGISTRY}/argo-api:initial"
docker push "${REGISTRY}/argo-api:latest"
docker push "${REGISTRY}/argo-dashboard:initial"
docker push "${REGISTRY}/argo-dashboard:latest"

echo
echo "Done. Now:"
echo "  1. make argo-env"
echo "  2. make argo-up"

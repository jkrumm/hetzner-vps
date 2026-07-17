#!/usr/bin/env bash
# Seed the registry with an :initial basalt-ui-marketing image so RollHook has a
# running container to authorize OIDC deploys against. Run once per fresh
# server before the first GitHub Actions deploy succeeds.
#
# RollHook's discover step matches a *running* container by image name and reads
# its compose labels; with no container it fails ErrServiceNotFound. Hence the
# chicken-and-egg this script breaks.
#
# Idempotent — re-running just rebuilds and re-pushes.
#
# Run via:  make basalt-ui-marketing-bootstrap-image
# Requires: ROLLHOOK_SECRET in env (provided by op run via the Make target).

set -euo pipefail

: "${ROLLHOOK_SECRET:?ROLLHOOK_SECRET not set — run via 'make basalt-ui-marketing-bootstrap-image'}"

REGISTRY="rollhook.jkrumm.com"
SRC_DIR="${BASALT_UI_SRC_DIR:-/tmp/basalt-ui-bootstrap}"
REPO_URL="https://github.com/jkrumm/basalt-ui"

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

# Monorepo build — the Dockerfile lives under apps/marketing but needs the repo
# root as context (root package.json + bun.lock + every workspace manifest).
echo "[3/4] Build ${REGISTRY}/basalt-ui-marketing:initial"
docker build \
  -t "${REGISTRY}/basalt-ui-marketing:initial" \
  -t "${REGISTRY}/basalt-ui-marketing:latest" \
  -f "${SRC_DIR}/apps/marketing/Dockerfile" \
  "${SRC_DIR}"

echo "[4/4] Push ${REGISTRY}/basalt-ui-marketing:{initial,latest}"
docker push "${REGISTRY}/basalt-ui-marketing:initial"
docker push "${REGISTRY}/basalt-ui-marketing:latest"

echo "Done. Now run:  make basalt-ui-marketing-up"

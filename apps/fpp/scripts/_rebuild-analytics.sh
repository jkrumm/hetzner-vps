#!/usr/bin/env bash
# Temporary one-shot to rebuild fpp-analytics from /tmp/fpp-bootstrap with
# any local patches applied. Used to unblock bootstrap when a fix needs to
# land before the FPP commit can be pushed. Delete once we don't need it.
set -euo pipefail
: "${ROLLHOOK_SECRET:?run via 'op run --env-file=.env.tpl --'}"

REGISTRY=rollhook.jkrumm.com
SRC=/tmp/fpp-bootstrap

echo "${ROLLHOOK_SECRET}" | docker login "${REGISTRY}" -u rollhook --password-stdin

docker build \
  -t "${REGISTRY}/fpp-analytics:latest" \
  -f "${SRC}/fpp-analytics/Dockerfile" \
  "${SRC}/fpp-analytics"
docker push "${REGISTRY}/fpp-analytics:latest"

-include .env
export

ENV ?= dev

OP_RUN = op run --account tkrumm --env-file=.env.tpl --

.DEFAULT_GOAL := help

.PHONY: help require-prod require-dev \
        up down networking-up networking-down infra-up infra-down monitoring-up monitoring-down \
        rollhook-update \
        fpp-up fpp-down fpp-mariadb-setup fpp-cert-sync fpp-bootstrap-images fpp-env \
        fpp-backup fpp-shell fpp-restore-local fpp-sync-from-prod \
        bun-email-api-up bun-email-api-down bun-email-api-env bun-email-api-bootstrap-image \
        argo-up argo-down argo-env argo-bootstrap-image \
        research-gateway-up research-gateway-down research-gateway-env research-gateway-bootstrap-image \
        image-gen-gateway-up image-gen-gateway-down image-gen-gateway-env image-gen-gateway-redeploy image-gen-gateway-bootstrap-image \
        photo-gallery-up photo-gallery-down \
        imgproxy-up imgproxy-down \
        basalt-ui-marketing-up basalt-ui-marketing-down basalt-ui-marketing-bootstrap-image \
        modelpick-up modelpick-down modelpick-env modelpick-refresh modelpick-migrate modelpick-seed \
        audio-gateway-up audio-gateway-down audio-gateway-env audio-gateway-bootstrap-image \
        postgres-setup cron-env-seed ps backup restore-local sync-from-prod pg-sync-schema firewall shell-postgres db-counts prune

## Show this help (default). Adapts to ENV — dims targets not available in the current env.
help:
	@printf "vps — ENV=$(ENV)\n\n"
	@awk -v env="$(ENV)" 'BEGIN { FS = ":"; primary_n = 0; other_n = 0 } \
		/^## / { if (doc == "") doc = substr($$0, 4); next } \
		/^[a-zA-Z][a-zA-Z0-9_-]*:/ { \
			split($$0, parts, ":"); \
			target = parts[1]; \
			prereqs = parts[2]; \
			sub(/[ \t]*;.*/, "", prereqs); \
			if (target == "require-prod" || target == "require-dev") { doc = ""; next } \
			tag = "any"; \
			if (prereqs ~ /require-prod/) tag = "prod"; \
			else if (prereqs ~ /require-dev/) tag = "dev"; \
			if (tag == "any" || tag == env) { \
				primary[primary_n++] = sprintf("  \033[36m%-26s\033[0m %s", target, doc); \
			} else { \
				other[other_n++] = sprintf("  \033[2m%-26s %s\033[0m", target, doc); \
			} \
			doc = ""; next \
		} \
		/^[[:space:]]*$$/ { doc = "" } \
		END { \
			printf "Available now (ENV=%s):\n\n", env; \
			for (i = 0; i < primary_n; i++) print primary[i]; \
			if (other_n > 0) { \
				other_env = (env == "dev") ? "prod" : "dev"; \
				printf "\nRequires ENV=%s:\n\n", other_env; \
				for (i = 0; i < other_n; i++) print other[i]; \
			} \
		}' $(MAKEFILE_LIST)

## Internal env gates — keep prod/dev-only targets from running in the wrong env.
require-prod:
	@[ "$(ENV)" = "prod" ] || { echo "ERROR: target requires ENV=prod (got ENV=$(ENV))"; exit 1; }

require-dev:
	@[ "$(ENV)" = "dev" ] || { echo "ERROR: target requires ENV=dev (got ENV=$(ENV))"; exit 1; }

## All stacks — adapts to ENV (dev: compose.dev.yml, prod: ordered stack sequence)
## Dev: if something is already bound to :6379 (e.g. another project's Valkey),
## skip our valkey service and let apps share the existing one. Same image,
## same protocol, dev data is throwaway — no reason to fight over the port.
up:
ifeq ($(ENV),prod)
	$(MAKE) networking-up
	$(MAKE) infra-up
	$(MAKE) monitoring-up
	$(MAKE) fpp-up
	$(MAKE) bun-email-api-up
	$(MAKE) photo-gallery-up
	$(MAKE) imgproxy-up
	$(MAKE) audio-gateway-up
else
	@if lsof -nP -iTCP:6379 -sTCP:LISTEN >/dev/null 2>&1; then \
		echo "→ Detected existing Redis/Valkey on :6379 — skipping the dev valkey service"; \
		echo "  Apps still connect to localhost:6379 either way."; \
		$(OP_RUN) docker compose -f compose.dev.yml up -d postgres mariadb clickstack; \
	else \
		$(OP_RUN) docker compose -f compose.dev.yml up -d; \
	fi
endif

down:
ifeq ($(ENV),prod)
	$(MAKE) audio-gateway-down
	$(MAKE) imgproxy-down
	$(MAKE) photo-gallery-down
	$(MAKE) bun-email-api-down
	$(MAKE) fpp-down
	$(MAKE) monitoring-down
	$(MAKE) infra-down
	$(MAKE) networking-down
else
	$(OP_RUN) docker compose -f compose.dev.yml down
endif

## Individual prod stacks — targeted restarts
networking-up:   require-prod ; $(OP_RUN) docker compose -f compose.networking.yml up -d
networking-down: require-prod ; $(OP_RUN) docker compose -f compose.networking.yml down
infra-up:        require-prod ; $(OP_RUN) docker compose -f compose.infra.yml up -d
infra-down:      require-prod ; $(OP_RUN) docker compose -f compose.infra.yml down
monitoring-up:   require-prod ; $(OP_RUN) docker compose -f compose.monitoring.yml up -d
monitoring-down: require-prod ; $(OP_RUN) docker compose -f compose.monitoring.yml down

## Pull the newest ghcr.io/jkrumm/rollhook:latest and recreate the container.
## RollHook deploys every other app but cannot deploy itself; Watchtower only
## picks it up at the 04:00 sweep. Use this to take a fresh release immediately.
## Prints the running version afterwards — the container publishes no host port,
## so the probe goes through `docker exec`.
rollhook-update: require-prod
	$(OP_RUN) docker compose -f compose.networking.yml pull rollhook
	$(OP_RUN) docker compose -f compose.networking.yml up -d rollhook
	@sleep 5; echo "  running: $$(docker exec rollhook curl -sf http://localhost:7700/health || echo '<not answering yet>')"

## FPP stack (MariaDB now; fpp-server + fpp-analytics later) — apps/fpp/compose.yml
## On a fresh server: networking-up first, then fpp-cert-sync, then fpp-up.
fpp-up:   require-prod ; $(OP_RUN) docker compose -f apps/fpp/compose.yml up -d
fpp-down: require-prod ; $(OP_RUN) docker compose -f apps/fpp/compose.yml down
fpp-mariadb-setup: require-prod
	$(OP_RUN) ./apps/fpp/scripts/setup-mariadb.sh
fpp-cert-sync: require-prod
	$(OP_RUN) ./apps/fpp/scripts/cert-sync.sh
## One-shot bootstrap — pushes :initial fpp-server/fpp-analytics images to rollhook.jkrumm.com
## so RollHook has running containers to authorize OIDC deploys against. Re-runnable.
fpp-bootstrap-images: require-prod
	$(OP_RUN) ./apps/fpp/scripts/bootstrap-images.sh
## Materialize apps/fpp/.env from apps/fpp/.env.tpl (via `op inject`). Required so
## RollHook's `docker compose up --scale` — which doesn't go through `op run` —
## can resolve ${VAR} interpolations in apps/fpp/compose.yml. Re-run after secret
## rotation. The resulting .env is chmod 600, gitignored, and stays on VPS.
fpp-env: require-prod
	op --account tkrumm inject -i apps/fpp/.env.tpl -o apps/fpp/.env -f
	chmod 644 apps/fpp/.env
	@echo "Wrote apps/fpp/.env (chmod 644, gitignored)"
	@echo "Note: 644 is required because the RollHook container runs as a"
	@echo "non-root user whose uid doesn't match the host's jkrumm uid."
	@echo "VPS has no other shell users so the local-readability risk is bounded."
## FPP MariaDB → S3 backup (cron 03:30 in prod; manual via this target).
fpp-backup: require-prod
	$(OP_RUN) ./apps/fpp/scripts/backup-mariadb.sh
# NOTE: restoring PROD MariaDB from S3 has NO make target by design — it overwrites
# production. It is a gated, human-only DR tool: apps/fpp/scripts/restore-mariadb.sh
# (see docs/disaster-recovery.md).
## Dev — pull latest (or BACKUP_FILE=...) S3 backup → local mariadb. Validates DR chain.
fpp-restore-local: require-dev
	$(OP_RUN) ./apps/fpp/scripts/restore-mariadb-local.sh
## Dev — fresh sync from prod mariadb over SSH (no S3). Re-runnable.
# No OP_RUN: the VPS resolves the prod credentials remotely (inside the script's
# `ssh vps ... op run`), and the local half reads the dev container's own env.
# That keeps this runnable on the headless mini, where op has no biometric.
fpp-sync-from-prod: require-dev
	./apps/fpp/scripts/sync-mariadb-from-vps.sh
## Interactive mariadb shell — works in both envs (resolves the local mariadb container).
fpp-shell:
	$(OP_RUN) sh -c 'docker exec -it -e MYSQL_PWD="$$MARIADB_ROOT_PASSWORD" mariadb mariadb -u root "$$MARIADB_DB"'

## bun-email-api stack (Bun + Resend, RollHook-managed) — apps/bun-email-api/compose.yml
## Stateless, no DB. RollHook deploys on push to jkrumm/bun-email-api:master.
bun-email-api-up:   require-prod ; $(OP_RUN) docker compose -f apps/bun-email-api/compose.yml up -d
bun-email-api-down: require-prod ; $(OP_RUN) docker compose -f apps/bun-email-api/compose.yml down
## One-shot bootstrap — clone bun-email-api repo, build, and push :initial to
## rollhook.jkrumm.com so RollHook has a running container to authorize OIDC
## deploys against. Re-runnable.
bun-email-api-bootstrap-image: require-prod
	$(OP_RUN) ./apps/bun-email-api/scripts/bootstrap-image.sh
## Materialize apps/bun-email-api/.env from .env.tpl (via `op inject`). Required so
## RollHook's `docker compose up --scale` — which doesn't go through `op run` —
## can resolve ${VAR} interpolations in apps/bun-email-api/compose.yml. Re-run
## after rotating BEA secrets. Resulting .env is chmod 644 and gitignored.
bun-email-api-env: require-prod
	op --account tkrumm inject -i apps/bun-email-api/.env.tpl -o apps/bun-email-api/.env -f
	chmod 644 apps/bun-email-api/.env
	@echo "Wrote apps/bun-email-api/.env (chmod 644, gitignored)"

## argo stack (api + dashboard, RollHook-managed) — apps/argo/compose.yml
## Tailscale-only via DNS-only A record argo.jkrumm.com → ${VPS_TAILSCALE_IP}.
## RollHook deploys on push to jkrumm/argo:master.
##
## argo-up: recreate containers WITHOUT pulling a new image. Reads the SHAs
## of the currently-running containers and pins IMAGE_TAG to each. Use this
## when you change apps/argo/compose.yml (labels, mounts, env) and need the
## changes applied without bumping the running code. To deploy new code, use
## `make argo-redeploy` (triggers RollHook via empty-commit push).
##
## Why this dance: RollHook tags pushed images by git SHA only — it does NOT
## update the :latest tag. So a naive `docker compose up -d` would resolve
## `${IMAGE_TAG:-...:latest}` and roll the running containers back to a stale
## :latest. Pinning to the running image avoids that regression.
argo-up: require-prod
	@API_IMG=$$(docker inspect --format '{{.Config.Image}}' $$(docker ps --filter 'label=com.docker.compose.service=argo-api' --format '{{.Names}}' | head -1) 2>/dev/null || echo ""); \
	WEB_IMG=$$(docker inspect --format '{{.Config.Image}}' $$(docker ps --filter 'label=com.docker.compose.service=argo-dashboard' --format '{{.Names}}' | head -1) 2>/dev/null || echo ""); \
	if [ -z "$$API_IMG" ] || [ -z "$$WEB_IMG" ]; then \
	  echo "  ✗ argo containers not running — bootstrap via 'make argo-bootstrap-image' then push to argo master to trigger RollHook"; \
	  exit 1; \
	fi; \
	echo "  pinning argo-api      → $$API_IMG"; \
	echo "  pinning argo-dashboard → $$WEB_IMG"; \
	$(OP_RUN) env ARGO_API_IMAGE=$$API_IMG ARGO_DASHBOARD_IMAGE=$$WEB_IMG docker compose -f apps/argo/compose.yml --env-file apps/argo/.env up -d
argo-down: require-prod ; $(OP_RUN) docker compose -f apps/argo/compose.yml --env-file apps/argo/.env down

## Trigger a fresh RollHook deploy by pushing an empty commit to argo's master.
## RollHook detects the push, rebuilds both images at the new SHA, and rolling-
## restarts the containers. Use this instead of `make argo-up` when you want
## new code (or when you just want compose.yml changes safely applied via a
## fresh build).
argo-redeploy: require-dev
	@if [ ! -d $$HOME/SourceRoot/argo ]; then echo "  ✗ argo repo not found at ~/SourceRoot/argo"; exit 1; fi
	@cd $$HOME/SourceRoot/argo && \
	  git commit --allow-empty -m "chore: redeploy (triggered via vps make argo-redeploy)" && \
	  git push && \
	  echo "  ✓ pushed — watch the build at https://github.com/jkrumm/argo/actions"
## One-shot bootstrap — clone argo repo, build both images, push :initial to
## rollhook.jkrumm.com so RollHook has running containers to authorize OIDC
## deploys against. Re-runnable.
argo-bootstrap-image: require-prod
	$(OP_RUN) ./apps/argo/scripts/bootstrap-image.sh
## Materialize apps/argo/.env from .env.tpl. Required so RollHook's
## `docker compose up --scale` can resolve ${VAR} interpolations. Re-run after
## rotating any argo secret. Resulting .env is chmod 644 and gitignored.
argo-env: require-prod
	op --account tkrumm inject -i apps/argo/.env.tpl -o apps/argo/.env -f
	chmod 644 apps/argo/.env
	@echo "Wrote apps/argo/.env (chmod 644, gitignored)"

## research-gateway stack (Bun research API, RollHook-managed) — apps/research-gateway/compose.yml
## Deploys to research.jkrumm.com. RollHook deploys on push to jkrumm/research-gateway:master.
##
## research-gateway-up: recreate container WITHOUT pulling a new image. Reads the SHA
## of the currently-running container and pins RESEARCH_GATEWAY_IMAGE to it. Use this
## when you change apps/research-gateway/compose.yml (labels, mounts, env) and need the
## changes applied without bumping the running code. To deploy new code, use
## `make research-gateway-redeploy` (triggers RollHook via empty-commit push).
##
## Why this dance: RollHook tags pushed images by git SHA only — it does NOT
## update the :latest tag. So a naive `docker compose up -d` would resolve
## `${IMAGE_TAG:-...:latest}` and roll the running container back to a stale
## :latest. Pinning to the running image avoids that regression.
research-gateway-up: require-prod
	@IMG=$$(docker inspect --format '{{.Config.Image}}' $$(docker ps --filter 'label=com.docker.compose.service=research-gateway' --format '{{.Names}}' | head -1) 2>/dev/null || echo ""); \
	if [ -z "$$IMG" ]; then \
	  echo "  no running container — genesis start from :latest (bootstrap-seeded)"; \
	  $(OP_RUN) docker compose -f apps/research-gateway/compose.yml --env-file apps/research-gateway/.env up -d; \
	else \
	  echo "  pinning research-gateway → $$IMG"; \
	  $(OP_RUN) env RESEARCH_GATEWAY_IMAGE=$$IMG docker compose -f apps/research-gateway/compose.yml --env-file apps/research-gateway/.env up -d; \
	fi
research-gateway-down: require-prod ; $(OP_RUN) docker compose -f apps/research-gateway/compose.yml --env-file apps/research-gateway/.env down

## Trigger a fresh RollHook deploy by pushing an empty commit to research-gateway's master.
## RollHook detects the push, rebuilds the image at the new SHA, and rolling-
## restarts the container. Use this instead of `make research-gateway-up` when you want
## new code (or when you just want compose.yml changes safely applied via a fresh build).
research-gateway-redeploy: require-dev
	@if [ ! -d $$HOME/SourceRoot/research-gateway ]; then echo "  ✗ research-gateway repo not found at ~/SourceRoot/research-gateway"; exit 1; fi
	@cd $$HOME/SourceRoot/research-gateway && \
	  git commit --allow-empty -m "chore: redeploy (triggered via vps make research-gateway-redeploy)" && \
	  git push && \
	  echo "  ✓ pushed — watch the build at https://github.com/jkrumm/research-gateway/actions"
## One-shot bootstrap — clone research-gateway repo, build image, push :initial to
## rollhook.jkrumm.com so RollHook has a running container to authorize OIDC
## deploys against. Re-runnable.
research-gateway-bootstrap-image: require-prod
	$(OP_RUN) ./apps/research-gateway/scripts/bootstrap-image.sh
## Materialize apps/research-gateway/.env from .env.tpl. Required so RollHook's
## `docker compose up --scale` can resolve ${VAR} interpolations. Re-run after
## rotating any research-gateway secret. Resulting .env is chmod 644 and gitignored.
research-gateway-env: require-prod
	op --account tkrumm inject -i apps/research-gateway/.env.tpl -o apps/research-gateway/.env -f
	chmod 644 apps/research-gateway/.env
	@echo "Wrote apps/research-gateway/.env (chmod 644, gitignored)"

## image-gen-gateway stack (Bun image API, RollHook-managed) — apps/image-gen-gateway/compose.yml
## Deploys to image.jkrumm.com (Tailscale-only, grey-cloud A record — NOT the cloudflared
## tunnel). RollHook deploys on push to jkrumm/image-gen:master touching gateway/** or shared/**.
##
## Same image-pinning dance as research-gateway-up above, for the same reason: RollHook
## tags by git SHA and never moves :latest, so a naive `up -d` would roll the container
## back to a stale :latest.
image-gen-gateway-up: require-prod
	@IMG=$$(docker inspect --format '{{.Config.Image}}' $$(docker ps --filter 'label=com.docker.compose.service=image-gen-gateway' --format '{{.Names}}' | head -1) 2>/dev/null || echo ""); \
	if [ -z "$$IMG" ]; then \
	  echo "  no running container — genesis start from :latest (bootstrap-seeded)"; \
	  $(OP_RUN) docker compose -f apps/image-gen-gateway/compose.yml --env-file apps/image-gen-gateway/.env up -d; \
	else \
	  echo "  pinning image-gen-gateway → $$IMG"; \
	  $(OP_RUN) env IMAGE_GEN_GATEWAY_IMAGE=$$IMG docker compose -f apps/image-gen-gateway/compose.yml --env-file apps/image-gen-gateway/.env up -d; \
	fi
image-gen-gateway-down: require-prod ; $(OP_RUN) docker compose -f apps/image-gen-gateway/compose.yml --env-file apps/image-gen-gateway/.env down

## Trigger a fresh RollHook deploy of image-gen-gateway via workflow_dispatch.
## NOT the empty-commit trick the other -redeploy targets use: image-gen's deploy.yml is
## path-filtered (gateway/**, shared/**, the workflow itself), so an empty commit touches
## none of those paths and would silently do nothing.
image-gen-gateway-redeploy: require-dev
	@if [ ! -d $$HOME/SourceRoot/image-gen ]; then echo "  ✗ image-gen repo not found at ~/SourceRoot/image-gen"; exit 1; fi
	@gh workflow run deploy.yml --repo jkrumm/image-gen --ref master && \
	  echo "  ✓ dispatched — watch the build at https://github.com/jkrumm/image-gen/actions"
## One-shot bootstrap — clone image-gen repo, build image, push :initial to
## rollhook.jkrumm.com so RollHook has a running container to authorize OIDC
## deploys against. Re-runnable. Builds from the REPO ROOT (bun monorepo).
image-gen-gateway-bootstrap-image: require-prod
	$(OP_RUN) ./apps/image-gen-gateway/scripts/bootstrap-image.sh
## Materialize apps/image-gen-gateway/.env from .env.tpl. Required so RollHook's
## `docker compose up --scale` can resolve ${VAR} interpolations. Re-run after
## rotating any image-gen-gateway secret. Resulting .env is chmod 644 and gitignored.
image-gen-gateway-env: require-prod
	op --account tkrumm inject -i apps/image-gen-gateway/.env.tpl -o apps/image-gen-gateway/.env -f
	chmod 644 apps/image-gen-gateway/.env
	@echo "Wrote apps/image-gen-gateway/.env (chmod 644, gitignored)"

## modelpick stack (Bun + TanStack Start SSR, RollHook-managed) — apps/modelpick/compose.yml
## Deploys to modelpick.jkrumm.com. RollHook deploys on push to jkrumm/modelpick:master.
modelpick-up:   require-prod ; $(OP_RUN) docker compose -f apps/modelpick/compose.yml up -d
modelpick-down: require-prod ; $(OP_RUN) docker compose -f apps/modelpick/compose.yml down
## Materialize apps/modelpick/.env from .env.tpl (via `op inject`). Required so
## RollHook's `docker compose up --scale` — which doesn't go through `op run` —
## can resolve ${VAR} interpolations in apps/modelpick/compose.yml. Re-run after
## rotating any modelpick secret. Resulting .env is chmod 644 and gitignored.
modelpick-env: require-prod
	op --account tkrumm inject -i apps/modelpick/.env.tpl -o apps/modelpick/.env -f
	chmod 644 apps/modelpick/.env
	@echo "Wrote apps/modelpick/.env (chmod 644, gitignored)"
## Apply Drizzle migrations inside the running container.
modelpick-migrate: require-prod
	@CONTAINER=$$(docker ps --filter 'label=com.docker.compose.service=modelpick' --format '{{.Names}}' | head -1); \
	[ -n "$$CONTAINER" ] || { echo "  ✗ modelpick not running"; exit 1; }; \
	docker exec "$$CONTAINER" bun run scripts/migrate.ts
## Seed the model catalog (idempotent — safe to re-run).
modelpick-seed: require-prod
	@CONTAINER=$$(docker ps --filter 'label=com.docker.compose.service=modelpick' --format '{{.Names}}' | head -1); \
	[ -n "$$CONTAINER" ] || { echo "  ✗ modelpick not running"; exit 1; }; \
	docker exec "$$CONTAINER" bun run scripts/seed-run.ts
## Manually trigger the daily data refresh (probe → collect → recommend → news).
## In prod this runs via cron — see the deploy README for the cron entry.
modelpick-refresh: require-prod
	@CONTAINER=$$(docker ps --filter 'label=com.docker.compose.service=modelpick' --format '{{.Names}}' | head -1); \
	[ -n "$$CONTAINER" ] || { echo "  ✗ modelpick not running"; exit 1; }; \
	docker exec "$$CONTAINER" bun run scripts/refresh.ts

## audio-gateway stack (Bun audio service, RollHook-managed) — apps/audio-gateway/compose.yml
## Tailscale-only via DNS-only A record audio-gateway.jkrumm.com → ${VPS_TAILSCALE_IP}.
## RollHook deploys on push to jkrumm/audio-gateway:master.
audio-gateway-up:   require-prod ; $(OP_RUN) docker compose -f apps/audio-gateway/compose.yml up -d
audio-gateway-down: require-prod ; $(OP_RUN) docker compose -f apps/audio-gateway/compose.yml down
## Materialize apps/audio-gateway/.env from .env.tpl (via `op inject`). Required so
## RollHook's `docker compose up --scale` — which doesn't go through `op run` —
## can resolve ${VAR} interpolations in apps/audio-gateway/compose.yml. Re-run after
## rotating any audio-gateway secret. Resulting .env is chmod 644 and gitignored.
audio-gateway-env: require-prod
	op --account tkrumm inject -i apps/audio-gateway/.env.tpl -o apps/audio-gateway/.env -f
	chmod 644 apps/audio-gateway/.env
	@echo "Wrote apps/audio-gateway/.env (chmod 644, gitignored)"
## One-shot bootstrap — clone audio-gateway repo, build, and push :initial to
## rollhook.jkrumm.com so RollHook has a running container to authorize OIDC
## deploys against. Re-runnable.
audio-gateway-bootstrap-image: require-prod
	$(OP_RUN) ./apps/audio-gateway/scripts/bootstrap-image.sh

## photo-gallery stack — static Astro gallery served by nginx from a host volume.
## Content lives at /home/jkrumm/photo-gallery-dist on the VPS; photo-flow CLI on the
## developer laptop rsyncs the built dist/ there. No registry, no RollHook — the
## container only serves files. First bring-up requires content already in place
## (at minimum index.html) so the healthcheck can pass.
photo-gallery-up:   require-prod ; $(OP_RUN) docker compose -f apps/photo-gallery/compose.yml up -d
photo-gallery-down: require-prod ; $(OP_RUN) docker compose -f apps/photo-gallery/compose.yml down

## imgproxy stack — image CDN at img.DOMAIN, sourcing a private B2 bucket.
## Stateless: no volumes, no DB. Cloudflare's edge cache is the CDN layer.
## Requires op://vps/imgproxy/* (read-only, bucket-scoped B2 key) to exist first.
imgproxy-up:   require-prod ; $(OP_RUN) docker compose -f apps/imgproxy/compose.yml up -d
imgproxy-down: require-prod ; $(OP_RUN) docker compose -f apps/imgproxy/compose.yml down

## basalt-ui-marketing stack (static Astro docs site, RollHook-managed) — apps/basalt-ui-marketing/compose.yml
## Stateless, no DB, no .env — the image bakes the built site; RollHook injects IMAGE_TAG.
## RollHook deploys on pushes to jkrumm/basalt-ui:master touching apps/marketing/**.
basalt-ui-marketing-up:   require-prod ; $(OP_RUN) docker compose -f apps/basalt-ui-marketing/compose.yml up -d
basalt-ui-marketing-down: require-prod ; $(OP_RUN) docker compose -f apps/basalt-ui-marketing/compose.yml down
## One-shot bootstrap — clone basalt-ui, build apps/marketing, and push :initial to
## rollhook.jkrumm.com so RollHook has a running container to authorize OIDC
## deploys against. Re-runnable.
basalt-ui-marketing-bootstrap-image: require-prod
	$(OP_RUN) ./apps/basalt-ui-marketing/scripts/bootstrap-image.sh

## Postgres schema/user provisioning — idempotent, works for both envs
postgres-setup:
	$(OP_RUN) ./scripts/setup-postgres.sh

## Materialize /etc/vps/*.env for cron jobs from cron/*.env.tpl (via op inject).
## Re-run after rotating a referenced secret.
cron-env-seed: require-prod
	./scripts/seed-cron-env.sh

## Status — docker ps with name/status/ports
ps:
	docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

## Manual Postgres → S3 backup (cron 03:00 in prod; manual via this target).
backup: require-prod
	$(OP_RUN) ./scripts/backup-pg.sh
# NOTE: restoring PROD Postgres from S3 has NO make target by design — it overwrites
# production. It is a gated, human-only DR tool: scripts/restore-pg.sh
# (see docs/disaster-recovery.md).
## Dev — pull latest (or BACKUP_FILE=...) S3 pg backup → local. Validates DR chain. Drops whole local DB.
restore-local: require-dev
	$(OP_RUN) ./scripts/restore-pg-local.sh
## Dev — fresh whole-DB sync from prod Postgres over SSH (no S3). Drops whole local DB.
sync-from-prod: require-dev
	$(OP_RUN) ./scripts/sync-pg-from-vps.sh
## Dev — per-schema sync from prod (SCHEMA=argo). Least-priv, leaves other schemas intact.
pg-sync-schema: require-dev
	SCHEMA="$(SCHEMA)" $(OP_RUN) ./scripts/sync-pg-schema-from-vps.sh

## UFW status + rules — prod-only (the dev box has its own firewall).
firewall: require-prod
	./scripts/firewall.sh

## Interactive psql shell — works in both envs.
shell-postgres:
	$(OP_RUN) docker exec -it postgres psql -U $${POSTGRES_USER} -d $${POSTGRES_DB}

## Exact per-table row counts (Postgres all schemas + MariaDB fpp). Read-only,
## both envs, diff-friendly — use to verify two DB states match after sync/restore.
db-counts:
	./scripts/db-counts.sh

## Reclaim disk: stopped containers, unused images, build cache. Both envs. Never touches volumes.
prune:
	@echo "→ Pruning stopped containers..."
	@docker container prune -f
	@echo ""
	@echo "→ Pruning unused images (tagged + dangling)..."
	@docker image prune -af
	@echo ""
	@echo "→ Pruning build cache..."
	@docker builder prune -af
	@echo ""
	@echo "✓ Done. Volumes left intact — run 'docker volume prune' manually if you really mean it."

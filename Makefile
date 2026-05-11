-include .env
export

ENV ?= dev

OP_RUN = op run --env-file=.env.tpl --

.DEFAULT_GOAL := help

.PHONY: help require-prod require-dev \
        up down networking-up networking-down infra-up infra-down monitoring-up monitoring-down \
        fpp-up fpp-down fpp-mariadb-setup fpp-cert-sync fpp-bootstrap-images fpp-env \
        fpp-backup fpp-restore fpp-shell fpp-restore-local fpp-sync-from-prod \
        bun-email-api-up bun-email-api-down bun-email-api-env bun-email-api-bootstrap-image \
        argo-up argo-down argo-env argo-bootstrap-image \
        postgres-setup ps backup firewall shell-postgres prune

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
	op inject -i apps/fpp/.env.tpl -o apps/fpp/.env -f
	chmod 644 apps/fpp/.env
	@echo "Wrote apps/fpp/.env (chmod 644, gitignored)"
	@echo "Note: 644 is required because the RollHook container runs as a"
	@echo "non-root user whose uid doesn't match the host's jkrumm uid."
	@echo "VPS has no other shell users so the local-readability risk is bounded."
## FPP MariaDB → S3 backup (cron 03:30 in prod; manual via this target).
fpp-backup: require-prod
	$(OP_RUN) ./apps/fpp/scripts/backup-mariadb.sh
## Interactive restore of FPP MariaDB from S3 — drops DB first, confirms before proceeding.
fpp-restore: require-prod
	$(OP_RUN) ./apps/fpp/scripts/restore-mariadb.sh
## Dev — pull latest (or BACKUP_FILE=...) S3 backup → local mariadb. Validates DR chain.
fpp-restore-local: require-dev
	$(OP_RUN) ./apps/fpp/scripts/restore-mariadb-local.sh
## Dev — fresh sync from prod mariadb over SSH (no S3). Re-runnable.
fpp-sync-from-prod: require-dev
	$(OP_RUN) ./apps/fpp/scripts/sync-mariadb-from-vps.sh
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
	op inject -i apps/bun-email-api/.env.tpl -o apps/bun-email-api/.env -f
	chmod 644 apps/bun-email-api/.env
	@echo "Wrote apps/bun-email-api/.env (chmod 644, gitignored)"

## argo stack (api + dashboard, RollHook-managed) — apps/argo/compose.yml
## Tailscale-only via DNS-only A record argo.jkrumm.com → ${VPS_TAILSCALE_IP}.
## RollHook deploys on push to jkrumm/argo:master.
argo-up:   require-prod ; $(OP_RUN) docker compose -f apps/argo/compose.yml --env-file apps/argo/.env up -d
argo-down: require-prod ; $(OP_RUN) docker compose -f apps/argo/compose.yml --env-file apps/argo/.env down
## One-shot bootstrap — clone argo repo, build both images, push :initial to
## rollhook.jkrumm.com so RollHook has running containers to authorize OIDC
## deploys against. Re-runnable.
argo-bootstrap-image: require-prod
	$(OP_RUN) ./apps/argo/scripts/bootstrap-image.sh
## Materialize apps/argo/.env from .env.tpl. Required so RollHook's
## `docker compose up --scale` can resolve ${VAR} interpolations. Re-run after
## rotating any argo secret. Resulting .env is chmod 644 and gitignored.
argo-env: require-prod
	op inject -i apps/argo/.env.tpl -o apps/argo/.env -f
	chmod 644 apps/argo/.env
	@echo "Wrote apps/argo/.env (chmod 644, gitignored)"

## Postgres schema/user provisioning — idempotent, works for both envs
postgres-setup:
	$(OP_RUN) ./scripts/setup-postgres.sh

## Status — docker ps with name/status/ports
ps:
	docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

## Manual Postgres → S3 backup (cron 03:00 in prod; manual via this target).
backup: require-prod
	$(OP_RUN) ./scripts/backup-pg.sh

## UFW status + rules — prod-only (the dev box has its own firewall).
firewall: require-prod
	./scripts/firewall.sh

## Interactive psql shell — works in both envs.
shell-postgres:
	$(OP_RUN) docker exec -it postgres psql -U $${POSTGRES_USER} -d $${POSTGRES_DB}

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

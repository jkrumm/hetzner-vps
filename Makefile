-include .env
export

ENV ?= dev

OP_RUN = op run --env-file=.env.tpl --

.PHONY: up down networking-up networking-down infra-up infra-down monitoring-up monitoring-down \
        fpp-up fpp-down fpp-mariadb-setup fpp-cert-sync fpp-backup fpp-restore fpp-shell \
        fpp-restore-local fpp-sync-from-prod \
        bun-email-api-up bun-email-api-down bun-email-api-env bun-email-api-bootstrap-image \
        argo-up argo-down argo-env argo-bootstrap-image \
        postgres-setup ps backup firewall shell-postgres

## All stacks — adapts to ENV (dev: compose.dev.yml, prod: ordered stack sequence)
up:
ifeq ($(ENV),prod)
	$(MAKE) networking-up
	$(MAKE) infra-up
	$(MAKE) monitoring-up
	$(MAKE) fpp-up
	$(MAKE) bun-email-api-up
else
	$(OP_RUN) docker compose -f compose.dev.yml up -d
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
networking-up:   ; $(OP_RUN) docker compose -f compose.networking.yml up -d
networking-down: ; $(OP_RUN) docker compose -f compose.networking.yml down
infra-up:        ; $(OP_RUN) docker compose -f compose.infra.yml up -d
infra-down:      ; $(OP_RUN) docker compose -f compose.infra.yml down
monitoring-up:   ; $(OP_RUN) docker compose -f compose.monitoring.yml up -d
monitoring-down: ; $(OP_RUN) docker compose -f compose.monitoring.yml down

## FPP stack (MariaDB now; fpp-server + fpp-analytics later) — apps/fpp/compose.yml
## On a fresh server: networking-up first, then fpp-cert-sync, then fpp-up.
fpp-up:          ; $(OP_RUN) docker compose -f apps/fpp/compose.yml up -d
fpp-down:        ; $(OP_RUN) docker compose -f apps/fpp/compose.yml down
fpp-mariadb-setup:
	$(OP_RUN) ./apps/fpp/scripts/setup-mariadb.sh
fpp-cert-sync:
	$(OP_RUN) ./apps/fpp/scripts/cert-sync.sh
## One-shot bootstrap — pushes :initial fpp-server/fpp-analytics images to rollhook.jkrumm.com
## so RollHook has running containers to authorize OIDC deploys against. Re-runnable.
fpp-bootstrap-images:
	$(OP_RUN) ./apps/fpp/scripts/bootstrap-images.sh
## Materialize apps/fpp/.env from apps/fpp/.env.tpl (via `op inject`). Required so
## RollHook's `docker compose up --scale` — which doesn't go through `op run` —
## can resolve ${VAR} interpolations in apps/fpp/compose.yml. Re-run after secret
## rotation. The resulting .env is chmod 600, gitignored, and stays on VPS.
fpp-env:
	op inject -i apps/fpp/.env.tpl -o apps/fpp/.env -f
	chmod 644 apps/fpp/.env
	@echo "Wrote apps/fpp/.env (chmod 644, gitignored)"
	@echo "Note: 644 is required because the RollHook container runs as a"
	@echo "non-root user whose uid doesn't match the host's jkrumm uid."
	@echo "VPS has no other shell users so the local-readability risk is bounded."
fpp-backup:
	@[ "$(ENV)" = "prod" ] || { echo "ERROR: backup requires ENV=prod"; exit 1; }
	$(OP_RUN) ./apps/fpp/scripts/backup-mariadb.sh
fpp-restore:
	@[ "$(ENV)" = "prod" ] || { echo "ERROR: restore requires ENV=prod"; exit 1; }
	$(OP_RUN) ./apps/fpp/scripts/restore-mariadb.sh
## Dev — pull latest (or BACKUP_FILE=...) S3 backup → local mariadb. Validates DR chain.
fpp-restore-local:
	@[ "$(ENV)" = "dev" ] || { echo "ERROR: fpp-restore-local requires ENV=dev"; exit 1; }
	$(OP_RUN) ./apps/fpp/scripts/restore-mariadb-local.sh
## Dev — fresh sync from prod mariadb over SSH (no S3). Re-runnable.
fpp-sync-from-prod:
	@[ "$(ENV)" = "dev" ] || { echo "ERROR: fpp-sync-from-prod requires ENV=dev"; exit 1; }
	$(OP_RUN) ./apps/fpp/scripts/sync-mariadb-from-vps.sh
fpp-shell:
	$(OP_RUN) sh -c 'docker exec -it -e MYSQL_PWD="$$MARIADB_ROOT_PASSWORD" mariadb mariadb -u root "$$MARIADB_DB"'

## bun-email-api stack (Bun + Resend, RollHook-managed) — apps/bun-email-api/compose.yml
## Stateless, no DB. RollHook deploys on push to jkrumm/bun-email-api:master.
bun-email-api-up:    ; $(OP_RUN) docker compose -f apps/bun-email-api/compose.yml up -d
bun-email-api-down:  ; $(OP_RUN) docker compose -f apps/bun-email-api/compose.yml down
## One-shot bootstrap — clone bun-email-api repo, build, and push :initial to
## rollhook.jkrumm.com so RollHook has a running container to authorize OIDC
## deploys against. Re-runnable.
bun-email-api-bootstrap-image:
	$(OP_RUN) ./apps/bun-email-api/scripts/bootstrap-image.sh
## Materialize apps/bun-email-api/.env from .env.tpl (via `op inject`). Required so
## RollHook's `docker compose up --scale` — which doesn't go through `op run` —
## can resolve ${VAR} interpolations in apps/bun-email-api/compose.yml. Re-run
## after rotating BEA secrets. Resulting .env is chmod 644 and gitignored.
bun-email-api-env:
	op inject -i apps/bun-email-api/.env.tpl -o apps/bun-email-api/.env -f
	chmod 644 apps/bun-email-api/.env
	@echo "Wrote apps/bun-email-api/.env (chmod 644, gitignored)"

## argo stack (api + dashboard, RollHook-managed) — apps/argo/compose.yml
## Tailscale-only via DNS-only A record argo.jkrumm.com → ${VPS_TAILSCALE_IP}.
## RollHook deploys on push to jkrumm/argo:master.
argo-up:    ; $(OP_RUN) docker compose -f apps/argo/compose.yml --env-file apps/argo/.env up -d
argo-down:  ; $(OP_RUN) docker compose -f apps/argo/compose.yml --env-file apps/argo/.env down
## One-shot bootstrap — clone argo repo, build both images, push :initial to
## rollhook.jkrumm.com so RollHook has running containers to authorize OIDC
## deploys against. Re-runnable.
argo-bootstrap-image:
	$(OP_RUN) ./apps/argo/scripts/bootstrap-image.sh
## Materialize apps/argo/.env from .env.tpl. Required so RollHook's
## `docker compose up --scale` can resolve ${VAR} interpolations. Re-run after
## rotating any argo secret. Resulting .env is chmod 644 and gitignored.
argo-env:
	op inject -i apps/argo/.env.tpl -o apps/argo/.env -f
	chmod 644 apps/argo/.env
	@echo "Wrote apps/argo/.env (chmod 644, gitignored)"

## Postgres schema/user provisioning — idempotent, works for both envs
postgres-setup:
	$(OP_RUN) ./scripts/setup-postgres.sh

## Status / ops
ps:
	docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

## Prod-only — guarded against accidental dev runs
backup:
	@[ "$(ENV)" = "prod" ] || { echo "ERROR: backup requires ENV=prod"; exit 1; }
	$(OP_RUN) ./scripts/backup-pg.sh

firewall:
	./scripts/firewall.sh

shell-postgres:
	$(OP_RUN) docker exec -it postgres psql -U $${POSTGRES_USER} -d $${POSTGRES_DB}

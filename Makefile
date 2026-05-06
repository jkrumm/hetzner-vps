-include .env
export

ENV ?= dev

OP_RUN = op run --env-file=.env.tpl --

.PHONY: up down networking-up networking-down infra-up infra-down monitoring-up monitoring-down \
        fpp-up fpp-down fpp-mariadb-setup fpp-cert-sync fpp-backup fpp-restore fpp-shell \
        postgres-setup ps backup firewall shell-postgres

## All stacks — adapts to ENV (dev: compose.dev.yml, prod: ordered stack sequence)
up:
ifeq ($(ENV),prod)
	$(MAKE) networking-up
	$(MAKE) infra-up
	$(MAKE) monitoring-up
	$(MAKE) fpp-up
else
	$(OP_RUN) docker compose -f compose.dev.yml up -d
endif

down:
ifeq ($(ENV),prod)
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
fpp-shell:
	$(OP_RUN) sh -c 'docker exec -it -e MYSQL_PWD="$$MARIADB_ROOT_PASSWORD" mariadb mariadb -u root "$$MARIADB_DB"'

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

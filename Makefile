-include .env
export

ENV ?= dev

ifeq ($(ENV),prod)
DOPPLER_RUN = doppler run --
else
DOPPLER_RUN = doppler run -p vps -c dev --
endif

.PHONY: up down networking-up networking-down infra-up infra-down monitoring-up monitoring-down \
        postgres-setup ps backup firewall shell-postgres

## All stacks — adapts to ENV (dev: compose.dev.yml, prod: ordered stack sequence)
up:
ifeq ($(ENV),prod)
	$(MAKE) networking-up
	$(MAKE) infra-up
	$(MAKE) monitoring-up
else
	$(DOPPLER_RUN) docker compose -f compose.dev.yml up -d
endif

down:
ifeq ($(ENV),prod)
	$(MAKE) monitoring-down
	$(MAKE) infra-down
	$(MAKE) networking-down
else
	$(DOPPLER_RUN) docker compose -f compose.dev.yml down
endif

## Individual prod stacks — targeted restarts
networking-up:   ; doppler run -- docker compose -f compose.networking.yml up -d
networking-down: ; doppler run -- docker compose -f compose.networking.yml down
infra-up:        ; doppler run -- docker compose -f compose.infra.yml up -d
infra-down:      ; doppler run -- docker compose -f compose.infra.yml down
monitoring-up:   ; doppler run -- docker compose -f compose.monitoring.yml up -d
monitoring-down: ; doppler run -- docker compose -f compose.monitoring.yml down

## Postgres schema/user provisioning — idempotent, works for both envs
postgres-setup:
	$(DOPPLER_RUN) ./scripts/setup-postgres.sh

## Status / ops
ps:
	docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

## Prod-only — guarded against accidental dev runs
backup:
	@[ "$(ENV)" = "prod" ] || { echo "ERROR: backup requires ENV=prod"; exit 1; }
	doppler run -- ./scripts/backup-pg.sh

firewall:
	./scripts/firewall.sh

shell-postgres:
	$(DOPPLER_RUN) docker exec -it postgres psql -U $${POSTGRES_USER} -d $${POSTGRES_DB}

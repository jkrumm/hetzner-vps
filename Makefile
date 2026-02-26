.PHONY: up down networking-up networking-down infra-up infra-down monitoring-up monitoring-down \
        ps backup firewall shell-postgres dev-up dev-down

COMPOSE_NET   = doppler run -- docker compose -f compose.networking.yml
COMPOSE_INFRA = doppler run -- docker compose -f compose.infra.yml
COMPOSE_MON   = doppler run -- docker compose -f compose.monitoring.yml
COMPOSE_DEV   = docker compose -f compose.dev.yml

## All stacks — bring up in dependency order
up:
	$(MAKE) networking-up
	$(MAKE) infra-up
	$(MAKE) monitoring-up

## All stacks — tear down in reverse order
down:
	$(MAKE) monitoring-down
	$(MAKE) infra-down
	$(MAKE) networking-down

## Individual stacks — for targeted restarts
networking-up:   ; $(COMPOSE_NET) up -d
networking-down: ; $(COMPOSE_NET) down
infra-up:        ; $(COMPOSE_INFRA) up -d
infra-down:      ; $(COMPOSE_INFRA) down
monitoring-up:   ; $(COMPOSE_MON) up -d
monitoring-down: ; $(COMPOSE_MON) down

## Status / ops
ps:
	docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

backup:
	./scripts/backup-pg.sh

firewall:
	./scripts/firewall.sh

shell-postgres:
	docker exec -it postgres psql -U $${POSTGRES_USER} -d $${POSTGRES_DB}

## Local dev (Postgres + Valkey, ports exposed, no Doppler)
dev-up:   ; $(COMPOSE_DEV) up -d
dev-down: ; $(COMPOSE_DEV) down

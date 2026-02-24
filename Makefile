.PHONY: up down monitoring-up monitoring-down logs ps backup firewall shell-postgres

COMPOSE       = doppler run -- docker compose
COMPOSE_MON   = doppler run -- docker compose -f compose.monitoring.yml

## Core infra
up:
	$(COMPOSE) up -d

down:
	$(COMPOSE) down

## Monitoring stack
monitoring-up:
	$(COMPOSE_MON) up -d

monitoring-down:
	$(COMPOSE_MON) down

## Logs (follow all running stacks)
logs:
	$(COMPOSE) logs -f

logs-monitoring:
	$(COMPOSE_MON) logs -f

## Status
ps:
	docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

## Backup (manual trigger)
backup:
	./scripts/backup-pg.sh

## Hetzner Cloud Firewall (IaC)
firewall:
	./scripts/firewall.sh

## Postgres shell
shell-postgres:
	docker exec -it postgres psql -U $${POSTGRES_USER} -d $${POSTGRES_DB}

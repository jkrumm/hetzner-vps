.PHONY: networking-up networking-down infra-up infra-down monitoring-up monitoring-down \
        logs-networking logs-infra logs-monitoring ps backup firewall shell-postgres

COMPOSE_NET   = doppler run -- docker compose -f compose.networking.yml
COMPOSE_INFRA = doppler run -- docker compose -f compose.infra.yml
COMPOSE_MON   = doppler run -- docker compose -f compose.monitoring.yml

## Networking stack (cloudflared, Traefik, socket-proxy)
networking-up:
	$(COMPOSE_NET) up -d

networking-down:
	$(COMPOSE_NET) down

## Infra stack (Postgres, Valkey)
infra-up:
	$(COMPOSE_INFRA) up -d

infra-down:
	$(COMPOSE_INFRA) down

## Monitoring stack (OTel, Beszel, Dozzle, Watchtower)
monitoring-up:
	$(COMPOSE_MON) up -d

monitoring-down:
	$(COMPOSE_MON) down

## Logs (per stack)
logs-networking:
	$(COMPOSE_NET) logs -f

logs-infra:
	$(COMPOSE_INFRA) logs -f

logs-monitoring:
	$(COMPOSE_MON) logs -f

## Status (all containers)
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

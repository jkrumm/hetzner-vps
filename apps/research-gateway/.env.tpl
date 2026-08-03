# Production secrets template for the VPS.
# Materialized into a real (gitignored) `.env` on the VPS via `op inject` — see DEPLOY.md.
# Place this file in the vps repo at apps/research-gateway/.env.tpl and re-run the env target
# after rotating any secret. These secret refs are INFERRED — confirm with /secrets.

DOMAIN=op://vps/config/DOMAIN

# Gateway's own bearer
API_SECRET=op://vps/research-gateway/API_SECRET

# IU unified endpoint
IU_BASE_URL=op://common/anthropic/OPENAI_BASE_URL
IU_API_KEY=op://common/anthropic/API_KEY
# Model choice is NOT configured here. The lead and worker models come from the defaults
# in the app's src/env.ts, which carry the rationale for the current choice. An IU_MODEL
# var used to sit here pinned to DeepSeek-V4-Pro; nothing ever read it, so it silently
# misdescribed the running config. Setting a model here would override the code default —
# do that only to pin a deliberate exception, and say why.

# Tavily
TAVILY_API_KEY=op://common/tavily/API_KEY

# Context7 (optional)
CONTEXT7_API_KEY=op://vps/research-gateway/CONTEXT7_API_KEY

# GitHub (githubFile / githubRepo / findPackages source-of-truth tools). They work
# unauthenticated, but anonymous GitHub is 60 req/h PER IP shared by every worker of every
# concurrent job; a fine-grained PAT with NO permissions (public read only) raises it to
# 5000/h. The 1Password field may be left EMPTY — the gateway treats empty as unset and
# falls back to anonymous — but the field must EXIST or `op inject` fails on a missing ref.
GITHUB_TOKEN=op://vps/research-gateway/GITHUB_TOKEN

# Telemetry → argo
# internal docker route — argo is Tailscale-only (grey-cloud); the container posts to argo-api directly, not the public host
ARGO_USAGE_URL=http://argo-api:4000/usage/records
ARGO_API_SECRET=op://common/api/SECRET

RESEARCH_MAX_CONCURRENCY=3

# modelpick .env.tpl — 1Password references resolved by `op inject`.
# Run `make modelpick-env` to materialize → apps/modelpick/.env (gitignored).
# Re-run after rotating any secret.

DOMAIN=op://vps/config/DOMAIN
POSTGRES_DB=op://vps/config/POSTGRES_DB
MODELPICK_DB_PASSWORD=op://vps/modelpick/DB_PASSWORD

# IU unified endpoint — shared with sideclaw, hermes, argo
IU_API_KEY=op://common/anthropic/IU_API_KEY
IU_BASE_URL=op://common/anthropic/IU_BASE_URL
IU_OPENAI_BASE_URL=op://common/anthropic/IU_OPENAI_BASE_URL

# External leaderboard APIs
OPENROUTER_API_KEY=op://vps/modelpick/OPENROUTER_API_KEY
ARTIFICIALANALYSIS_API_KEY=op://vps/modelpick/ARTIFICIALANALYSIS_API_KEY

# Admin gate
MODELPICK_ADMIN_KEY=op://vps/modelpick/ADMIN_KEY

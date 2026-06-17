# audio-gateway .env.tpl — 1Password references resolved by `op inject`.
# Run `make audio-gateway-env` to materialize → apps/audio-gateway/.env (gitignored).
# Re-run after rotating any secret.
IU_API_KEY=op://common/anthropic/API_KEY
IU_OPENAI_BASE_URL=op://common/anthropic/OPENAI_BASE_URL
IU_GEMINI_BASE_URL=op://common/anthropic/GEMINI_BASE_URL
DOMAIN=op://vps/config/DOMAIN
USAGE_DB=/data/usage.db
STT_PROMPT=Die Aufnahme ist auf Deutsch oder Englisch.

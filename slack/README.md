# Slack app identity

App ID: `A0BV9MG54TD` (created 2026-09-07 via `apps.manifest.create`; use it for `apps.manifest.update`).

`app-manifest.json` declares this stack's own Slack bot, so messages it posts
are attributable at a glance (HomeLab, Hermes, VPS and Argo are four apps, not
four usernames on one bot).

Create or update it with an **app configuration token** — a human-only,
12-hour credential minted at https://api.slack.com/apps → *Your App
Configuration Tokens*. Never store it; paste it into one command:

```bash
# create
curl -s -X POST https://slack.com/api/apps.manifest.create \
  -H "Authorization: Bearer <xoxe-config-token>" -H 'content-type: application/json' \
  -d "$(jq -n --slurpfile m app-manifest.json '{manifest: $m[0]}')" | jq '{ok, app_id, error}'
# update (after editing the manifest)
curl -s -X POST https://slack.com/api/apps.manifest.update \
  -H "Authorization: Bearer <xoxe-config-token>" -H 'content-type: application/json' \
  -d "$(jq -n --arg id <APP_ID> --slurpfile m app-manifest.json '{app_id: $id, manifest: $m[0]}')" | jq '{ok, error}'
```

Then install it to the workspace once in the UI (*OAuth & Permissions → Install*)
and store the Bot User OAuth Token in 1Password; the repo reads it through its
`.env.tpl` ref. Re-install after every scope change — the token keeps its value
but only gains scopes on install.

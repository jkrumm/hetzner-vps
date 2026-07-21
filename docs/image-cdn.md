# Image CDN — imgproxy + Backblaze B2 + Cloudflare

Phase 1 of the image serving substrate. A private B2 bucket holds originals;
imgproxy on the VPS renders resized/reformatted derivatives on demand;
Cloudflare's edge caches those derivatives. Consumers: the static photo-gallery
site, blog/articles, the Obsidian vault, and agents.

The later self-built photo service (shutterflow.app) is a separate project that
will consume this same substrate — nothing here is specific to it.

```
client → Cloudflare edge (cache) → tunnel → Traefik → imgproxy → B2 (private)
```

---

## Access model

URLs are **unsigned**. imgproxy runs without `IMGPROXY_KEY`/`IMGPROXY_SALT`,
which puts it in unsigned mode and makes the `/insecure` prefix mandatory:

```
https://img.<domain>/insecure/rs:fit:800/plain/s3://<bucket>/fuji/foo.jpg@webp
```

Anyone who knows an object key can render it. That is intended for phase 1, and
the security properties come from elsewhere:

| Control | What it prevents |
|-|-|
| `IMGPROXY_ALLOWED_SOURCES=s3://<bucket>/` | imgproxy being used as an open proxy for arbitrary URLs |
| `IMGPROXY_S3_ALLOWED_BUCKETS=<bucket>` | reaching any other bucket in the same B2 account (enforced in the S3 client, independent of the prefix match) |
| Bucket-scoped read-only B2 key | imgproxy writing or deleting anything, ever |
| `IMGPROXY_ALLOW_PRIVATE_SOURCE_ADDRESSES=false` | SSRF into the internal Docker/Tailscale networks |
| Non-enumerable object keys | discovery of anything not meant to be public |

The bucket itself stays **private** — B2 never serves it directly, only imgproxy
reads from it.

**Upgrading to signed URLs later:** set `IMGPROXY_KEY` and `IMGPROXY_SALT`. The
`/insecure` prefix immediately stops being accepted, so every consumer must be
migrated to generating HMAC signatures in the same change.

---

## Prefix layout (convention, not enforced)

Nothing in the config restricts prefixes — this is a documented convention so
the bucket stays navigable.

| Prefix | Contents | Naming |
|-|-|-|
| `fuji/` | curated camera exports | readable paths OK (`fuji/2026-portugal/DSCF1234.jpg`) |
| `blog/` | article images | readable paths OK |
| `gen/` | generated / AI / ad-hoc | non-guessable (hash or nanoid) |
| `misc/` | everything else | non-guessable |

Readable paths are only appropriate where the content is meant to be
discoverable anyway. Anything sensitive goes under a non-guessable name,
because unsigned URLs mean the key *is* the access control.

---

## Cloudflare caching — and the `Vary` caveat

`IMGPROXY_TTL=31536000` emits `Cache-Control: max-age=31536000`, which
Cloudflare's default static caching honours. Derivative URLs are immutable (the
processing options are in the path), so a year is correct.

**The caveat:** imgproxy sets `Vary: Accept` when `IMGPROXY_AUTO_WEBP` /
`IMGPROXY_AUTO_AVIF` are on, but **Cloudflare ignores `Vary` on non-Enterprise
plans for everything except `Accept-Encoding`**. So the first client to request a
given URL determines the cached format for every subsequent client. If an
AVIF-capable browser warms the cache, an AVIF response is what an
AVIF-incapable client gets too.

In practice this is low-risk in 2026 — every current browser engine supports
AVIF. It matters for:

- old Safari (< 16.4) and other stale clients
- scrapers, RSS readers, and social/OpenGraph link unfurlers, which often send
  a generic or absent `Accept`

**Mitigation where it matters:** pin the extension in the URL instead of relying
on negotiation. `.../plain/s3://<bucket>/blog/x.jpg@jpg` always renders JPEG and
caches as JPEG. Use pinned extensions for OpenGraph/RSS/email images; use
auto-negotiation for in-page `<img>` tags.

Do not add a Cloudflare cache rule unless verification actually shows repeat
`MISS`es — the default static-asset caching covers this given the headers above.

---

## Provisioning B2

Manual, one-time. Requires the account master key, so run it from a machine with
interactive 1Password (the headless Mac mini can't — `op://Private/*` is outside
the offline-cache allowlist by design).

1. **Bucket** — create `<bucket>` in the existing account, **private**, same
   region as the backups bucket (endpoint `s3.eu-central-003.backblazeb2.com`,
   region `eu-central-003`).

2. **Read-only key for imgproxy** — scoped to this bucket only, capabilities
   `listBuckets`, `listFiles`, `readFiles`. Store as:

   | 1Password field | Value |
   |-|-|
   | `op://vps/imgproxy/B2_KEY_ID` | `keyID` |
   | `op://vps/imgproxy/B2_APP_KEY` | `applicationKey` |
   | `op://vps/imgproxy/B2_BUCKET` | bucket name |
   | `op://vps/imgproxy/B2_ENDPOINT` | `https://s3.eu-central-003.backblazeb2.com` |
   | `op://vps/imgproxy/B2_REGION` | `eu-central-003` |

3. **Read+write key for uploads** (Mac — photoflow, Obsidian plugin later) —
   scoped to the same bucket, capabilities `listBuckets`, `listFiles`,
   `readFiles`, `writeFiles`. **No `deleteFiles`** — uploads must not be able to
   destroy originals. Store as `op://Private/b2-images-write`
   (`B2_KEY_ID` / `B2_APP_KEY`).

B2 application keys are shown exactly once at creation. Capture both into
1Password immediately.

---

## Deploy

```bash
# after the 1Password items exist
git push && ssh vps "cd ~/vps && git pull && make imgproxy-up ENV=prod"
```

Then add the DNS record via the `/cloudflare` skill: `img.<domain>` → CNAME to
the tunnel, **proxied (orange cloud)** so edge caching applies. The wildcard
tunnel ingress (`*.<domain>` → `https://traefik:443`) already routes it — no
tunnel config change needed.

---

## Verification

```bash
# 1. upload a test image with the WRITE key
aws s3 cp test.jpg s3://<bucket>/misc/cdn-smoke-test.jpg \
  --endpoint-url https://s3.eu-central-003.backblazeb2.com

# 2. resized rendition, auto-format
curl -sI -H 'Accept: image/avif,image/webp,image/*' \
  'https://img.<domain>/insecure/rs:fit:800/plain/s3://<bucket>/misc/cdn-smoke-test.jpg'
#    → 200, content-type: image/avif (or image/webp)

# 3. repeat → edge cache hit
#    → cf-cache-status: HIT

# 4. source lock — an off-bucket source must be rejected
curl -so /dev/null -w '%{http_code}\n' \
  'https://img.<domain>/insecure/rs:fit:800/plain/https://example.com/x.jpg'
#    → 404 (imgproxy reports a forbidden source as 404, not 403)
```

Confirm dimensions with `curl ... | file -` or by piping to an image tool —
`rs:fit:800` bounds the *longest* side to 800, it does not force width.

# Image CDN — imgproxy + B2 + Cloudflare

Phase 1 of the image serving substrate. The `img/` prefix of the existing
private object-storage bucket holds originals; imgproxy on the VPS renders
resized/reformatted derivatives on demand; Cloudflare's edge caches those
derivatives. Consumers: the static photo-gallery site, blog/articles, the
Obsidian vault, and agents.

The later self-built photo service (shutterflow.app) is a separate project that
will consume this same substrate — nothing here is specific to it.

```
client → Cloudflare edge (cache) → tunnel → Traefik → imgproxy → B2 img/ (private)
```

---

## The bucket is shared with backups — read this first

`img/` lives in the **same bucket as the database backups** (`backups/vps/postgres/`,
`backups/vps/mariadb/`, …). imgproxy is public and unauthenticated. The only thing
standing between an anonymous request and a Postgres dump is the credential scope:

> **The imgproxy B2 application key MUST be created with `--name-prefix img/`.**
> B2 enforces that server-side. A key scoped this way returns 401 for
> `backups/…` no matter what URL reaches imgproxy.

`IMGPROXY_S3_ALLOWED_BUCKETS` does **not** help here — `backups/` is in the same
bucket it allows. `IMGPROXY_ALLOWED_SOURCES=s3://<bucket>/img/` is a real second
layer, but it is imgproxy-side config, not a credential boundary. Treat the
name-prefix as the control and the rest as defence in depth.

Never point imgproxy at `op://common/backblaze-s3/*` — that credential is
bucket-wide with `writeFiles`, and exists for the backup scripts.

---

## Access model

URLs are **unsigned**. imgproxy runs without `IMGPROXY_KEY`/`IMGPROXY_SALT`,
which puts it in unsigned mode and makes the `/insecure` prefix mandatory:

```
https://img.<domain>/insecure/rs:fit:800/plain/s3://<bucket>/img/fuji/foo.jpg@webp
```

Anyone who knows an object key can render it. That is intended for phase 1.

| Control | What it prevents |
|-|-|
| B2 key `--name-prefix img/` | reading `backups/` or anything else in the bucket (server-side, authoritative) |
| B2 key read-only caps | imgproxy writing or deleting anything, ever |
| `IMGPROXY_ALLOWED_SOURCES=s3://<bucket>/img/` | imgproxy being used as an open proxy for arbitrary URLs |
| `IMGPROXY_S3_ALLOWED_BUCKETS` | reaching a *different* bucket in the account |
| `IMGPROXY_ALLOW_PRIVATE_SOURCE_ADDRESSES=false` | SSRF into the internal Docker/Tailscale networks |
| Non-enumerable object keys | discovery of anything not meant to be public |

The bucket stays **private** — B2 never serves it directly, only imgproxy reads
from it.

**Upgrading to signed URLs later:** set `IMGPROXY_KEY` and `IMGPROXY_SALT`. The
`/insecure` prefix immediately stops being accepted, so every consumer must be
migrated to generating HMAC signatures in the same change.

---

## Prefix layout (convention, not enforced)

Everything lives under `img/`. Below that, nothing in the config restricts
prefixes — this is a documented convention so the bucket stays navigable.

| Prefix | Contents | Naming |
|-|-|-|
| `img/fuji/` | curated camera exports | readable paths OK (`img/fuji/2026-portugal/DSCF1234.jpg`) |
| `img/blog/` | article images | readable paths OK |
| `img/gen/` | generated / AI / ad-hoc | non-guessable (hash or nanoid) |
| `img/misc/` | everything else | non-guessable |

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

**Confirmed live**, not theoretical: a request sending `Accept: image/webp,image/*`
(no AVIF) was served `image/avif` from the edge, because an AVIF-capable client
had warmed that URL first.

In practice this is low-risk in 2026 — every current browser engine supports
AVIF. It matters for:

- old Safari (< 16.4) and other stale clients
- scrapers, RSS readers, and social/OpenGraph link unfurlers, which often send
  a generic or absent `Accept`

**Mitigation where it matters — use `f:jpg`, NOT `@jpg`:**

```
.../rs:fit:800/f:jpg/plain/s3://<bucket>/img/blog/x.jpg      ✅ pinned AND cached
.../rs:fit:800/plain/s3://<bucket>/img/blog/x.jpg@jpg        ❌ pinned, NOT cached
```

Both pin the output format. But Cloudflare's default static caching keys off the
**URL's trailing extension**, and the `@jpg` form ends the path in `.jpg@jpg`,
which Cloudflare does not recognise — measured `cf-cache-status: DYNAMIC` on
every repeat request, i.e. every hit goes to origin. The `f:jpg` processing
option leaves the path ending in `.jpg`, and measured `MISS` → `HIT`.

Use `f:jpg` for OpenGraph/RSS/email images; use auto-negotiation for in-page
`<img>` tags.

Do not add a Cloudflare cache rule unless verification actually shows repeat
`MISS`es — the default static-asset caching covers this given the headers above.

---

## Provisioning the B2 keys

**Requires the B2 account master key, which is NOT in 1Password.** Both stored
credentials (`op://Private/Backblaze B2` and `op://common/backblaze-s3`) are
already bucket-restricted and lack the `writeKeys` capability, so neither can
create application keys. Use the B2 web console (login in
`op://Private/Backblaze B2`), or authorize the CLI with a real master key.

Create two keys, both restricted to the bucket **and** the `img/` prefix:

| Key | Capabilities | Stored at |
|-|-|-|
| `imgproxy-read` | `listBuckets,listFiles,readFiles` | `op://vps/imgproxy/{B2_KEY_ID,B2_APP_KEY}` |
| `images-write` | `listBuckets,listFiles,readFiles,writeFiles` | `op://common/b2-images-write/{B2_KEY_ID,B2_APP_KEY}` |

Neither gets `deleteFiles` — uploads must not be able to destroy originals, and
the CDN must not be able to write at all.

With a master key authorized, the CLI form is:

```bash
b2 key create --bucket <bucket> --name-prefix img/ \
  imgproxy-read listBuckets,listFiles,readFiles

b2 key create --bucket <bucket> --name-prefix img/ \
  images-write listBuckets,listFiles,readFiles,writeFiles
```

B2 prints the application key exactly once, at creation. Capture both into
1Password immediately. Bucket coordinates (`BUCKET`, `ENDPOINT`, `REGION`) are
reused from the existing `op://common/backblaze-s3` item — no new fields needed
beyond `REGION`.

**Verify the prefix restriction actually took** before deploying:

```bash
b2 account authorize <imgproxy-read-id> <imgproxy-read-key>
b2 file download b2://<bucket>/backups/vps/postgres/<any-file> /tmp/x  # must FAIL
b2 ls b2://<bucket>/img/                                               # must succeed
b2 account clear
```

---

## Deploy

```bash
# only after op://vps/imgproxy/* exists — every `make` target on the VPS
# resolves the whole .env.tpl, so an unresolvable ref breaks all of them
git push && ssh vps "cd ~/vps && git pull && make imgproxy-up ENV=prod"
```

Then add the DNS record via the `/cloudflare` skill: `img.<domain>` → CNAME to
the tunnel, **proxied (orange cloud)** so edge caching applies. The wildcard
tunnel ingress (`*.<domain>` → `https://traefik:443`) already routes it — no
tunnel config change needed.

---

## Verification

A 2000×2000 smoke-test object is **already staged** at
`img/misc/cdn-smoke-test.jpg` (uploaded with the admin key while provisioning,
since `images-write` did not exist yet). `rs:fit:800` against it should return
800×800. Re-run step 1 with the real write key once it exists, to confirm that
key works too.

```bash
# 1. upload a test image with the WRITE key
aws s3 cp test.jpg s3://<bucket>/img/misc/cdn-smoke-test.jpg \
  --endpoint-url <endpoint>

# 2. resized rendition, auto-format
curl -sI -H 'Accept: image/avif,image/webp,image/*' \
  'https://img.<domain>/insecure/rs:fit:800/plain/s3://<bucket>/img/misc/cdn-smoke-test.jpg'
#    → 200, content-type: image/avif (or image/webp)

# 3. repeat → edge cache hit
#    → cf-cache-status: HIT

# 4. source lock — off-bucket source must be rejected
curl -so /dev/null -w '%{http_code}\n' \
  'https://img.<domain>/insecure/rs:fit:800/plain/https://example.com/x.jpg'
#    → 404 (imgproxy reports a forbidden source as 404, not 403)

# 5. THE IMPORTANT ONE — backups must be unreachable through the CDN
curl -so /dev/null -w '%{http_code}\n' \
  'https://img.<domain>/insecure/rs:fit:800/plain/s3://<bucket>/backups/vps/postgres/<file>'
#    → 404
```

Step 5 is the one that matters given the shared bucket. Re-run it after any
change to the key, `ALLOWED_SOURCES`, or the bucket layout.

### Results at go-live (2026-07-21)

| Check | Result |
|-|-|
| `rs:fit:800` on a 2000×2000 source | 200, 800×800, `image/avif` |
| `cache-control` | `public, max-age=31536000` |
| Repeat request | `cf-cache-status: HIT` |
| Off-bucket source (`https://…`, other bucket) | 404 |
| `backups/…` real dump filename via CDN | 404 |
| B2 key listing `backups/` directly | `unauthorized` (server-side, `restricted to files that start with 'img/'`) |
| `f:jpg` | `image/jpeg`, MISS → HIT |
| `@jpg` | `image/jpeg`, `DYNAMIC` (uncached — see above) |

Confirm dimensions with `curl ... | file -` — `rs:fit:800` bounds the *longest*
side to 800, it does not force width.

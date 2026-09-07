# Integrating Umami on a New Website

### Embed snippet

The Umami dashboard shows `script.js` in its tracking code UI — **ignore it**. The actual script path is renamed to bypass ad blockers. Always use:

```html
<script defer src="https://umami.jkrumm.com/p.js" data-website-id="<website-id>"></script>
```

Get `data-website-id` from the Umami dashboard (Settings → Websites → your site).

### Why `/p.js` and not `/script.js`

`TRACKER_SCRIPT_NAME=p.js` and `COLLECT_API_ENDPOINT=/api/p` are set in `compose.monitoring.yml`. This renames both endpoints so they don't match ad blocker filter lists (uBlock, Helium, etc.), which target known paths like `/script.js` and `/api/send`.

Brave Shields can still block third-party analytics origins regardless of path. If that matters for a site, the next step is proxying both endpoints through the site's own domain (same-origin requests can't be blocked without breaking the site itself). For an Astro site this means adding rewrites; for Next.js use `next.config.js` rewrites:

```js
// next.config.js
rewrites: async () => [
  { source: '/p.js', destination: 'https://umami.jkrumm.com/p.js' },
  { source: '/api/p', destination: 'https://umami.jkrumm.com/api/p' },
]
// Then embed: <script defer src="/p.js" data-website-id="...">
```

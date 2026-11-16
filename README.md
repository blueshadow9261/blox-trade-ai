# Market data collector

Collects Blox Fruits trading values from bloxfruitsvalues.gg (public pages, robots.txt obeyed),
validates them, and publishes `latest.json`, `history.json`, `status.json` to GitHub Pages.
Zero third-party Python dependencies. Run tests: `python -m unittest discover -s tests`.

First run on your machine (checks the parser against the live site; writes nothing):
    python -m collector.run --diagnose

Local collection: `python -m collector.run --out site`

## Deploy (GitHub Actions + Pages, free, no server)
1. Push this project to a GitHub repo (it can be private; Pages on private repos needs a paid plan, otherwise make it public).
2. Settings > Actions > General > Workflow permissions: **Read and write**.
3. Actions > collect-market-data > Run workflow (creates the `gh-pages` branch).
4. Settings > Pages > Source: Deploy from branch > `gh-pages` / root.
5. Your feed URL: `https://<user>.github.io/<repo>/latest.json`. Put it in `MarketDataManager.gd` (`FEED_URL`)
   or in project settings `blox/market/feed_url`.
6. GitHub disables scheduled workflows after 60 days without repo activity: check Actions occasionally.

Alternative (any VPS): cron `*/30 * * * *  cd /opt/blox/backend && python3 -m collector.run --out /var/www/market`
behind nginx/Caddy with HTTPS.

## Behaviour
- Fail closed: HTTP/robots/parse/validation failure -> `latest.json` untouched, reason in `status.json`.
- Detail pages are fetched only for new/changed fruits plus `COLLECTOR_DETAIL_ROTATION` (3) oldest per run
  (~400 requests/day total, 2 s apart). Permanent values can therefore lag up to ~8 h if the site changes
  them without changing the list-level value/demand/trend.
- Extra feeds for conflict display: `COLLECTOR_EXTRA_FEEDS="name=https://host/feed.json"` (our schema).

## Fallback source: eggvalues.com (new)
Used ONLY when bloxfruitsvalues.gg fails (never averaged or mixed with it). It reads the public HTML tables at
eggvalues.com/blox-fruits/values/ (robots.txt obeyed, fail closed). It has no rarity/image/dealer price, so it only
refreshes fruits already in the last accepted snapshot; other fruits are kept unchanged and flagged
"not refreshed by fallback". Fallback records have confidence_status `partial`, source `eggvalues.com`.
Its "adopted" values come from other community lists, so it is not guaranteed independent of the primary.
The parser was written from the page's described layout, not saved HTML (the sandbox could not reach the site):
run `python -m collector.run --diagnose-egg` once to confirm it matches the live page.

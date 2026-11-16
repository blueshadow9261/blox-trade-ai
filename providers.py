"""Source providers. Each returns ProviderResult; failure never raises past collect()."""
import json
import time
import urllib.request
import urllib.error
import urllib.robotparser
from urllib.parse import urlparse
from . import config, parse, egg

class FetchError(Exception):
    pass

class ProviderResult:
    def __init__(self, name, ok, fruits=None, error=None, requests_made=0, site_updated=None):
        self.name, self.ok, self.fruits = name, ok, fruits or []
        self.error, self.requests_made, self.site_updated = error, requests_made, site_updated

class Fetcher:
    """HTTPS-only fetcher that obeys robots.txt (fail closed) and rate-limits itself."""
    def __init__(self, base, user_agent=config.USER_AGENT):
        if not base.startswith("https://"):
            raise FetchError("only https sources are allowed")
        self.base, self.ua, self._last, self.count = base, user_agent, 0.0, 0
        self.delay = config.MIN_DELAY_SECONDS
        self._robots = None

    def _raw(self, url, accept="text/html"):
        wait = self.delay - (time.monotonic() - self._last)
        if wait > 0:
            time.sleep(wait)
        req = urllib.request.Request(url, headers={"User-Agent": self.ua, "Accept": accept})
        try:
            with urllib.request.urlopen(req, timeout=config.REQUEST_TIMEOUT) as r:
                body = r.read(config.MAX_BODY_BYTES + 1)
                if len(body) > config.MAX_BODY_BYTES:
                    raise FetchError("response too large: " + url)
                return r.status, body.decode("utf-8", "replace")
        except urllib.error.HTTPError as e:
            return e.code, ""
        except (urllib.error.URLError, TimeoutError, OSError) as e:
            raise FetchError("network error for %s: %s" % (url, e))
        finally:
            self._last = time.monotonic()
            self.count += 1

    def _load_robots(self):
        status, body = self._raw(self.base + "/robots.txt", "text/plain")
        rp = urllib.robotparser.RobotFileParser()
        if status in (404, 410):
            rp.parse([])                     # no robots.txt = everything allowed (RFC 9309)
        elif status == 200:
            rp.parse(body.splitlines())
        else:
            raise FetchError("robots.txt unavailable (HTTP %d); refusing to crawl" % status)
        self._robots = rp
        cd = rp.crawl_delay(self.ua)
        if cd:
            self.delay = max(self.delay, float(cd))

    def get(self, path):
        if self._robots is None:
            self._load_robots()
        url = self.base + path
        if not self._robots.can_fetch(self.ua, url):
            raise FetchError("robots.txt disallows " + path)
        status, body = self._raw(url)
        if status != 200:
            raise FetchError("HTTP %d for %s" % (status, path))
        return body

class BloxFruitsValuesProvider:
    name = "bloxfruitsvalues.gg"

    def __init__(self, fetcher=None):
        self.fetcher = fetcher or Fetcher(config.SITE)

    def collect(self, previous_by_id, now_iso):
        try:
            cards = []
            for tier in config.RARITY_TIERS:
                cards += parse.parse_list_page(self.fetcher.get("/values/rarity/" + tier), tier)
            if not cards:
                raise parse.ParseError("no fruits parsed")
            by_id = {}
            for c in cards:
                if c["id"] in by_id:
                    raise parse.ParseError("fruit listed in two tiers: " + c["id"])
                by_id[c["id"]] = c
            fruits = self._build(by_id, previous_by_id, now_iso)
            return ProviderResult(self.name, True, fruits, requests_made=self.fetcher.count)
        except (FetchError, parse.ParseError) as e:
            return ProviderResult(self.name, False, error=str(e), requests_made=self.fetcher.count)

    def _build(self, by_id, prev, now):
        # decide which detail pages to fetch
        need = []
        for fid, c in by_id.items():
            p = prev.get(fid)
            changed = (not p or any(p.get(k) != c[k] for k in
                       ("physical_value", "physical_demand", "market_trend", "beli_price", "rarity")))
            if changed:
                need.append(fid)
        rest = sorted((f for f in by_id if f not in need),
                      key=lambda f: (prev.get(f) or {}).get("detail_fetched_at") or "")
        need += rest[:config.DETAIL_ROTATION_PER_RUN]
        out = []
        for fid, c in by_id.items():
            p = prev.get(fid) or {}
            rec = {
                "id": fid, "name": c["name"], "image": c["image"] or
                    "https://bloxfruitsvalues.gg/fruits/%s.webp" % fid,
                "rarity": c["rarity"], "fruit_type": c["fruit_type"],
                "physical_value": c["physical_value"],
                "permanent_value": p.get("permanent_value"),
                "physical_demand": c["physical_demand"], "permanent_demand": None,
                "beli_price": c["beli_price"], "robux_price": p.get("robux_price"),
                "market_trend": c["market_trend"] or "unknown",
                "last_updated": p.get("last_updated"), "source": self.name,
                "confidence_status": "partial", "fetched_at": now,
                "detail_fetched_at": p.get("detail_fetched_at"), "flags": [],
            }
            if fid in need:
                try:
                    d = parse.parse_detail_page(self.fetcher.get("/values/" + fid), fid)
                    rec["permanent_value"] = d["permanent_value"]
                    rec["robux_price"] = d["robux_price"]
                    rec["last_updated"] = d["last_updated"]
                    rec["detail_fetched_at"] = now
                    if d["beli_price"] is not None:
                        rec["beli_price"] = d["beli_price"]
                    rec["flags"] += d["notes"]
                    lv, dv = c["physical_value"], d["physical_value"]
                    if lv and dv and abs(lv - dv) > 0.01 * dv:
                        rec["flags"].append("list/detail physical value mismatch")
                except (FetchError, parse.ParseError) as e:
                    rec["flags"].append("detail unavailable: %s" % e)
            if rec["last_updated"] is None:
                rec["last_updated"] = now[:10]
            fresh = rec["detail_fetched_at"] and rec["detail_fetched_at"] >= _hours_ago(now, 12)
            rec["confidence_status"] = "needs_review" if rec["flags"] and any(
                "mismatch" in f or "disagree" in f for f in rec["flags"]) else (
                "verified" if fresh else "partial")
            out.append(rec)
        return out

def _hours_ago(now_iso, h):
    from datetime import datetime, timedelta, timezone
    t = datetime.strptime(now_iso, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    return (t - timedelta(hours=h)).strftime("%Y-%m-%dT%H:%M:%SZ")

class JsonFeedProvider:
    """Reads a feed in OUR normalized schema (a 'fruits' array) from a source you may use."""
    def __init__(self, name, url):
        self.name, self.url = name, url

    def collect(self, previous_by_id, now_iso):
        try:
            f = Fetcher("https://" + urlparse(self.url).netloc)
            body = f.get(urlparse(self.url).path or "/")
            data = json.loads(body)
            fruits = data["fruits"]
            if not isinstance(fruits, list):
                raise ValueError("fruits is not a list")
            for x in fruits:
                x["source"] = self.name
            return ProviderResult(self.name, True, fruits, requests_made=f.count)
        except (FetchError, ValueError, KeyError, TypeError) as e:
            return ProviderResult(self.name, False, error=str(e))


class EggValuesProvider:
    """FALLBACK ONLY (used when the primary source fails). eggvalues.com has no rarity, image or dealer
    price, so it can only refresh fruits already present in the last accepted snapshot; unknown fruits
    are skipped. Needs a previous snapshot, otherwise it fails closed."""
    name = "eggvalues.com"
    PATH = "/blox-fruits/values/"

    def __init__(self, fetcher=None):
        self.fetcher = fetcher or Fetcher("https://eggvalues.com")

    def collect(self, previous_by_id, now_iso):
        try:
            if not previous_by_id:
                raise parse.ParseError("no previous snapshot to merge fallback values into")
            rows = egg.parse_values_page(self.fetcher.get(self.PATH))
            by_key = {egg.name_key(p["name"]): p for p in previous_by_id.values()}
            out, seen = [], set()
            for r in rows:
                prev = previous_by_id.get(egg.slugify(r["name"])) or by_key.get(egg.name_key(r["name"]))
                if not prev or prev["id"] in seen:
                    continue
                seen.add(prev["id"])
                rec = dict(prev)
                rec.update(physical_value=r["physical_value"], permanent_value=r["permanent_value"],
                           physical_demand=r["physical_demand"], permanent_demand=r["permanent_demand"],
                           source=self.name, fetched_at=now_iso, last_updated=now_iso[:10],
                           confidence_status="partial", flags=list(r["flags"]))
                out.append(rec)
            if not out:
                raise parse.ParseError("eggvalues: no fruit matched the previous snapshot")
            for prev in previous_by_id.values():      # keep fruits eggvalues doesn't list, marked stale
                if prev["id"] not in seen:
                    rec = dict(prev)
                    rec["flags"] = [f for f in prev.get("flags", []) if f != "not refreshed by fallback"] \
                        + ["not refreshed by fallback"]
                    out.append(rec)
            return ProviderResult(self.name, True, out, requests_made=self.fetcher.count)
        except (FetchError, parse.ParseError) as e:
            return ProviderResult(self.name, False, error=str(e), requests_made=self.fetcher.count)

    def collect_extras(self, taken_ids, now_iso):
        """Fruit skins + limited items as extra records. Raises FetchError/ParseError (caller decides)."""
        rows = egg.parse_extras_page(self.fetcher.get(self.PATH))
        out, seen = [], set(taken_ids)
        for r in rows:
            fid = egg.slugify(r["name"])[:64].strip("-")
            if not fid or fid in seen or len(r["name"]) > 64:
                continue
            seen.add(fid)
            out.append({
                "id": fid, "name": r["name"], "image": None, "rarity": r["category"], "fruit_type": r["type"],
                "physical_value": r["value"], "permanent_value": None, "physical_demand": r["demand"],
                "permanent_demand": None, "beli_price": None, "robux_price": r["robux"], "market_trend": r["trend"],
                "last_updated": now_iso[:10], "source": self.name, "confidence_status": "partial",
                "fetched_at": now_iso, "detail_fetched_at": None, "flags": list(r["flags"])})
        if not out:
            raise parse.ParseError("eggvalues: no usable skin/limited rows")
        return out

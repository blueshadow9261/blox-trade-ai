"""Collector entry point.
  python -m collector.run --out site          # collect, validate, write latest.json/history.json
  python -m collector.run --diagnose          # fetch + parse only, print a report, write nothing
Fail closed: if anything is wrong, latest.json is left exactly as it was."""
import argparse
import json
import os
import sys
import tempfile
from datetime import datetime, timezone
from . import config, merge, parse, providers, validate

def now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

def read_json(path, default):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return default

def write_json_atomic(path, data):
    d = os.path.dirname(path) or "."
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=d, suffix=".tmp")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, separators=(",", ":"), sort_keys=True)
    os.replace(tmp, path)

def build_extra_providers():
    out = []
    for part in filter(None, (p.strip() for p in config.EXTRA_FEEDS.split(","))):
        name, _, url = part.partition("=")
        if name and url.startswith("https://"):
            out.append(providers.JsonFeedProvider(name, url))
    return out

_DEFAULT = object()

def run(out_dir, primary=None, extras=None, now=None, fallback=_DEFAULT):
    now = now or now_iso()
    latest_path = os.path.join(out_dir, "latest.json")
    prev = read_json(latest_path, {})
    prev_fruits = prev.get("fruits", []) if isinstance(prev, dict) else []
    prev_by_id = {f["id"]: f for f in prev_fruits if isinstance(f, dict) and "id" in f}
    primary = primary or providers.BloxFruitsValuesProvider()
    extras = build_extra_providers() if extras is None else extras

    res = primary.collect(prev_by_id, now)
    status = {"checked_at": now, "ok": res.ok, "error": res.error, "requests": res.requests_made}
    others, notes = {}, []
    fb = providers.EggValuesProvider() if fallback is _DEFAULT else fallback
    from_fallback = False
    if not res.ok:
        # Fallback only: used when the primary fails. Same validation applies; never merged with the primary.
        primary_error = res.error
        if fb is None:
            return _fail(out_dir, status, primary_error)
        res = fb.collect(prev_by_id, now)
        status.update(fallback=fb.name, requests=status["requests"] + res.requests_made)
        if not res.ok:
            return _fail(out_dir, status, "%s | fallback %s: %s" % (primary_error, fb.name, res.error))
        notes.append("primary source failed (%s); values come from fallback %s" % (primary_error, fb.name))
        status["ok"], status["error"] = True, None
        from_fallback = True

    if not from_fallback and fb is not None and hasattr(fb, "collect_extras"):
        # Fruit skins and limited items (not on the primary's fruit lists). Failure never fails the run:
        # the previous extras are carried over, marked stale, so the fruit-count guard doesn't misfire.
        taken = {f["id"] for f in res.fruits}
        try:
            extra = fb.collect_extras(taken, now, [f["name"] for f in res.fruits])
        except (providers.FetchError, parse.ParseError) as e:
            extra = []
            for p in prev_by_id.values():
                if p.get("rarity") in ("skin", "limited") and p["id"] not in taken:
                    q = dict(p)
                    q["flags"] = [x for x in p.get("flags", []) if x != "stale: extras source unavailable"] + \
                        ["stale: extras source unavailable"]
                    q["confidence_status"] = "partial"
                    extra.append(q)
            notes.append("skins/limited items not refreshed: %s" % e)
        res.fruits = list(res.fruits) + extra

    for ex in extras:
        r = ex.collect(prev_by_id, now)
        if r.ok and not validate.validate_batch(r.fruits, 0):
            others[r.name] = r.fruits
        else:
            notes.append("extra source %s skipped: %s" % (r.name, r.error or "invalid data"))

    errors = validate.validate_batch(res.fruits, len(prev_by_id))
    if errors:
        return _fail(out_dir, status, "validation failed: " + " | ".join(errors[:5]))

    fruits, conflicts = merge.merge_sources(res.fruits, others)
    new_by_id = {f["id"]: f for f in fruits}
    flagged = validate.flag_large_changes(new_by_id, prev_by_id)
    events = merge.diff(prev_by_id, new_by_id, now) if prev_by_id else []

    snapshot = {
        "schema_version": config.SCHEMA_VERSION,
        "generated_at": now,
        "data_freshness": "periodic_snapshot",
        "freshness_note": "Community-maintained values published in periodic updates. Not real-time.",
        "sources": [{"name": res.name, "ok": True}] +
                   [{"name": n, "ok": True} for n in others],
        "notes": notes,
        "count": len(fruits),
        "review": sorted(set(flagged)),
        "conflicts": conflicts,
        "fruits": sorted(fruits, key=lambda f: f["id"]),
    }
    write_json_atomic(latest_path, snapshot)
    hist_path = os.path.join(out_dir, "history.json")
    hist = read_json(hist_path, {"events": []})
    hist["events"] = (events + hist.get("events", []))[:config.HISTORY_MAX_EVENTS]
    write_json_atomic(hist_path, hist)
    status.update(count=len(fruits), events=len(events))
    write_json_atomic(os.path.join(out_dir, "status.json"), status)
    return 0, status

def _fail(out_dir, status, error):
    status["ok"], status["error"] = False, error
    write_json_atomic(os.path.join(out_dir, "status.json"), status)
    print("::warning::collection failed, previous data kept: %s" % error, file=sys.stderr)
    return 1, status

def diagnose():
    p = providers.BloxFruitsValuesProvider()
    r = p.collect({}, now_iso())
    print("ok:", r.ok, "| requests:", r.requests_made, "| error:", r.error)
    for f in r.fruits[:50]:
        print("%-22s %-10s %-9s phys=%-12s perm=%-12s dem=%s trend=%-9s beli=%s robux=%s rev=%s %s" % (
            f["name"], f["rarity"], f["fruit_type"], f["physical_value"], f["permanent_value"],
            f["physical_demand"], f["market_trend"], f["beli_price"], f["robux_price"],
            f["last_updated"], f["flags"]))
    return 0 if r.ok else 1

def diagnose_egg():
    from . import egg
    f = providers.Fetcher("https://eggvalues.com")
    try:
        rows = egg.parse_values_page(f.get(providers.EggValuesProvider.PATH))
    except (providers.FetchError, parse.ParseError) as e:
        print("ok: False | error:", e)
        return 1
    print("ok: True | rows:", len(rows))
    for r in rows[:50]:
        print("%-22s %-10s phys=%-12s perm=%-12s pdem=%s mdem=%s %s" % (
            r["name"], r["fruit_type"], r["physical_value"], r["permanent_value"],
            r["physical_demand"], r["permanent_demand"], r["flags"][1:]))
    return 0

if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="site")
    ap.add_argument("--diagnose", action="store_true")
    ap.add_argument("--diagnose-egg", action="store_true", help="check the eggvalues.com fallback parser")
    a = ap.parse_args()
    if a.diagnose_egg:
        sys.exit(diagnose_egg())
    if a.diagnose:
        sys.exit(diagnose())
    code, _ = run(a.out)
    sys.exit(0)   # fail-closed runs are warnings, not red builds; see status.json

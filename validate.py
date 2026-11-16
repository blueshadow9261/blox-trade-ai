"""Server-side validation. Mirrors scripts/market/DataValidator.gd (client re-validates everything)."""
import re
from . import config

ID_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,63}$")
RARITIES = {"common", "uncommon", "rare", "legendary", "mythical"}
TRENDS = {"stable", "overpaid", "rising", "dropping", "unknown"}
STATUSES = {"verified", "partial", "needs_review", "conflict"}
REQUIRED = ["id", "name", "image", "rarity", "fruit_type", "physical_value", "permanent_value",
            "physical_demand", "permanent_demand", "beli_price", "robux_price", "market_trend",
            "last_updated", "source", "confidence_status"]

def _num_ok(v, nullable=True):
    if v is None:
        return nullable
    return isinstance(v, int) and not isinstance(v, bool) and 0 <= v <= config.MAX_VALUE

def validate_fruit(f):
    """Return a list of error strings (empty = valid)."""
    e = []
    if not isinstance(f, dict):
        return ["not an object"]
    for k in REQUIRED:
        if k not in f:
            e.append("missing field " + k)
    if e:
        return e
    if not (isinstance(f["id"], str) and ID_RE.match(f["id"])):
        e.append("bad id")
    if not (isinstance(f["name"], str) and 0 < len(f["name"].strip()) <= 64):
        e.append("bad name")
    if f["rarity"] not in RARITIES:
        e.append("bad rarity")
    if f["market_trend"] not in TRENDS:
        e.append("bad trend")
    if f["confidence_status"] not in STATUSES:
        e.append("bad confidence_status")
    if not _num_ok(f["physical_value"], nullable=False):
        e.append("physical_value must be a non-negative integer")
    for k in ("permanent_value", "beli_price", "robux_price"):
        if not _num_ok(f[k]):
            e.append(k + " must be null or a non-negative integer")
    for k in ("physical_demand", "permanent_demand"):
        v = f[k]
        if v is not None and not (isinstance(v, int) and not isinstance(v, bool) and 0 <= v <= 10):
            e.append(k + " must be null or 0..10")
    if f["image"] is not None and not (isinstance(f["image"], str) and f["image"].startswith("https://")):
        e.append("image must be https or null")
    return e

def validate_batch(fruits, previous_count):
    """Whole-snapshot checks. Returns list of errors; any error rejects the snapshot."""
    errs, seen = [], set()
    if not fruits:
        return ["snapshot is empty"]
    for f in fruits:
        fe = validate_fruit(f)
        if fe:
            errs.append("%s: %s" % (f.get("id") if isinstance(f, dict) else "?", "; ".join(fe)))
            continue
        if f["id"] in seen:
            errs.append("duplicate id " + f["id"])
        seen.add(f["id"])
    if previous_count and len(fruits) < previous_count * config.MIN_COUNT_RATIO:
        errs.append("fruit count dropped from %d to %d (looks like a partial scrape)" %
                    (previous_count, len(fruits)))
    return errs

def pct_change(old, new):
    if old in (None, 0) or new is None:
        return None
    return (new - old) / old * 100.0

def flag_large_changes(new_by_id, old_by_id):
    """Mark records whose value moved more than LARGE_CHANGE_PCT versus the previous accepted
    snapshot. Value is kept (the site may be right) but status becomes needs_review."""
    flagged = []
    for fid, n in new_by_id.items():
        o = old_by_id.get(fid)
        if not o:
            continue
        for field in ("physical_value", "permanent_value"):
            p = pct_change(o.get(field), n.get(field))
            if p is not None and abs(p) >= config.LARGE_CHANGE_PCT:
                n.setdefault("flags", []).append("large_change:%s:%.1f%%" % (field, p))
                if n["confidence_status"] != "conflict":
                    n["confidence_status"] = "needs_review"
                flagged.append(fid)
    return flagged

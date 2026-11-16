"""Cross-source merge (conflicts are reported, never averaged) and change detection."""
from . import config
from .validate import pct_change

COMPARED = ("physical_value", "permanent_value", "physical_demand", "rarity", "market_trend")

def merge_sources(primary, others):
    """primary: list of records (kept as the displayed values). others: {provider: [records]}.
    Returns (records, conflicts). A disagreement sets confidence_status='conflict' and lists each
    source's value; the primary's number stays displayed but is explicitly marked disputed."""
    by_id = {f["id"]: f for f in primary}
    conflicts = []
    for pname, recs in others.items():
        for r in recs:
            base = by_id.get(r.get("id"))
            if not base:
                continue
            for field in COMPARED:
                a, b = base.get(field), r.get(field)
                if a is None or b is None or a == b:
                    continue
                if isinstance(a, int) and isinstance(b, int) and field.endswith("value"):
                    p = pct_change(a, b)
                    if p is not None and abs(p) <= config.CONFLICT_TOLERANCE_PCT:
                        continue
                conflicts.append({"id": base["id"], "field": field,
                                  "values": {base["source"]: a, pname: b}})
                base["confidence_status"] = "conflict"
    return list(by_id.values()), conflicts

def diff(old_by_id, new_by_id, now):
    """Events between two accepted snapshots."""
    ev = []
    for fid, n in new_by_id.items():
        o = old_by_id.get(fid)
        if not o:
            ev.append({"t": now, "id": fid, "type": "added", "name": n["name"]})
            continue
        if o["name"] != n["name"]:
            ev.append({"t": now, "id": fid, "type": "renamed", "old": o["name"], "new": n["name"]})
        for f in ("physical_value", "permanent_value"):
            if o.get(f) != n.get(f):
                p = pct_change(o.get(f), n.get(f))
                ev.append({"t": now, "id": fid, "type": "value", "field": f, "old": o.get(f),
                           "new": n.get(f), "pct": None if p is None else round(p, 2)})
        for f in ("physical_demand", "permanent_demand"):
            if o.get(f) != n.get(f):
                ev.append({"t": now, "id": fid, "type": "demand", "field": f,
                           "old": o.get(f), "new": n.get(f)})
        if o.get("market_trend") != n.get("market_trend"):
            ev.append({"t": now, "id": fid, "type": "trend", "old": o.get("market_trend"),
                       "new": n.get("market_trend")})
    for fid, o in old_by_id.items():
        if fid not in new_by_id:
            ev.append({"t": now, "id": fid, "type": "removed", "name": o["name"]})
    return ev

class_name MarketDiff
extends RefCounted
## Change detection between two accepted snapshots (dictionaries keyed by fruit id).

static func _norm(s: String) -> String:
	var out := ""
	for c in s.to_lower():
		if (c >= "a" and c <= "z") or (c >= "0" and c <= "9"):
			out += c
	return out

static func compute(old_by_id: Dictionary, new_by_id: Dictionary) -> Dictionary:
	var d := {"added": [], "removed": [], "renamed": [], "value_changes": [], "demand_changes": [],
		"trend_changes": [], "review": [], "conflicts": [], "is_first_load": old_by_id.is_empty()}
	for id in new_by_id:
		var n: Dictionary = new_by_id[id]
		if n["confidence_status"] == "needs_review":
			d["review"].append(id)
		elif n["confidence_status"] == "conflict":
			d["conflicts"].append(id)
		if not old_by_id.has(id):
			d["added"].append({"id": id, "name": n["name"]})
			continue
		var o: Dictionary = old_by_id[id]
		if o["name"] != n["name"]:
			d["renamed"].append({"id": id, "old_id": id, "old": o["name"], "new": n["name"]})
		for f in ["physical_value", "permanent_value"]:
			if o.get(f) != n.get(f):
				d["value_changes"].append({"id": id, "name": n["name"], "field": f, "old": o.get(f),
					"new": n.get(f), "pct": DataValidator.pct_change(o.get(f), n.get(f))})
		for f in ["physical_demand", "permanent_demand"]:
			if o.get(f) != n.get(f):
				d["demand_changes"].append({"id": id, "name": n["name"], "field": f, "old": o.get(f), "new": n.get(f)})
		if o["market_trend"] != n["market_trend"]:
			d["trend_changes"].append({"id": id, "name": n["name"], "old": o["market_trend"], "new": n["market_trend"]})
	for id in old_by_id:
		if not new_by_id.has(id):
			d["removed"].append({"id": id, "name": old_by_id[id]["name"]})
	_pair_id_renames(d)
	d["empty"] = d["added"].is_empty() and d["removed"].is_empty() and d["renamed"].is_empty() \
		and d["value_changes"].is_empty() and d["demand_changes"].is_empty() and d["trend_changes"].is_empty()
	return d

## A fruit whose id changed but whose name is the same (ignoring punctuation/case) is a rename, not add+remove.
static func _pair_id_renames(d: Dictionary) -> void:
	var still_removed: Array = []
	for r in d["removed"]:
		var matched := -1
		for i in d["added"].size():
			if _norm(d["added"][i]["name"]) == _norm(r["name"]):
				matched = i
				break
		if matched >= 0:
			var a: Dictionary = d["added"][matched]
			d["renamed"].append({"id": a["id"], "old_id": r["id"], "old": r["name"], "new": a["name"]})
			d["added"].remove_at(matched)
		else:
			still_removed.append(r)
	d["removed"] = still_removed

static func to_events(d: Dictionary, ts: int) -> Array:
	var ev: Array = []
	for x in d["added"]:
		ev.append({"t": ts, "type": "added", "id": x["id"], "name": x["name"]})
	for x in d["removed"]:
		ev.append({"t": ts, "type": "removed", "id": x["id"], "name": x["name"]})
	for x in d["renamed"]:
		ev.append({"t": ts, "type": "renamed", "id": x["id"], "old": x["old"], "new": x["new"]})
	for x in d["value_changes"]:
		ev.append({"t": ts, "type": "value", "id": x["id"], "name": x["name"], "field": x["field"],
			"old": x["old"], "new": x["new"], "pct": x["pct"]})
	for x in d["demand_changes"]:
		ev.append({"t": ts, "type": "demand", "id": x["id"], "name": x["name"], "field": x["field"],
			"old": x["old"], "new": x["new"]})
	for x in d["trend_changes"]:
		ev.append({"t": ts, "type": "trend", "id": x["id"], "name": x["name"], "old": x["old"], "new": x["new"]})
	return ev

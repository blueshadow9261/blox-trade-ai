class_name DataValidator
extends RefCounted
## Validates market snapshots. Nothing is accepted unless the whole snapshot is valid.
## Used for every source of data: network, background-sync file, and the on-disk cache.

const SCHEMA_VERSION := 1
const MAX_BYTES := 2000000
const MAX_VALUE := 10000000000000.0
const MIN_COUNT_RATIO := 0.7
const LARGE_CHANGE_PCT := 50.0
const REQUIRED := ["id", "name", "image", "rarity", "fruit_type", "physical_value", "permanent_value",
	"physical_demand", "permanent_demand", "beli_price", "robux_price", "market_trend",
	"last_updated", "source", "confidence_status"]
const RARITIES := ["common", "uncommon", "rare", "legendary", "mythical"]
const TRENDS := ["stable", "overpaid", "rising", "dropping", "unknown"]
const STATUSES := ["verified", "partial", "needs_review", "conflict"]

static func _is_num(v) -> bool:
	return typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT

static func _valid_amount(v, nullable: bool) -> bool:
	if v == null:
		return nullable
	if not _is_num(v):
		return false
	var f := float(v)
	return f >= 0.0 and f <= MAX_VALUE and f == floorf(f)

static func _opt_int(v):
	return null if v == null else int(v)

static func parse_iso(s) -> int:
	if typeof(s) != TYPE_STRING:
		return -1
	var t: String = s.strip_edges()
	if t.ends_with("Z"):
		t = t.substr(0, t.length() - 1)
	var re := RegEx.new()
	re.compile("^\\d{4}-\\d{2}-\\d{2}(T\\d{2}:\\d{2}:\\d{2})?$")
	if re.search(t) == null:
		return -1
	return int(Time.get_unix_time_from_datetime_string(t))

## Returns {"errors": Array, "clean": Dictionary}. clean is empty when errors exist.
static func validate_fruit(f) -> Dictionary:
	var errs: Array = []
	if typeof(f) != TYPE_DICTIONARY:
		return {"errors": ["not an object"], "clean": {}}
	for k in REQUIRED:
		if not f.has(k):
			errs.append("missing " + k)
	if not errs.is_empty():
		return {"errors": errs, "clean": {}}
	var id = f["id"]
	if typeof(id) != TYPE_STRING:
		errs.append("id not a string")
	else:
		var re := RegEx.new()
		re.compile("^[a-z0-9][a-z0-9-]{0,63}$")
		if re.search(id) == null:
			errs.append("bad id")
	if typeof(f["name"]) != TYPE_STRING or f["name"].strip_edges().is_empty() or f["name"].length() > 64:
		errs.append("bad name")
	if not (f["rarity"] in RARITIES):
		errs.append("bad rarity")
	if typeof(f["fruit_type"]) != TYPE_STRING:
		errs.append("bad fruit_type")
	if not (f["market_trend"] in TRENDS):
		errs.append("bad market_trend")
	if not (f["confidence_status"] in STATUSES):
		errs.append("bad confidence_status")
	if not _valid_amount(f["physical_value"], false):
		errs.append("physical_value must be a non-negative whole number")
	for k in ["permanent_value", "beli_price", "robux_price"]:
		if not _valid_amount(f[k], true):
			errs.append(k + " must be null or a non-negative whole number")
	for k in ["physical_demand", "permanent_demand"]:
		var d = f[k]
		if d != null and not (_is_num(d) and float(d) >= 0.0 and float(d) <= 10.0 and float(d) == floorf(float(d))):
			errs.append(k + " must be null or 0..10")
	if f["image"] != null and not (typeof(f["image"]) == TYPE_STRING and f["image"].begins_with("https://")):
		errs.append("image must be https or null")
	if typeof(f["last_updated"]) != TYPE_STRING and f["last_updated"] != null:
		errs.append("bad last_updated")
	if typeof(f["source"]) != TYPE_STRING:
		errs.append("bad source")
	if not errs.is_empty():
		return {"errors": errs, "clean": {}}
	var flags: Array = []
	if f.has("flags") and typeof(f["flags"]) == TYPE_ARRAY:
		for x in f["flags"]:
			flags.append(str(x))
	return {"errors": [], "clean": {
		"id": id, "name": f["name"].strip_edges(), "image": f["image"], "rarity": f["rarity"],
		"fruit_type": f["fruit_type"], "physical_value": int(f["physical_value"]),
		"permanent_value": _opt_int(f["permanent_value"]),
		"physical_demand": _opt_int(f["physical_demand"]), "permanent_demand": _opt_int(f["permanent_demand"]),
		"beli_price": _opt_int(f["beli_price"]), "robux_price": _opt_int(f["robux_price"]),
		"market_trend": f["market_trend"], "last_updated": f["last_updated"], "source": f["source"],
		"confidence_status": f["confidence_status"], "flags": flags}}

## Returns {"ok": bool, "errors": Array, "snapshot": Dictionary}
static func validate_snapshot(d) -> Dictionary:
	var errs: Array = []
	if typeof(d) != TYPE_DICTIONARY:
		return _fail("snapshot is not an object")
	if not _is_num(d.get("schema_version")) or int(d.get("schema_version")) != SCHEMA_VERSION:
		return _fail("unsupported schema_version")
	var gen := parse_iso(d.get("generated_at"))
	if gen < 0:
		return _fail("bad generated_at")
	var arr = d.get("fruits")
	if typeof(arr) != TYPE_ARRAY or arr.is_empty():
		return _fail("fruits missing or empty")
	var clean: Array = []
	var seen := {}
	for f in arr:
		var r := validate_fruit(f)
		if not r.errors.is_empty():
			var fid = f.get("id", "?") if typeof(f) == TYPE_DICTIONARY else "?"
			errs.append("%s: %s" % [fid, ", ".join(r.errors)])
			continue
		if seen.has(r.clean["id"]):
			errs.append("duplicate id " + r.clean["id"])
			continue
		seen[r.clean["id"]] = true
		clean.append(r.clean)
	var conflicts: Array = []
	var cf = d.get("conflicts", [])
	if typeof(cf) != TYPE_ARRAY:
		errs.append("conflicts is not a list")
	else:
		for c in cf:
			if typeof(c) == TYPE_DICTIONARY and c.has("id") and c.has("field") and typeof(c.get("values")) == TYPE_DICTIONARY:
				conflicts.append(c)
			else:
				errs.append("malformed conflict entry")
	var sources: Array = d["sources"] if typeof(d.get("sources")) == TYPE_ARRAY else []
	var review: Array = d["review"] if typeof(d.get("review")) == TYPE_ARRAY else []
	if not errs.is_empty():
		return {"ok": false, "errors": errs, "snapshot": {}}
	return {"ok": true, "errors": [], "snapshot": {
		"schema_version": SCHEMA_VERSION, "generated_at": d["generated_at"], "generated_unix": gen,
		"data_freshness": str(d.get("data_freshness", "periodic_snapshot")),
		"freshness_note": str(d.get("freshness_note", "")),
		"sources": sources, "conflicts": conflicts, "review": review, "fruits": clean}}

static func parse_snapshot_text(text: String) -> Dictionary:
	if text.is_empty() or text.to_utf8_buffer().size() > MAX_BYTES:
		return _fail("empty or oversized response")
	var json := JSON.new()
	if json.parse(text) != OK:
		return _fail("malformed JSON (line %d): %s" % [json.get_error_line(), json.get_error_message()])
	return validate_snapshot(json.data)

static func _fail(msg: String) -> Dictionary:
	return {"ok": false, "errors": [msg], "snapshot": {}}

static func count_is_sane(new_count: int, old_count: int) -> bool:
	return old_count == 0 or float(new_count) >= float(old_count) * MIN_COUNT_RATIO

static func pct_change(old_v, new_v):
	if old_v == null or new_v == null or float(old_v) == 0.0:
		return null
	return (float(new_v) - float(old_v)) / float(old_v) * 100.0

## Marks records whose value moved >= pct versus the previous accepted data. The new value is
## kept (the market may really have moved) but the record is flagged for review.
static func flag_large_changes(new_by_id: Dictionary, old_by_id: Dictionary, pct := LARGE_CHANGE_PCT) -> Array:
	var flagged: Array = []
	for id in new_by_id:
		if not old_by_id.has(id):
			continue
		var n: Dictionary = new_by_id[id]
		for field in ["physical_value", "permanent_value"]:
			var p = pct_change(old_by_id[id].get(field), n.get(field))
			if p != null and absf(p) >= pct:
				var tag := "large_change:%s:%.1f%%" % [field, p]
				if not n["flags"].has(tag):
					n["flags"].append(tag)
				if n["confidence_status"] != "conflict":
					n["confidence_status"] = "needs_review"
				if not flagged.has(id):
					flagged.append(id)
	return flagged

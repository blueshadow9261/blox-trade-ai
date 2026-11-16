extends Node
## Persistent history: change events (newest first) and per-fruit value series (changes only).

const PATH := "user://market_history.json"
const MAX_EVENTS := 1000
const MAX_POINTS := 240

var events: Array = []
var series: Dictionary = {}     # id -> [[unix, physical, permanent, demand], ...]

func _ready() -> void:
	if not FileAccess.file_exists(PATH):
		return
	var d = JSON.parse_string(FileAccess.get_file_as_string(PATH))
	if typeof(d) == TYPE_DICTIONARY:
		if typeof(d.get("events")) == TYPE_ARRAY:
			events = d["events"]
		if typeof(d.get("series")) == TYPE_DICTIONARY:
			series = d["series"]

func _same(a, b) -> bool:
	if a == null or b == null:
		return a == null and b == null
	return float(a) == float(b)

func record(new_by_id: Dictionary, diff: Dictionary, ts: int) -> void:
	if not diff.get("is_first_load", false):
		events = MarketDiff.to_events(diff, ts) + events
		if events.size() > MAX_EVENTS:
			events.resize(MAX_EVENTS)
	for id in new_by_id:
		var f: Dictionary = new_by_id[id]
		var pt := [ts, f["physical_value"], f["permanent_value"], f["physical_demand"]]
		var s: Array = series.get(id, [])
		var last = s[-1] if not s.is_empty() else null
		if last == null or not (_same(last[1], pt[1]) and _same(last[2], pt[2]) and _same(last[3], pt[3])):
			s.append(pt)
			if s.size() > MAX_POINTS:
				s = s.slice(s.size() - MAX_POINTS)
			series[id] = s
	_save()

func _save() -> void:
	var f := FileAccess.open(PATH, FileAccess.WRITE)
	if f == null:
		push_warning("Cannot write market history")
		return
	f.store_string(JSON.stringify({"events": events, "series": series}))
	f.close()

func recent_events(limit := 50, types: Array = []) -> Array:
	var out: Array = []
	for e in events:
		if types.is_empty() or e.get("type") in types:
			out.append(e)
			if out.size() >= limit:
				break
	return out

## Most recent value-change event for a fruit/field, or {} if none recorded.
func last_value_change(id: String, field := "physical_value") -> Dictionary:
	for e in events:
		if e.get("type") == "value" and e.get("id") == id and e.get("field") == field:
			return e
	return {}

## Biggest movers since `since_unix`, by absolute percent change. direction: "up" | "down".
func movers(since_unix: int, direction: String, limit := 5) -> Array:
	var out: Array = []
	for e in events:
		if e.get("type") != "value" or e.get("field") != "physical_value" or e.get("pct") == null:
			continue
		if int(e.get("t", 0)) < since_unix:
			continue
		if (direction == "up" and float(e["pct"]) > 0.0) or (direction == "down" and float(e["pct"]) < 0.0):
			out.append(e)
	out.sort_custom(func(a, b): return absf(float(a["pct"])) > absf(float(b["pct"])))
	return out.slice(0, limit)

func series_for(id: String) -> Array:
	return series.get(id, [])

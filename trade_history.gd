extends Node

var entries: Array = []
const PATH := "user://history.json"

func _ready() -> void:
	if FileAccess.file_exists(PATH):
		var d = JSON.parse_string(FileAccess.get_file_as_string(PATH))
		if d is Array:
			entries = d

func _ref(i: Dictionary) -> Dictionary:
	return {"id": i.get("id", ""), "variant": i.get("variant", "physical"), "name": i["name"], "value": i.get("value")}

func add(mine: Array, theirs: Array, r: Dictionary) -> void:
	entries.push_front({
		"time": Time.get_datetime_string_from_system(),
		"mine": mine.map(func(i): return i["name"]),
		"theirs": theirs.map(func(i): return i["name"]),
		"mine_items": mine.map(_ref), "their_items": theirs.map(_ref),
		"mine_total": r.mine, "their_total": r.theirs,
		"result": TradeEngine.label(r.result),
		"market_version": ItemDB.data_version})
	_save()

## Re-evaluates a saved trade with today's market values. Returns {} for entries saved before
## item ids were recorded, or when an item is no longer listed.
func reevaluate(e: Dictionary, threshold_pct := 5.0) -> Dictionary:
	if not e.has("mine_items") or not e.has("their_items"):
		return {}
	var now_mine: Array = []
	var now_theirs: Array = []
	for pair in [[e["mine_items"], now_mine], [e["their_items"], now_theirs]]:
		for ref in pair[0]:
			var it: Dictionary = ItemDB.get_item(str(ref.get("id", "")), str(ref.get("variant", "physical")))
			if it.is_empty():
				return {"missing": ref.get("name", "?")}
			pair[1].append(it)
	var r := TradeEngine.evaluate(now_mine, now_theirs, threshold_pct)
	r["label"] = TradeEngine.label(r["result"])
	return r

func remove_at(i: int) -> void:
	if i >= 0 and i < entries.size():
		entries.remove_at(i)
		_save()

func _save() -> void:
	var f := FileAccess.open(PATH, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify(entries))
	f.close()

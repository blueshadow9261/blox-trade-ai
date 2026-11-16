extends Node
## Validated, cached fruit market data. The only writer is replace_all(), which is only ever
## called with a snapshot that already passed DataValidator.

signal database_changed

const CACHE_PATH := "user://market_cache.json"
const BAK_PATH := "user://market_cache.bak.json"
## Ids used by older versions of the app -> current ids.
const LEGACY_IDS := {"trex": "t-rex"}

var fruits: Dictionary = {}     # id -> clean record
var meta: Dictionary = {}       # generated_at, generated_unix, data_freshness, sources, conflicts, review

func _ready() -> void:
	_load_cache()

func _load_cache() -> void:
	for p in [CACHE_PATH, BAK_PATH]:
		if not FileAccess.file_exists(p):
			continue
		var parsed := DataValidator.parse_snapshot_text(FileAccess.get_file_as_string(p))
		if parsed["ok"]:
			_apply_snapshot(parsed["snapshot"])
			return
		push_warning("Ignoring invalid market cache %s: %s" % [p, parsed["errors"]])

func _apply_snapshot(snapshot: Dictionary) -> void:
	var by_id := {}
	for f in snapshot["fruits"]:
		by_id[f["id"]] = f
	fruits = by_id
	meta = {"generated_at": snapshot["generated_at"], "generated_unix": snapshot["generated_unix"],
		"data_freshness": snapshot["data_freshness"], "freshness_note": snapshot["freshness_note"],
		"sources": snapshot["sources"], "conflicts": snapshot["conflicts"], "review": snapshot["review"]}

## Atomically persists, then swaps in. Returns false (and changes nothing) if saving fails.
func replace_all(snapshot: Dictionary) -> bool:
	if not _save(snapshot):
		return false
	_apply_snapshot(snapshot)
	database_changed.emit()
	return true

func _save(snapshot: Dictionary) -> bool:
	var tmp := CACHE_PATH + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		push_warning("Cannot write market cache: %d" % FileAccess.get_open_error())
		return false
	f.store_string(JSON.stringify(snapshot))
	f.close()
	# verify what we wrote before it can replace a good cache
	if not DataValidator.parse_snapshot_text(FileAccess.get_file_as_string(tmp))["ok"]:
		DirAccess.remove_absolute(tmp)
		return false
	if FileAccess.file_exists(CACHE_PATH):
		DirAccess.copy_absolute(CACHE_PATH, BAK_PATH)
		DirAccess.remove_absolute(CACHE_PATH)
	return DirAccess.rename_absolute(tmp, CACHE_PATH) == OK

func has_data() -> bool:
	return not fruits.is_empty()

func generated_unix() -> int:
	return int(meta.get("generated_unix", 0))

func resolve_id(id: String) -> String:
	return str(LEGACY_IDS.get(id, id)) if not fruits.has(id) else id

func get_fruit(id: String) -> Dictionary:
	return fruits.get(resolve_id(id), {})

func search(query := "", rarity := "", sort := "value") -> Array:
	var q := query.strip_edges().to_lower()
	var out: Array = []
	for id in fruits:
		var f: Dictionary = fruits[id]
		if rarity != "" and f["rarity"] != rarity:
			continue
		if q != "" and not f["name"].to_lower().contains(q):
			continue
		out.append(f)
	match sort:
		"name": out.sort_custom(func(a, b): return a["name"] < b["name"])
		"demand": out.sort_custom(func(a, b): return _dem(a) > _dem(b))
		_: out.sort_custom(func(a, b): return a["physical_value"] > b["physical_value"])
	return out

func conflicts_for(id: String) -> Array:
	var out: Array = []
	for c in meta.get("conflicts", []):
		if c.get("id") == id:
			out.append(c)
	return out

## Calculator-ready item. variant: "physical" | "permanent". value is null when unknown.
func make_item(id: String, variant := "physical") -> Dictionary:
	var f := get_fruit(id)
	if f.is_empty():
		return {}
	var perm := variant == "permanent"
	return {"id": f["id"], "name": f["name"] + (" (Permanent)" if perm else ""), "base_name": f["name"],
		"variant": variant, "category": "fruit", "rarity": f["rarity"],
		"value": f["permanent_value"] if perm else f["physical_value"],
		"demand": f["permanent_demand"] if perm else f["physical_demand"],
		"trend": f["market_trend"], "updated": f["last_updated"], "status": f["confidence_status"],
		"source": f["source"]}

static func _dem(f: Dictionary) -> int:
	var d = f.get("physical_demand")
	if d == null:
		return -1
	return int(d)

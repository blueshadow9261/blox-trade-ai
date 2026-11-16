extends Node
## Item database used by the calculator and lists.
## With market data (FruitDatabase) items come from the validated feed. Without it the app falls
## back to the names-only list and any manual values; manual values are ignored for fruits the
## market feed covers so a stale manual number can never override live data.

var items: Dictionary = {}
var data_version := "none"
var data_source := "none"
var favorites: Array = []
var overrides := {"version": "none", "source": "none", "values": {}}
var _base_items: Dictionary = {}

func _ready() -> void:
	_load_base()
	_load_overrides()
	var f = _read_json("user://favorites.json")
	if f is Array:
		for id in f:
			var rid: String = FruitDatabase.resolve_id(str(id))
			if not favorites.has(rid):
				favorites.append(rid)
	FruitDatabase.database_changed.connect(_rebuild)
	_rebuild()

func _read_json(path: String):
	if not FileAccess.file_exists(path):
		return null
	return JSON.parse_string(FileAccess.get_file_as_string(path))

func _load_base() -> void:
	var d = _read_json("res://data/items.json")
	if d is Dictionary:
		for it in d.get("items", []):
			_base_items[it["id"]] = it

func _load_overrides() -> void:
	var o = _read_json("user://values.json")
	if o is Dictionary:
		overrides = o

func using_market_data() -> bool:
	return FruitDatabase.has_data()

func _rebuild() -> void:
	items = {}
	if FruitDatabase.has_data():
		for id in FruitDatabase.fruits:
			items[id] = FruitDatabase.make_item(id, "physical")
		data_version = str(FruitDatabase.meta.get("generated_at", "unknown"))
		var names: Array = []
		for s in FruitDatabase.meta.get("sources", []):
			names.append(str(s.get("name", "?")))
		data_source = ", ".join(names) + " (periodic community snapshot)"
		return
	for id in _base_items:
		items[id] = _base_items[id].duplicate()
	data_version = str(overrides.get("version", "none"))
	data_source = str(overrides.get("source", "none"))
	for id in overrides.get("values", {}):
		if items.has(id):
			items[id].merge(overrides["values"][id], true)

## variant: "physical" | "permanent" (permanent only exists in market data).
func get_item(id: String, variant := "physical") -> Dictionary:
	if FruitDatabase.has_data():
		return FruitDatabase.make_item(id, variant)
	return items.get(id, {}).duplicate()

func search(q: String, fav_only := false) -> Array:
	var out: Array = []
	for id in items:
		var it: Dictionary = items[id]
		if fav_only and not favorites.has(id):
			continue
		if q.strip_edges() == "" or it["name"].to_lower().contains(q.strip_edges().to_lower()):
			out.append(it)
	out.sort_custom(func(a, b): return a["name"] < b["name"])
	return out

func set_value(id: String, value: float, demand = null) -> void:
	if using_market_data() or not items.has(id):
		return
	var e := {"value": value, "updated": Time.get_date_string_from_system(), "source": "manual"}
	if demand != null:
		e["demand"] = demand
	overrides["values"][id] = e
	overrides["version"] = "manual-" + Time.get_datetime_string_from_system()
	overrides["source"] = "manual / imported"
	items[id].merge(e, true)
	data_version = overrides["version"]
	data_source = overrides["source"]
	_save_overrides()

## Expected JSON: {"version":"...","source":"...","values":{"kitsune":{"value":123,"demand":"high","updated":"2026-11-15"}}}
## Only used when no market feed data exists.
func import_values(text: String) -> String:
	if using_market_data():
		return "Manual import is disabled while live market data is available."
	var d = JSON.parse_string(text)
	if not (d is Dictionary) or not (d.get("values") is Dictionary):
		return "Invalid format: expected an object with a 'values' object."
	var n := 0
	for id in d["values"]:
		var e = d["values"][id]
		if not items.has(id) or not (e is Dictionary) or not (e.get("value") is float or e.get("value") is int):
			continue
		if float(e["value"]) < 0.0:
			continue
		overrides["values"][id] = e
		items[id].merge(e, true)
		n += 1
	overrides["version"] = str(d.get("version", "imported-" + Time.get_datetime_string_from_system()))
	overrides["source"] = str(d.get("source", "imported"))
	data_version = overrides["version"]
	data_source = overrides["source"]
	_save_overrides()
	return "" if n > 0 else "No valid entries matched known item ids."

func toggle_favorite(id: String) -> void:
	if favorites.has(id):
		favorites.erase(id)
	else:
		favorites.append(id)
	var f := FileAccess.open("user://favorites.json", FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(favorites))
		f.close()

func _save_overrides() -> void:
	var f := FileAccess.open("user://values.json", FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(overrides))
		f.close()

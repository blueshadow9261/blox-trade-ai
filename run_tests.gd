extends SceneTree
## Run: godot --headless -s tests/run_tests.gd

var fails := 0

func check(name: String, cond: bool) -> void:
	if not cond:
		fails += 1
		print("FAIL: ", name)

func _init() -> void:
	var a := {"name": "A", "value": 100.0}
	var b := {"name": "B", "value": 104.0}
	var c := {"name": "C", "value": 150.0}
	var n := {"name": "N", "value": null}
	check("equal fair", TradeEngine.evaluate([a], [a]).result == TradeEngine.Result.FAIR)
	check("within threshold fair", TradeEngine.evaluate([a], [b]).result == TradeEngine.Result.FAIR)
	check("win", TradeEngine.evaluate([a], [c]).result == TradeEngine.Result.WIN)
	check("loss", TradeEngine.evaluate([c], [a]).result == TradeEngine.Result.LOSS)
	check("threshold adjustable", TradeEngine.evaluate([a], [b], 1.0).result == TradeEngine.Result.WIN)
	check("empty unknown", TradeEngine.evaluate([], []).result == TradeEngine.Result.UNKNOWN)
	check("missing unknown", TradeEngine.evaluate([a], [n]).result == TradeEngine.Result.UNKNOWN)
	check("duplicates sum", TradeEngine.evaluate([a, a], [c]).mine == 200.0)
	check("large values", TradeEngine.evaluate([{"value": 1e12}], [{"value": 1e12}]).result == TradeEngine.Result.FAIR)
	check("pct", is_equal_approx(TradeEngine.evaluate([a], [c]).pct, 50.0))

	_test_market()
	print("Tests done, failures: ", fails)
	quit(1 if fails > 0 else 0)

func _fruit(id: String, over := {}) -> Dictionary:
	var f := {"id": id, "name": id.capitalize(), "image": "https://example.test/x.webp", "rarity": "rare",
		"fruit_type": "natural", "physical_value": 100, "permanent_value": null, "physical_demand": 5,
		"permanent_demand": null, "beli_price": 50, "robux_price": null, "market_trend": "stable",
		"last_updated": "2026-11-05", "source": "test", "confidence_status": "verified"}
	f.merge(over, true)
	return f

func _snap(fruits: Array) -> Dictionary:
	return {"schema_version": 1, "generated_at": "2026-11-15T10:00:00Z", "fruits": fruits}

func _test_market() -> void:
	# NOTE: synthetic fixtures for logic tests only; they are never shipped as market data.
	var ok := DataValidator.validate_snapshot(_snap([_fruit("a"), _fruit("b")]))
	check("valid snapshot accepted", ok.ok)
	check("null permanent kept as null", ok.snapshot.fruits[0]["permanent_value"] == null)
	check("generated_unix parsed", ok.snapshot.generated_unix > 0)
	check("negative physical rejected", not DataValidator.validate_snapshot(_snap([_fruit("a", {"physical_value": -1})])).ok)
	check("negative permanent rejected", not DataValidator.validate_snapshot(_snap([_fruit("a", {"permanent_value": -5})])).ok)
	check("null physical rejected", not DataValidator.validate_snapshot(_snap([_fruit("a", {"physical_value": null})])).ok)
	check("bool value rejected", not DataValidator.validate_snapshot(_snap([_fruit("a", {"physical_value": true})])).ok)
	check("fraction rejected", not DataValidator.validate_snapshot(_snap([_fruit("a", {"physical_value": 1.5})])).ok)
	check("string value rejected", not DataValidator.validate_snapshot(_snap([_fruit("a", {"physical_value": "100"})])).ok)
	check("demand out of range rejected", not DataValidator.validate_snapshot(_snap([_fruit("a", {"physical_demand": 11})])).ok)
	check("bad rarity rejected", not DataValidator.validate_snapshot(_snap([_fruit("a", {"rarity": "epic"})])).ok)
	check("http image rejected", not DataValidator.validate_snapshot(_snap([_fruit("a", {"image": "http://x/y.webp"})])).ok)
	check("duplicate id rejected", not DataValidator.validate_snapshot(_snap([_fruit("a"), _fruit("a")])).ok)
	check("empty fruits rejected", not DataValidator.validate_snapshot(_snap([])).ok)
	var missing := _fruit("a")
	missing.erase("rarity")
	check("missing field rejected", not DataValidator.validate_snapshot(_snap([missing])).ok)
	var bad_schema := _snap([_fruit("a")])
	bad_schema["schema_version"] = 99
	check("unknown schema rejected", not DataValidator.validate_snapshot(bad_schema).ok)
	check("malformed JSON rejected", not DataValidator.parse_snapshot_text("{\"fruits\": [").ok)
	check("non-object JSON rejected", not DataValidator.parse_snapshot_text("[1,2,3]").ok)
	check("empty text rejected", not DataValidator.parse_snapshot_text("").ok)
	check("good JSON text accepted", DataValidator.parse_snapshot_text(JSON.stringify(_snap([_fruit("a")]))).ok)
	check("count sanity", DataValidator.count_is_sane(40, 43) and not DataValidator.count_is_sane(10, 43) and DataValidator.count_is_sane(5, 0))

	# change detection
	var old := {"a": _fruit("a"), "gone": _fruit("gone"), "r": _fruit("r", {"name": "Old"}), "oldid": _fruit("oldid", {"name": "T-Rex"})}
	var nw := {"a": _fruit("a", {"physical_value": 300, "physical_demand": 8, "market_trend": "rising"}),
		"new": _fruit("new"), "r": _fruit("r", {"name": "Renamed"}), "newid": _fruit("newid", {"name": "TRex"})}
	var flagged := DataValidator.flag_large_changes(nw, old)
	check("large change flagged", flagged == ["a"] and nw["a"]["confidence_status"] == "needs_review")
	var d := MarketDiff.compute(old, nw)
	check("added detected", d.added.size() == 1 and d.added[0]["id"] == "new")
	check("removed detected", d.removed.size() == 1 and d.removed[0]["id"] == "gone")
	check("renamed detected incl. id change", d.renamed.size() == 2)
	check("value change detected", d.value_changes.size() == 1 and absf(d.value_changes[0]["pct"] - 200.0) < 0.01)
	check("demand change detected", d.demand_changes.size() == 1)
	check("trend change detected", d.trend_changes.size() == 1)
	check("review listed", d.review == ["a"])
	check("identical snapshots are empty diff", MarketDiff.compute(old, old).empty)
	check("first load flagged", MarketDiff.compute({}, nw).is_first_load)
	check("events generated", MarketDiff.to_events(d, 1).size() >= 6)

	# formatting + engine warnings
	check("compact B", MarketFormat.compact(2750000000) == "2.75B")
	check("compact M", MarketFormat.compact(450000000) == "450M")
	check("compact null", MarketFormat.compact(null) == "n/a")
	var w := TradeEngine.warnings([{"name": "X", "status": "conflict"}, {"name": "Y", "status": "needs_review"}, {"name": "Z", "status": "verified"}])
	check("engine warnings", w.size() == 2)
	var r := TradeEngine.evaluate([{"name": "P", "value": 100.0, "status": "verified"}], [{"name": "Q (Permanent)", "value": null, "variant": "permanent"}])
	check("null permanent -> no verdict", r.result == TradeEngine.Result.UNKNOWN)

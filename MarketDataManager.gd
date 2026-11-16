extends Node
## Orchestrates market sync: refresh on launch, every 15 min while the app is in the foreground,
## on resume if stale, and on manual request. Fail-closed: a failed/invalid response never
## touches the cached data.

signal refresh_started(manual: bool)
signal refresh_finished(success: bool, summary: Dictionary)
signal market_updated(diff: Dictionary)
signal sync_state_changed(state: String)
signal offline_mode_changed(offline: bool)

const STATE_PATH := "user://market_state.cfg"
const REFRESH_INTERVAL := 900.0          # 15 minutes
const MANUAL_COOLDOWN := 5
const BG_SYNC_MINUTES := 60              # WorkManager periodic interval (Android minimum is 15)

var state := "idle"                      # idle | syncing | ok | offline | error | not_configured
var offline := false
var last_success_unix := 0               # last time the feed was successfully fetched and verified
var last_attempt_unix := 0
var last_error := ""
var etag := ""
var bg_sync_enabled := false

var _busy := false
var _timer: Timer
var _cfg := ConfigFile.new()

func feed_url() -> String:
	return str(ProjectSettings.get_setting("blox/market/feed_url", "")).strip_edges()

func _ready() -> void:
	_load_state()
	_timer = Timer.new()
	_timer.wait_time = REFRESH_INTERVAL
	_timer.one_shot = false
	_timer.timeout.connect(func(): refresh(false))
	add_child(_timer)
	_ingest_background_snapshot()
	_apply_bg_schedule()
	_timer.start()
	refresh.call_deferred(false)

func _notification(what: int) -> void:
	if _timer == null:
		return
	match what:
		NOTIFICATION_APPLICATION_PAUSED:
			_timer.stop()                # no foreground polling while the app is backgrounded
		NOTIFICATION_APPLICATION_RESUMED:
			_timer.start()
			_ingest_background_snapshot()
			if is_stale():
				refresh(false)

func is_stale() -> bool:
	return int(Time.get_unix_time_from_system()) - last_success_unix >= int(REFRESH_INTERVAL)

func is_busy() -> bool:
	return _busy

func refresh(manual := false) -> void:
	if _busy:
		return
	var now := int(Time.get_unix_time_from_system())
	if manual and now - last_attempt_unix < MANUAL_COOLDOWN:
		return
	var url := feed_url()
	if url == "":
		last_error = "No data feed configured (project setting blox/market/feed_url)."
		_set_state("not_configured")
		refresh_finished.emit(false, {"ok": false, "error": last_error})
		return
	_busy = true
	last_attempt_unix = now
	_set_state("syncing")
	refresh_started.emit(manual)
	var r: Dictionary = await APIManager.get_text(url, etag if FruitDatabase.has_data() else "", 1 if manual else 0)
	var summary := _handle(r)
	_busy = false
	_save_state()
	refresh_finished.emit(summary["ok"], summary)

func _handle(r: Dictionary) -> Dictionary:
	if r["status"] == "not_modified":
		_mark_success()
		return {"ok": true, "unchanged": true}
	if r["status"] != "ok":
		var is_net: bool = r["status"] in ["network", "timeout"]
		_set_offline(is_net)
		return _fail(r["message"], "offline" if is_net else "error")
	_set_offline(false)
	var parsed := DataValidator.parse_snapshot_text(r["body"])
	if not parsed["ok"]:
		return _fail("Rejected invalid data: " + "; ".join(parsed["errors"].slice(0, 3)), "error")
	var res := apply_snapshot(parsed["snapshot"])
	if res["ok"]:
		etag = r["etag"]
		_mark_success()
	else:
		last_error = res["error"]
		_set_state("error")
	return res

## Shared by network and background-sync paths. The snapshot must already be validated.
func apply_snapshot(snap: Dictionary) -> Dictionary:
	var old: Dictionary = FruitDatabase.fruits
	if FruitDatabase.has_data() and int(snap["generated_unix"]) < FruitDatabase.generated_unix():
		return {"ok": true, "unchanged": true, "note": "Older snapshot ignored."}
	if not DataValidator.count_is_sane(snap["fruits"].size(), old.size()):
		return {"ok": false, "error": "Rejected: fruit count dropped from %d to %d (possible partial data)." % [old.size(), snap["fruits"].size()]}
	var new_by_id := {}
	for f in snap["fruits"]:
		new_by_id[f["id"]] = f
	DataValidator.flag_large_changes(new_by_id, old)
	var diff := MarketDiff.compute(old, new_by_id)
	snap["review"] = diff["review"]
	if not FruitDatabase.replace_all(snap):
		return {"ok": false, "error": "Could not save data; previous data kept."}
	MarketHistory.record(new_by_id, diff, int(Time.get_unix_time_from_system()))
	if diff["is_first_load"] or not diff["empty"]:
		market_updated.emit(diff)
	return {"ok": true, "unchanged": false, "diff": diff}

func _fail(msg: String, st: String) -> Dictionary:
	last_error = msg
	_set_state(st)
	return {"ok": false, "error": msg}

func _mark_success() -> void:
	last_success_unix = int(Time.get_unix_time_from_system())
	last_error = ""
	_set_state("ok")

func _set_state(s: String) -> void:
	if s != state:
		state = s
		sync_state_changed.emit(s)

func _set_offline(v: bool) -> void:
	if v != offline:
		offline = v
		offline_mode_changed.emit(v)

# ---- display helpers -------------------------------------------------------------------------

func last_sync_text() -> String:
	if last_success_unix <= 0:
		return "Not synced yet"
	return "Last successful sync: %s" % MarketFormat.ago(last_success_unix)

func freshness_label() -> String:
	if not FruitDatabase.has_data():
		return "no market data"
	return "snapshot collected %s" % MarketFormat.ago(FruitDatabase.generated_unix())

func status_text() -> String:
	var parts: Array = []
	if state == "not_configured":
		return "Market feed not configured. " + last_error
	parts.append(last_sync_text())
	if FruitDatabase.has_data():
		parts.append("Data " + freshness_label())
	if offline:
		parts.append("OFFLINE - showing saved data")
	elif state == "error":
		parts.append("Last update failed: " + last_error)
	return "\n".join(parts)

# ---- persistence -------------------------------------------------------------------------------

func _load_state() -> void:
	if _cfg.load(STATE_PATH) != OK:
		return
	last_success_unix = int(_cfg.get_value("sync", "last_success_unix", 0))
	etag = str(_cfg.get_value("sync", "etag", ""))
	bg_sync_enabled = bool(_cfg.get_value("sync", "bg_sync_enabled", false))
	# A stored etag is only valid together with stored data.
	if not FruitDatabase.has_data():
		etag = ""

func _save_state() -> void:
	_cfg.set_value("sync", "last_success_unix", last_success_unix)
	_cfg.set_value("sync", "etag", etag)
	_cfg.set_value("sync", "bg_sync_enabled", bg_sync_enabled)
	_cfg.save(STATE_PATH)

# ---- Android background sync (WorkManager, via the BloxCapture plugin) ------------------------

func background_sync_available() -> bool:
	return Engine.has_singleton("BloxCapture") and feed_url() != ""

func set_background_sync(enabled: bool) -> void:
	bg_sync_enabled = enabled
	_save_state()
	_apply_bg_schedule()

func _apply_bg_schedule() -> void:
	if not background_sync_available():
		return
	var p = Engine.get_singleton("BloxCapture")
	if bg_sync_enabled:
		p.scheduleMarketSync(feed_url(), BG_SYNC_MINUTES)
	else:
		p.cancelMarketSync()

## The worker only downloads; everything it saved is fully re-validated here before use.
func _ingest_background_snapshot() -> void:
	if not Engine.has_singleton("BloxCapture"):
		return
	var p = Engine.get_singleton("BloxCapture")
	var text: String = p.readMarketSnapshot()
	if text == "":
		return
	var parsed := DataValidator.parse_snapshot_text(text)
	if parsed["ok"]:
		apply_snapshot(parsed["snapshot"])
	p.clearMarketSnapshot()

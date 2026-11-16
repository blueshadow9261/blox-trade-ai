extends Node
## Bridge to the BloxCapture Android plugin. Does nothing off-Android.

signal status_changed(text: String)

var plugin = null
var frame_count := 0

func _ready() -> void:
	MarketDataManager.refresh_finished.connect(func(_ok, _s): _push_overlay())
	if Engine.has_singleton("BloxCapture"):
		plugin = Engine.get_singleton("BloxCapture")
		plugin.connect("capture_status", _on_status)
		plugin.connect("frame_ready", _on_frame)

## Overlay text always states how old the values are; it never claims data is live.
func _push_overlay() -> void:
	if plugin != null and plugin.isCapturing():
		plugin.setOverlay("Blox Trade AI", "Capturing. Recognition is not set up, so no verdict. Values: %s." % MarketDataManager.freshness_label(), "#C0C8D0")

func available() -> bool:
	return plugin != null

func start() -> void:
	if plugin == null:
		status_changed.emit("Capture plugin not available (Android build only).")
		return
	if not plugin.hasOverlayPermission():
		plugin.requestOverlayPermission()
		status_changed.emit("Allow 'display over other apps', come back, then press Start again.")
		return
	plugin.requestNotificationPermission()
	frame_count = 0
	plugin.requestCapture(50, 500, 3)

func stop() -> void:
	if plugin != null:
		plugin.stopCapture()

func _on_status(s: String) -> void:
	match s:
		"started":
			_push_overlay()
			status_changed.emit("Capturing.")
		"permission_denied":
			status_changed.emit("Screen capture permission denied. Nothing is captured.")
		"stopped_by_system":
			status_changed.emit("ANALYSIS PAUSED: Android ended screen capture.")
		"stopped":
			status_changed.emit("Stopped.")
		_:
			status_changed.emit(s)

func _on_frame(path: String) -> void:
	frame_count += 1
	var img := Image.load_from_file(path)
	var sz := "?" if img == null else "%dx%d" % [img.get_width(), img.get_height()]
	status_changed.emit("Capturing. Changed frames: %d (%s). Recognition not set up." % [frame_count, sz])
	# TODO next stage: crop trade window, run recognizer, evaluate with TradeEngine, call plugin.setOverlay().

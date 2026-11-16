@tool
extends EditorExportPlugin

func _get_name() -> String:
	return "BloxCapture"

func _supports_platform(platform: EditorExportPlatform) -> bool:
	return platform is EditorExportPlatformAndroid

func _get_android_libraries(platform: EditorExportPlatform, debug: bool) -> PackedStringArray:
	if debug:
		return PackedStringArray(["res://addons/bloxcapture/bin/debug/BloxCapture-debug.aar"])
	return PackedStringArray(["res://addons/bloxcapture/bin/release/BloxCapture-release.aar"])

func _get_android_dependencies(platform: EditorExportPlatform, debug: bool) -> PackedStringArray:
	return PackedStringArray(["org.jetbrains.kotlin:kotlin-stdlib:1.9.24"])

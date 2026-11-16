@tool
extends EditorPlugin

const Exporter = preload("res://addons/bloxcapture/export_plugin.gd")
var exporter

func _enter_tree() -> void:
	exporter = Exporter.new()
	add_export_plugin(exporter)

func _exit_tree() -> void:
	remove_export_plugin(exporter)
	exporter = null

@tool
extends EditorPlugin

## Editor entry point for dot-weather. Registers the node type only.
##
## No autoloads: a client drawing weather and a server that only runs its schedule are two
## nodes in one process, and a global would make them one.


func _enter_tree() -> void:
	add_custom_type("DotWeather", "Node3D", load("res://addons/dot_weather/runtime/dot_weather.gd"), null)


func _exit_tree() -> void:
	remove_custom_type("DotWeather")

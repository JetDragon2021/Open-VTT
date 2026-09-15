# Attach this script to a Button node added to the map.tscn toolbar.
# The button instantiates and shows the BridgePanel window when pressed.
#
# EDITOR STEP (T018):
#   1. Open scenes/map.tscn in the Godot editor
#   2. Find the existing toolbar/HBoxContainer in the UI
#   3. Add a new Button node, set Text = "🔗 Bridge"
#   4. Attach this script to that Button node
#   5. Save the scene

extends Button

const BridgePanelScene = preload("res://components/bridge_panel.tscn")

var _panel: Window = null


func _ready() -> void:
	text = "🔗 Bridge"
	pressed.connect(_on_pressed)


func _on_pressed() -> void:
	if _panel == null or not is_instance_valid(_panel):
		_panel = BridgePanelScene.instantiate()
		get_tree().root.add_child(_panel)
	_panel.show()
	_panel.grab_focus()

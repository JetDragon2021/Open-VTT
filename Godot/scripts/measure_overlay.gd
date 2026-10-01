# Shows sizes in the map's units: beside a rectangle or circle while it's being
# drawn, and above whatever is selected ("15 × 10 ft", "⌀ 20 ft"). It reads the
# drawing state each frame, so every way of drawing, selecting or resizing keeps
# it current without hooks scattered through draw.gd.

extends Node2D

var _label: Label
@onready var _draw: Node2D = get_parent()


func _ready() -> void:
	z_as_relative = false
	z_index = RenderingServer.CANVAS_ITEM_Z_MAX
	_label = MapMeasure.make_label(_draw.unshaded_material)
	_label.visible = false
	add_child(_label)


func _process(_delta: float) -> void:
	var reading := _reading()
	_label.visible = not reading.is_empty()
	if reading.is_empty():
		return
	_label.text = reading[0]
	MapMeasure.scale_label(_label)
	_label.position = reading[1]


# [text, where] — or [] when there's nothing to measure.
func _reading() -> Array:
	var zoom: float = Globals.camera.zoom.x if Globals.camera != null else 1.0
	var drawing: bool = _draw.pressed and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
	var beside_cursor: Vector2 = _draw.mouse_pos + Vector2(18, 18) / zoom

	if drawing and Globals.tool == "rect" and is_instance_valid(_draw.current_panel):
		return [MapMeasure.size_text(_draw.current_panel.size), beside_cursor]
	if drawing and Globals.tool == "circle" and is_instance_valid(_draw.current_ellipse):
		return [MapMeasure.size_text(_draw.current_ellipse.size, true), beside_cursor]

	if Globals.tool != "select" or not is_instance_valid(_draw.select_box):
		return []
	var picked: Array = _draw.selected.filter(func(o): return is_instance_valid(o))
	if picked.is_empty():
		return []
	var text: String
	if picked.size() == 1:
		var s = picked[0]
		if s.get_meta("type", "") == "text":
			return []
		text = MapMeasure.size_text(s.size * s.scale, s.get_meta("type", "") == "circle")
	else:
		text = MapMeasure.size_text(_draw.select_box.size)
	# Just above the selection's top-left corner, clear of the rotate handle.
	var lift: float = (_label.get_combined_minimum_size().y + 6.0) / zoom
	return [text, _draw.select_box.global_position - Vector2(0, lift)]

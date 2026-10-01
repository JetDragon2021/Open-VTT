#Author: Vladimír Horák
#Desc:
#Script controlling Object settings tab in Toolpanel

extends MarginContainer

signal object_change(index, value)
	
# ========================= emiting signals on value changed ========================

#transform
func _on_pos_x_spin_box_value_changed(value):
	emit_signal("object_change", 0, value)
	
	
func _on_pos_y_spin_box_value_changed(value):
	emit_signal("object_change", 1, value)


func _on_size_x_spin_box_value_changed(value):
	emit_signal("object_change", 2, value)


func _on_size_y_spin_box_value_changed(value):
	emit_signal("object_change", 3, value)


func _on_scale_x_spin_box_value_changed(value):
	emit_signal("object_change", 4, value)


func _on_scale_y_spin_box_value_changed(value):
	emit_signal("object_change", 5, value)


func _on_rot_spin_box_value_changed(value):
	emit_signal("object_change", 6, value)

#light
func _on_cast_light_toggled(button_pressed):
	emit_signal("object_change", 10, button_pressed)
	
	
func _on_offset_x_spin_box_value_changed(value):
	emit_signal("object_change", 11, value)


func _on_offset_y_spin_box_value_changed(value):
	emit_signal("object_change", 12, value)


func _on_resolution_spin_box_value_changed(value):
	emit_signal("object_change", 13, value)


func _on_radius_spin_box_value_changed(value):
	emit_signal("object_change", 14, value)


func _on_color_picker_button_color_changed(color):
	emit_signal("object_change", 15, color)


func _on_energy_spin_box_value_changed(value):
	emit_signal("object_change", 16, value)
	
#shadows
func _on_cast_shadow_toggled(button_pressed):
	emit_signal("object_change", 20, button_pressed)


func _on_one_sided_toggled(button_pressed):
	emit_signal("object_change", 21, button_pressed)


func _on_flip_sides_toggled(button_pressed):
	emit_signal("object_change", 22, button_pressed)
	
# ============================== reading values =================================
#transform
func get_position_x():
	return $"ScrollContainer/VBoxContainer/CollapsibleContainer/Container/TransformContainer/Position X/PosXSpinBox".value
	
func get_position_y():
	return $"ScrollContainer/VBoxContainer/CollapsibleContainer/Container/TransformContainer/Position Y/PosYSpinBox".value
	
func get_size_x():
	return $"ScrollContainer/VBoxContainer/CollapsibleContainer/Container/TransformContainer/Size X/SizeXSpinBox".value
	
func get_size_y():
	return $"ScrollContainer/VBoxContainer/CollapsibleContainer/Container/TransformContainer/Size Y/SizeYSpinBox".value
	
func get_scale_x():
	return $"ScrollContainer/VBoxContainer/CollapsibleContainer/Container/TransformContainer/Scale X/ScaleXSpinBox".value
	
func get_scale_y():
	return $"ScrollContainer/VBoxContainer/CollapsibleContainer/Container/TransformContainer/Scale Y/ScaleYSpinBox".value
	
func get_rotation():
	return $ScrollContainer/VBoxContainer/CollapsibleContainer/Container/TransformContainer/Rotation/RotSpinBox.value
	
#light
func get_cast_light():
	return $ScrollContainer/VBoxContainer/CollapsibleContainer2/Container/LightContainer/CastLight.button_pressed
	
func get_light_offset_x():
	return $"ScrollContainer/VBoxContainer/CollapsibleContainer2/Container/LightContainer/Offset X/OffsetXSpinBox".value
	
func get_light_offset_y():
	return $"ScrollContainer/VBoxContainer/CollapsibleContainer2/Container/LightContainer/Offset Y/OffsetYSpinBox".value
	
func get_light_resolution():
	return $ScrollContainer/VBoxContainer/CollapsibleContainer2/Container/LightContainer/Resolution/ResolutionSpinBox.value
	
func get_light_radius():
	return $ScrollContainer/VBoxContainer/CollapsibleContainer2/Container/LightContainer/Radius/RadiusSpinBox.value
	
func get_light_color():
	return $ScrollContainer/VBoxContainer/CollapsibleContainer2/Container/LightContainer/Color/ColorPickerButton.color
	
func get_light_energy():
	return $ScrollContainer/VBoxContainer/CollapsibleContainer2/Container/LightContainer/Energy/EnergySpinBox.value
	
#shadow
func get_cast_shadow():
	return $ScrollContainer/VBoxContainer/CollapsibleContainer3/Container/ShadowContainer/CastShadow.button_pressed
	
func get_shadow_one_sided():
	return $ScrollContainer/VBoxContainer/CollapsibleContainer3/Container/ShadowContainer/OneSided.button_pressed
	
func get_shadow_flipped():
	return $ScrollContainer/VBoxContainer/CollapsibleContainer3/Container/ShadowContainer/FlipSides.button_pressed
	


# ============================ size in feet, live values ============================
# The transform fields only ever pushed values out — nothing filled them from the
# selection, so they never showed what was selected. Now they follow it, and a
# width and height in the map's units (ft) sit on top, which is how a GM thinks
# about a spell area or a room.

const TRANSFORM = "ScrollContainer/VBoxContainer/CollapsibleContainer/Container/TransformContainer"

var _width_units: SpinBox
var _height_units: SpinBox


func _ready() -> void:
	var transform := get_node(TRANSFORM)
	_width_units = _units_row(transform, "Width", 0)
	_height_units = _units_row(transform, "Height", 1)
	_width_units.value_changed.connect(_on_units_changed.bind(0))
	_height_units.value_changed.connect(_on_units_changed.bind(1))
	for row in ["Size X", "Size Y"]:
		var label: Label = transform.get_node(row + "/Label")
		label.text = row + " (px):"
		label.tooltip_text = "Size before scaling, in pixels. Width and Height above are the size on the map."
	# Its label had a stray line break, which made the row twice as tall.
	transform.get_node("Scale X/Label").text = "Scale X:"


func _units_row(parent: Node, label_text: String, index: int) -> SpinBox:
	var row := HBoxContainer.new()
	var label := Label.new()
	label.text = "%s (%s):" % [label_text, MapMeasure.unit()]
	label.tooltip_text = "How big the selected shape is on the map. Type a size to resize it."
	var spin := SpinBox.new()
	spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spin.step = 0.5
	spin.min_value = 0.5
	spin.allow_greater = true
	spin.max_value = 10000
	spin.select_all_on_focus = true
	row.add_child(label)
	row.add_child(spin)
	parent.add_child(row)
	parent.move_child(row, index)
	return spin


func _single_selected() -> Control:
	if Globals.draw_comp == null:
		return null
	var picked: Array = Globals.draw_comp.selected.filter(func(o): return is_instance_valid(o))
	return picked[0] if picked.size() == 1 else null


# Typing a width or height in feet: the object's pixel size is whatever, at its
# current scale, comes out that many feet on the map.
func _on_units_changed(value: float, axis: int) -> void:
	var s := _single_selected()
	if s == null:
		return
	var scale_on_axis: float = absf(s.scale[axis]) if s.scale[axis] != 0 else 1.0
	emit_signal("object_change", 2 + axis, MapMeasure.units_to_px(value) / scale_on_axis)
	# Keep the selection outline around the resized object.
	var box = Globals.draw_comp.select_box
	if is_instance_valid(box):
		box.size = (s.size * s.scale).abs()


func _process(_delta: float) -> void:
	if not is_visible_in_tree():
		return
	var s := _single_selected()
	if s == null:
		return
	var transform := get_node(TRANSFORM)
	_show(_width_units, absf(s.size.x * s.scale.x) / MapMeasure.grid_px() * MapMeasure.unit_size())
	_show(_height_units, absf(s.size.y * s.scale.y) / MapMeasure.grid_px() * MapMeasure.unit_size())
	_show(transform.get_node("Position X/PosXSpinBox"), s.position.x)
	_show(transform.get_node("Position Y/PosYSpinBox"), s.position.y)
	_show(transform.get_node("Size X/SizeXSpinBox"), s.size.x)
	_show(transform.get_node("Size Y/SizeYSpinBox"), s.size.y)
	_show(transform.get_node("Scale X/ScaleXSpinBox"), s.scale.x)
	_show(transform.get_node("Scale Y/ScaleYSpinBox"), s.scale.y)
	_show(transform.get_node("Rotation/RotSpinBox"), s.rotation)


# Updates a field without firing its change signal — and never while it's being typed in.
func _show(spin: SpinBox, value: float) -> void:
	if spin.get_line_edit().has_focus() or is_equal_approx(spin.value, value):
		return
	spin.set_value_no_signal(value)

#Author: Vladimír Horák
#Desc:
#Script controlling map_tools - drawing tools on the left side of screen

extends Control
# Called when the node enters the scene tree for the first time.
func _ready():
	Globals.tool_bar = $MarginContainer/VBoxContainer/Select
	$VBoxContainer/TextOptions/Panel/VBoxContainer/FontSizeSpinBox.get_line_edit().focus_mode = FOCUS_CLICK
	$VBoxContainer/LineOptions/Panel/VBoxContainer/LineSpinBox.get_line_edit().focus_mode = FOCUS_CLICK
	_ready_labels()
	_ready_ruler_modes()
	_ready_map_image()
	_ready_hint()


func _on_draw_item_selected(index):
	if index == 0:
		Globals.tool = "rect"
	elif index == 1:
		Globals.tool = "lines"
	elif index == 2:
		Globals.tool = "circle"
	Globals.tool_bar = $MarginContainer/VBoxContainer/Draw

func _on_margin_container_mouse_entered():
	Globals.mouseOverButton = true


func _on_margin_container_mouse_exited():
	Globals.mouseOverButton = false


func _on_select_pressed():
	Globals.tool = "select"
	Globals.tool_bar = $MarginContainer/VBoxContainer/Select


func _on_draw_pressed():
	var draw = $MarginContainer/VBoxContainer/Draw
	var index = draw.get_selected_id()
	if index == 0:
		Globals.tool = "rect"
	elif index == 1:
		Globals.tool = "lines"
	elif index == 2:
		Globals.tool = "circle"
	Globals.tool_bar = draw


func _on_snap_options_pressed():
	$MarginContainer/VBoxContainer/SnapPopupPanel.visible = not $MarginContainer/VBoxContainer/SnapPopupPanel.visible
	$MarginContainer/VBoxContainer/SnapPanelContainer/HBoxContainer/SnapOptions.get_popup().visible = false


func _on_snap_check_box_toggled(button_pressed):
	Globals.snapping = not Globals.snapping


func _on_snap_fraction_option_button_item_selected(index):
	Globals.snappingFraction = index + 1


func _on_measure_options_pressed():
	Globals.tool = "measure"
	$MarginContainer/VBoxContainer/MeasurePopupPanel.visible = not $MarginContainer/VBoxContainer/MeasurePopupPanel.visible
	$MarginContainer/VBoxContainer/HBoxContainer/MeasureOptions.get_popup().visible = false
	Globals.tool_bar = $MarginContainer/VBoxContainer/HBoxContainer/Measure


func _on_measure_pressed():
	Globals.tool = "measure"
	Globals.tool_bar = $MarginContainer/VBoxContainer/HBoxContainer/Measure

func _on_measure_line_radio_toggled(button_pressed):
	if button_pressed:
		Globals.measureTool = 1


func _on_measure_circle_radio_toggled(button_pressed):
	if button_pressed:
		Globals.measureTool = 2


func _on_measure_angle_radio_toggled(button_pressed):
	if button_pressed:
		Globals.measureTool = 3


func _on_line_edit_text_changed(new_text):
	Globals.measureAngle = int($MarginContainer/VBoxContainer/MeasurePopupPanel/VBoxContainer/HBoxContainer/MeasureAngleLineEdit.text)


func _on_text_pressed():
	Globals.tool = "text"
	Globals.tool_bar = $MarginContainer/VBoxContainer/Text


func _on_font_option_button_item_selected(index):
	Globals.font = $VBoxContainer/TextOptions/Panel/VBoxContainer/FontOptionButton.get_item_text(index) # Replace with function body.
	Globals.draw_comp.emit_signal("font_settings_changed", "f")


func _on_font_size_spin_box_value_changed(value):
	Globals.fontSize = value
	Globals.draw_comp.emit_signal("font_settings_changed", "fs")


func _on_font_color_picker_button_color_changed(color):
	Globals.fontColor = color
	Globals.draw_comp.emit_signal("font_settings_changed", "fc")

func _on_line_spin_box_value_changed(value):
	Globals.lineWidth = value
	Globals.draw_comp.emit_signal("line_settings_changed", "lw")


func _on_line_color_picker_button_color_changed(color):
	Globals.colorLines = color
	Globals.draw_comp.emit_signal("line_settings_changed", "lc")


func _on_fill_color_picker_button_color_changed(color):
	Globals.colorBack = color
	Globals.draw_comp.emit_signal("line_settings_changed", "bg")

#func _on_line_color_picker_button_focus_exited():
	#$VBoxContainer/LineOptions/Panel/VBoxContainer/LineColorPickerButton.get_popup().hide()


func _on_turn_order_pressed():
	if Globals.turn_order.visible:
		Globals.turn_order.hide()
	else:
		Globals.turn_order.popup()


# The two spin boxes below were wired to this from the start, but it was never
# written, so focusing either one logged an error. Nothing needs doing.
func _on_spin_box_focus_entered():
	pass


# ================== making the toolbar say what it does ==================
# Every button was a bare symbol with no tooltip. Each now has a word and a
# tooltip, the tool in use is highlighted, and a line at the top of the map says
# how to use it. Set up here rather than in map_tools.tscn, so it reads in one place.

const ACTIVE = Color(1.0, 0.82, 0.35)
const BUTTON_FONT = 16

const HINTS = {
	"select": "Select — click a token or shape, or drag a box around several. Drag a corner to resize, the top handle to rotate. Sizes in feet show above the selection; the Object tab on the right has the numbers. Double-click a token for its sheet.",
	"rect": "Rectangle — drag on the map to draw. Hold Shift for a square. The size in feet shows as you drag.",
	"lines": "Freehand — drag on the map to draw a line.",
	"circle": "Circle — drag on the map to draw. Hold Shift for a perfect circle. The size in feet shows as you drag.",
	"measure1": "Ruler — drag from one point to another. Shows feet and squares; let go to clear it. ▾ changes how diagonals count.",
	"measure2": "Radius — drag out from a centre point to see a radius, like a fireball's 20 ft. Let go to clear it.",
	"measure3": "Cone — drag from the caster to see a cone. Set its angle in the ▾ menu. Let go to clear it.",
	"text": "Text — click the map to type a label.",
}

@onready var _tools = $MarginContainer/VBoxContainer
var _hint: Label
var _map_image_button: Button
var _remove_map_button: Button
var _last_tool := ""


func _process(_delta):
	var key: String = Globals.tool + (str(Globals.measureTool) if Globals.tool == "measure" else "")
	if key == _last_tool:
		return
	_last_tool = key
	_show_active_tool(key)


func _ready_labels():
	# Wide enough for words, not just symbols.
	$MarginContainer.offset_right = 150
	var snap: CheckBox = _tools.get_node("SnapPanelContainer/HBoxContainer/SnapCheckBox")
	snap.text = "▦ Snap"
	snap.tooltip_text = "Snap to grid: drawing, measuring and moving line up with the grid squares. ▾ sets how finely (1/2 = half squares)."
	_tools.get_node("SnapPanelContainer/HBoxContainer/SnapOptions").tooltip_text = "Snap settings"

	var select: Button = _tools.get_node("Select")
	select.text = "Select"
	select.tooltip_text = "Select, move, resize and rotate things on the map."

	var draw: OptionButton = _tools.get_node("Draw")
	for item in [["▭ Rectangle", 0], ["〰 Freehand", 1], ["◯ Circle", 2]]:
		draw.set_item_text(item[1], item[0])
	draw.tooltip_text = "Draw a shape. Click to use it; pick rectangle, freehand or circle from the list."

	var measure: Button = _tools.get_node("HBoxContainer/Measure")
	measure.tooltip_text = "Measure distances in feet and squares. ▾ for a radius, a cone, or how diagonals count."
	_tools.get_node("HBoxContainer/MeasureOptions").tooltip_text = "Ruler options: line, radius or cone, and how diagonals count"

	var text: Button = _tools.get_node("Text")
	text.text = "T  Text"
	text.tooltip_text = "Write a label on the map."

	var turns: Button = _tools.get_node("TurnOrder")
	turns.text = "Turns"
	turns.tooltip_text = "Show or hide the turn order (initiative) window."

	for b in [snap, select, draw, measure, text, turns]:
		b.add_theme_font_size_override("font_size", BUTTON_FONT)
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	select.icon_alignment = HORIZONTAL_ALIGNMENT_LEFT
	turns.icon_alignment = HORIZONTAL_ALIGNMENT_LEFT

	# The style panels at the bottom: what new shapes and labels look like.
	var lines = $VBoxContainer/LineOptions/Panel/VBoxContainer
	lines.get_node("LinesLabel").text = "Outline"
	lines.get_node("LineSpinBox").tooltip_text = "Outline thickness for new shapes"
	lines.get_node("LineColorPickerButton").tooltip_text = "Outline colour for new shapes"
	lines.get_node("FillColorPickerButton").tooltip_text = "Fill colour for new shapes — see-through by default, so the map shows under spell areas"
	lines.get_node("LineSpinBox").set_value_no_signal(Globals.lineWidth)
	lines.get_node("LineColorPickerButton").color = Globals.colorLines
	lines.get_node("FillColorPickerButton").color = Globals.colorBack
	lines.get_node("FillColorPickerButton").edit_alpha = true
	var texts = $VBoxContainer/TextOptions/Panel/VBoxContainer
	texts.get_node("FontSizeSpinBox").tooltip_text = "Text size for new labels"
	texts.get_node("FontColorPickerButton").tooltip_text = "Text colour for new labels"


func _ready_ruler_modes():
	var popup: PopupPanel = _tools.get_node("MeasurePopupPanel")
	popup.title = "Ruler options"
	popup.wrap_controls = true
	var box = popup.get_node("VBoxContainer")
	var heading: Label = box.get_node("MeasureDiagonalLabel")
	heading.text = "Diagonals count as"
	heading.visible = true
	var modes := OptionButton.new()
	for label in MapMeasure.RULER_MODE_LABELS:
		modes.add_item(label)
	modes.select(Globals.rulerMode)
	modes.tooltip_text = "D&D (2024 rules) counts a diagonal step as one square. Straight line gives the exact distance."
	modes.item_selected.connect(func(i: int) -> void: Globals.rulerMode = i)
	box.add_child(modes)
	box.move_child(modes, heading.get_index() + 1)
	box.get_node("MeasureLineRadio").text = "Ruler (line)"
	box.get_node("MeasureCircleRadio").text = "Radius (circle)"
	box.get_node("MeasureAngleRadio").text = "Cone (angle)"


func _ready_map_image():
	# Only the GM puts maps down; players' copies follow.
	if not Globals.lobby.check_is_server():
		return
	_map_image_button = Button.new()
	_map_image_button.text = "🗺 Map image"
	_map_image_button.tooltip_text = "Put a battle map image under everything on this map, lined up with the grid."
	_map_image_button.focus_mode = Control.FOCUS_CLICK
	_map_image_button.mouse_filter = Control.MOUSE_FILTER_PASS
	_map_image_button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_map_image_button.add_theme_font_size_override("font_size", BUTTON_FONT)
	_map_image_button.pressed.connect(_choose_map_image)
	_tools.add_child(_map_image_button)
	_tools.move_child(_map_image_button, _tools.get_node("Text").get_index() + 1)

	_remove_map_button = Button.new()
	_remove_map_button.text = "✕ Remove map"
	_remove_map_button.tooltip_text = "Take a map image off this map (Ctrl+Z brings it back)."
	_remove_map_button.focus_mode = Control.FOCUS_CLICK
	_remove_map_button.mouse_filter = Control.MOUSE_FILTER_PASS
	_remove_map_button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_remove_map_button.add_theme_font_size_override("font_size", BUTTON_FONT)
	_remove_map_button.pressed.connect(_choose_map_to_remove)
	_tools.add_child(_remove_map_button)
	_tools.move_child(_remove_map_button, _map_image_button.get_index() + 1)


func _ready_hint():
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0, 0, 0, 0.6)
	style.set_corner_radius_all(6)
	style.content_margin_left = 10
	style.content_margin_right = 10
	style.content_margin_top = 4
	style.content_margin_bottom = 4
	panel.add_theme_stylebox_override("panel", style)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.position = Vector2(160, 6)
	_hint = Label.new()
	_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hint.custom_minimum_size = Vector2(760, 0)
	_hint.add_theme_font_size_override("font_size", 14)
	panel.add_child(_hint)
	add_child(panel)


const VIEW_HINT = "Move the view: WASD, arrow keys (when nothing is selected), hold Space and drag, or drag with the middle mouse button. Shift = faster. Scroll wheel zooms."

func _show_active_tool(key: String) -> void:
	if _hint != null:
		_hint.text = HINTS.get(key, "") + "\n" + VIEW_HINT
	var measure: Button = _tools.get_node("HBoxContainer/Measure")
	measure.text = {"measure2": "◎ Radius", "measure3": "◸ Cone"}.get(key, "📏 Ruler")
	var draw: Control = _tools.get_node("Draw")
	var active: Control = {
		"select": _tools.get_node("Select"),
		"rect": draw, "lines": draw, "circle": draw,
		"text": _tools.get_node("Text"),
	}.get(key, measure if key.begins_with("measure") else null)
	for b in [_tools.get_node("Select"), draw, measure, _tools.get_node("Text")]:
		b.modulate = ACTIVE if b == active else Color.WHITE


# ── Map image ──────────────────────────────────────────────────────────────

func _choose_map_image():
	var dialog := FileDialog.new()
	dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	dialog.access = FileDialog.ACCESS_FILESYSTEM
	dialog.use_native_dialog = true
	dialog.title = "Choose a map image"
	dialog.filters = PackedStringArray(["*.png, *.jpg, *.jpeg, *.webp ; Images"])
	dialog.file_selected.connect(func(path: String) -> void:
		dialog.queue_free()
		_ask_map_width(path))
	dialog.canceled.connect(dialog.queue_free)
	add_child(dialog)
	dialog.popup_centered_ratio(0.6)


# One map image: confirm and remove it. Several: pick which. None: say so.
func _choose_map_to_remove():
	var images: Array = Globals.draw_comp.map_images()
	if images.is_empty():
		var none := AcceptDialog.new()
		none.title = "No map image"
		none.dialog_text = "There's no map image on this map. Use 🗺 Map image to add one."
		none.confirmed.connect(none.queue_free)
		none.canceled.connect(none.queue_free)
		add_child(none)
		none.popup_centered()
		return

	var dialog := ConfirmationDialog.new()
	dialog.title = "Remove map image"
	dialog.ok_button_text = "Remove"
	var box := VBoxContainer.new()
	var info := Label.new()
	info.text = "Remove this map image? Ctrl+Z brings it back." if images.size() == 1 else "Which map image should be removed? Ctrl+Z brings it back."
	box.add_child(info)
	var list := ItemList.new()
	list.custom_minimum_size = Vector2(380, 40 + 28 * mini(images.size(), 6))
	# Top-most first, the one you can see.
	for i in range(images.size() - 1, -1, -1):
		var image: Panel = images[i]
		var path: String = image.get_theme_stylebox("panel").texture.get_meta("image_path", "")
		var squares := MapMeasure.px_to_units(image.size.x * image.scale.x) / MapMeasure.unit_size()
		list.add_item("%s  (%s squares wide)" % [path.get_file() if path != "" else "map image", MapMeasure.num(squares)])
		list.set_item_metadata(list.item_count - 1, image)
	list.select(0)
	box.add_child(list)
	dialog.add_child(box)
	dialog.confirmed.connect(func() -> void:
		var picked := list.get_selected_items()
		if not picked.is_empty():
			Globals.draw_comp.remove_map_image(list.get_item_metadata(picked[0]))
		dialog.queue_free())
	dialog.canceled.connect(dialog.queue_free)
	add_child(dialog)
	dialog.popup_centered()


# Battle maps come with their own grid; saying how many squares wide it is makes
# its squares line up with this map's, so tokens, the ruler and shapes all agree.
func _ask_map_width(path: String):
	var dialog := ConfirmationDialog.new()
	dialog.title = "Fit the map to the grid"
	dialog.ok_button_text = "Place map"
	var box := VBoxContainer.new()
	var info := Label.new()
	info.text = "How many grid squares wide is this map?\nCount the squares along its top edge. Leave 0 to use the image's own size."
	var squares := SpinBox.new()
	squares.min_value = 0
	squares.max_value = 500
	squares.suffix = "squares"
	box.add_child(info)
	box.add_child(squares)
	dialog.add_child(box)
	dialog.confirmed.connect(func() -> void:
		Globals.draw_comp.add_map_image(path, int(squares.value))
		dialog.queue_free())
	dialog.canceled.connect(dialog.queue_free)
	add_child(dialog)
	dialog.popup_centered()
	squares.get_line_edit().grab_focus()
	squares.get_line_edit().select_all()


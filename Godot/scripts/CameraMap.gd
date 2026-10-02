#Author: Vladimír Horák
#Desc:
#Script for controlling camera in map scene

extends Camera2D

#settings for map camera navigation
var zoomSpd: float = 0.05
var minZoom: float = 0.001
var maxZoom: float = 2.0
var dragSen: float = 1.0
# Keyboard panning: screen pixels per second, and the multiplier while Shift is held.
var keySpeed: float = 900.0
var keyFastFactor: float = 3.0

# Called when the node enters the scene tree for the first time.
func _ready():
	Globals.camera = self


# True while the GM is typing somewhere — keys then mean letters, not movement.
func _typing() -> bool:
	var focus := get_viewport().gui_get_focus_owner()
	return focus is LineEdit or focus is TextEdit


# Holding Space turns the left mouse button into a hand that drags the view.
# draw.gd checks this first, so the drag doesn't also draw or select.
func hand_held() -> bool:
	return Input.is_key_pressed(KEY_SPACE) and not _typing()


# Keyboard panning. WASD always; the arrow keys only when nothing is selected,
# since with something selected they nudge it a grid square (draw.gd).
func _process(delta):
	Input.set_default_cursor_shape(Input.CURSOR_DRAG if hand_held() else Input.CURSOR_ARROW)
	if _typing():
		return
	var dir := Vector2(
		float(Input.is_key_pressed(KEY_D)) - float(Input.is_key_pressed(KEY_A)),
		float(Input.is_key_pressed(KEY_S)) - float(Input.is_key_pressed(KEY_W)))
	var focus := get_viewport().gui_get_focus_owner()
	var arrows_free: bool = Globals.draw_comp != null and Globals.draw_comp.selected.is_empty() \
		and not (focus is Tree or focus is ItemList or focus is OptionButton)
	if arrows_free:
		dir.x += float(Input.is_key_pressed(KEY_RIGHT)) - float(Input.is_key_pressed(KEY_LEFT))
		dir.y += float(Input.is_key_pressed(KEY_DOWN)) - float(Input.is_key_pressed(KEY_UP))
	if dir == Vector2.ZERO or Input.is_key_pressed(KEY_CTRL):
		return
	var speed := keySpeed * (keyFastFactor if Input.is_key_pressed(KEY_SHIFT) else 1.0)
	# Screen pixels per second, so panning feels the same at any zoom.
	position += dir.normalized() * speed * delta / zoom.x


#handles user input
func _unhandled_input(event):
	#movement - middle mouse button, or Space + left mouse button
	if event is InputEventMouseMotion and (Input.is_mouse_button_pressed(MOUSE_BUTTON_MIDDLE) \
			or (Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) and hand_held())):
		position -= event.relative * dragSen / zoom
		
	#zoom
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			zoom += Vector2(zoomSpd, zoomSpd)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			zoom -= Vector2(zoomSpd, zoomSpd)
		else:
			return
		zoom = clamp(zoom, Vector2(minZoom, minZoom), Vector2(maxZoom, maxZoom))
		#resize selection box handles
		if $"../Draw/Select".get_child_count() == 1:
			var handles = $"../Draw/Select".get_child(0).get_children()
			for handle in handles:
				handle.scale = Vector2(1/zoom.x,1/zoom.y)

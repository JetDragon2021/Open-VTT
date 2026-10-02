# While the Light tool is in use, shows where every light reaches: a ring at its
# dim edge, a fainter one at its bright edge. With "Remove light" chosen, the
# light a click would remove is filled red - any click inside a lit area counts,
# so a Daylight light can be removed without finding its tiny marker.

extends Node2D

const RING = Color(1.0, 0.85, 0.4, 0.9)
const BRIGHT_RING = Color(1.0, 0.85, 0.4, 0.45)
const TARGET = Color(1.0, 0.25, 0.2)

@onready var _draw_comp: Node2D = get_parent()


func _ready() -> void:
	z_as_relative = false
	z_index = RenderingServer.CANVAS_ITEM_Z_MAX - 1


func _process(_delta: float) -> void:
	queue_redraw()


func _draw() -> void:
	if Globals.tool != "light":
		return
	var zoom: float = Globals.camera.zoom.x if Globals.camera != null else 1.0
	var target = _draw_comp.light_at(get_global_mouse_position()) if _draw_comp.light_preset == "remove" else null
	for light in _draw_comp.all_lights():
		var hit: bool = target != null and light.object == target.object
		if hit:
			draw_circle(light.center, light.reach, Color(TARGET, 0.18))
		draw_arc(light.center, light.reach, 0, TAU, 96, TARGET if hit else RING, 3.0 / zoom)
		draw_arc(light.center, light.bright, 0, TAU, 96, Color(TARGET, 0.6) if hit else BRIGHT_RING, 2.0 / zoom)
		draw_circle(light.center, 4.0 / zoom, TARGET if hit else RING)

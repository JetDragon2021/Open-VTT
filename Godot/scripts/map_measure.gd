# Distances and sizes on the map in the map's own units (5 ft per square by
# default), shared by the ruler, the shape-size labels and the Object panel.
# Map settings: grid_size = pixels per square, unit_size = units per square,
# unit = "ft".

class_name MapMeasure
extends RefCounted

# How the ruler counts diagonal moves — Globals.rulerMode.
enum Ruler { GRID, STRAIGHT, ALTERNATE }
const RULER_MODE_LABELS = [
	"D&D grid — a diagonal square is 5 ft",
	"Straight line — exact distance",
	"Alternating — diagonals 5 ft, then 10 ft",
]

const RULER_COLOR = Color(1.0, 0.82, 0.2)
const LABEL_FONT_SIZE = 18


static func _map() -> Map_res:
	return Globals.map if Globals.map != null else Globals.new_map


static func grid_px() -> float:
	var m := _map()
	return float(m.grid_size) if m != null and m.grid_size > 0 else 70.0


static func unit_size() -> float:
	var m := _map()
	return float(m.unit_size) if m != null else 5.0


static func unit() -> String:
	var m := _map()
	return m.unit if m != null and m.unit != "" else "ft"


static func px_to_units(px: float) -> float:
	return px / grid_px() * unit_size()


static func units_to_px(units: float) -> float:
	return units / unit_size() * grid_px()


# 17.5 → "17.5", 20.0 → "20"
static func num(value: float) -> String:
	var rounded := snappedf(value, 0.1)
	return str(int(rounded)) if is_equal_approx(rounded, roundf(rounded)) else str(rounded)


static func length_text(px: float) -> String:
	return "%s %s" % [num(px_to_units(px)), unit()]


# The ruler's reading between two points: "25 ft · 5 sq". On a grid, D&D counts
# a diagonal step as one square, so the straight-line length would overstate it.
static func ruler_text(from: Vector2, to: Vector2) -> String:
	var d := (to - from).abs() / grid_px()
	var squares: float
	match Globals.rulerMode:
		Ruler.STRAIGHT:
			squares = from.distance_to(to) / grid_px()
		Ruler.ALTERNATE:
			# Every second diagonal costs double (the DMG's optional rule).
			squares = maxf(d.x, d.y) + floorf(minf(d.x, d.y) / 2.0)
		_:
			squares = maxf(d.x, d.y)
	return "%s %s · %s sq" % [num(squares * unit_size()), unit(), num(squares)]


# A shape's size: "15 × 10 ft", or "⌀ 20 ft" for a round one.
static func size_text(size_px: Vector2, round_shape := false) -> String:
	var w := absf(size_px.x)
	var h := absf(size_px.y)
	if round_shape and is_equal_approx(snappedf(w, 0.5), snappedf(h, 0.5)):
		return "⌀ %s (radius %s)" % [length_text(w), length_text(w / 2.0)]
	return "%s × %s %s" % [num(px_to_units(w)), num(px_to_units(h)), unit()]


# A label that reads the same at any zoom and in the dark: world-space, unshaded,
# outlined, on a dark backing.
static func make_label(unshaded: Material) -> Label:
	var label := Label.new()
	label.material = unshaded
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_color_override("font_color", Color.WHITE)
	label.add_theme_color_override("font_outline_color", Color.BLACK)
	label.add_theme_constant_override("outline_size", 4)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0, 0, 0, 0.65)
	style.set_corner_radius_all(4)
	style.content_margin_left = 6
	style.content_margin_right = 6
	style.content_margin_top = 2
	style.content_margin_bottom = 2
	label.add_theme_stylebox_override("normal", style)
	scale_label(label)
	return label


# Keeps a world-space label the same size on screen as the camera zooms.
static func scale_label(label: Label) -> void:
	var zoom := 1.0
	if Globals.camera != null:
		zoom = maxf(Globals.camera.zoom.x, 0.05)
	label.scale = Vector2.ONE / zoom
	label.add_theme_font_size_override("font_size", LABEL_FONT_SIZE)

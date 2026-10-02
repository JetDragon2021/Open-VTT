# What can be seen from a point: the area within a radius that no wall hides.
# Pure geometry, world coordinates — party_vision.gd builds the player view
# from these shapes (what each PC sees, what each light reaches) and their
# overlaps.

class_name VisionGeometry
extends RefCounted

# How finely the edge of the radius is drawn. Walls are exact either way.
const CIRCLE_STEPS = 72
# Rays just either side of each wall corner, so sight slips past corners.
const NUDGE = 0.0005


# Every wall as a pair of world points: the shadows of walls and of shapes with
# Cast Shadow on. Tokens can cast shadows too, but a creature doesn't hide the
# room behind it, so theirs are left out.
static func wall_segments(layers: Array) -> Array:
	var segments: Array = []
	for layer in layers:
		_collect(layer, segments)
	return segments


static func _collect(node: Node, segments: Array) -> void:
	for child in node.get_children():
		if child is LightOccluder2D:
			if child.occluder == null or _on_token(child) or not child.is_visible_in_tree():
				continue
			var xf: Transform2D = child.get_global_transform()
			var points: PackedVector2Array = child.occluder.polygon
			for i in range(points.size() - 1):
				segments.append([xf * points[i], xf * points[i + 1]])
			if child.occluder.closed and points.size() > 2:
				segments.append([xf * points[-1], xf * points[0]])
		elif child.get_child_count() > 0:
			_collect(child, segments)


static func _on_token(node: Node) -> bool:
	var parent := node.get_parent()
	while parent != null and not (parent is CanvasLayer):
		if parent.get_meta("type", "") == "token" or "character" in parent:
			return true
		parent = parent.get_parent()
	return false


# The area visible from `origin` out to `radius`, as a polygon.
static func visibility(origin: Vector2, radius: float, segments: Array) -> PackedVector2Array:
	if radius <= 0:
		return PackedVector2Array()
	# Only walls that can reach into the radius matter.
	var reach := Rect2(origin - Vector2(radius, radius), Vector2(radius, radius) * 2)
	var near: Array = []
	for s in segments:
		if reach.intersects(Rect2(s[0], Vector2.ZERO).expand(s[1]), true):
			near.append(s)

	var angles: Array = []
	for i in CIRCLE_STEPS:
		angles.append(TAU * i / CIRCLE_STEPS - PI)
	for s in near:
		for p in s:
			if origin.distance_to(p) <= radius:
				var a: float = (p - origin).angle()
				angles.append(a - NUDGE)
				angles.append(a)
				angles.append(a + NUDGE)
	angles.sort()

	var polygon := PackedVector2Array()
	for a in angles:
		var far: Vector2 = origin + Vector2.from_angle(a) * radius
		var best := far
		var best_d := radius
		for s in near:
			var hit = Geometry2D.segment_intersects_segment(origin, far, s[0], s[1])
			if hit != null:
				var d: float = origin.distance_to(hit)
				if d < best_d:
					best_d = d
					best = hit
		if polygon.is_empty() or polygon[-1].distance_squared_to(best) > 0.01:
			polygon.append(best)
	return clean(polygon)


# Drops what makes a polygon fail to draw: the last point repeating the first
# (the sweep wraps round), and points lying on the line between their neighbours.
static func clean(polygon: PackedVector2Array) -> PackedVector2Array:
	while polygon.size() > 1 and polygon[-1].distance_squared_to(polygon[0]) <= 0.01:
		polygon.remove_at(polygon.size() - 1)
	var i := 0
	while polygon.size() > 3 and i < polygon.size():
		var prev := polygon[(i - 1 + polygon.size()) % polygon.size()]
		var next := polygon[(i + 1) % polygon.size()]
		if absf((polygon[i] - prev).cross(next - polygon[i])) < 0.01:
			polygon.remove_at(i)
		else:
			i += 1
	return polygon


# Where two visible areas overlap (seen by someone, and lit by something).
static func overlap(a: PackedVector2Array, b: PackedVector2Array) -> Array:
	if a.size() < 3 or b.size() < 3:
		return []
	return Geometry2D.intersect_polygons(a, b)

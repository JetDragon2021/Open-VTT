# Player view: the map as the party sees it, for screen-sharing to the players.
#
# A fog covers everything the party can't see. What they can see is worked out
# from the walls (anything with a shadow: the Walls tool, or Cast Shadow on in
# the Object tab) by vision_geometry.gd:
#
#   - a lit map (Darkness off in the Map tab): everything in a party member's
#     line of sight;
#   - a dark map (Darkness on): what's in their line of sight AND lit —
#       bright light: fully;  dim light: dimmed;
#     plus their darkvision: darkness within it shows dimmed, and dim light
#     within it as if bright (2024 rules). A party member always sees their own
#     square, so nobody vanishes in the dark.
#
# Lights: anything with Cast Light on (the 💡 Light tool places them; a light's
# radius is its dim edge, bright reaches half way — a torch is 20 ft bright +
# 20 ft dim), and a "light" attribute on a character, which goes where their
# token goes ("torch", "lantern", or "20/20" for bright/dim feet).
#
# Who's in the party: is_party_member (and the "Who sees" list in the toolbar).
# A "sight" attribute (ft) on a character lets them see that far regardless.
#
# Godot's own lights only ADD brightness, so a torch in a room the party can't
# see would have shown that room; drawing the fog from the overlap of sight and
# light is what keeps it dark. Turning Player view off puts everything back.

class_name PartyVision
extends Node

# On a lit map the walls are the limit, not distance — this is just "far".
const LINE_OF_SIGHT_FT = 600.0
const BRIGHT = Color(1, 1, 1)
const DIM = Color(0.55, 0.55, 0.55)
# Light presets, in feet: [bright, dim beyond it].
const LIGHTS = {
	"candle": [5, 5], "torch": [20, 20], "lantern": [30, 30], "light": [20, 20],
	"daylight": [60, 60], "continual flame": [20, 20],
}

const FOG_SHADER = """
shader_type canvas_item;
// The mask is white where the party sees clearly, grey where it's dim, black
// where they see nothing; the fog is its opposite.
void fragment() {
	float seen = texture(TEXTURE, UV).r;
	COLOR = vec4(0.0, 0.0, 0.0, 1.0 - seen);
}
"""

var active := false
var _saved := {}
var _hidden: Array = [] # [node, property, value before] for everything hidden

var _fog_layer: CanvasLayer
var _mask_viewport: SubViewport
var _mask: Node2D
var _bright: Array = [] # polygons, world coordinates
var _dim: Array = []
var _signature := ""

@onready var _map: Node = get_parent().get_parent() # Draw → Map


func set_active(on: bool) -> void:
	if on == active:
		return
	active = on
	if on:
		_build_fog()
		_hide_for_players()
		_signature = ""
	else:
		_fog_layer.queue_free()
		_fog_layer = null
		_restore_hidden()
		# Back to whatever the Map tab says now — it may have changed meanwhile.
		var map: Map_res = Globals.map if Globals.map != null else Globals.new_map
		_map.get_node("Darkness").visible = map != null and map.darkness_enable


func _process(_delta: float) -> void:
	if not active:
		return
	# The mask follows the camera, at the window's size.
	var view := get_viewport()
	_mask_viewport.size = Vector2i(view.get_visible_rect().size)
	_mask_viewport.canvas_transform = view.canvas_transform
	_hide_new_walls()
	_hide_new_lights()
	# The GM's darkness tint stays off: turning Darkness on in the Map tab while
	# this is on switches it back on, and it would dim what the party sees.
	_map.get_node("Darkness").visible = false
	# Recompute only when something that changes the view has changed.
	var inputs := _inputs()
	if inputs.signature != _signature:
		_signature = inputs.signature
		_compute(inputs)
	_mask.queue_redraw()


# ── The fog ─────────────────────────────────────────────────────────────────

func _build_fog() -> void:
	_fog_layer = CanvasLayer.new()
	_fog_layer.layer = 2 # over the map and its grid, under the GM's toolbars
	_mask_viewport = SubViewport.new()
	_mask_viewport.disable_3d = true
	_mask_viewport.transparent_bg = false
	_mask_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_mask = Node2D.new()
	_mask.draw.connect(_draw_mask)
	_mask_viewport.add_child(_mask)
	_fog_layer.add_child(_mask_viewport)
	var fog := TextureRect.new()
	fog.texture = _mask_viewport.get_texture()
	fog.set_anchors_preset(Control.PRESET_FULL_RECT)
	fog.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var material := ShaderMaterial.new()
	material.shader = Shader.new()
	material.shader.code = FOG_SHADER
	fog.material = material
	_fog_layer.add_child(fog)
	add_child(_fog_layer)


func _draw_mask() -> void:
	# Unseen everywhere in view, then what's dim, then what's bright on top.
	var inverse := _mask_viewport.canvas_transform.affine_inverse()
	var corners := Rect2(Vector2.ZERO, Vector2(_mask_viewport.size))
	_mask.draw_rect(Rect2(inverse * corners.position, Vector2.ZERO).expand(inverse * corners.end), Color.BLACK)
	for polygon in _dim:
		_fill(polygon, DIM)
	for polygon in _bright:
		_fill(polygon, BRIGHT)


# Draws a polygon as triangles worked out once here, rather than leaving Godot
# to fail on an awkward one: a shape that won't triangulate is skipped, not an error.
func _fill(polygon: PackedVector2Array, color: Color) -> void:
	if polygon.size() < 3:
		return
	var indices := Geometry2D.triangulate_polygon(polygon)
	if indices.is_empty():
		return
	var colors := PackedColorArray([color, color, color])
	for i in range(0, indices.size(), 3):
		_mask.draw_primitive(PackedVector2Array([polygon[indices[i]], polygon[indices[i + 1]], polygon[indices[i + 2]]]), colors, PackedVector2Array())


# ── What the party sees ─────────────────────────────────────────────────────

func _inputs() -> Dictionary:
	var map: Map_res = Globals.map if Globals.map != null else Globals.new_map
	var dark: bool = map != null and map.darkness_enable
	var eyes: Array = [] # [position, darkvision px, sight px]
	var lights: Array = [] # [position, bright px, dim edge px]
	var signature := "dark" if dark else "lit"
	for token in tokens():
		var c: Character = token.character
		var where: Vector2 = token.token_polygon.get_global_transform() * (token.token_polygon.size / 2)
		var carried := light_feet(c)
		if carried[1] > 0:
			lights.append([where, MapMeasure.units_to_px(carried[0]), MapMeasure.units_to_px(carried[1])])
		if is_party_member(c):
			eyes.append([where, MapMeasure.units_to_px(_attr_feet(c, "darkvision")), MapMeasure.units_to_px(_attr_feet(c, "sight"))])
	for light in _object_lights():
		# Hidden by Player view itself still counts; switched off by the GM doesn't.
		if not light.visible and not _hid_by_us(light):
			continue
		var reach: float = light.texture_scale * light.texture.get_height() / 2.0
		lights.append([light.global_position, reach / 2.0, reach])
	var walls := VisionGeometry.wall_segments(_all_layers())
	for e in eyes:
		signature += "|e%s,%s,%s" % [e[0].round(), e[1], e[2]]
	for l in lights:
		signature += "|l%s,%s,%s" % [l[0].round(), l[1], l[2]]
	signature += "|w%d" % walls.size()
	for s in walls:
		signature += "%s" % s[0].round()
	return {"dark": dark, "eyes": eyes, "lights": lights, "walls": walls, "signature": signature}


func _compute(inputs: Dictionary) -> void:
	_bright.clear()
	_dim.clear()
	var walls: Array = inputs.walls
	var far := MapMeasure.units_to_px(LINE_OF_SIGHT_FT)
	var own_square := MapMeasure.grid_px() * 0.6
	# What each light reaches: its bright part, and out to its dim edge.
	var lit_bright: Array = []
	var lit_dim: Array = []
	if inputs.dark:
		for l in inputs.lights:
			lit_bright.append(VisionGeometry.visibility(l[0], l[1], walls))
			lit_dim.append(VisionGeometry.visibility(l[0], l[2], walls))

	for e in inputs.eyes:
		var where: Vector2 = e[0]
		var sight: float = e[2]
		if not inputs.dark:
			_bright.append(VisionGeometry.visibility(where, sight if sight > 0 else far, walls))
			continue
		_dim.append(VisionGeometry.visibility(where, own_square, walls))
		if sight > 0:
			_bright.append(VisionGeometry.visibility(where, sight, walls))
		var line_of_sight := VisionGeometry.visibility(where, far, walls)
		var darkvision: PackedVector2Array = VisionGeometry.visibility(where, e[1], walls) if e[1] > 0 else PackedVector2Array()
		if darkvision.size() > 2:
			_dim.append(darkvision) # darkness within darkvision: as if dim
		for i in lit_bright.size():
			_bright.append_array(VisionGeometry.overlap(line_of_sight, lit_bright[i]))
			_dim.append_array(VisionGeometry.overlap(line_of_sight, lit_dim[i]))
			# Dim light within darkvision: as if bright.
			_bright.append_array(VisionGeometry.overlap(darkvision, lit_dim[i]))


# ── Who and what ────────────────────────────────────────────────────────────

# Whether this character's token sees for the party. Characters default to the
# player flag, and monsters spawned from the compendium before it was cleared on
# spawn still have it — but a stat block has a challenge rating, and a player
# character never does. A stat-block creature the GM ticked under "Who sees" (an
# ally, a familiar) carries a "party_vision" attribute saying so.
static func is_party_member(character: Character) -> bool:
	return character.player_character and (not character.attributes.has("cr") or character.attributes.has("party_vision"))


# The light a character carries, [bright, dim edge] in feet, from their "light"
# attribute: a preset name ("torch") or "bright/dim" ("20/20"); [0, 0] for none.
static func light_feet(character: Character) -> Array:
	var value = character.attributes.get("light")
	if value is Array and not value.is_empty():
		value = value[0]
	if value == null:
		return [0.0, 0.0]
	var text := str(value).strip_edges().to_lower()
	for preset in LIGHTS:
		if text.begins_with(preset):
			return [float(LIGHTS[preset][0]), float(LIGHTS[preset][0] + LIGHTS[preset][1])]
	var parts := text.replace("ft", "").split("/")
	var bright := parts[0].to_float()
	var dim := parts[1].to_float() if parts.size() > 1 else bright
	return [bright, bright + dim] if bright > 0 else [0.0, 0.0]


# Reads "60 ft" or "60" from a character attribute; 0 if it isn't there.
static func _attr_feet(character: Character, key: String) -> float:
	var value = character.attributes.get(key)
	if value is Array and not value.is_empty():
		value = value[0]
	return maxf(0.0, str(value).to_float()) if value != null else 0.0


func tokens() -> Array:
	var map: Map_res = Globals.map if Globals.map != null else Globals.new_map
	if map == null:
		return []
	return map.tokens.filter(func(t): return t != null and is_instance_valid(t) and t.is_inside_tree() and t.token_polygon != null)


func _all_layers() -> Array:
	var found: Array = []
	if Globals.layers == null:
		return found
	var item: TreeItem = Globals.layers.tree.get_root().get_next_in_tree()
	while item != null:
		found.append(item.get_meta("draw_layer"))
		item = item.get_next_in_tree()
	return found


# Lights placed on the map: anything with Cast Light on.
func _object_lights() -> Array:
	var found: Array = []
	for layer in _all_layers():
		for child in layer.get_children():
			if child is PointLight2D and child.get_meta("type", "") == "light" and child.texture != null:
				found.append(child)
	return found


# ── Hiding what players shouldn't see, and putting it back ──────────────────

func _hide(node: Object, property: String, value) -> void:
	_hidden.append([node, property, node.get(property)])
	node.set(property, value)


func _hide_for_players() -> void:
	_hidden.clear()
	# The fog does the darkness; the GM's darkness tint and the lights' own glow
	# would only darken or wash out what the party can see.
	_hide_new_lights()
	for layer in _all_layers():
		if layer.visible and layer.get_meta("DM", 0):
			_hide(layer, "visible", false)
	_hide_new_walls()


func _hid_by_us(node: Object) -> bool:
	for entry in _hidden:
		if entry[0] == node and entry[1] == "visible" and entry[2]:
			return true
	return false


func _hide_new_lights() -> void:
	for light in _object_lights():
		if light.visible:
			_hide(light, "visible", false)


# Walls are the GM's markings: players see where sight stops, not the pink line.
func _hide_new_walls() -> void:
	for layer in _all_layers():
		for object in layer.get_children():
			if Globals.draw_comp.is_wall(object):
				for child in object.get_children():
					if child is Line2D and child.visible:
						_hide(child, "visible", false)


func _restore_hidden() -> void:
	_hidden.reverse()
	for entry in _hidden:
		if is_instance_valid(entry[0]):
			entry[0].set(entry[1], entry[2])
	_hidden.clear()

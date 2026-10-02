# Player view: the map as the party sees it, for screen-sharing to the players.
#
# Everything outside the player characters' sight goes black. Each PC token's
# vision light (token.fov) reveals the map around it, and anything with Cast
# Shadow on (Object tab) blocks it — those shapes are the walls. Tokens outside
# everyone's sight disappear with the rest of the dark. DM-only layers are hidden.
#
# How far a PC sees:
#   - a lit map (Darkness off in the Map tab): as far as the walls allow;
#   - a dark map (Darkness on): their "darkvision" attribute, which the GM
#     Companion sends with the character sheet (e.g. "60 ft") — none, none at all;
#   - a "sight" attribute on the character, in feet, overrides both (a torch, a
#     spell, a homebrew sense).
#
# The token's light used to light only a hidden overlay on another canvas layer,
# which lights can't reach in Godot 4, so the old FOV setting never showed
# anything. Turning this off puts every light and setting back as it was.

extends Node

const UNSEEN = Color(0, 0, 0)
# On a lit map distance isn't the limit, the walls are — this is just "far".
const LINE_OF_SIGHT_FT = 600.0
const ALL_LAYERS = 0xFFFFF
const DISC_SIZE = 512

var active := false
var _disc: Texture2D
var _saved_darkness := {}
var _hidden_layers: Array = []

@onready var _map: Node = get_parent().get_parent() # Draw → Map


func _ready() -> void:
	_disc = _make_disc()


# A disc with a hard edge, so a sight range is a clear line, not a fade.
func _make_disc() -> Texture2D:
	var gradient := Gradient.new()
	gradient.set_offset(0, 0.0)
	gradient.set_color(0, Color.WHITE)
	gradient.set_offset(1, 1.0)
	gradient.set_color(1, Color(1, 1, 1, 0))
	gradient.add_point(0.97, Color.WHITE)
	var tex := GradientTexture2D.new()
	tex.gradient = gradient
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(1.0, 0.5)
	tex.width = DISC_SIZE
	tex.height = DISC_SIZE
	return tex


func set_active(on: bool) -> void:
	if on == active:
		return
	active = on
	var darkness: CanvasModulate = _map.get_node("Darkness")
	# The grid and the background colour sit on their own canvas layers, which
	# the darkness doesn't reach — so outside the map they'd still show.
	var grid: CanvasLayer = _map.get_node("ParallaxBackground")
	var background: ColorRect = Globals.BG_ColorRect
	if on:
		_saved_darkness = {
			"visible": darkness.visible, "color": darkness.color, "grid": grid.visible,
			"background": background.color if background != null else UNSEEN,
		}
		darkness.color = UNSEEN
		darkness.visible = true
		grid.visible = false
		if background != null:
			background.color = UNSEEN
		_hidden_layers.clear()
		for layer in _all_layers():
			if layer.visible and layer.get_meta("DM", 0):
				layer.visible = false
				_hidden_layers.append(layer)
	else:
		darkness.visible = _saved_darkness.get("visible", darkness.visible)
		darkness.color = _saved_darkness.get("color", darkness.color)
		grid.visible = _saved_darkness.get("grid", grid.visible)
		if background != null:
			background.color = _saved_darkness.get("background", background.color)
		for layer in _hidden_layers:
			if is_instance_valid(layer):
				layer.visible = true
		_hidden_layers.clear()
		_show_walls()
	for token in _tokens():
		if on:
			_light_up(token)
		else:
			_restore(token)


func _process(_delta: float) -> void:
	# Tokens come and go, and sheets change — keep every PC's light current.
	if active:
		for token in _tokens():
			_light_up(token)
		_hide_walls()


# Walls are the GM's markings: players see the shadow a wall casts, not the
# pink line. Only the line is hidden — the shadow is its sibling and keeps working.
var _hidden_wall_lines: Array = []

func _hide_walls() -> void:
	for layer in _all_layers():
		for object in layer.get_children():
			if Globals.draw_comp.is_wall(object):
				for child in object.get_children():
					if child is Line2D and child.visible:
						child.visible = false
						_hidden_wall_lines.append(child)


func _show_walls() -> void:
	for line in _hidden_wall_lines:
		if is_instance_valid(line):
			line.visible = true
	_hidden_wall_lines.clear()


func _tokens() -> Array:
	var map: Map_res = Globals.map if Globals.map != null else Globals.new_map
	if map == null:
		return []
	return map.tokens.filter(func(t): return t != null and is_instance_valid(t) and t.is_inside_tree() and t.fov != null)


func _all_layers() -> Array:
	var found: Array = []
	if Globals.layers == null:
		return found
	var item: TreeItem = Globals.layers.tree.get_root().get_next_in_tree()
	while item != null:
		found.append(item.get_meta("draw_layer"))
		item = item.get_next_in_tree()
	return found


# How far this character sees right now, in feet (0 = not at all).
static func sight_feet(character: Character, dark_map: bool) -> float:
	var sight := _attr_feet(character, "sight")
	if sight > 0:
		return sight
	return _attr_feet(character, "darkvision") if dark_map else LINE_OF_SIGHT_FT


# Reads "60 ft" or "60" from a character attribute; 0 if it isn't there.
static func _attr_feet(character: Character, key: String) -> float:
	var value = character.attributes.get(key)
	if value is Array and not value.is_empty():
		value = value[0]
	return maxf(0.0, str(value).to_float()) if value != null else 0.0


func _light_up(token) -> void:
	var light: PointLight2D = token.fov
	if not light.has_meta("before_player_view"):
		light.set_meta("before_player_view", {
			"visible": light.visible, "texture": light.texture, "texture_scale": light.texture_scale,
			"range_item_cull_mask": light.range_item_cull_mask, "shadow_item_cull_mask": light.shadow_item_cull_mask,
			"color": light.color,
		})
	var map: Map_res = Globals.map if Globals.map != null else Globals.new_map
	var feet := sight_feet(token.character, map != null and map.darkness_enable) if token.character.player_character else 0.0
	light.visible = feet > 0
	if feet <= 0:
		return
	light.texture = _disc
	light.texture_scale = MapMeasure.units_to_px(feet) * 2.0 / DISC_SIZE
	# Light the whole map, and let walls on any layer cast shadows.
	light.range_item_cull_mask = ALL_LAYERS
	light.shadow_item_cull_mask = ALL_LAYERS
	light.shadow_enabled = true
	light.color = Color.WHITE
	light.energy = 1.0


func _restore(token) -> void:
	var light: PointLight2D = token.fov
	if not light.has_meta("before_player_view"):
		return
	var before: Dictionary = light.get_meta("before_player_view")
	for key in before:
		light.set(key, before[key])
	light.remove_meta("before_player_view")

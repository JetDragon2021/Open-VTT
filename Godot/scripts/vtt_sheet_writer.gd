# Writes companion sheets onto VTT characters. Shared by the bridge panel (the
# "Send to VTT" button) and EventBridge (a boss changing phase mid-fight), which
# have to do exactly the same thing to a token — so it lives here, once.
#
# Deliberately knows nothing about EventBridge: the caller passes in what to run
# to reset the HP baseline. A script that EventBridge loads can't also depend on
# EventBridge without the two becoming compile-time dependencies of each other.

extends RefCounted

# Attribute groups written from a companion sheet, as "[group] name" keys. Only
# these are removed on a resync — anything the GM added by hand stays.
#   Feature/Mastery/Cantrip/Spell/Pending — a player character's sheet
#   Trait/Action/Reaction/Other            — a GM-made NPC
#   Legendary/Lair                         — a boss's legendary and lair actions
#   Phase N …                              — what a boss gained in a later phase
const SHEET_GROUP_PREFIXES = [
	"[Feature] ", "[Mastery] ", "[Cantrip] ", "[Spell ", "[Pending] ",
	"[Trait] ", "[Action] ", "[Reaction] ", "[Other] ",
	"[Legendary] ", "[Lair] ", "[Phase ",
]


# One grid square = 70px = 5 ft.
static func size_to_token_size(size: String) -> Vector2:
	match size:
		"Tiny":       return Vector2(35, 35)   # 2.5 ft — half square
		"Small":      return Vector2(70, 70)   # 5 ft  — 1×1
		"Medium":     return Vector2(70, 70)   # 5 ft  — 1×1
		"Large":      return Vector2(140, 140) # 10 ft — 2×2
		"Huge":       return Vector2(210, 210) # 15 ft — 3×3
		"Gargantuan": return Vector2(280, 280) # 20 ft — 4×4
	return Vector2(70, 70)


# Green for a player character, blue for an NPC — monsters are red.
static func hp_bar(is_pc: bool) -> Dictionary:
	return {
		"attr1":  "hp",
		"attr2":  "max_hp",
		"color":  Color(0.2, 0.7, 0.3, 1.0) if is_pc else Color(0.3, 0.5, 0.9, 1.0),
		"size":   10.0,
	}


# A sheet's attributes and abilities flattened to one "key: text" dictionary.
static func sheet_attributes(sheet: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	var attrs: Dictionary = sheet.get("attributes", {})
	for key in attrs:
		result[key] = str(attrs[key])
	for ab in sheet.get("abilities", []):
		result["[%s] %s" % [ab["group"], ab["name"]]] = str(ab["text"])
	return result


# The VTT character whose "name" attribute matches — that attribute is how the
# bridge ties a token to a companion entity.
static func find_character(tree: Tree, char_name: String) -> Object:
	if tree == null or char_name.is_empty():
		return null
	var root = tree.get_root()
	return _find_in_tree(root, char_name) if root != null else null


static func _find_in_tree(item: TreeItem, char_name: String) -> Object:
	if item.has_meta("character"):
		var character = item.get_meta("character")
		if character != null and str(character.attributes.get("name", ["", ""])[1]) == char_name:
			return character
	var child = item.get_first_child()
	while child != null:
		var found = _find_in_tree(child, char_name)
		if found != null:
			return found
		child = child.get_next()
	return null


# Resync after a level-up, a rest, or a boss changing phase: replaces what the
# companion owns and keeps tokens, bars, images and anything the GM added by hand.
# `rebaseline` is EventBridge.rebaseline_character — it must run before the
# signals below, because the bridge logs HP changes from attr_updated and taking
# the companion's HP must not be logged as damage or healing.
static func apply_update(character: Object, sheet: Dictionary, rebaseline: Callable) -> void:
	var incoming := sheet_attributes(sheet)

	var removed: Array = []
	for key in character.attributes.keys():
		if incoming.has(key):
			continue
		for prefix in SHEET_GROUP_PREFIXES:
			if str(key).begins_with(prefix):
				removed.append(key)
				break

	var created: Array = []
	var updated: Array = []
	for key in incoming:
		if not character.attributes.has(key):
			created.append(key)
		elif str(character.attributes[key][0]) != incoming[key]:
			updated.append(key)
		character.attributes[key] = [incoming[key], incoming[key]]
	for key in removed:
		character.attributes.erase(key)

	character.token_size = size_to_token_size(str(sheet.get("size", "Medium")))
	# An NPC that had no hit points when it was first sent may have gained some.
	if character.bars.is_empty() and incoming.has("hp") and incoming.has("max_hp"):
		character.bars = [hp_bar(str(sheet.get("kind", "pc")) == "pc")]
	character.save()

	rebaseline.call(character)
	for key in removed:
		character.emit_signal("attr_removed", key)
	for key in created:
		if character.token != null:
			character.token.on_attr_created(key, character.attributes[key])
		character.emit_signal("attr_created", key, character.attributes[key])
	for key in updated:
		character.emit_signal("attr_updated", key, false)
	character.emit_signal("bars_changed")
	character.emit_signal("attr_bubbles_changed")

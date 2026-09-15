# Bridge panel — settings, status, session control, and compendium browser.
# Attach to the BridgePanel Window node in bridge_panel.tscn.

extends Window

const MAX_LOG_LINES = 5
const MAX_RESULTS = 20

# ── Connection tab nodes ─────────────────────────────────────────────────────
var _url_input: LineEdit
var _secret_input: LineEdit
var _save_button: Button
var _test_button: Button
var _status_label: Label
var _start_button: Button
var _end_button: Button
var _log_label: Label
var _log_lines: Array = []

# ── Compendium tab nodes ─────────────────────────────────────────────────────
var _type_filter: OptionButton
var _search_input: LineEdit
var _results_list: ItemList
var _detail_panel: VBoxContainer
var _monster_name_label: Label
var _stats_label: Label
var _type_label: Label
var _abilities_label: Label
var _name_row: HBoxContainer
var _name_input: LineEdit
var _add_button: Button
var _compendium_status: Label

# ── Full monster dict (set on selection + enriched when detail arrives) ──────
var _full_monster: Dictionary = {}

# ── Character created locally, awaiting the companion's authoritative name ───
# The companion numbers duplicate names (Goblin, Goblin 2, …) because the event
# bridge resolves characters to entities BY NAME. We create the VTT character
# optimistically, then rename it to whatever the companion actually stored.
var _pending_character: Object = null
var _pending_tree_item: TreeItem = null

# ── Search debounce ──────────────────────────────────────────────────────────
var _search_timer: Timer


func _ready() -> void:
	# ── Connection tab ──────────────────────────────────────────────────────
	var conn = $VBoxContainer/TabContainer/Connection
	_url_input    = conn.get_node("URLInput")
	_secret_input = conn.get_node("SecretInput")
	_save_button  = conn.get_node("ButtonRow/SaveButton")
	_test_button  = conn.get_node("ButtonRow/TestButton")
	_status_label = conn.get_node("StatusLabel")
	_start_button = conn.get_node("SessionRow/StartButton")
	_end_button   = conn.get_node("SessionRow/EndButton")
	_log_label    = conn.get_node("LogLabel")

	# Pre-fill from saved config
	_url_input.text    = EventBridge._companion_url
	_secret_input.text = EventBridge._bridge_secret

	# Connection tab button signals
	_save_button.pressed.connect(_on_save_pressed)
	_test_button.pressed.connect(_on_test_pressed)
	_start_button.pressed.connect(_on_start_pressed)
	_end_button.pressed.connect(_on_end_pressed)

	# Bridge status changes
	EventBridge.status_changed.connect(update_status)
	update_status(EventBridge.get_status_text())

	# ── Compendium tab ──────────────────────────────────────────────────────
	var comp = $VBoxContainer/TabContainer/Compendium
	_type_filter       = comp.get_node("SearchRow/TypeFilter")
	_search_input      = comp.get_node("SearchRow/SearchInput")
	_results_list      = comp.get_node("ResultsList")
	_detail_panel      = comp.get_node("DetailPanel")
	_monster_name_label = comp.get_node("DetailPanel/MonsterNameLabel")
	_stats_label       = comp.get_node("DetailPanel/StatsLabel")
	_type_label        = comp.get_node("DetailPanel/TypeLabel")
	_abilities_label   = comp.get_node("DetailPanel/AbilitiesScroll/AbilitiesLabel")
	_name_row          = comp.get_node("NameRow")
	_name_input        = comp.get_node("NameRow/NameInput")
	_add_button        = comp.get_node("AddButton")
	_compendium_status = comp.get_node("CompendiumStatusLabel")

	# Debounce timer
	_search_timer = Timer.new()
	_search_timer.wait_time = 0.3
	_search_timer.one_shot = true
	add_child(_search_timer)
	_search_timer.timeout.connect(_on_search_timer_timeout)

	# Populate type filter dropdown
	_type_filter.add_item("All Types", 0)
	for creature_type in ["aberration", "beast", "celestial", "construct", "dragon",
			"elemental", "fey", "fiend", "giant", "humanoid",
			"monstrosity", "ooze", "plant", "undead"]:
		_type_filter.add_item(creature_type.capitalize(), _type_filter.item_count)
	_type_filter.item_selected.connect(_on_type_filter_changed)

	# Compendium tab signals
	_search_input.text_changed.connect(_on_search_text_changed)
	_results_list.item_selected.connect(_on_result_selected)
	_add_button.pressed.connect(_on_add_pressed)

	# EventBridge compendium signals
	EventBridge.compendium_results_received.connect(_on_compendium_results)
	EventBridge.monster_detail_received.connect(_on_monster_detail_received)
	EventBridge.compendium_spawn_completed.connect(_on_spawn_completed)
	EventBridge.compendium_spawn_failed.connect(_on_spawn_failed)

	# Tab change guard
	$VBoxContainer/TabContainer.tab_changed.connect(_on_tab_changed)


# ═══════════════════════════════════════════════════════════════════════════
# Connection tab
# ═══════════════════════════════════════════════════════════════════════════

func _on_save_pressed() -> void:
	EventBridge.save_config(_url_input.text, _secret_input.text)


func _on_test_pressed() -> void:
	_test_button.disabled = true
	_test_button.text = "Testing…"
	EventBridge.test_connection()
	await get_tree().create_timer(3.5).timeout
	_test_button.disabled = false
	_test_button.text = "Test Connection"


func _on_start_pressed() -> void:
	EventBridge.start_session()


func _on_end_pressed() -> void:
	EventBridge.end_session()


func update_status(status_text: String) -> void:
	if _status_label == null:
		return
	_status_label.text = status_text
	match EventBridge._connection_status:
		EventBridge.Status.CONNECTED:
			_status_label.modulate = Color(0.2, 0.9, 0.3)
		EventBridge.Status.ERROR:
			_status_label.modulate = Color(0.9, 0.3, 0.2)
		_:
			_status_label.modulate = Color(0.7, 0.7, 0.7)


func append_event_log(line: String) -> void:
	_log_lines.append(line)
	if _log_lines.size() > MAX_LOG_LINES:
		_log_lines.pop_front()
	if _log_label != null:
		_log_label.text = "\n".join(_log_lines)


# ═══════════════════════════════════════════════════════════════════════════
# Compendium tab — search (US1)
# ═══════════════════════════════════════════════════════════════════════════

func _on_tab_changed(tab: int) -> void:
	if tab == 1:
		_check_bridge_configured()


func _check_bridge_configured() -> void:
	if EventBridge._companion_url.is_empty() or EventBridge._bridge_secret.is_empty():
		_compendium_status.text = "Configure bridge connection first (Connection tab)."
		_search_input.editable = false
	else:
		_search_input.editable = true


func _on_search_text_changed(_new_text: String) -> void:
	_search_timer.stop()
	if _new_text.strip_edges().is_empty() and _selected_type().is_empty():
		_results_list.clear()
		_hide_detail()
		_compendium_status.text = ""
		return
	_search_timer.start()


func _selected_type() -> String:
	if _type_filter.selected <= 0:
		return ""
	return _type_filter.get_item_text(_type_filter.selected).to_lower()


func _on_type_filter_changed(_index: int) -> void:
	# Re-run search immediately when type filter changes
	_search_timer.stop()
	_fire_search()


func _fire_search() -> void:
	_check_bridge_configured()
	if not _search_input.editable:
		return
	var query = _search_input.text.strip_edges()
	var type  = _selected_type()
	# Require at least something to filter on — name OR type
	if query.is_empty() and type.is_empty():
		_results_list.clear()
		_hide_detail()
		_compendium_status.text = ""
		return
	EventBridge.search_compendium(query, type)


func _on_search_timer_timeout() -> void:
	_fire_search()


func _on_compendium_results(monsters: Array) -> void:
	_results_list.clear()
	_hide_detail()
	_compendium_status.text = ""
	if monsters.is_empty():
		_compendium_status.text = "No monsters found."
		return
	var shown = monsters.slice(0, MAX_RESULTS)
	for m in shown:
		var idx = _results_list.add_item("[CR %s]  %s  —  %s" % [m["crDisplay"], m["name"], m["type"]])
		_results_list.set_item_metadata(idx, m)
	if monsters.size() > MAX_RESULTS:
		var idx = _results_list.add_item("Showing first %d — refine search" % MAX_RESULTS)
		_results_list.set_item_disabled(idx, true)


func _hide_detail() -> void:
	_full_monster = {}
	_abilities_label.text = ""
	_detail_panel.visible = false
	_name_row.visible = false
	_add_button.visible = false
	_add_button.disabled = false


# ═══════════════════════════════════════════════════════════════════════════
# Compendium tab — preview (US2)
# ═══════════════════════════════════════════════════════════════════════════

func _on_result_selected(index: int) -> void:
	var m = _results_list.get_item_metadata(index)
	if m == null:
		return
	_full_monster = m  # summary data available immediately
	_detail_panel.visible = true
	_name_row.visible = true
	_add_button.visible = true
	_add_button.disabled = true  # wait for stat block
	_monster_name_label.text = m["name"]
	_stats_label.text = "AC %d  ·  HP %d (%s)" % [m["ac"], m["hpAverage"], m["hpFormula"]]
	_type_label.text = "%s  %s" % [m["size"], m["type"]]
	_name_input.text = m["name"]
	_abilities_label.text = ""
	_compendium_status.text = "Loading abilities…"
	EventBridge.fetch_monster_detail(m["slug"])


func _on_monster_detail_received(monster: Dictionary) -> void:
	_full_monster = monster
	_abilities_label.text = _format_abilities_preview(monster.get("statBlockJson", null))
	var ability_count = _count_abilities(monster.get("statBlockJson", {}))
	_compendium_status.text = "%d abilities loaded." % ability_count if ability_count > 0 else ""
	_add_button.disabled = false


func _format_abilities_preview(stat_block) -> String:
	if typeof(stat_block) != TYPE_DICTIONARY:
		return ""
	var sections: Array = []
	var section_labels = {
		"trait":     "Traits",
		"action":    "Actions",
		"reaction":  "Reactions",
		"legendary": "Legendary Actions",
		"bonus":     "Bonus Actions",
	}
	for key in ["trait", "action", "bonus", "reaction", "legendary"]:
		var abilities = stat_block.get(key, [])
		if typeof(abilities) != TYPE_ARRAY or abilities.is_empty():
			continue
		var lines: Array = ["— %s —" % section_labels[key]]
		for ability in abilities:
			if typeof(ability) != TYPE_DICTIONARY:
				continue
			var ability_name = str(ability.get("name", ""))
			if ability_name.is_empty():
				continue
			var text = _entries_to_text(ability.get("entries", []))
			lines.append("%s\n%s" % [ability_name, text] if not text.is_empty() else ability_name)
		sections.append("\n".join(lines))
	return "\n\n".join(sections)


# ═══════════════════════════════════════════════════════════════════════════
# Compendium tab — add to VTT (US3)
# ═══════════════════════════════════════════════════════════════════════════

func _on_add_pressed() -> void:
	var name = _name_input.text.strip_edges()
	if name.is_empty():
		_compendium_status.text = "Name is required."
		return
	if Globals.char_tree == null:
		_compendium_status.text = "Open a campaign map first before adding characters."
		return
	if _full_monster.is_empty():
		return

	# Clear first: _create_vtt_character can bail before creating anything, and
	# a leftover reference would rename the previously added character instead.
	_pending_character = null
	_pending_tree_item = null
	_create_vtt_character(name, _full_monster)

	_add_button.disabled = true
	_compendium_status.text = "Adding to companion…"
	EventBridge.spawn_entity(_full_monster.get("slug", ""), name)


func _size_to_token_size(size: String) -> Vector2:
	# One grid square = 70px = 5 ft
	match size:
		"Tiny":       return Vector2(35, 35)   # 2.5 ft — half square
		"Small":      return Vector2(70, 70)   # 5 ft  — 1×1
		"Medium":     return Vector2(70, 70)   # 5 ft  — 1×1
		"Large":      return Vector2(140, 140) # 10 ft — 2×2
		"Huge":       return Vector2(210, 210) # 15 ft — 3×3
		"Gargantuan": return Vector2(280, 280) # 20 ft — 4×4
	return Vector2(70, 70)


func _ability_mod_str(score: int) -> String:
	var mod = int(floor((score - 10.0) / 2.0))
	return "+%d" % mod if mod >= 0 else str(mod)


func _parse_speeds(speed_json) -> Dictionary:
	# 5etools speed values can be plain numbers OR objects like {"number":30,"condition":"..."}.
	if typeof(speed_json) != TYPE_DICTIONARY:
		return {"speed": "30 ft"}
	var name_map = {
		"walk":   "speed",
		"fly":    "fly_speed",
		"swim":   "swim_speed",
		"climb":  "climb_speed",
		"burrow": "burrow_speed",
	}
	var result: Dictionary = {}
	for key in name_map:
		if not speed_json.has(key):
			continue
		var val = speed_json[key]
		var num: int = 0
		match typeof(val):
			TYPE_INT, TYPE_FLOAT:
				num = int(val)
			TYPE_DICTIONARY:
				num = int(val.get("number", 0))
			TYPE_STRING:
				num = val.to_int()
			_:
				continue
		if num > 0:
			result[name_map[key]] = "%d ft" % num
	return result if not result.is_empty() else {"speed": "30 ft"}


func _entries_to_text(entries) -> String:
	if entries == null:
		return ""
	# Plain string — most common case
	if typeof(entries) == TYPE_STRING:
		return entries
	# Scalar (number/bool from some 5etools entries)
	if typeof(entries) in [TYPE_INT, TYPE_FLOAT, TYPE_BOOL]:
		return str(entries)
	if typeof(entries) != TYPE_ARRAY:
		return ""
	var parts: Array = []
	for entry in entries:
		if entry == null:
			continue
		match typeof(entry):
			TYPE_STRING:
				parts.append(entry)
			TYPE_INT, TYPE_FLOAT, TYPE_BOOL:
				parts.append(str(entry))
			TYPE_DICTIONARY:
				var t = entry.get("type", "")
				match t:
					"entries", "section":
						var sub = _entries_to_text(entry.get("entries", []))
						if not sub.is_empty():
							parts.append(sub)
					"item":
						var n = str(entry.get("name", ""))
						var e = _entries_to_text(entry.get("entry", entry.get("entries", [])))
						if not n.is_empty() and not e.is_empty():
							parts.append(n + ". " + e)
						elif not e.is_empty():
							parts.append(e)
					"list":
						var items = entry.get("items", [])
						parts.append(_entries_to_text(items))
					"table":
						var caption = entry.get("caption", "")
						if not caption.is_empty():
							parts.append("[Table: %s]" % caption)
					_:
						# Fallback: try common sub-entry keys
						for sub_key in ["entries", "items", "entry"]:
							var sub_val = entry.get(sub_key, null)
							if sub_val != null:
								var sub = _entries_to_text(sub_val)
								if not sub.is_empty():
									parts.append(sub)
									break
			_:
				pass
	return "\n".join(parts)


func _add_ability_group(character, stat_block: Dictionary, key: String, prefix: String) -> int:
	var abilities = stat_block.get(key, [])
	if typeof(abilities) != TYPE_ARRAY:
		return 0
	var count = 0
	for ability in abilities:
		if typeof(ability) != TYPE_DICTIONARY:
			continue
		var ability_name = ability.get("name", "")
		if ability_name.is_empty():
			continue
		var text = _entries_to_text(ability.get("entries", []))
		var attr_key = "[%s] %s" % [prefix, ability_name]
		character.attributes[attr_key] = [text, text]
		count += 1
	return count


func _count_abilities(stat_block) -> int:
	if typeof(stat_block) != TYPE_DICTIONARY:
		return 0
	var total = 0
	for key in ["trait", "action", "reaction", "legendary"]:
		var arr = stat_block.get(key, [])
		if typeof(arr) == TYPE_ARRAY:
			total += arr.size()
	return total


func _create_vtt_character(char_name: String, monster: Dictionary) -> void:
	var root = Globals.char_tree.get_root()
	var campaign_item: TreeItem = null
	var child = root.get_first_child()
	while child != null:
		if child.get_text(0) == "Campaign":
			campaign_item = child
			break
		child = child.get_next()
	if campaign_item == null:
		campaign_item = root.get_first_child()
	if campaign_item == null:
		_compendium_status.text = "No character group found — load a campaign map first."
		return

	var tree_item = Globals.char_tree.add_new_item(char_name, campaign_item)
	var character = tree_item.get_meta("character")

	# Remember them so _on_spawn_completed can apply the companion's final name.
	_pending_tree_item = tree_item
	_pending_character = character

	# Clear any attributes duplicated from the parent character folder —
	# we want a clean slate populated entirely from the compendium stat block.
	character.attributes.clear()

	# ── Identity & core combat ───────────────────────────────────────────────
	var hp  = int(monster.get("hpAverage", 1))
	var ac  = int(monster.get("ac", 10))
	character.attributes["name"]    = [char_name, char_name]
	character.attributes["hp"]      = [str(hp), str(hp)]
	character.attributes["max_hp"]  = [str(hp), str(hp)]
	character.attributes["hp_formula"] = [monster.get("hpFormula", ""), monster.get("hpFormula", "")]
	character.attributes["ac"]      = [str(ac), str(ac)]
	character.attributes["cr"]      = [monster.get("crDisplay", "—"), monster.get("crDisplay", "—")]
	character.attributes["type"]    = [monster.get("type", ""), monster.get("type", "")]
	character.attributes["size"]    = [monster.get("size", ""), monster.get("size", "")]

	# ── Ability scores + modifiers ───────────────────────────────────────────
	for ability in ["str", "dex", "con", "int", "wis", "cha"]:
		var score = int(monster.get(ability, 10))
		character.attributes[ability]          = [str(score), str(score)]
		character.attributes[ability + "_mod"] = [_ability_mod_str(score), _ability_mod_str(score)]

	# ── Derived stats ────────────────────────────────────────────────────────
	var wis_score = int(monster.get("wis", 10))
	var wis_mod   = int(floor((wis_score - 10.0) / 2.0))
	var passive_perc = str(10 + wis_mod)
	character.attributes["passive_perception"] = [passive_perc, passive_perc]

	# ── Speed ────────────────────────────────────────────────────────────────
	var speeds = _parse_speeds(monster.get("speedJson", null))
	for attr_name in speeds:
		character.attributes[attr_name] = [speeds[attr_name], speeds[attr_name]]

	# ── Token size ───────────────────────────────────────────────────────────
	character.token_size = _size_to_token_size(monster.get("size", "Medium"))

	# ── HP bar ───────────────────────────────────────────────────────────────
	character.bars = [{
		"attr1":  "hp",
		"attr2":  "max_hp",
		"color":  Color(0.8, 0.2, 0.2, 1.0),
		"size":   10.0,
	}]

	# ── Attr bubbles (visible on token during play) ──────────────────────────
	character.attr_bubbles = [
		{"name": "ac",    "edit": false, "icon": "", "image": ""},
		{"name": "speed", "edit": false, "icon": "", "image": ""},
	]

	# ── Abilities from stat block ────────────────────────────────────────────
	var stat_block = monster.get("statBlockJson", null)
	if typeof(stat_block) == TYPE_DICTIONARY:
		_add_ability_group(character, stat_block, "trait",     "Trait")
		_add_ability_group(character, stat_block, "action",    "Action")
		_add_ability_group(character, stat_block, "reaction",  "Reaction")
		_add_ability_group(character, stat_block, "legendary", "Legendary")

	character.save()


func _on_spawn_completed(_entity_id: String, entity_name: String) -> void:
	_add_button.disabled = false

	# The companion is authoritative on the name — it appends a number when one
	# is already taken. Adopt its name so the event bridge's name-based lookup
	# resolves this character to this entity and not to an earlier duplicate.
	var renamed := false
	if not entity_name.is_empty() and _pending_character != null:
		var local_name: String = str(_pending_character.attributes.get("name", ["", ""])[1])
		if local_name != entity_name:
			_pending_character.attributes["name"] = [entity_name, entity_name]
			_pending_character.save()
			if _pending_tree_item != null:
				_pending_tree_item.set_text(0, entity_name)
			renamed = true

	_pending_character = null
	_pending_tree_item = null

	if renamed:
		_compendium_status.text = "✓ Added as \"%s\" (name was taken)." % entity_name
	else:
		_compendium_status.text = "✓ %s added to VTT and companion." % entity_name


func _on_spawn_failed(error: String) -> void:
	_add_button.disabled = false
	var char_name = _name_input.text.strip_edges()
	# The VTT character exists but has no companion entity, so HP changes on it
	# will not be logged until a matching entity is created.
	_pending_character = null
	_pending_tree_item = null
	_compendium_status.text = "⚠ %s added to VTT only — companion save failed: %s" % [char_name, error]

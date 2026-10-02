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
var _session_status_label: Label

# ── Header (always visible) ──────────────────────────────────────────────────
const EXPANDED_SIZE = Vector2i(460, 760)
# Wide enough for the session status, Note and Expand; tall enough for one row.
const COMPACT_SIZE = Vector2i(340, 100)
var _tabs: TabContainer
var _mini_status: Label
var _note_button: Button
var _minimize_button: Button
var _compact: bool = false
# The size the GM had it at, restored on expand — they may have resized it.
var _expanded_size: Vector2i = EXPANDED_SIZE
var _log_label: Label
var _log_lines: Array = []
var _path_input: LineEdit
var _open_button: Button
var _player_link_input: LineEdit
var _copy_link_button: Button
var _player_link_status: Label
# Re-checks the player link until the tunnel is up; it can take a minute.
var _link_timer: Timer

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

# ── Characters tab nodes ─────────────────────────────────────────────────────
var _refresh_button: Button
var _character_list: ItemList
var _sheet_preview_label: Label
var _send_button: Button
var _characters_status: Label
var _kind_picker: OptionButton
var _characters_hint: Label
# "pc" lists player characters; "npc" lists the GM's NPCs.
var _kind: String = "pc"

# The companion sheet (lib/vtt-sheet.ts) of the selected character, once loaded.
var _selected_sheet: Dictionary = {}
# Writing companion sheets onto VTT characters is shared with EventBridge, which
# does the same when a boss changes phase.
const VttSheetWriter = preload("res://scripts/vtt_sheet_writer.gd")


func _ready() -> void:
	_place_on_open_map()
	get_tree().root.size_changed.connect(_keep_on_screen)
	# ── Connection tab ──────────────────────────────────────────────────────
	var conn = $VBoxContainer/TabContainer/Connection
	_url_input    = conn.get_node("URLInput")
	_secret_input = conn.get_node("SecretInput")
	_save_button  = conn.get_node("ButtonRow/SaveButton")
	_test_button  = conn.get_node("ButtonRow/TestButton")
	_status_label = conn.get_node("StatusLabel")
	_start_button = conn.get_node("SessionRow/StartButton")
	_end_button   = conn.get_node("SessionRow/EndButton")
	_session_status_label = conn.get_node("SessionStatusLabel")
	_log_label    = conn.get_node("LogLabel")
	_path_input   = conn.get_node("PathInput")
	_open_button  = conn.get_node("OpenButton")
	_player_link_input  = conn.get_node("PlayerLinkRow/PlayerLinkInput")
	_copy_link_button   = conn.get_node("PlayerLinkRow/CopyLinkButton")
	_player_link_status = conn.get_node("PlayerLinkStatus")
	_copy_link_button.pressed.connect(_copy_player_link)
	conn.get_node("PlayerLinkRow/RefreshLinkButton").pressed.connect(_refresh_player_link)
	_link_timer = Timer.new()
	_link_timer.wait_time = 5.0
	_link_timer.timeout.connect(_refresh_player_link)
	add_child(_link_timer)

	# ── Header ──────────────────────────────────────────────────────────────
	var header = $VBoxContainer/HeaderRow
	_tabs            = $VBoxContainer/TabContainer
	_mini_status     = header.get_node("MiniStatus")
	_note_button     = header.get_node("NoteButton")
	_minimize_button = header.get_node("MinimizeButton")
	_note_button.pressed.connect(EventBridge.open_note_window)
	_minimize_button.pressed.connect(_toggle_compact)
	# A Window doesn't hide itself when its close button is pressed, so without
	# this the X did nothing and the panel couldn't be put away.
	close_requested.connect(hide)

	# Pre-fill from saved config
	_url_input.text    = EventBridge._companion_url
	_secret_input.text = EventBridge._bridge_secret
	_path_input.text   = EventBridge._companion_path

	# Connection tab button signals
	_save_button.pressed.connect(_on_save_pressed)
	_open_button.pressed.connect(_on_open_pressed)
	EventBridge.launch_finished.connect(_set_open_busy.bind(false))
	EventBridge.launch_finished.connect(_refresh_player_link)
	# A launch started before the panel was reopened may still be running.
	_set_open_busy(EventBridge.is_launching())
	_test_button.pressed.connect(_on_test_pressed)
	_start_button.pressed.connect(_on_start_pressed)
	_end_button.pressed.connect(_on_end_pressed)

	# Bridge status changes
	EventBridge.status_changed.connect(update_status)
	update_status(EventBridge.get_status_text())

	# Session status
	EventBridge.session_status_changed.connect(_on_session_status_changed)
	EventBridge.refresh_session_status()
	_refresh_player_link()

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

	# ── Characters tab ──────────────────────────────────────────────────────
	var chars = $VBoxContainer/TabContainer/Characters
	_refresh_button      = chars.get_node("RefreshButton")
	_character_list      = chars.get_node("CharacterList")
	_sheet_preview_label = chars.get_node("SheetPreviewScroll/SheetPreviewLabel")
	_send_button         = chars.get_node("SendButton")
	_characters_status   = chars.get_node("CharactersStatusLabel")
	_kind_picker         = chars.get_node("KindPicker")
	_characters_hint     = chars.get_node("CharactersHint")
	_kind_picker.add_item("Player characters")
	_kind_picker.add_item("NPCs")
	_kind_picker.item_selected.connect(_on_kind_selected)
	_refresh_button.pressed.connect(_refresh_characters)
	_character_list.item_selected.connect(_on_character_selected)
	_send_button.pressed.connect(_on_send_pressed)
	EventBridge.characters_received.connect(_on_characters_received)
	EventBridge.character_sheet_received.connect(_on_character_sheet_received)
	EventBridge.characters_failed.connect(_on_characters_failed)

	# Tab change guard
	$VBoxContainer/TabContainer.tab_changed.connect(_on_tab_changed)


# ═══════════════════════════════════════════════════════════════════════════
# Connection tab
# ═══════════════════════════════════════════════════════════════════════════

# ── Where the window sits ────────────────────────────────────────────────────
# A Window with no position opens in the top-left corner — right on top of the
# map toolbar, expanded or minimized. It opens instead over empty map, just left
# of the right-hand tabs and under the top bar, stays wholly on screen, and goes
# wherever the GM drags it from then on.

const TOP_BAR = 84        # clear of the Bridge / Maps buttons: 44, plus the window's own title bar above its position
const RIGHT_PANELS = 310  # the Characters / Object tabs and the roll panel
const GAP = 12

func _place_on_open_map() -> void:
	var view := get_tree().root.get_visible_rect().size
	position = Vector2i(int(view.x) - RIGHT_PANELS - size.x - GAP, TOP_BAR)
	_keep_on_screen()


# Pulls the window back inside the screen — after a resize of the app, or when
# opening it grew past an edge. Leaves it alone otherwise, wherever it was put.
func _keep_on_screen() -> void:
	var view := get_tree().root.get_visible_rect().size
	position = Vector2i(
		clampi(position.x, 0, maxi(0, int(view.x) - size.x)),
		clampi(position.y, 0, maxi(0, int(view.y) - size.y)))


func _on_save_pressed() -> void:
	EventBridge.save_config(_url_input.text, _secret_input.text, _path_input.text)


func _on_open_pressed() -> void:
	# Save first so the launcher uses what's on screen, not the last saved values.
	EventBridge.save_config(_url_input.text, _secret_input.text, _path_input.text)
	_set_open_busy(true)
	EventBridge.open_companion()


func _set_open_busy(busy: bool) -> void:
	_open_button.disabled = busy
	_open_button.text = "Opening…" if busy else "Open Companion"


func _on_test_pressed() -> void:
	_test_button.disabled = true
	_test_button.text = "Testing…"
	EventBridge.test_connection()
	_refresh_player_link()
	await get_tree().create_timer(3.5).timeout
	_test_button.disabled = false
	_test_button.text = "Test Connection"


# ── Player link ──────────────────────────────────────────────────────────────
# The companion's launcher starts the player site and a tunnel to it; this
# shows the public link it got, so the GM can paste it to the players.

func _refresh_player_link() -> void:
	EventBridge.fetch_player_link(_on_player_link)


func _on_player_link(code: int, data: Dictionary) -> void:
	var url := str(data.get("url", "")) if data.get("url") != null else ""
	var status := str(data.get("status", ""))
	_player_link_input.text = url
	_copy_link_button.disabled = url.is_empty()
	if code != 200:
		_player_link_status.text = str(data.get("error", "Couldn't ask the companion for the link"))
		_player_link_status.modulate = Color(0.7, 0.7, 0.7)
	elif status == "up":
		_player_link_status.text = "● Players can open it now. It changes every time the companion starts."
		_player_link_status.modulate = Color(0.2, 0.9, 0.3)
	else:
		_player_link_status.text = str(data.get("message", "")) if data.get("message") != null else "Starting…"
		_player_link_status.modulate = Color(0.95, 0.7, 0.2) if status == "starting" else Color(0.9, 0.4, 0.3)
	# Keep checking while it's on its way; stop once there's a link or nothing is running.
	if status == "starting" or (status == "error" and code == 200 and url.is_empty() and str(data.get("message", "")).contains("trying again")):
		if _link_timer.is_stopped():
			_link_timer.start()
	else:
		_link_timer.stop()


func _copy_player_link() -> void:
	if _player_link_input.text.is_empty():
		return
	DisplayServer.clipboard_set(_player_link_input.text)
	_player_link_status.text = "✓ Copied — paste it to your players."
	_player_link_status.modulate = Color(0.2, 0.9, 0.3)


func _on_start_pressed() -> void:
	EventBridge.start_session()


func _on_end_pressed() -> void:
	EventBridge.end_session()


func _on_session_status_changed(active: bool, session_name: String) -> void:
	if _session_status_label == null:
		return
	if active:
		_session_status_label.text = "● Session active: %s" % session_name
		_session_status_label.modulate = Color(0.2, 0.9, 0.3)
	else:
		_session_status_label.text = "○ No session running"
		_session_status_label.modulate = Color(0.7, 0.7, 0.7)
	# The collapsed strip shows the same thing, so it's readable without expanding.
	_mini_status.text = ("● %s" % session_name) if active else "○ No session"
	_mini_status.modulate = _session_status_label.modulate


# Embedded sub-windows have no native minimize, so this collapses the panel to
# a strip that still shows whether a session is running.
func _toggle_compact() -> void:
	_set_compact(not _compact)


func _set_compact(compact: bool) -> void:
	if compact == _compact:
		return
	if compact:
		_expanded_size = size
	_compact = compact
	_tabs.visible = not compact
	_mini_status.visible = compact
	_minimize_button.text = "Expand" if compact else "Minimize"
	_minimize_button.tooltip_text = "Show the full bridge panel" if compact else "Shrink this window to a small strip"
	var old_width := size.x
	size = COMPACT_SIZE if compact else _expanded_size
	# Keep the right edge where it was, so it shrinks and grows toward the map.
	position.x += old_width - size.x
	_keep_on_screen()


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
	elif tab == 2:
		_refresh_characters()


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
			var text = _entries_to_text(ability.get("text", ability.get("entries", [])))
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
	return VttSheetWriter.size_to_token_size(size)


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
		var text = _entries_to_text(ability.get("text", ability.get("entries", [])))
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


# ═══════════════════════════════════════════════════════════════════════════
# Characters tab — send companion character sheets to the VTT
# ═══════════════════════════════════════════════════════════════════════════

func _on_kind_selected(index: int) -> void:
	_kind = "npc" if index == 1 else "pc"
	_characters_hint.text = "NPCs in the companion's active campaign." if _kind == "npc" else "Player characters in the companion's active campaign."
	_character_list.clear()
	_selected_sheet = {}
	_sheet_preview_label.text = ""
	_send_button.disabled = true
	_refresh_characters()


func _refresh_characters() -> void:
	if EventBridge._companion_url.is_empty() or EventBridge._bridge_secret.is_empty():
		_characters_status.text = "Configure bridge connection first (Connection tab)."
		return
	_characters_status.text = "Loading NPCs…" if _kind == "npc" else "Loading characters…"
	EventBridge.fetch_characters(_kind)


func _on_characters_received(characters: Array) -> void:
	_character_list.clear()
	_selected_sheet = {}
	_sheet_preview_label.text = ""
	_send_button.disabled = true
	if characters.is_empty():
		_characters_status.text = "No NPCs in the active campaign yet — make one in the companion." if _kind == "npc" else "No characters in the active campaign yet."
		return
	_characters_status.text = ""
	for c in characters:
		if _kind == "npc":
			var detail = " · ".join(PackedStringArray([str(c.get("summary", "")), str(c.get("creatureType", ""))].filter(func(x): return x != "" and x != "<null>")))
			var npc_on_vtt = "  ✓ on VTT" if _find_vtt_character(str(c["name"])) != null else ""
			var npc_idx = _character_list.add_item("%s%s%s" % [c["name"], " — " + detail if detail != "" else "", npc_on_vtt])
			_character_list.set_item_metadata(npc_idx, c)
			continue
		# classLabel names every class ("Fighter 3 (Champion) / Wizard 1"); an
		# older companion only sends className, so fall back to it.
		var classes = str(c.get("classLabel", c["className"]))
		var on_vtt = "  ✓ on VTT" if _find_vtt_character(str(c["name"])) != null else ""
		var idx = _character_list.add_item("%s — Level %d %s, %s%s" % [c["name"], int(c["level"]), classes, c["species"], on_vtt])
		_character_list.set_item_metadata(idx, c)


func _on_character_selected(index: int) -> void:
	var c = _character_list.get_item_metadata(index)
	if c == null:
		return
	_selected_sheet = {}
	_send_button.disabled = true
	_sheet_preview_label.text = ""
	_characters_status.text = "Loading sheet…"
	EventBridge.fetch_character_sheet(str(c["id"]), _kind)


func _on_character_sheet_received(sheet: Dictionary) -> void:
	_selected_sheet = sheet
	var a: Dictionary = sheet.get("attributes", {})
	var lines: Array = []
	if str(sheet.get("kind", "pc")) == "npc":
		# An NPC only has what the GM filled in, so list just that.
		lines.append("%s — %s" % [a.get("name", ""), a.get("role", "NPC")])
		var facts: Array = []
		for key in ["type", "ac", "speed"]:
			if a.has(key):
				facts.append(("AC %s" if key == "ac" else "%s") % a[key])
		facts.push_front(str(sheet.get("size", "Medium")))
		lines.append(" · ".join(PackedStringArray(facts)))
		lines.append("HP %s/%s" % [a["hp"], a["max_hp"]] if a.has("hp") else "No hit points — damage on this token won't be tracked.")
		if sheet.has("boss") or a.has("legendary_resistance") or a.has("legendary_actions"):
			var boss_bits: Array = []
			if sheet.has("boss"):
				boss_bits.append("Phase %d of %d" % [int(sheet["boss"]["currentPhase"]), int(sheet["boss"]["phases"])])
			if a.has("legendary_resistance"):
				boss_bits.append("Legendary resistance %s" % a["legendary_resistance"])
			if a.has("legendary_actions"):
				boss_bits.append("Legendary actions %s" % a["legendary_actions"])
			lines.append("Boss · " + " · ".join(PackedStringArray(boss_bits)))
		if a.has("str"):
			lines.append("STR %s  DEX %s  CON %s  INT %s  WIS %s  CHA %s" % [a.get("str", ""), a.get("dex", ""), a.get("con", ""), a.get("int", ""), a.get("wis", ""), a.get("cha", "")])
	else:
		lines = [
			"%s — %s" % [a.get("name", ""), a.get("class", "")],
			"%s · %s" % [a.get("species", ""), a.get("background", "")],
			"HP %s/%s · AC %s · Speed %s · Init %s · PB %s" % [a.get("hp", ""), a.get("max_hp", ""), a.get("ac", ""), a.get("speed", ""), a.get("initiative", ""), a.get("proficiency_bonus", "")],
			"STR %s  DEX %s  CON %s  INT %s  WIS %s  CHA %s" % [a.get("str", ""), a.get("dex", ""), a.get("con", ""), a.get("int", ""), a.get("wis", ""), a.get("cha", "")],
		]
	if a.has("spell_save_dc"):
		lines.append("Spell save DC %s · Spell attack %s" % [a["spell_save_dc"], a.get("spell_attack", "")])
	var counts: Dictionary = {}
	for ab in sheet.get("abilities", []):
		counts[ab["group"]] = counts.get(ab["group"], 0) + 1
	for group in counts:
		lines.append("%d × %s" % [counts[group], group])
	_sheet_preview_label.text = "\n".join(lines)
	var existing = _find_vtt_character(str(sheet.get("name", "")))
	_send_button.text = "Update on VTT" if existing != null else "Send to VTT"
	_send_button.disabled = false
	_characters_status.text = ""


func _on_characters_failed(error: String) -> void:
	_characters_status.text = "⚠ " + error


func _on_send_pressed() -> void:
	if _selected_sheet.is_empty():
		return
	if Globals.char_tree == null:
		_characters_status.text = "Open a campaign map first before adding characters."
		return
	var char_name = str(_selected_sheet.get("name", ""))
	var character = _find_vtt_character(char_name)
	if character != null:
		_update_vtt_character(character, _selected_sheet)
		_characters_status.text = "✓ %s updated on the VTT." % char_name
	else:
		if _create_sheet_character(_selected_sheet):
			_characters_status.text = "✓ %s added to the VTT. HP changes on its tokens are logged to the companion." % char_name
	_send_button.text = "Update on VTT"


# The event bridge matches tokens to companion entities by the "name"
# attribute, so that is what identifies a synced character.
func _find_vtt_character(char_name: String) -> Object:
	return VttSheetWriter.find_character(Globals.char_tree, char_name)


# Creates a VTT character from a companion sheet — a player character or an NPC.
func _create_sheet_character(sheet: Dictionary) -> bool:
	var root = Globals.char_tree.get_root()
	var campaign_item: TreeItem = null
	var child = root.get_first_child() if root != null else null
	while child != null:
		if child.get_text(0) == "Campaign":
			campaign_item = child
			break
		child = child.get_next()
	if campaign_item == null and root != null:
		campaign_item = root.get_first_child()
	if campaign_item == null:
		_characters_status.text = "No character group found — load a campaign map first."
		return false

	var char_name = str(sheet.get("name", ""))
	var tree_item = Globals.char_tree.add_new_item(char_name, campaign_item)
	var character = tree_item.get_meta("character")
	# Start clean rather than inheriting the parent folder's attributes.
	character.attributes.clear()
	var is_pc = str(sheet.get("kind", "pc")) == "pc"
	# Player characters get the player flag (their token lights the map for them);
	# an NPC is the GM's, like a monster.
	character.player_character = is_pc
	_write_sheet(character, sheet)
	character.token_size = _size_to_token_size(str(sheet.get("size", "Medium")))
	# An NPC with no hit points has nothing to draw a bar for, and nothing for
	# the bridge to log damage against.
	var attrs: Dictionary = sheet.get("attributes", {})
	if attrs.has("hp") and attrs.has("max_hp"):
		character.bars = [_hp_bar(is_pc)]
	var bubbles: Array = []
	for bubble in ["ac", "speed"]:
		if attrs.has(bubble):
			bubbles.append({"name": bubble, "edit": false, "icon": "", "image": ""})
	character.attr_bubbles = bubbles
	character.save()
	EventBridge.rebaseline_character(character)
	return true


# Resync after a level-up or rest: replaces what the companion owns and keeps
# tokens, bars, images and anything the GM added by hand.
func _update_vtt_character(character: Object, sheet: Dictionary) -> void:
	VttSheetWriter.apply_update(character, sheet, EventBridge.rebaseline_character)


# Green for a player character, blue for an NPC — monsters are red.
func _hp_bar(is_pc: bool) -> Dictionary:
	return VttSheetWriter.hp_bar(is_pc)


func _write_sheet(character: Object, sheet: Dictionary) -> void:
	var incoming = _sheet_attributes(sheet)
	for key in incoming:
		character.attributes[key] = [incoming[key], incoming[key]]


func _sheet_attributes(sheet: Dictionary) -> Dictionary:
	return VttSheetWriter.sheet_attributes(sheet)

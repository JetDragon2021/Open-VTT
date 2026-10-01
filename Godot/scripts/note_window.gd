# Quick note — a small pop-up for logging a narrative event into the running
# session without leaving the map. Open it with Ctrl+Shift+N or the bridge
# panel's Note button; Ctrl+Enter logs and closes, Escape closes.

extends Window

const TYPE_ORDER = ["pc", "npc", "monster", "location", "faction", "item", "quest", "thread"]
const TYPE_LABEL = {
	"pc": "PC", "npc": "NPC", "monster": "monster", "location": "location",
	"faction": "faction", "item": "item", "quest": "quest", "thread": "plot thread",
}
# What the window logs: a note, or a new quest / plot thread for the
# companion's quest board. [label, mode, quest name placeholder]
const MODES = [
	["Note", "note", ""],
	["Open new quest", "quest", "Quest name — \"Find the mayor's daughter\""],
	["Open new plot thread", "thread", "Plot thread — \"Who is paying the bandits?\""],
]
const NOTE_PLACEHOLDER = "What happened? A promise, a discovery, a decision…"
const QUEST_PLACEHOLDER = "What's it about? Who asked, what's at stake… (optional)"
# What a note can create on the spot — the kinds with no other screen yet.
const NEW_TYPES = [["NPC", "npc"], ["Location", "location"], ["Faction", "faction"]]

const COLOR_OK = Color(0.2, 0.9, 0.3)
const COLOR_WARN = Color(0.95, 0.7, 0.2)
const COLOR_ERROR = Color(0.9, 0.3, 0.2)
const COLOR_MUTED = Color(0.7, 0.7, 0.7)

var _session_label: Label
var _mode_picker: OptionButton
var _quest_name: LineEdit
var _steps_input: TextEdit
var _about_row: Control
var _new_row: Control
var _picker: OptionButton
var _new_name: LineEdit
var _new_type: OptionButton
var _add_button: Button
var _note_input: TextEdit
var _status_label: Label
var _close_button: Button
var _log_button: Button
var _log_close_button: Button

# Survives a refresh, and a close/reopen, so the next note about the same
# person doesn't mean finding them in the list again.
var _selected_id: String = ""
var _busy: bool = false
var _placed: bool = false


func _ready() -> void:
	var root = $VBoxContainer
	_session_label = root.get_node("SessionLabel")
	_mode_picker   = root.get_node("ModeRow/ModePicker")
	_quest_name    = root.get_node("QuestName")
	_steps_input   = root.get_node("StepsInput")
	_about_row     = root.get_node("AboutRow")
	_new_row       = root.get_node("NewRow")
	_picker        = root.get_node("AboutRow/EntityPicker")
	_new_name      = root.get_node("NewRow/NewName")
	_new_type      = root.get_node("NewRow/NewType")
	_add_button    = root.get_node("NewRow/AddButton")
	_note_input    = root.get_node("NoteInput")
	_status_label  = root.get_node("StatusLabel")
	_close_button  = root.get_node("ButtonRow/CloseButton")
	_log_button    = root.get_node("ButtonRow/LogButton")
	_log_close_button = root.get_node("ButtonRow/LogCloseButton")

	for m in MODES:
		_mode_picker.add_item(m[0])
		_mode_picker.set_item_metadata(_mode_picker.item_count - 1, m[1])
	_mode_picker.item_selected.connect(func(_i: int) -> void: _apply_mode())
	_quest_name.text_submitted.connect(func(_text: String) -> void: _log(false))
	_apply_mode()

	for t in NEW_TYPES:
		_new_type.add_item(t[0])
		_new_type.set_item_metadata(_new_type.item_count - 1, t[1])

	# A Window doesn't hide itself when its close button is pressed.
	close_requested.connect(hide)
	_close_button.pressed.connect(hide)
	_log_button.pressed.connect(_log.bind(false))
	_log_close_button.pressed.connect(_log.bind(true))
	_add_button.pressed.connect(_add_entity)
	_new_name.text_submitted.connect(func(_text: String) -> void: _add_entity())
	_picker.item_selected.connect(_on_picker_selected)
	_note_input.gui_input.connect(_on_note_gui_input)
	EventBridge.session_status_changed.connect(_on_session_status_changed)


# Called each time the window is summoned. Shows it where the GM left it after
# the first time, and always starts from a fresh look at the campaign.
func open() -> void:
	if not _placed:
		popup_centered()
		_placed = true
	else:
		show()
	grab_focus()
	_set_status("", COLOR_MUTED)
	_update_session_label()
	EventBridge.refresh_session_status()
	_refresh_entities()
	_note_input.grab_focus()


func _input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if visible and key != null and key.pressed and not key.echo and key.keycode == KEY_ESCAPE:
		hide()
		set_input_as_handled()


func _on_note_gui_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	if (key.keycode == KEY_ENTER or key.keycode == KEY_KP_ENTER) and key.ctrl_pressed:
		_note_input.accept_event()
		_log(true)


# ── Session status ──────────────────────────────────────────────────────────

func _on_session_status_changed(_active: bool, _session_name: String) -> void:
	_update_session_label()


func _update_session_label() -> void:
	if _session_label == null:
		return
	if EventBridge.session_active:
		_session_label.text = "● Session active: %s" % EventBridge.session_name
		_session_label.modulate = COLOR_OK
	else:
		# The companion accepts the note but files it under no session, so it
		# would never reach a recap. Worth saying before the GM writes it.
		_session_label.text = "○ No session running — a note logged now won't appear in any session or its recap."
		_session_label.modulate = COLOR_WARN


# ── Who the note is about ───────────────────────────────────────────────────

func _refresh_entities() -> void:
	_set_status("Loading…", COLOR_MUTED)
	EventBridge.fetch_entities(_on_entities)


func _on_entities(code: int, data: Dictionary) -> void:
	if code != 200:
		_set_status(str(data.get("error", "Couldn't load characters and places")), COLOR_ERROR)
		return
	_set_status("", COLOR_MUTED)
	_populate(data.get("entities", []))


func _populate(entities: Array) -> void:
	var keep := _current_id()
	if keep.is_empty():
		keep = _selected_id
	_picker.clear()

	var sorted := entities.duplicate()
	sorted.sort_custom(func(a, b) -> bool:
		var ta := TYPE_ORDER.find(str(a.get("type", "")))
		var tb := TYPE_ORDER.find(str(b.get("type", "")))
		if ta != tb:
			return ta < tb
		return str(a.get("name", "")).to_lower() < str(b.get("name", "")).to_lower())

	for e in sorted:
		var label: String = TYPE_LABEL.get(str(e.get("type", "")), str(e.get("type", "")))
		_picker.add_item("%s  ·  %s" % [e.get("name", "?"), label])
		_picker.set_item_metadata(_picker.item_count - 1, str(e.get("id", "")))

	if _picker.item_count == 0:
		_picker.add_item("No characters or places yet — add one below")
		_picker.set_item_disabled(0, true)
		_selected_id = ""
		return

	var index := 0
	for i in range(_picker.item_count):
		if str(_picker.get_item_metadata(i)) == keep:
			index = i
			break
	_picker.select(index)
	_selected_id = str(_picker.get_item_metadata(index))


func _on_picker_selected(index: int) -> void:
	_selected_id = str(_picker.get_item_metadata(index))


func _current_id() -> String:
	if _picker.item_count == 0 or _picker.selected < 0 or _picker.is_item_disabled(_picker.selected):
		return ""
	return str(_picker.get_item_metadata(_picker.selected))


func _add_entity() -> void:
	var entity_name := _new_name.text.strip_edges()
	if entity_name.is_empty() or _busy:
		return
	_set_busy(true)
	var type: String = _new_type.get_item_metadata(_new_type.selected)
	EventBridge.create_entity(entity_name, type, _on_entity_created)


func _on_entity_created(code: int, data: Dictionary) -> void:
	_set_busy(false)
	if code != 201:
		_set_status(str(data.get("error", "Couldn't add it")), COLOR_ERROR)
		return
	var entity: Dictionary = data.get("entity", {})
	_selected_id = str(entity.get("id", ""))
	_new_name.clear()
	_set_status("✓ Added %s — the companion may have numbered it if the name was taken." % entity.get("name", ""), COLOR_OK)
	# Re-list, so the picker shows exactly what the companion stored.
	EventBridge.fetch_entities(func(c: int, d: Dictionary) -> void:
		if c == 200:
			_populate(d.get("entities", [])))
	_note_input.grab_focus()


# ── Mode ────────────────────────────────────────────────────────────────────

func _mode() -> String:
	return str(_mode_picker.get_item_metadata(_mode_picker.selected))


# A note is about someone, so it needs the picker; a quest or plot thread is a
# thing of its own, so it needs a name and can take starting steps instead.
func _apply_mode() -> void:
	var mode := _mode()
	var is_note := mode == "note"
	_about_row.visible = is_note
	_new_row.visible = is_note
	_quest_name.visible = not is_note
	_steps_input.visible = not is_note
	_note_input.placeholder_text = NOTE_PLACEHOLDER if is_note else QUEST_PLACEHOLDER
	for m in MODES:
		if m[1] == mode and not is_note:
			_quest_name.placeholder_text = m[2]
	_log_button.text = "Log note" if is_note else "Open"
	_log_close_button.text = "Log & close" if is_note else "Open & close"
	_set_status("", COLOR_MUTED)
	if not is_note:
		_quest_name.grab_focus()


# ── Logging ─────────────────────────────────────────────────────────────────

func _log(close_after: bool) -> void:
	if _busy:
		return
	if _mode() != "note":
		_open_quest(close_after)
		return
	var id := _current_id()
	var text := _note_input.text.strip_edges()
	if id.is_empty():
		_set_status("Pick who or what the note is about.", COLOR_WARN)
		return
	if text.is_empty():
		_set_status("Write something first.", COLOR_WARN)
		return
	_set_busy(true)
	EventBridge.log_note(id, text, _on_logged.bind(close_after))


func _on_logged(code: int, data: Dictionary, close_after: bool) -> void:
	_set_busy(false)
	if code != 201:
		# The text stays put, so a dropped connection doesn't cost the note.
		_set_status(str(data.get("error", "Couldn't log the note")), COLOR_ERROR)
		return
	_note_input.clear()
	_set_status("✓ Logged", COLOR_OK)
	if close_after:
		hide()
	else:
		_note_input.grab_focus()


func _open_quest(close_after: bool) -> void:
	var quest_name := _quest_name.text.strip_edges()
	if quest_name.is_empty():
		_set_status("Give it a name first.", COLOR_WARN)
		_quest_name.grab_focus()
		return
	var steps: Array = []
	for line in _steps_input.text.split("
"):
		var step: String = line.strip_edges().trim_prefix("- ").trim_prefix("• ").strip_edges()
		if not step.is_empty():
			steps.append(step)
	_set_busy(true)
	EventBridge.open_quest(_mode(), quest_name, _note_input.text.strip_edges(), steps, _on_quest_opened.bind(close_after))


func _on_quest_opened(code: int, data: Dictionary, close_after: bool) -> void:
	_set_busy(false)
	if code != 201:
		# Everything typed stays put, so a dropped connection costs nothing.
		_set_status(str(data.get("error", "Couldn't open it")), COLOR_ERROR)
		return
	var quest: Dictionary = data.get("quest", {})
	_quest_name.clear()
	_steps_input.clear()
	_note_input.clear()
	# Back to notes, about the new quest — the next note is usually about it.
	_selected_id = str(quest.get("id", ""))
	_mode_picker.select(0)
	_apply_mode()
	_set_status("✓ Opened %s — tick its steps on the companion's quest board." % quest.get("name", ""), COLOR_OK)
	EventBridge.fetch_entities(func(c: int, d: Dictionary) -> void:
		if c == 200:
			_populate(d.get("entities", [])))
	if close_after:
		hide()
	else:
		_note_input.grab_focus()


func _set_busy(busy: bool) -> void:
	_busy = busy
	for b in [_log_button, _log_close_button, _add_button]:
		b.disabled = busy
	if busy:
		_log_button.text = "Working…"
	else:
		_log_button.text = "Log note" if _mode() == "note" else "Open"


func _set_status(text: String, color: Color) -> void:
	_status_label.text = text
	_status_label.modulate = color

# EventBridge — GM Companion integration autoload
# Watches Open-VTT for HP changes and turn advances, forwards them to the
# companion's event API via non-blocking HTTP (fire-and-forget queue).
#
# Setup: configure companion_url + bridge_secret in the bridge panel, then
# click "Test Connection". Events flow automatically once a session is active.

extends Node

signal status_changed(status: String)
signal compendium_results_received(monsters: Array)
signal monster_detail_received(monster: Dictionary)
signal compendium_spawn_completed(entity_id: String, entity_name: String)
signal compendium_spawn_failed(error: String)
signal launch_finished
signal characters_received(characters: Array)
signal character_sheet_received(sheet: Dictionary)
signal characters_failed(error: String)
signal session_status_changed(active: bool, session_name: String)
# A boss entered a phase; `change` is the companion's phase_changes entry.
signal phase_changed(change: Dictionary)

# ── Connection status ───────────────────────────────────────────────────────
enum Status { DISCONNECTED, CONNECTED, ERROR }

var _companion_url: String = ""
var _bridge_secret: String = ""
var _connection_status: Status = Status.DISCONNECTED
var _status_message: String = "Not configured"

# ── Companion launcher ──────────────────────────────────────────────────────
# Folder of the gm-companion project, used to start its dev server locally.
var _companion_path: String = ""
var _launching: bool = false

# ── Session state ───────────────────────────────────────────────────────────
var _active_session_id: String = ""
# Mirrors the last known session state; read by the note window on open.
var session_active: bool = false
var session_name: String = ""

# ── Entity name → UUID cache (populated lazily per character) ───────────────
var _entity_cache: Dictionary = {}

# ── Per-character previous attribute values (for delta calculation) ─────────
# Key: character instance_id (int), Value: { attr_name: float }
var _prev_attrs: Dictionary = {}

# ── HTTP event dispatch queue (bounded to 50) ───────────────────────────────
var _event_queue: Array = []
var _http_busy: bool = false
var _http: HTTPRequest          # main dispatch node
var _http_lookup: HTTPRequest   # entity-lookup node (separate lifecycle)
var _http_compendium: HTTPRequest  # compendium search node
var _http_detail: HTTPRequest      # monster detail / stat block node
var _http_spawn: HTTPRequest       # companion spawn node
var _http_characters: HTTPRequest  # player character list
var _http_sheet: HTTPRequest       # one character's VTT sheet
var _http_session_status: HTTPRequest  # active-session poll

const MAX_QUEUE = 50
# Shared with the bridge panel — see the script for why it isn't inline.
const VttSheetWriter = preload("res://scripts/vtt_sheet_writer.gd")
const CONFIG_PATH = "user://event_bridge.cfg"


# ═══════════════════════════════════════════════════════════════════════════
# Lifecycle
# ═══════════════════════════════════════════════════════════════════════════

func _ready() -> void:
	_http = HTTPRequest.new()
	_http_lookup = HTTPRequest.new()
	add_child(_http)
	add_child(_http_lookup)
	_http.request_completed.connect(_on_request_completed)
	_http_lookup.request_completed.connect(_on_lookup_completed)
	_http_compendium = HTTPRequest.new()
	_http_detail = HTTPRequest.new()
	_http_spawn = HTTPRequest.new()
	add_child(_http_compendium)
	add_child(_http_detail)
	add_child(_http_spawn)
	_http_compendium.request_completed.connect(_on_compendium_search_completed)
	_http_detail.request_completed.connect(_on_monster_detail_completed)
	_http_spawn.request_completed.connect(_on_spawn_completed)
	_http_characters = HTTPRequest.new()
	_http_sheet = HTTPRequest.new()
	add_child(_http_characters)
	add_child(_http_sheet)
	_http_characters.request_completed.connect(_on_characters_completed)
	_http_sheet.request_completed.connect(_on_character_sheet_completed)
	_http_session_status = HTTPRequest.new()
	add_child(_http_session_status)
	_http_session_status.request_completed.connect(_on_session_status_completed)

	_load_config()
	get_tree().node_added.connect(_on_node_added)
	call_deferred("_connect_turn_order")


func _connect_turn_order() -> void:
	if Globals.turn_order == null:
		return
	if not Globals.turn_order.is_connected("token_turn_selected", _on_turn_selected):
		Globals.turn_order.connect("token_turn_selected", _on_turn_selected)


# ═══════════════════════════════════════════════════════════════════════════
# Config persistence
# ═══════════════════════════════════════════════════════════════════════════

func _load_config() -> void:
	_companion_path = _guess_companion_path()
	var cfg = ConfigFile.new()
	if cfg.load(CONFIG_PATH) != OK:
		return
	_companion_url = cfg.get_value("bridge", "companion_url", "")
	_bridge_secret = cfg.get_value("bridge", "bridge_secret", "")
	_companion_path = cfg.get_value("bridge", "companion_path", _companion_path)


func save_config(url: String, secret: String, companion_path: String) -> void:
	_companion_url = url.strip_edges()
	_bridge_secret = secret.strip_edges()
	_companion_path = companion_path.strip_edges()
	var cfg = ConfigFile.new()
	cfg.set_value("bridge", "companion_url", _companion_url)
	cfg.set_value("bridge", "bridge_secret", _bridge_secret)
	cfg.set_value("bridge", "companion_path", _companion_path)
	cfg.save(CONFIG_PATH)
	_set_status(Status.DISCONNECTED, "Settings saved — click Test Connection")


# ═══════════════════════════════════════════════════════════════════════════
# Token detection — watch for new Token nodes entering the scene
# ═══════════════════════════════════════════════════════════════════════════

func _on_node_added(node: Node) -> void:
	if node.get_script() == null:
		return
	if not node.get_script().resource_path.ends_with("token.gd"):
		return
	if node.character == null:
		return
	_init_prev_attrs(node.character)
	node.character.connect("attr_updated", _on_attr_updated.bind(node.character))


func _init_prev_attrs(char: Object) -> void:
	var cid = char.get_instance_id()
	if not _prev_attrs.has(cid):
		_prev_attrs[cid] = {}
	for attr in char.attributes:
		var val_str = char.attributes[attr][1]
		if val_str.is_valid_float():
			_prev_attrs[cid][attr] = val_str.to_float()


# ═══════════════════════════════════════════════════════════════════════════
# HP change detection (US1)
# ═══════════════════════════════════════════════════════════════════════════

func _on_attr_updated(attr: StringName, remote: bool, char: Object) -> void:
	# remote=true means this change was replicated in from another connected
	# peer rather than made on this client. The bridge used to skip those to
	# avoid double-counting — but only the GM's install has bridge credentials
	# configured, so this client is the only one that will ever try to forward
	# a given change; a locally-made edit only ever fires once as remote=false,
	# and a peer-made edit only ever arrives once as remote=true. Tracking both
	# means damage/healing applied on ANY connected player's screen (not just
	# the GM's) reaches the companion.

	# Only track attributes that back a visible HP bar (bar.attr1)
	var is_hp_attr = false
	for bar_data in char.bars:
		if bar_data.get("attr1", "") == attr:
			is_hp_attr = true
			break
	if not is_hp_attr:
		return

	var new_val_str = char.attributes.get(attr, [null, "0"])[1]
	if not new_val_str.is_valid_float():
		return
	var new_val: float = new_val_str.to_float()

	var cid = char.get_instance_id()
	if not _prev_attrs.has(cid):
		_prev_attrs[cid] = {}
	var old_val: float = _prev_attrs[cid].get(attr, new_val)
	_prev_attrs[cid][attr] = new_val

	var delta: float = new_val - old_val
	if delta == 0.0:
		return

	var amount := int(abs(delta))
	if amount == 0:
		return  # a fraction of a point — the companion only takes whole HP
	var kind: String = "healing" if delta > 0 else "damage"
	var char_name: String = _get_char_name(char)
	# The delta says what happened; hp_after says where the token ended up. The
	# companion pins HP to it, so a value set straight to full can't drift the
	# total, and it is never negative there.
	_enqueue_after_lookup(char_name, kind, amount, { "hp_after": maxi(0, int(new_val)) })


func _get_char_name(char: Object) -> String:
	if char.attributes.has("name"):
		return str(char.attributes["name"][1])
	return char.name


# ═══════════════════════════════════════════════════════════════════════════
# Turn order advance (US2)
# ═══════════════════════════════════════════════════════════════════════════

# ═══════════════════════════════════════════════════════════════════════════
# Deletion = death
# ═══════════════════════════════════════════════════════════════════════════

# A creature leaves play in one of two ways, and the GM does either when it is
# gone — so the companion records both as a death:
#   - deleting its token from the map (Delete key): report_token_removed
#   - deleting the character from the tool panel's tree: report_character_deleted
# Both can happen for the same creature; the companion ignores the repeat.
# Call these BEFORE the node is freed: only the name is read, but it has to
# still be readable.
func report_character_deleted(char: Object) -> void:
	if char == null:
		return
	var char_name := _get_char_name(char)
	if char_name.is_empty():
		return
	_report_death(char_name)
	# Drop the cached id only after enqueuing, so this event can still use it.
	# A later character reusing the name must re-resolve rather than inherit it.
	_prev_attrs.erase(char.get_instance_id())
	_entity_cache.erase(char_name)


# `object` is whatever draw.gd is about to remove: the token, or the polygon
# inside it that actually gets selected. Anything else on the map (drawings,
# lights, text) has no character and is ignored.
func report_token_removed(object: Object) -> void:
	if object == null or not is_instance_valid(object):
		return
	var token: Object = null
	if object.has_meta("type"):
		if object.get_meta("type") == "token":
			token = object
	else:
		var parent = object.get_parent()
		if parent != null and parent.has_meta("type") and parent.get_meta("type") == "token":
			token = parent
	if token == null or not ("character" in token) or token.character == null:
		return
	# Unlike deleting the character itself, the character may live on (it is
	# still in the tree, or another token shares it) — so its bookkeeping stays.
	var char_name := _get_char_name(token.character)
	if not char_name.is_empty():
		_report_death(char_name)


func _report_death(char_name: String) -> void:
	_enqueue_after_lookup(char_name, "died", -1)


func _on_turn_selected(token) -> void:
	if token == null or token.character == null:
		return
	var char_name: String = _get_char_name(token.character)
	_enqueue_after_lookup(char_name, "turn_advanced", -1)


# ═══════════════════════════════════════════════════════════════════════════
# Entity name → UUID lookup
# ═══════════════════════════════════════════════════════════════════════════

# Pending lookups, keyed by character name: { kind, amount }.
# Only the most recent unresolved event per character is kept.
var _lookup_pending: Dictionary = {}

# Character name whose lookup is currently in flight, or "" when idle. The
# response carries no echo of the query, so this is the only way to know which
# name a given reply answers.
var _lookup_inflight: String = ""

# `extra` carries optional fields for the event body (currently hp_after).
func _enqueue_after_lookup(char_name: String, kind: String, amount: int, extra: Dictionary = {}) -> void:
	if _companion_url.is_empty() or _bridge_secret.is_empty():
		return
	if _entity_cache.has(char_name):
		_enqueue(_make_event(_entity_cache[char_name], kind, amount, extra))
		return
	_lookup_pending[char_name] = { "kind": kind, "amount": amount, "extra": extra }
	_pump_lookups()


func _make_event(entity_id: String, kind: String, amount: int, extra: Dictionary) -> Dictionary:
	var event := { "entity_id": entity_id, "kind": kind, "amount": amount }
	event.merge(extra)
	return event


# Sends the next queued lookup if none is in flight. Lookups are serialised
# because a single HTTPRequest node can only carry one request at a time.
func _pump_lookups() -> void:
	if _lookup_inflight != "" or _lookup_pending.is_empty():
		return
	if _http_lookup.get_http_client_status() != HTTPClient.STATUS_DISCONNECTED:
		return

	var char_name: String = _lookup_pending.keys()[0]
	var url = _companion_url.trim_suffix("/") + "/api/entities?name=" + char_name.uri_encode()
	var headers = PackedStringArray(["Authorization: Bearer " + _bridge_secret])
	if _http_lookup.request(url, headers, HTTPClient.METHOD_GET) != OK:
		return  # retried on the next attribute change
	_lookup_inflight = char_name


func _on_lookup_completed(_result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	var char_name: String = _lookup_inflight
	_lookup_inflight = ""
	if char_name.is_empty():
		_pump_lookups()
		return

	var pending: Dictionary = _lookup_pending.get(char_name, {})
	_lookup_pending.erase(char_name)

	var found_id: String = ""
	if code == 200:
		var json = JSON.new()
		if json.parse(body.get_string_from_utf8()) == OK:
			var data = json.get_data()
			if typeof(data) == TYPE_DICTIONARY:
				for ent in data.get("entities", []):
					if str(ent.get("name", "")).to_lower() == char_name.to_lower():
						found_id = str(ent.get("id", ""))
						break

	if found_id.is_empty():
		# Deliberately NOT cached. A miss is usually temporary — the entity may
		# be spawned later in the session — and caching it would silently mute
		# this character's events until the VTT restarts.
		print("[EventBridge] No entity found for \"%s\" — event skipped" % char_name)
	else:
		_entity_cache[char_name] = found_id
		if not pending.is_empty():
			_enqueue(_make_event(found_id, pending["kind"], pending["amount"], pending.get("extra", {})))

	_pump_lookups()


# ═══════════════════════════════════════════════════════════════════════════
# Event queue and HTTP dispatch
# ═══════════════════════════════════════════════════════════════════════════

func _enqueue(event: Dictionary) -> void:
	if _event_queue.size() >= MAX_QUEUE:
		_event_queue.pop_front()  # drop oldest on overflow
		print("[EventBridge] Queue overflow — oldest event dropped")
	_event_queue.append(event)
	if not _http_busy:
		_dispatch_next()


func _dispatch_next() -> void:
	if _event_queue.is_empty() or _http_busy:
		return
	if _companion_url.is_empty() or _bridge_secret.is_empty():
		return

	var event: Dictionary = _event_queue.pop_front()
	var eid: String = event["entity_id"]
	var kind: String = event["kind"]
	var amount = event["amount"]  # int or -1 (null sentinel)

	var json_body: String = JSON.stringify(_event_body(event))
	var headers = PackedStringArray([
		"Authorization: Bearer " + _bridge_secret,
		"Content-Type: application/json",
	])
	var url = _companion_url.trim_suffix("/") + "/api/events"

	var err = _http.request(url, headers, HTTPClient.METHOD_POST, json_body)
	if err != OK:
		print("[EventBridge] HTTP request error: ", err)
		_http_busy = false
		_dispatch_next()
		return

	_http_busy = true
	var label = "%s %s" % [kind, ("" if amount < 0 else str(amount) + " for")]
	print("[EventBridge] → %s \"%s\"" % [label, eid])


# The JSON body for POST /api/events. `amount` -1 means "none" (a death, a turn).
func _event_body(event: Dictionary) -> Dictionary:
	var eid: String = event["entity_id"]
	var body_dict: Dictionary = {
		"kind": event["kind"],
		"actor_entity_id": eid,
		"entity_ids": [eid],
	}
	if event["amount"] >= 0:
		body_dict["amount"] = event["amount"]
	if event.has("hp_after"):
		body_dict["hp_after"] = event["hp_after"]
	return body_dict


func _on_request_completed(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	_http_busy = false

	if result != HTTPRequest.RESULT_SUCCESS:
		print("[EventBridge] Request failed (network error %d)" % result)
		_set_status(Status.ERROR, "Network error — companion unreachable")
	elif code == 401:
		print("[EventBridge] 401 Unauthorized — check bridge secret")
		_set_status(Status.ERROR, "Invalid secret — check bridge settings")
	elif code >= 500:
		print("[EventBridge] Server error %d: %s" % [code, body.get_string_from_utf8()])
		_set_status(Status.ERROR, "Companion server error %d" % code)
	else:
		if _connection_status != Status.CONNECTED:
			_set_status(Status.CONNECTED, "Connected")

	if result == HTTPRequest.RESULT_SUCCESS and code == 201:
		_check_for_phase_changes(body)

	_dispatch_next()


# ═══════════════════════════════════════════════════════════════════════════
# Session management (US3)
# ═══════════════════════════════════════════════════════════════════════════

func start_session() -> void:
	if _companion_url.is_empty() or _bridge_secret.is_empty():
		print("[EventBridge] Cannot start session — not configured")
		return
	var today = Time.get_date_string_from_system()
	var body = JSON.stringify({ "name": "Session — " + today })
	var headers = PackedStringArray([
		"Authorization: Bearer " + _bridge_secret,
		"Content-Type: application/json",
	])
	var url = _companion_url.trim_suffix("/") + "/api/sessions"
	var hr = HTTPRequest.new()
	add_child(hr)
	hr.request_completed.connect(_on_session_start_completed.bind(hr))
	hr.request(url, headers, HTTPClient.METHOD_POST, body)


func _on_session_start_completed(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray, hr: HTTPRequest) -> void:
	hr.queue_free()
	if result != HTTPRequest.RESULT_SUCCESS:
		print("[EventBridge] start_session network error")
		return
	var json = JSON.new()
	if json.parse(body.get_string_from_utf8()) != OK:
		return
	var data = json.get_data()
	if code == 201:
		var session: Dictionary = data.get("session", {})
		_active_session_id = session.get("id", "")
		print("[EventBridge] Session started: ", _active_session_id)
		_set_session_state(true, str(session.get("name", "")))
	elif code == 409:
		_active_session_id = data.get("activeSessionId", "")
		print("[EventBridge] Adopted existing session: ", _active_session_id)
		refresh_session_status()  # 409 doesn't carry the session's name


func end_session() -> void:
	if _active_session_id.is_empty():
		print("[EventBridge] No active session to end")
		return
	var body = JSON.stringify({ "action": "end" })
	var headers = PackedStringArray([
		"Authorization: Bearer " + _bridge_secret,
		"Content-Type: application/json",
	])
	var url = _companion_url.trim_suffix("/") + "/api/sessions/" + _active_session_id
	var hr = HTTPRequest.new()
	add_child(hr)
	hr.request_completed.connect(_on_session_end_completed.bind(hr))
	hr.request(url, headers, HTTPClient.METHOD_PATCH, body)


func _on_session_end_completed(result: int, code: int, _headers: PackedStringArray, _body: PackedByteArray, hr: HTTPRequest) -> void:
	hr.queue_free()
	if result == HTTPRequest.RESULT_SUCCESS and code == 200:
		print("[EventBridge] Session ended: ", _active_session_id)
		_active_session_id = ""
		_set_session_state(false, "")
	else:
		print("[EventBridge] end_session failed — result %d code %d" % [result, code])


func _set_session_state(active: bool, session_name_: String) -> void:
	session_active = active
	session_name = session_name_
	emit_signal("session_status_changed", active, session_name_)


# Polls the companion for whether a session is currently active, and emits
# session_status_changed with the result. Safe to call any time the bridge is
# configured — e.g. when the panel opens, so a session started or ended in an
# earlier run of the game (or from another client) is reflected immediately.
func refresh_session_status() -> void:
	if _companion_url.is_empty() or _bridge_secret.is_empty():
		return
	if _http_session_status.get_http_client_status() != HTTPClient.STATUS_DISCONNECTED:
		return
	var url = _companion_url.trim_suffix("/") + "/api/sessions?active=true"
	var headers = PackedStringArray(["Authorization: Bearer " + _bridge_secret])
	_http_session_status.request(url, headers, HTTPClient.METHOD_GET)


func _on_session_status_completed(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		return
	var json = JSON.new()
	if json.parse(body.get_string_from_utf8()) != OK:
		return
	var data = json.get_data()
	if typeof(data) != TYPE_DICTIONARY:
		return
	var session = data.get("session")
	if typeof(session) == TYPE_DICTIONARY:
		_active_session_id = str(session.get("id", ""))
		_set_session_state(true, str(session.get("name", "")))
	else:
		_active_session_id = ""
		_set_session_state(false, "")


# ═══════════════════════════════════════════════════════════════════════════
# Connection test (US4)
# ═══════════════════════════════════════════════════════════════════════════

func test_connection() -> void:
	if _companion_url.is_empty() or _bridge_secret.is_empty():
		_set_status(Status.ERROR, "Enter URL and secret first")
		return
	_set_status(Status.DISCONNECTED, "Testing…")
	var headers = PackedStringArray(["Authorization: Bearer " + _bridge_secret])
	var url = _companion_url.trim_suffix("/") + "/api/sessions"
	var hr = HTTPRequest.new()
	add_child(hr)
	hr.request_completed.connect(_on_test_completed.bind(hr))
	hr.request(url, headers, HTTPClient.METHOD_GET)


func _on_test_completed(result: int, code: int, _headers: PackedStringArray, _body: PackedByteArray, hr: HTTPRequest) -> void:
	hr.queue_free()
	if result != HTTPRequest.RESULT_SUCCESS:
		_set_status(Status.ERROR, "Companion unreachable")
	elif code == 401:
		_set_status(Status.ERROR, "Invalid secret — check bridge settings")
	elif code == 200:
		_set_status(Status.CONNECTED, "Connected")
		refresh_session_status()
	else:
		_set_status(Status.ERROR, "Unexpected response: %d" % code)


# ═══════════════════════════════════════════════════════════════════════════
# Companion launcher — open the web app, starting the local dev server if needed
# ═══════════════════════════════════════════════════════════════════════════
#
# Opening the browser before the dev server is up shows "can't reach this
# page", and `next dev` takes several seconds to answer after it starts. So:
# probe first, launch only when nothing answers, and open the browser once the
# server responds.

const LAUNCH_TIMEOUT_SEC = 90.0
const LAUNCH_POLL_SEC = 2.0


func open_companion() -> void:
	if _launching:
		return
	if _companion_url.is_empty():
		_set_status(Status.ERROR, "Enter the companion URL first")
		return

	_launching = true
	if await _companion_responds():
		OS.shell_open(_companion_url)
		_finish_launch()
		_after_open()
		return

	if not _is_local_url(_companion_url):
		_finish_launch()
		_set_status(Status.ERROR, "Companion unreachable at %s" % _companion_url)
		return

	var launch_error := _start_dev_server()
	if not launch_error.is_empty():
		_finish_launch()
		_set_status(Status.ERROR, launch_error)
		return

	var started := Time.get_ticks_msec()
	while true:
		var elapsed := (Time.get_ticks_msec() - started) / 1000.0
		if elapsed > LAUNCH_TIMEOUT_SEC:
			_finish_launch()
			_set_status(Status.ERROR, "Companion didn't start within %ds — check its console window" % int(LAUNCH_TIMEOUT_SEC))
			return
		_set_status(Status.DISCONNECTED, "Starting companion… %ds" % int(elapsed))
		await get_tree().create_timer(LAUNCH_POLL_SEC).timeout
		if await _companion_responds():
			break

	OS.shell_open(_companion_url)
	_finish_launch()
	_after_open()


func is_launching() -> bool:
	return _launching


func _finish_launch() -> void:
	_launching = false
	emit_signal("launch_finished")


# Any HTTP response at all means the server is up. /api/auth/session needs no
# auth and is excluded from the companion's login redirect.
func _companion_responds() -> bool:
	var hr := HTTPRequest.new()
	hr.timeout = 15.0  # the first request to `next dev` compiles the route
	add_child(hr)
	var err := hr.request(_companion_url.trim_suffix("/") + "/api/auth/session")
	if err != OK:
		hr.queue_free()
		return false
	var response: Array = await hr.request_completed
	hr.queue_free()
	return response[0] == HTTPRequest.RESULT_SUCCESS


func _after_open() -> void:
	if _bridge_secret.is_empty():
		_set_status(Status.DISCONNECTED, "Companion opened — enter the bridge secret to connect")
	else:
		test_connection()


func _is_local_url(url: String) -> bool:
	var authority := url.get_slice("://", 1).get_slice("/", 0).to_lower()
	# IPv6 hosts are bracketed and contain colons, so only split off a port otherwise.
	var host := authority.get_slice("]", 0) + "]" if authority.begins_with("[") else authority.get_slice(":", 0)
	return host in ["localhost", "127.0.0.1", "[::1]"]


# Returns an error message, or "" once the server process has been spawned.
func _start_dev_server() -> String:
	if _companion_path.is_empty():
		return "Set the companion folder to launch it from here"
	if not FileAccess.file_exists(_companion_path.path_join("package.json")):
		return "No package.json in companion folder: %s" % _companion_path

	var pid := -1
	if OS.get_name() == "Windows":
		# `start` gives the server its own console window, so its logs stay
		# visible and closing that window (or Ctrl+C) stops it. start-dev.bat
		# also puts Node on PATH, which a Godot-launched process may lack.
		# `start /D` needs backslashes: it reads "/Users" in C:/Users as a switch
		# and silently launches nothing.
		# `.\` because cmd skips the current folder when NoDefaultCurrentDirectoryInExePath is set.
		var script := ".\\start-dev.bat" if FileAccess.file_exists(_companion_path.path_join("start-dev.bat")) else "npm run dev"
		var win_path := _companion_path.replace("/", "\\")
		pid = OS.create_process("cmd.exe", ["/c", "start", "GM Companion", "/D", win_path, "cmd", "/k", script])
	else:
		pid = OS.create_process("sh", ["-c", "cd \"$1\" && exec npm run dev", "sh", _companion_path])

	if pid == -1:
		return "Couldn't start the companion dev server"
	return ""


func _guess_companion_path() -> String:
	# Default layout: gm-companion is a sibling of the Open-VTT repo, and this
	# project lives in Open-VTT/Godot. Only meaningful when run from source.
	var guess := ProjectSettings.globalize_path("res://").path_join("../../gm-companion").simplify_path()
	return guess if FileAccess.file_exists(guess.path_join("package.json")) else ""


# ═══════════════════════════════════════════════════════════════════════════
# Compendium browser (US1–US3 of slice 007)
# ═══════════════════════════════════════════════════════════════════════════

func search_compendium(query: String, type: String = "") -> void:
	if _companion_url.is_empty() or _bridge_secret.is_empty():
		emit_signal("compendium_spawn_failed", "Bridge not configured")
		return
	if _http_compendium.get_http_client_status() != HTTPClient.STATUS_DISCONNECTED:
		_http_compendium.cancel_request()
	var params = []
	if not query.is_empty():
		params.append("name=" + query.uri_encode())
	if not type.is_empty():
		params.append("type=" + type.uri_encode())
	var qs = "?" + "&".join(params) if not params.is_empty() else ""
	var url = _companion_url.trim_suffix("/") + "/api/compendium/monsters" + qs
	var headers = PackedStringArray(["Authorization: Bearer " + _bridge_secret])
	_http_compendium.request(url, headers, HTTPClient.METHOD_GET)


func _on_compendium_search_completed(_result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if code != 200:
		emit_signal("compendium_spawn_failed", "Search failed (%d)" % code)
		return
	var json = JSON.new()
	if json.parse(body.get_string_from_utf8()) != OK:
		emit_signal("compendium_spawn_failed", "Invalid response from companion")
		return
	var data = json.get_data()
	emit_signal("compendium_results_received", data.get("monsters", []))


func fetch_monster_detail(slug: String) -> void:
	if _companion_url.is_empty() or _bridge_secret.is_empty():
		return
	if _http_detail.get_http_client_status() != HTTPClient.STATUS_DISCONNECTED:
		_http_detail.cancel_request()
	var url = _companion_url.trim_suffix("/") + "/api/compendium/monsters/" + slug
	var headers = PackedStringArray(["Authorization: Bearer " + _bridge_secret])
	_http_detail.request(url, headers, HTTPClient.METHOD_GET)


func _on_monster_detail_completed(_result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if code != 200:
		return  # fail silently — abilities just won't appear
	var json = JSON.new()
	if json.parse(body.get_string_from_utf8()) != OK:
		return
	var data = json.get_data()
	emit_signal("monster_detail_received", data.get("monster", {}))


func spawn_entity(slug: String, name: String) -> void:
	if _companion_url.is_empty() or _bridge_secret.is_empty():
		emit_signal("compendium_spawn_failed", "Bridge not configured")
		return
	var url = _companion_url.trim_suffix("/") + "/api/compendium/monsters/" + slug + "/spawn"
	var headers = PackedStringArray([
		"Authorization: Bearer " + _bridge_secret,
		"Content-Type: application/json",
	])
	var body = JSON.stringify({ "name": name })
	_http_spawn.request(url, headers, HTTPClient.METHOD_POST, body)


func _on_spawn_completed(_result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if code != 201:
		emit_signal("compendium_spawn_failed", "Companion save failed (%d)" % code)
		return
	var json = JSON.new()
	if json.parse(body.get_string_from_utf8()) != OK:
		emit_signal("compendium_spawn_failed", "Invalid response from companion")
		return
	var data = json.get_data()
	var entity = data.get("entity", {})
	emit_signal("compendium_spawn_completed", entity.get("id", ""), entity.get("name", ""))


# ═══════════════════════════════════════════════════════════════════════════
# Player characters (sheets built in the companion)
# ═══════════════════════════════════════════════════════════════════════════

# Lists the active campaign's characters.
# Which list the request in flight asked for, since the two answer under
# different keys ("characters" / "npcs").
var _characters_kind: String = "pc"


# kind is "pc" for player characters or "npc" for GM-run NPCs.
func fetch_characters(kind: String = "pc") -> void:
	if _companion_url.is_empty() or _bridge_secret.is_empty():
		emit_signal("characters_failed", "Bridge not configured")
		return
	if _http_characters.get_http_client_status() != HTTPClient.STATUS_DISCONNECTED:
		_http_characters.cancel_request()
	_characters_kind = kind
	var path = "/api/npcs" if kind == "npc" else "/api/characters"
	var url = _companion_url.trim_suffix("/") + path
	var headers = PackedStringArray(["Authorization: Bearer " + _bridge_secret])
	_http_characters.request(url, headers, HTTPClient.METHOD_GET)


func _on_characters_completed(_result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if code != 200:
		emit_signal("characters_failed", "Couldn't load characters (%d)" % code)
		return
	var json = JSON.new()
	if json.parse(body.get_string_from_utf8()) != OK:
		emit_signal("characters_failed", "Invalid response from companion")
		return
	emit_signal("characters_received", json.get_data().get("npcs" if _characters_kind == "npc" else "characters", []))


# Fetches a character's sheet already flattened for the VTT
# (attributes + text blocks) — see lib/vtt-sheet.ts in the companion.
func fetch_character_sheet(character_id: String, kind: String = "pc") -> void:
	if _companion_url.is_empty() or _bridge_secret.is_empty():
		emit_signal("characters_failed", "Bridge not configured")
		return
	if _http_sheet.get_http_client_status() != HTTPClient.STATUS_DISCONNECTED:
		_http_sheet.cancel_request()
	var root = "/api/npcs/" if kind == "npc" else "/api/characters/"
	var url = _companion_url.trim_suffix("/") + root + character_id + "/vtt"
	var headers = PackedStringArray(["Authorization: Bearer " + _bridge_secret])
	_http_sheet.request(url, headers, HTTPClient.METHOD_GET)


func _on_character_sheet_completed(_result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if code != 200:
		emit_signal("characters_failed", "Couldn't load the sheet (%d)" % code)
		return
	var json = JSON.new()
	if json.parse(body.get_string_from_utf8()) != OK:
		emit_signal("characters_failed", "Invalid response from companion")
		return
	emit_signal("character_sheet_received", json.get_data().get("sheet", {}))


# Call after writing attributes from the companion, before emitting
# attr_updated: resets the HP baseline so a sync isn't logged as damage/healing.
func rebaseline_character(char: Object) -> void:
	_prev_attrs.erase(char.get_instance_id())
	_init_prev_attrs(char)



# ═══════════════════════════════════════════════════════════════════════════
# Quick notes — a pop-up window for logging narrative events mid-session
# ═══════════════════════════════════════════════════════════════════════════

var _note_window: Window = null


# Loaded at call time rather than preloaded: the window's script refers back to
# this autoload, and a preload would make the two compile-time dependencies of
# each other.
func open_note_window() -> void:
	if _note_window == null or not is_instance_valid(_note_window):
		var scene: PackedScene = load("res://components/note_window.tscn")
		_note_window = scene.instantiate()
		get_tree().root.add_child(_note_window)
	_note_window.open()


# Ctrl+Shift+N from anywhere in the VTT. Handled here, not in a scene, so it
# works without touching map.tscn — and only sees keys nothing else consumed,
# so typing into a text box never triggers it.
func _unhandled_key_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	if key.keycode == KEY_N and key.ctrl_pressed and key.shift_pressed:
		open_note_window()
		get_viewport().set_input_as_handled()


# One request to the companion, answered through `on_done(code, data)`. Code 0
# means the request never got a response; `data.error` always says why. A
# request of its own per call, so a slow one can't cancel another.
func _call_companion(method: int, path: String, body, on_done: Callable) -> void:
	if _companion_url.is_empty() or _bridge_secret.is_empty():
		on_done.call(0, { "error": "Bridge not configured — set the URL and secret on the Connection tab." })
		return
	var hr := HTTPRequest.new()
	hr.timeout = 15.0
	add_child(hr)
	hr.request_completed.connect(func(result: int, code: int, _headers: PackedStringArray, response: PackedByteArray) -> void:
		hr.queue_free()
		if result != HTTPRequest.RESULT_SUCCESS:
			on_done.call(0, { "error": "Companion unreachable — is it running?" })
			return
		var json := JSON.new()
		var data: Dictionary = {}
		if json.parse(response.get_string_from_utf8()) == OK and typeof(json.get_data()) == TYPE_DICTIONARY:
			data = json.get_data()
		if code >= 400 and not data.has("error"):
			data["error"] = "Companion returned %d" % code
		on_done.call(code, data))
	var headers := PackedStringArray(["Authorization: Bearer " + _bridge_secret, "Content-Type: application/json"])
	var url := _companion_url.trim_suffix("/") + path
	var err := hr.request(url, headers, method, "" if body == null else JSON.stringify(body))
	if err != OK:
		hr.queue_free()
		on_done.call(0, { "error": "Couldn't send the request (error %d)" % err })


# Everything a note can be about in the active campaign.
func fetch_entities(on_done: Callable) -> void:
	_call_companion(HTTPClient.METHOD_GET, "/api/entities", null, on_done)


func create_entity(entity_name: String, type: String, on_done: Callable) -> void:
	_call_companion(HTTPClient.METHOD_POST, "/api/entities", { "name": entity_name, "type": type }, on_done)


# Logs a note about one entity into the running session (or outside any session
# if none is running — the companion decides). Append-only: no undo.
func log_note(entity_id: String, text: String, on_done: Callable) -> void:
	_call_companion(HTTPClient.METHOD_POST, "/api/events", {
		"kind": "note",
		"text": text,
		"actor_entity_id": entity_id,
		"entity_ids": [entity_id],
	}, on_done)


# Opens a quest ("quest") or plot thread ("thread") on the companion, with what
# it's about and any starting steps. It shows up on the companion's quest board,
# where its steps are ticked off. Answers 201 with { quest } on success.
func open_quest(type: String, quest_name: String, text: String, steps: Array, on_done: Callable) -> void:
	var body := { "type": type, "name": quest_name, "steps": steps }
	if not text.is_empty():
		body["text"] = text
	_call_companion(HTTPClient.METHOD_POST, "/api/quests", body, on_done)


# ═══════════════════════════════════════════════════════════════════════════
# Boss phases
# ═══════════════════════════════════════════════════════════════════════════
#
# The companion decides when an HP-triggered phase starts, since it holds the
# event log HP is derived from; it reports the phases a hit carried the boss
# into in the response to that hit. This turns the report into what the GM
# needs at the table: the token updated, and a window saying what changed.

func _check_for_phase_changes(body: PackedByteArray) -> void:
	var json := JSON.new()
	if json.parse(body.get_string_from_utf8()) != OK or typeof(json.get_data()) != TYPE_DICTIONARY:
		return
	for change in json.get_data().get("phase_changes", []):
		if typeof(change) == TYPE_DICTIONARY:
			_handle_phase_change(change)


func _handle_phase_change(change: Dictionary) -> void:
	phase_changed.emit(change)
	var id := str(change.get("entity_id", ""))
	# The companion's sheet is already at the new phase, so the token takes it
	# whole rather than this trying to work out the difference.
	_call_companion(HTTPClient.METHOD_GET, "/api/npcs/%s/vtt" % id, null, func(code: int, data: Dictionary) -> void:
		var outcome := "failed"
		if code == 200:
			outcome = "updated" if _apply_phase_sheet(str(change.get("entity_name", "")), data.get("sheet", {})) else "no_token"
		_show_phase_alert(change, outcome))


# Updates the token named `entity_name`. False if there isn't one on the map — a
# boss can be tracked in the companion without ever being sent to the VTT.
func _apply_phase_sheet(entity_name: String, sheet: Dictionary) -> bool:
	if sheet.is_empty():
		return false
	var character = VttSheetWriter.find_character(Globals.char_tree, entity_name)
	if character == null:
		return false
	VttSheetWriter.apply_update(character, sheet, rebaseline_character)
	return true


# outcome: "updated" — the token now matches the phase; "no_token" — nothing on
# the map has this name; "failed" — the companion couldn't be reached for the sheet.
func _phase_alert_text(change: Dictionary, outcome: String) -> String:
	var paragraphs: Array = []
	var description = change.get("description")
	if typeof(description) == TYPE_STRING and description != "":
		paragraphs.append(description)
	var now: Array = []
	if change.get("ac") != null:
		now.append("AC %d" % int(change["ac"]))
	if typeof(change.get("speed")) == TYPE_STRING and change["speed"] != "":
		now.append("Speed %s" % change["speed"])
	if not now.is_empty():
		paragraphs.append("Now: " + " · ".join(PackedStringArray(now)))
	var gains: Array = change.get("ability_names", [])
	if not gains.is_empty():
		paragraphs.append("Gains: " + ", ".join(PackedStringArray(gains)))
	match outcome:
		"updated":
			paragraphs.append("The token has been updated.")
		"no_token":
			paragraphs.append("No token with this name is on the map, so nothing was updated.")
		_:
			paragraphs.append("Couldn't fetch the new stats from the companion, so the token wasn't updated. Use Update on VTT in the Characters tab.")
	return "\n\n".join(PackedStringArray(paragraphs))


# Not exclusive: the fight goes on behind it, and the GM shouldn't have to
# dismiss it before moving a token.
func _show_phase_alert(change: Dictionary, outcome: String) -> void:
	var dialog := AcceptDialog.new()
	dialog.title = "%s — Phase %d: %s" % [change.get("entity_name", "Boss"), int(change.get("number", 0)), change.get("name", "")]
	dialog.dialog_text = _phase_alert_text(change, outcome)
	dialog.dialog_autowrap = true
	dialog.ok_button_text = "Got it"
	dialog.exclusive = false
	dialog.confirmed.connect(dialog.queue_free)
	dialog.canceled.connect(dialog.queue_free)
	get_tree().root.add_child(dialog)
	dialog.popup_centered(Vector2i(480, 260))

# ═══════════════════════════════════════════════════════════════════════════
# Internal helpers
# ═══════════════════════════════════════════════════════════════════════════

func _set_status(s: Status, msg: String) -> void:
	_connection_status = s
	_status_message = msg
	emit_signal("status_changed", msg)


func get_status_text() -> String:
	return _status_message

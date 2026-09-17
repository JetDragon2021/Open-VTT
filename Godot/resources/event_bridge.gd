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

const MAX_QUEUE = 50
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
	# Only act on local changes — remote=true means peer replication
	if remote:
		return

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

	var kind: String = "healing" if delta > 0 else "damage"
	var char_name: String = _get_char_name(char)
	_enqueue_after_lookup(char_name, kind, int(abs(delta)))


func _get_char_name(char: Object) -> String:
	if char.attributes.has("name"):
		return str(char.attributes["name"][1])
	return char.name


# ═══════════════════════════════════════════════════════════════════════════
# Turn order advance (US2)
# ═══════════════════════════════════════════════════════════════════════════

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

func _enqueue_after_lookup(char_name: String, kind: String, amount: int) -> void:
	if _companion_url.is_empty() or _bridge_secret.is_empty():
		return
	if _entity_cache.has(char_name):
		_enqueue({ "entity_id": _entity_cache[char_name], "kind": kind, "amount": amount })
		return
	_lookup_pending[char_name] = { "kind": kind, "amount": amount }
	_pump_lookups()


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
			_enqueue({ "entity_id": found_id, "kind": pending["kind"], "amount": pending["amount"] })

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

	var body_dict: Dictionary = {
		"kind": kind,
		"actor_entity_id": eid,
		"entity_ids": [eid],
	}
	if amount >= 0:
		body_dict["amount"] = amount

	var json_body: String = JSON.stringify(body_dict)
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
		_active_session_id = data.get("session", {}).get("id", "")
		print("[EventBridge] Session started: ", _active_session_id)
	elif code == 409:
		_active_session_id = data.get("activeSessionId", "")
		print("[EventBridge] Adopted existing session: ", _active_session_id)


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
	else:
		print("[EventBridge] end_session failed — result %d code %d" % [result, code])


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
func fetch_characters() -> void:
	if _companion_url.is_empty() or _bridge_secret.is_empty():
		emit_signal("characters_failed", "Bridge not configured")
		return
	if _http_characters.get_http_client_status() != HTTPClient.STATUS_DISCONNECTED:
		_http_characters.cancel_request()
	var url = _companion_url.trim_suffix("/") + "/api/characters"
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
	emit_signal("characters_received", json.get_data().get("characters", []))


# Fetches a character's sheet already flattened for the VTT
# (attributes + text blocks) — see lib/vtt-sheet.ts in the companion.
func fetch_character_sheet(character_id: String) -> void:
	if _companion_url.is_empty() or _bridge_secret.is_empty():
		emit_signal("characters_failed", "Bridge not configured")
		return
	if _http_sheet.get_http_client_status() != HTTPClient.STATUS_DISCONNECTED:
		_http_sheet.cancel_request()
	var url = _companion_url.trim_suffix("/") + "/api/characters/" + character_id + "/vtt"
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
# Internal helpers
# ═══════════════════════════════════════════════════════════════════════════

func _set_status(s: Status, msg: String) -> void:
	_connection_status = s
	_status_message = msg
	emit_signal("status_changed", msg)


func get_status_text() -> String:
	return _status_message

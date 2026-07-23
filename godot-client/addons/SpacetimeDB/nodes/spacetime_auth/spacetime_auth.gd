@tool
class_name SpacetimeAuth extends Node

# Provider-agnostic SpacetimeAuth token exchange.
#
# POSTs to the SpacetimeAuth OIDC token endpoint with a `client_id`, a
# `grant_type`, and a set of provider-specific credential fields, then returns
# the issued id_token (a JWT you hand to SpacetimeDBClient as the connection
# token). The node owns its own HTTPRequest child, so callers just add it to the
# tree and await:
#
#     var auth := SpacetimeAuth.new()
#     add_child(auth)
#     var result := await auth.exchange(
#         "steam",                                # grant_type
#         {"steam_ticket": ticket_hex, "steam_app_id": "480"},  # provider fields
#         my_client_id,
#     )
#     auth.queue_free()
#     if result.is_successful():
#         connection_options.token = result.id_token
#
# The same result is also emitted via `exchange_completed` for signal-based
# callers. Build `extra_fields` per provider (e.g. {"gpg_authcode": code} for
# Google Play, {"epic_id_token": jwt} for Epic); grant-type strings and field
# names are documented at https://docs.spacetimedb.com/ .
#
# A failure reports facts, never prose: only the consuming game knows its tone,
# its languages, and what is safe to show a user.


## One HTTP attempt. The per-attempt timings are what separate failure modes that
## look identical from the final verdict alone: five attempts of ~20ms means no
## resolver, five of exactly `request_timeout_seconds` means a blocked port.
class Attempt extends RefCounted:
	var offset_ms: int = 0
	var elapsed_ms: int = 0
	## Non-OK when `HTTPRequest.request()` refused to submit; the two fields
	## below then stay at their defaults.
	var submit_error: Error = OK
	## `HTTPRequest.Result`; -1 if never submitted.
	var transport_result: int = -1
	## 0 = no response was produced at all, so the fault is below HTTP.
	var http_status: int = 0

	func is_transport_failure() -> bool:
		return submit_error != OK or http_status == 0


class ExchangeResult extends RefCounted:
	var id_token: String = ""
	var expires_in: int = 0
	var error: String = ""
	var endpoint: String = ""
	## Empty if the exchange failed before any request went out. The 1-based
	## attempt number is the array position.
	var attempts: Array[Attempt] = []
	## The denominator in "attempt 2 of 5". NOT `attempts.size()`: the ladder
	## stops early on an authoritative 2xx/4xx, so a first-try 401 leaves one
	## attempt out of five.
	var max_attempts: int = 0
	## Non-200 body, passed through `redact_fields`.
	var response_body: String = ""

	func is_successful() -> bool:
		return error.is_empty()

	func last_attempt() -> Attempt:
		return attempts[-1] if not attempts.is_empty() else null

	## Feed to `SpacetimeAuth.transport_result_name()` for a readable enum name.
	func transport_result() -> int:
		var last: Attempt = last_attempt()
		return last.transport_result if last != null else -1

	func http_status() -> int:
		var last: Attempt = last_attempt()
		return last.http_status if last != null else 0

	## No HTTP response ever came back, so the fault is below HTTP (DNS, routing,
	## TLS) — most likely the client's own machine or network, not the server.
	func is_transport_failure() -> bool:
		var last: Attempt = last_attempt()
		return last != null and last.is_transport_failure()


signal exchange_completed(result: ExchangeResult)

const TOKEN_URL_DEFAULT: String = "https://auth.spacetimedb.com/oidc/token"

@export var debug_mode: bool = false
## OIDC token endpoint. Override for a self-hosted SpacetimeAuth deployment.
@export var token_url: String = TOKEN_URL_DEFAULT
## Bounds the network hang on an unreachable endpoint (DNS stall, TLS failure).
@export var request_timeout_seconds: float = 15.0
## Transient failures (transport error / 5xx) are retried; a 2xx/4xx is
## authoritative and never retried. Set these from the consuming game — how long
## a user waits before being told sign-in failed is a product decision. Worst
## case is `max_attempts * request_timeout_seconds` PLUS the backoff, which a
## hung TCP connect does reach.
@export var max_attempts: int = 4
@export var base_retry_delay_seconds: float = 0.5
@export var max_retry_delay_seconds: float = 4.0
## Field names whose VALUES are redacted from any error body echoed to the log.
@export var redact_fields: Array[String] = [
	"id_token", "access_token", "refresh_token", "token", "code", "ticket", "client_secret",
]

var _http: HTTPRequest


func _print_log(message: String) -> void:
	if debug_mode:
		print("[SpacetimeAuth] %s" % message)


func _ensure_http() -> void:
	if _http == null or not is_instance_valid(_http):
		_http = HTTPRequest.new()
		add_child(_http)
	# Per exchange, not just at construction — the node is reusable, and an
	# @export that stopped taking effect after the first call would be a trap.
	_http.timeout = request_timeout_seconds


func exchange(grant_type: String, extra_fields: Dictionary, client_id: String) -> ExchangeResult:
	var result: ExchangeResult = ExchangeResult.new()
	result.endpoint = token_url
	result.max_attempts = max_attempts
	if max_attempts < 1:
		# Otherwise the loop never runs and this surfaces as "unexpected
		# request_completed payload", pointing triage at the network not the config.
		result.error = "max_attempts must be >= 1 (got %d)" % max_attempts
		push_error("[SpacetimeAuth] %s" % result.error)
		exchange_completed.emit(result)
		return result
	if client_id.is_empty():
		result.error = "client_id empty"
		exchange_completed.emit(result)
		return result
	if not is_inside_tree():
		result.error = "SpacetimeAuth node must be inside the scene tree before calling exchange()"
		push_error("[SpacetimeAuth] %s" % result.error)
		exchange_completed.emit(result)
		return result

	_ensure_http()

	var parts: PackedStringArray = PackedStringArray()
	parts.append("client_id=" + client_id.uri_encode())
	parts.append("grant_type=" + grant_type.uri_encode())
	for key: String in extra_fields.keys():
		parts.append("%s=%s" % [key.uri_encode(), String(extra_fields[key]).uri_encode()])
	var body: String = "&".join(parts)
	var headers: PackedStringArray = PackedStringArray(
		["content-type: application/x-www-form-urlencoded"]
	)

	_print_log("POST %s grant_type=%s client_id=%s (%d bytes)" % [
		token_url, grant_type, client_id, body.length(),
	])

	# Retried with exponential backoff: submit error, no HTTP response, or 5xx.
	# A 2xx/4xx is authoritative and breaks out immediately.
	var response: Array = []
	var run_started_ms: int = Time.get_ticks_msec()
	for attempt_index: int in max_attempts:
		var last: bool = attempt_index == max_attempts - 1
		var attempt: Attempt = Attempt.new()
		attempt.offset_ms = Time.get_ticks_msec() - run_started_ms
		result.attempts.append(attempt)

		var err: Error = _http.request(token_url, headers, HTTPClient.METHOD_POST, body)
		if err == OK:
			response = await _http.request_completed
			attempt.elapsed_ms = Time.get_ticks_msec() - run_started_ms - attempt.offset_ms
			if not is_instance_valid(_http):
				result.error = "HTTPRequest freed mid-await (node shutdown?)"
				exchange_completed.emit(result)
				return result
			attempt.transport_result = int(response[0]) if response.size() >= 1 else -1
			attempt.http_status = int(response[1]) if response.size() >= 2 else 0
			if not (attempt.http_status == 0 or attempt.http_status >= 500):
				break
		else:
			attempt.submit_error = err
			attempt.elapsed_ms = Time.get_ticks_msec() - run_started_ms - attempt.offset_ms
		if last:
			if err != OK:
				result.error = "HTTPRequest.request err=%d" % err
				push_error("[SpacetimeAuth] %s" % result.error)
				exchange_completed.emit(result)
				return result
			break
		var delay: float = minf(max_retry_delay_seconds, base_retry_delay_seconds * pow(2.0, float(attempt_index)))
		push_warning("[SpacetimeAuth] transient failure (attempt %d/%d), retry in %.1fs" % [
			attempt_index + 1, max_attempts, delay,
		])
		await get_tree().create_timer(delay).timeout

	if response.size() < 4:
		result.error = "unexpected request_completed payload size=%d" % response.size()
		push_error("[SpacetimeAuth] %s" % result.error)
		exchange_completed.emit(result)
		return result

	var transport_result: int = int(response[0])
	var code: int = int(response[1])
	var body_str: String = PackedByteArray(response[3]).get_string_from_utf8()
	_print_log("response: transport=%s(%d) HTTP=%d after %d attempt(s)" % [
		transport_result_name(transport_result), transport_result, code, result.attempts.size(),
	])

	# code == 0 means no HTTP response was produced; name the transport enum so
	# logs read "CANT_CONNECT" rather than an opaque "HTTP 0".
	if code == 0:
		result.error = "transport error: %s (HTTPRequest.Result=%d)" % [
			transport_result_name(transport_result), transport_result,
		]
		exchange_completed.emit(result)
		return result

	if code != 200:
		result.response_body = _redact_credentials(body_str)
		result.error = "HTTP %d: %s" % [code, result.response_body]
		exchange_completed.emit(result)
		return result

	var parsed_variant: Variant = JSON.parse_string(body_str)
	if not (parsed_variant is Dictionary):
		result.error = "response not JSON object"
		exchange_completed.emit(result)
		return result
	var parsed: Dictionary = parsed_variant
	result.id_token = String(parsed.get("id_token", ""))
	result.expires_in = int(parsed.get("expires_in", 0))
	if result.id_token.is_empty():
		result.error = "response missing id_token (keys=%s)" % str(parsed.keys())
	exchange_completed.emit(result)
	return result


# Scrubs credential fields from a body before it is logged, in both JSON and
# url-encoded form. Best-effort, NOT a security boundary — it just keeps
# single-use tickets and tokens out of log files.
func _redact_credentials(body: String) -> String:
	var redacted: String = body
	for field: String in redact_fields:
		var json_re: RegEx = RegEx.new()
		json_re.compile('"%s"\\s*:\\s*"[^"]*"' % field)
		redacted = json_re.sub(redacted, '"%s": "<redacted>"' % field, true)
		var form_re: RegEx = RegEx.new()
		form_re.compile("%s=[^&]*" % field)
		redacted = form_re.sub(redacted, "%s=<redacted>" % field, true)
	return redacted


## Readable name for an `HTTPRequest.Result`. Public so consumers explaining a
## transport failure don't each keep a copy of this table.
static func transport_result_name(rc: int) -> String:
	match rc:
		HTTPRequest.RESULT_SUCCESS: return "SUCCESS"
		HTTPRequest.RESULT_CHUNKED_BODY_SIZE_MISMATCH: return "CHUNKED_BODY_SIZE_MISMATCH"
		HTTPRequest.RESULT_CANT_CONNECT: return "CANT_CONNECT"
		HTTPRequest.RESULT_CANT_RESOLVE: return "CANT_RESOLVE"
		HTTPRequest.RESULT_CONNECTION_ERROR: return "CONNECTION_ERROR"
		HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR: return "TLS_HANDSHAKE_ERROR"
		HTTPRequest.RESULT_NO_RESPONSE: return "NO_RESPONSE"
		HTTPRequest.RESULT_BODY_SIZE_LIMIT_EXCEEDED: return "BODY_SIZE_LIMIT_EXCEEDED"
		HTTPRequest.RESULT_BODY_DECOMPRESS_FAILED: return "BODY_DECOMPRESS_FAILED"
		HTTPRequest.RESULT_REQUEST_FAILED: return "REQUEST_FAILED"
		HTTPRequest.RESULT_DOWNLOAD_FILE_CANT_OPEN: return "DOWNLOAD_FILE_CANT_OPEN"
		HTTPRequest.RESULT_DOWNLOAD_FILE_WRITE_ERROR: return "DOWNLOAD_FILE_WRITE_ERROR"
		HTTPRequest.RESULT_REDIRECT_LIMIT_REACHED: return "REDIRECT_LIMIT_REACHED"
		HTTPRequest.RESULT_TIMEOUT: return "TIMEOUT"
		_: return "UNKNOWN"

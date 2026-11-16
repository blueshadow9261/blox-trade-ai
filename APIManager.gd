extends Node
## HTTPS-only text fetcher with timeout, size limit, conditional requests and bounded retries.
## Usage: var r: Dictionary = await APIManager.get_text(url, etag, retries)
## r.status: ok | not_modified | network | timeout | too_large | http_error | bad_url | busy

const TIMEOUT_SECONDS := 15.0
const MAX_BYTES := 2000000

var _busy := false

func is_busy() -> bool:
	return _busy

func get_text(url: String, etag := "", retries := 0) -> Dictionary:
	if not url.begins_with("https://"):
		return _res("bad_url", 0, "", {}, "Only https:// URLs are allowed.")
	if _busy:
		return _res("busy", 0, "", {}, "Another request is in progress.")
	_busy = true
	var attempt := 0
	var res: Dictionary = {}
	while true:
		res = await _once(url, etag)
		if res["status"] != "network" and res["status"] != "timeout":
			break
		if attempt >= retries:
			break
		attempt += 1
		await get_tree().create_timer(2.0 * attempt).timeout
	_busy = false
	return res

func _once(url: String, etag: String) -> Dictionary:
	var http := HTTPRequest.new()
	http.timeout = TIMEOUT_SECONDS
	http.body_size_limit = MAX_BYTES
	http.max_redirects = 3
	http.use_threads = true
	add_child(http)
	var headers := PackedStringArray(["Accept: application/json", "User-Agent: BloxTradeAI/1.0"])
	if etag != "":
		headers.append("If-None-Match: " + etag)
	var err := http.request(url, headers)
	if err != OK:
		http.queue_free()
		return _res("network", 0, "", {}, "Could not start request (error %d)." % err)
	var out: Array = await http.request_completed
	http.queue_free()
	var result: int = out[0]
	var code: int = out[1]
	var hdrs: Dictionary = _headers(out[2])
	var body: PackedByteArray = out[3]
	if result == HTTPRequest.RESULT_TIMEOUT:
		return _res("timeout", code, "", hdrs, "Request timed out.")
	if result == HTTPRequest.RESULT_BODY_SIZE_LIMIT_EXCEEDED:
		return _res("too_large", code, "", hdrs, "Response too large.")
	if result != HTTPRequest.RESULT_SUCCESS:
		return _res("network", code, "", hdrs, "Network error (%d)." % result)
	if code == 304:
		return _res("not_modified", code, "", hdrs, "")
	if code != 200:
		return _res("http_error", code, "", hdrs, "Server returned HTTP %d." % code)
	if body.is_empty():
		return _res("http_error", code, "", hdrs, "Empty response.")
	return _res("ok", code, body.get_string_from_utf8(), hdrs, "")

func _headers(arr: PackedStringArray) -> Dictionary:
	var d := {}
	for h in arr:
		var i := h.find(":")
		if i > 0:
			d[h.substr(0, i).strip_edges().to_lower()] = h.substr(i + 1).strip_edges()
	return d

func _res(status: String, code: int, body: String, hdrs: Dictionary, message: String) -> Dictionary:
	return {"status": status, "code": code, "body": body, "etag": hdrs.get("etag", ""),
		"headers": hdrs, "message": message}

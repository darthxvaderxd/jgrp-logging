--- Thin wrapper over PerformHttpRequest.
Http = {}

--- Lower-cased header lookup. FiveM hands back response headers with whatever
--- casing the server used, so `Retry-After` vs `retry-after` is not stable.
function Http.header(headers, name)
    if type(headers) ~= 'table' then return nil end
    local want = name:lower()
    for key, value in pairs(headers) do
        if tostring(key):lower() == want then
            if type(value) == 'table' then return value[1] end
            return value
        end
    end
    return nil
end

--- POST a raw body and block the CALLING COROUTINE until the response lands.
--- Must be called from inside a CreateThread (the queue worker is), never from
--- a plain event handler.
--- Returns status, body, headers. Status -1 means the request never completed
--- (timeout or transport failure) — the caller decides whether to retry.
local function post(url, body, headers, timeoutMs)
    local done, status, text, responseHeaders = false, nil, nil, nil

    PerformHttpRequest(url, function(resStatus, resText, resHeaders)
        status, text, responseHeaders = resStatus, resText, resHeaders
        done = true
    end, 'POST', body, headers)

    local waited = 0
    local timeout = timeoutMs or 15000
    while not done and waited < timeout do
        Wait(50)
        waited = waited + 50
    end

    if not done then return -1, nil, nil end
    return status, text, responseHeaders
end

function Http.postJson(url, body, headers, timeoutMs)
    local requestHeaders = { ['Content-Type'] = 'application/json' }
    for key, value in pairs(headers or {}) do requestHeaders[key] = value end
    return post(url, json.encode(body), requestHeaders, timeoutMs)
end

--- A boundary that cannot appear in the parts it separates. Discord's file
--- endpoint is multipart-only, and a boundary colliding with the body would
--- truncate the upload at whatever line happened to match.
local function pickBoundary(...)
    local candidate = '----jgrpLoggingBoundary'
    for _ = 1, 8 do
        local collides = false
        for i = 1, select('#', ...) do
            local part = select(i, ...)
            if type(part) == 'string' and part:find(candidate, 1, true) then collides = true end
        end
        if not collides then return candidate end
        candidate = ('----jgrpLoggingBoundary%d%d'):format(math.random(0, 999999), os.time())
    end
    return candidate
end

--- POST a message with one JSON file attached, as multipart/form-data.
---
--- `payload` is the normal message body; `file` is { filename = ..., content =
--- ... }. Discord links the file to the message through the `attachments` array
--- in payload_json, whose `id` matches the `files[N]` part index.
function Http.postJsonWithFile(url, payload, file, headers, timeoutMs)
    local encodedPayload = json.encode(payload)
    local boundary = pickBoundary(encodedPayload, file.content, file.filename)
    local CRLF = '\r\n'

    local body = table.concat({
        '--', boundary, CRLF,
        'Content-Disposition: form-data; name="payload_json"', CRLF,
        'Content-Type: application/json', CRLF, CRLF,
        encodedPayload, CRLF,
        '--', boundary, CRLF,
        ('Content-Disposition: form-data; name="files[0]"; filename="%s"'):format(file.filename), CRLF,
        'Content-Type: application/json', CRLF, CRLF,
        file.content, CRLF,
        '--', boundary, '--', CRLF,
    })

    local requestHeaders = {
        ['Content-Type'] = 'multipart/form-data; boundary=' .. boundary,
    }
    for key, value in pairs(headers or {}) do requestHeaders[key] = value end

    return post(url, body, requestHeaders, timeoutMs)
end

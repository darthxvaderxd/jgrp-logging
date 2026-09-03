--- Shared helpers for jgrp-logging.
--- Server-side only, like the rest of the resource — the folder name is
--- historical. Nothing in here touches a native, so it stays independently
--- testable (see tests/spec.lua).
Util = {}

-- Zero-width space. Inserted into untrusted text to defuse mention and code
-- fence syntax without visibly mangling the message.
local ZWSP = '\226\128\139'

Util.LEVELS = {
    debug = 10,
    info = 20,
    warn = 30,
    error = 40,
    critical = 50,
}

--- Numeric weight for a level name. Unknown/absent levels count as `info`.
function Util.levelValue(level)
    if type(level) == 'number' then return level end
    return Util.LEVELS[tostring(level or 'info'):lower()] or Util.LEVELS.info
end

function Util.trim(s)
    if type(s) ~= 'string' then return s end
    return (s:gsub('^%s+', ''):gsub('%s+$', ''))
end

function Util.isBlank(s)
    return s == nil or (type(s) == 'string' and Util.trim(s) == '')
end

--- Drop a trailing partial UTF-8 sequence left behind by a byte-wise cut, so
--- Discord doesn't reject the payload as malformed.
local function stripPartialUtf8(s)
    while #s > 0 do
        local b = s:byte(#s)
        if b >= 0x80 and b <= 0xBF then       -- continuation byte
            s = s:sub(1, #s - 1)
        elseif b >= 0xC0 then                  -- lead byte with no continuation left
            return s:sub(1, #s - 1)
        else
            return s
        end
    end
    return s
end

--- Cut `s` to at most `max` bytes, marking the cut with an ellipsis.
function Util.truncate(s, max)
    if type(s) ~= 'string' or type(max) ~= 'number' or #s <= max then return s end
    if max <= 3 then return s:sub(1, max) end
    return stripPartialUtf8(s:sub(1, max - 3)) .. '...'
end

function Util.stringify(value)
    if value == nil then return '' end
    if type(value) == 'string' then return value end
    return tostring(value)
end

--- Neutralise Discord mention syntax in untrusted text. `allowed_mentions` in
--- the message payload is the real enforcement point; this is the second layer,
--- and it also keeps `@everyone` out of the visible text entirely.
function Util.sanitize(s)
    if type(s) ~= 'string' then return s end
    s = s:gsub('@everyone', '@' .. ZWSP .. 'everyone')
    s = s:gsub('@here', '@' .. ZWSP .. 'here')
    s = s:gsub('<@', '<' .. ZWSP .. '@')   -- <@user>, <@&role>
    return s
end

--- Stop a value from closing the ```json fence it is rendered inside and
--- writing raw markdown after it.
function Util.fenceSafe(s)
    if type(s) ~= 'string' then return s end
    return (s:gsub('```', '`' .. ZWSP .. '``'))
end

--- Shallow-merge tables left to right; later arguments win. Used for the
--- defaults < channel < activity < call-site override chain.
function Util.merge(...)
    local out = {}
    for i = 1, select('#', ...) do
        local t = select(i, ...)
        if type(t) == 'table' then
            for k, v in pairs(t) do out[k] = v end
        end
    end
    return out
end

--- Accepts 0xRRGGBB, "#RRGGBB", "RRGGBB" or a plain decimal, and returns the
--- integer Discord wants (or nil).
function Util.color(value)
    if type(value) == 'number' then return math.floor(value) end
    if type(value) ~= 'string' then return nil end
    local hex = value:gsub('^#', ''):gsub('^0[xX]', '')
    return tonumber(hex, 16)
end

--- ISO-8601 UTC timestamp, the format Discord embeds expect.
function Util.isoTimestamp()
    return os.date('!%Y-%m-%dT%H:%M:%SZ')
end

--------------------------------------------------------------------------------
-- JSON
--------------------------------------------------------------------------------
local ESCAPES = {
    ['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n', ['\r'] = '\\r',
    ['\t'] = '\\t', ['\b'] = '\\b', ['\f'] = '\\f',
}

local function escapeString(s)
    return (s:gsub('[%c"\\]', function(c)
        return ESCAPES[c] or ('\\u%04x'):format(c:byte())
    end))
end

--- Encode a value as the JSON string that gets logged.
---
--- Deliberately not the runtime's `json.encode`: a log line has to survive
--- whatever a caller hands it, so this one is depth-capped, cycle-safe,
--- per-string truncated, key-sorted (so the same object always renders the same
--- way and diffs cleanly), and indented for reading in Discord.
---
--- opts: indent (spaces, 0 for one line), maxDepth, maxStringLength.
function Util.encodeJson(value, opts)
    opts = opts or {}
    local indent = opts.indent == nil and 2 or opts.indent
    local maxDepth = opts.maxDepth or 4
    local maxString = opts.maxStringLength or 500

    local buf, seen = {}, {}

    local function pad(depth)
        if indent <= 0 then return '' end
        return '\n' .. string.rep(' ', indent * depth)
    end

    local function write(v, depth)
        local kind = type(v)

        if v == nil then
            buf[#buf + 1] = 'null'
        elseif kind == 'boolean' then
            buf[#buf + 1] = tostring(v)
        elseif kind == 'number' then
            if v ~= v or v == math.huge or v == -math.huge then
                buf[#buf + 1] = 'null'                    -- nan/inf aren't JSON
            elseif math.type and math.type(v) == 'integer' then
                buf[#buf + 1] = tostring(v)
            else
                buf[#buf + 1] = ('%.14g'):format(v)
            end
        elseif kind == 'string' then
            buf[#buf + 1] = '"' .. escapeString(Util.truncate(v, maxString)) .. '"'
        elseif kind ~= 'table' then
            buf[#buf + 1] = '"' .. escapeString(tostring(v)) .. '"'
        elseif seen[v] then
            buf[#buf + 1] = '"<cycle>"'
        elseif depth >= maxDepth then
            buf[#buf + 1] = '"<truncated>"'
        else
            seen[v] = true

            local keys, count, isArray = {}, 0, true
            for key in pairs(v) do
                count = count + 1
                if type(key) ~= 'number' then isArray = false end
                keys[#keys + 1] = key
            end

            if count == 0 then
                buf[#buf + 1] = '{}'
            elseif isArray and count == #v then
                buf[#buf + 1] = '['
                for i, item in ipairs(v) do
                    if i > 1 then buf[#buf + 1] = ',' end
                    buf[#buf + 1] = pad(depth + 1)
                    write(item, depth + 1)
                end
                buf[#buf + 1] = pad(depth) .. ']'
            else
                table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
                buf[#buf + 1] = '{'
                for i, key in ipairs(keys) do
                    if i > 1 then buf[#buf + 1] = ',' end
                    buf[#buf + 1] = pad(depth + 1)
                        .. '"' .. escapeString(tostring(key)) .. '":'
                        .. (indent > 0 and ' ' or '')
                    write(v[key], depth + 1)
                end
                buf[#buf + 1] = pad(depth) .. '}'
            end

            seen[v] = nil
        end
    end

    write(value, 0)
    return table.concat(buf)
end

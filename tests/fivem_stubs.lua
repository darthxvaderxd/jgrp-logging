--- Minimal stand-ins for the FiveM runtime, so the pure logic in this resource
--- (template rendering, activity resolution, embed building, queue batching,
--- client-payload validation) can be exercised outside the game server.
---
--- Everything the resource records here — HTTP requests, registered handlers,
--- console output — is readable from `Stub` so tests can assert on it.
Stub = {
    requests = {},
    responses = {},          -- queued { status, body, headers }; defaults to 204
    netEvents = {},
    events = {},
    commands = {},
    exports = {},
    threads = {},
    prints = {},
    convars = {},
    players = {},
    files = {},
    gameTimer = 0,
    waits = 0,
    maxWaits = 200,          -- guards the workers' `while true` loops
}

function Stub.reset()
    Stub.requests, Stub.responses = {}, {}
    Stub.prints, Stub.threads = {}, {}
    Stub.files = {}
    Stub.waits, Stub.gameTimer = 0, 0
end

--------------------------------------------------------------------------------
-- json (FiveM ships one; this is just enough for the code under test)
--------------------------------------------------------------------------------
json = {}

local function encodeValue(value)
    local kind = type(value)
    if value == nil then return 'null' end
    if kind == 'boolean' or kind == 'number' then return tostring(value) end
    if kind == 'string' then
        return '"' .. value:gsub('[%c"\\]', function(c)
            if c == '"' then return '\\"' end
            if c == '\\' then return '\\\\' end
            if c == '\n' then return '\\n' end
            return ('\\u%04x'):format(c:byte())
        end) .. '"'
    end
    if kind ~= 'table' then return '"' .. tostring(value) .. '"' end

    if #value > 0 then
        local parts = {}
        for _, item in ipairs(value) do parts[#parts + 1] = encodeValue(item) end
        return '[' .. table.concat(parts, ',') .. ']'
    end

    local keys = {}
    for key in pairs(value) do keys[#keys + 1] = tostring(key) end
    table.sort(keys)
    local parts = {}
    for _, key in ipairs(keys) do
        parts[#parts + 1] = encodeValue(key) .. ':' .. encodeValue(value[key])
    end
    return '{' .. table.concat(parts, ',') .. '}'
end

function json.encode(value) return encodeValue(value) end

--- Recursive-descent decode. Kept honest rather than approximate because the
--- resource round-trips real data through it: 429 bodies, and the spool file it
--- writes on stop and reads back on start.
function json.decode(text)
    text = tostring(text)
    local pos = 1

    local function fail(what)
        error(('invalid JSON at %d: expected %s'):format(pos, what), 0)
    end

    local function skipSpace()
        pos = text:find('[^ \t\r\n]', pos) or (#text + 1)
    end

    local parseValue

    local function parseString()
        if text:sub(pos, pos) ~= '"' then fail('a string') end
        pos = pos + 1
        local buf = {}
        while true do
            local char = text:sub(pos, pos)
            if char == '' then fail('a closing quote') end
            if char == '"' then pos = pos + 1 break end
            if char == '\\' then
                local escape = text:sub(pos + 1, pos + 1)
                local simple = { n = '\n', t = '\t', r = '\r', b = '\b', f = '\f',
                                 ['"'] = '"', ['\\'] = '\\', ['/'] = '/' }
                if simple[escape] then
                    buf[#buf + 1] = simple[escape]
                    pos = pos + 2
                elseif escape == 'u' then
                    local hex = text:sub(pos + 2, pos + 5)
                    buf[#buf + 1] = string.char(tonumber(hex, 16) % 256)
                    pos = pos + 6
                else
                    fail('a valid escape')
                end
            else
                buf[#buf + 1] = char
                pos = pos + 1
            end
        end
        return table.concat(buf)
    end

    parseValue = function()
        skipSpace()
        local char = text:sub(pos, pos)

        if char == '{' then
            pos = pos + 1
            local out = {}
            skipSpace()
            if text:sub(pos, pos) == '}' then pos = pos + 1 return out end
            while true do
                skipSpace()
                local key = parseString()
                skipSpace()
                if text:sub(pos, pos) ~= ':' then fail('a colon') end
                pos = pos + 1
                out[key] = parseValue()
                skipSpace()
                local next = text:sub(pos, pos)
                pos = pos + 1
                if next == '}' then return out end
                if next ~= ',' then fail('a comma or closing brace') end
            end
        end

        if char == '[' then
            pos = pos + 1
            local out = {}
            skipSpace()
            if text:sub(pos, pos) == ']' then pos = pos + 1 return out end
            while true do
                out[#out + 1] = parseValue()
                skipSpace()
                local next = text:sub(pos, pos)
                pos = pos + 1
                if next == ']' then return out end
                if next ~= ',' then fail('a comma or closing bracket') end
            end
        end

        if char == '"' then return parseString() end
        if text:sub(pos, pos + 3) == 'true' then pos = pos + 4 return true end
        if text:sub(pos, pos + 4) == 'false' then pos = pos + 5 return false end
        if text:sub(pos, pos + 3) == 'null' then pos = pos + 4 return nil end

        local number = text:match('^%-?%d+%.?%d*[eE]?[%+%-]?%d*', pos)
        if number and #number > 0 then
            pos = pos + #number
            return tonumber(number)
        end

        fail('a value')
    end

    return parseValue()
end

--------------------------------------------------------------------------------
-- Natives
--------------------------------------------------------------------------------
local realPrint = print
function print(...)
    Stub.prints[#Stub.prints + 1] = table.concat({ ... }, ' ')
    if Stub.echo then realPrint(...) end
end

function GetConvar(name, default)
    local value = Stub.convars[name]
    if value == nil then return default end
    return value
end

function GetCurrentResourceName() return 'jgrp-logging' end
function GetGameTimer() return Stub.gameTimer end

function GetPlayerName(id)
    local player = Stub.players[tonumber(id)]
    return player and player.name or nil
end

function GetPlayerIdentifiers(id)
    local player = Stub.players[tonumber(id)]
    return player and player.identifiers or {}
end

function GetPlayerEndpoint(id)
    local player = Stub.players[tonumber(id)]
    return player and player.endpoint or nil
end

--- Threads are recorded, not started; Stub.runThreads() drives them.
function CreateThread(fn) Stub.threads[#Stub.threads + 1] = fn end
function SetTimeout(_, fn) Stub.threads[#Stub.threads + 1] = fn end

--- Advances the fake clock, and aborts the caller once the budget is spent so a
--- worker's `while true` loop terminates.
function Wait(ms)
    Stub.gameTimer = Stub.gameTimer + (tonumber(ms) or 0)
    Stub.waits = Stub.waits + 1
    if Stub.waits > Stub.maxWaits then error('__halt', 0) end
end

function LoadResourceFile(_, path)
    return Stub.files[path]
end

function SaveResourceFile(_, path, data)
    Stub.files[path] = data
    return true
end

function PerformHttpRequest(url, cb, method, body, headers)
    Stub.requests[#Stub.requests + 1] = {
        url = url, method = method, body = body, headers = headers,
        -- When the request happened on the fake clock. Timing assertions have
        -- to compare these, not Stub.gameTimer: an idle worker's flush loop
        -- advances the clock on its own, which would pass any "time went by"
        -- assertion whether or not the code under test actually waited.
        at = Stub.gameTimer,
    }
    local response = table.remove(Stub.responses, 1) or { status = 204, body = '' }
    cb(response.status, response.body or '', response.headers or {})
end

function exports(name, fn) Stub.exports[name] = fn end
function RegisterNetEvent(name, fn) Stub.netEvents[name] = fn end
function AddEventHandler(name, fn)
    Stub.events[name] = Stub.events[name] or {}
    table.insert(Stub.events[name], fn)
end
function RegisterCommand(name, fn) Stub.commands[name] = fn end
function TriggerEvent(name, ...)
    for _, fn in ipairs(Stub.events[name] or {}) do fn(...) end
end

--- Run every queued worker until it exhausts its Wait budget.
function Stub.runThreads()
    local threads = Stub.threads
    Stub.threads = {}
    for _, fn in ipairs(threads) do
        Stub.waits = 0
        local ok, err = pcall(fn)
        if not ok and tostring(err):find('__halt') == nil then error(err, 0) end
    end
end

--- Invoke a client-triggered net event as `source`.
function Stub.fireNetEvent(name, src, ...)
    source = src
    local handler = Stub.netEvents[name]
    if handler then handler(...) end
    source = nil
end

--- Invoke a server event handler as `source`.
function Stub.fireEvent(name, src, ...)
    source = src
    for _, fn in ipairs(Stub.events[name] or {}) do fn(...) end
    source = nil
end

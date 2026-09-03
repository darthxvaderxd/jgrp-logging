--- Test suite for jgrp-logging. Run from the resource root:
---
---     lua tests/spec.lua
---
--- It loads the real resource files against tests/fivem_stubs.lua, so it covers
--- the parts that don't need a game server: JSON rendering and sanitization,
--- activity resolution, token/channel-id validation, embed building, and queue
--- batching and retry.

dofile('tests/fivem_stubs.lua')
dofile('shared/util.lua')
dofile('config/config.lua')
dofile('server/http.lua')
dofile('server/embed.lua')
dofile('server/queue.lua')
dofile('server/logger.lua')
dofile('server/spool.lua')
dofile('server/api.lua')

--------------------------------------------------------------------------------
-- Tiny test harness
--------------------------------------------------------------------------------
local passed, failed = 0, 0

local function it(name, fn)
    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
    else
        failed = failed + 1
        io.write(('  FAIL  %s\n         %s\n'):format(name, tostring(err)))
    end
end

local function check(condition, message)
    if not condition then error(message or 'assertion failed', 2) end
end

local function eq(actual, expected, message)
    if actual ~= expected then
        error(('%s\n         expected: %s\n         actual:   %s')
            :format(message or 'values differ', tostring(expected), tostring(actual)), 2)
    end
end

local function contains(haystack, needle)
    check(type(haystack) == 'string' and haystack:find(needle, 1, true) ~= nil,
        ('expected %q to contain %q'):format(tostring(haystack), needle))
end

local function excludes(haystack, needle, message)
    check(type(haystack) == 'string' and haystack:find(needle, 1, true) == nil,
        message or ('expected %q not to contain %q'):format(tostring(haystack), needle))
end

local TOKEN = 'MTIzNDU2Nzg5MDEyMzQ1Njc4.Gh1jK2.abcdefghijklmnopqrstuvwxyz012345'
local channelIds = {}

--- Restore a clean, fully-wired config before each scenario.
local function resetConfig()
    Stub.reset()
    Stub.convars = { jgrp_discord_token = TOKEN }
    Stub.players = {}

    local index = 0
    channelIds = {}
    for key, channel in pairs(Config.Channels) do
        index = index + 1
        channel.id = ('1000000000000000%02d'):format(index)
        channelIds[key] = channel.id
    end

    Config.Enabled = true
    Config.MinLevel = 'debug'
    Config.FallbackChannel = 'general'
    Logger.reset()
    Queue.reset()
end

local function lastRequest()
    local request = Stub.requests[#Stub.requests]
    check(request, 'no HTTP request was made')
    return request
end

--------------------------------------------------------------------------------
print('Util.encodeJson')
--------------------------------------------------------------------------------
it('renders an object with sorted keys and stable formatting', function()
    eq(Util.encodeJson({ b = 2, a = 'x' }, { indent = 0 }), '{"a":"x","b":2}')
end)

it('renders arrays as arrays and empty tables as objects', function()
    eq(Util.encodeJson({ 1, 2, 3 }, { indent = 0 }), '[1,2,3]')
    eq(Util.encodeJson({}, { indent = 0 }), '{}')
end)

it('indents nested structures', function()
    eq(Util.encodeJson({ a = { b = 1 } }, { indent = 2 }),
        '{\n  "a": {\n    "b": 1\n  }\n}')
end)

it('escapes strings that would break the JSON', function()
    eq(Util.encodeJson({ s = 'he said "hi"\n' }, { indent = 0 }), '{"s":"he said \\"hi\\"\\n"}')
end)

it('caps depth instead of recursing forever', function()
    local deep = { a = { b = { c = { d = { e = 'too far' } } } } }
    local out = Util.encodeJson(deep, { indent = 0, maxDepth = 3 })
    contains(out, '"<truncated>"')
    excludes(out, 'too far')
end)

it('survives a cyclic object', function()
    local node = { name = 'root' }
    node.self = node
    contains(Util.encodeJson(node, { indent = 0 }), '"<cycle>"')
end)

it('truncates long strings inside the object', function()
    local out = Util.encodeJson({ blob = string.rep('x', 900) }, { indent = 0, maxStringLength = 50 })
    check(#out < 120, 'oversized value should have been truncated, got ' .. #out)
end)

it('renders integers without a decimal tail', function()
    eq(Util.encodeJson({ n = 500 }, { indent = 0 }), '{"n":500}')
end)

--------------------------------------------------------------------------------
print('Util')
--------------------------------------------------------------------------------
it('defuses mention syntax in untrusted text', function()
    local out = Util.sanitize('@everyone <@1234> hi')
    excludes(out, '@everyone')
    excludes(out, '<@1234>')
    contains(out, 'hi')
end)

it('stops a value closing the code fence', function()
    excludes(Util.fenceSafe('a ``` b'), '```')
end)

it('truncates without leaving a partial UTF-8 sequence', function()
    local out = Util.truncate('aaaa\226\130\172bbbb', 8)
    check(#out <= 8, 'truncated string should fit the budget')
    eq(out, 'aaaa...')
end)

it('parses colours in every accepted form', function()
    eq(Util.color(0xE74C3C), 0xE74C3C)
    eq(Util.color('#E74C3C'), 0xE74C3C)
    eq(Util.color('E74C3C'), 0xE74C3C)
    eq(Util.color(nil), nil)
end)

it('orders levels', function()
    check(Util.levelValue('debug') < Util.levelValue('info'))
    check(Util.levelValue('critical') > Util.levelValue('error'))
    eq(Util.levelValue('nonsense'), Util.LEVELS.info)
end)

--------------------------------------------------------------------------------
print('Activity resolution')
--------------------------------------------------------------------------------
it('prefers an exact match over a wildcard', function()
    resetConfig()
    eq(Logger.resolveActivity('vehicle.spawn').title, 'Vehicle Spawned')
end)

it('falls back to the longest matching wildcard', function()
    resetConfig()
    Config.Activities['money.bank.*'] = { channel = 'admin' }
    Logger.reset()
    eq(Logger.resolveActivity('money.bank.withdraw').channel, 'admin')
    eq(Logger.resolveActivity('money.paycheck').channel, 'economy')
    Config.Activities['money.bank.*'] = nil
    Logger.reset()
end)

it('returns nil for an unmapped activity', function()
    resetConfig()
    eq(Logger.resolveActivity('totally.unmapped'), nil)
end)

--------------------------------------------------------------------------------
print('Discord endpoint')
--------------------------------------------------------------------------------
it('posts to the mapped channel id as the bot', function()
    resetConfig()
    eq(Logger.log('admin.ban', 'Bob was banned', { reason = 'RDM' }), true)
    Stub.runThreads()

    local request = lastRequest()
    eq(request.url, 'https://discord.com/api/v10/channels/' .. channelIds.admin .. '/messages')
    eq(request.method, 'POST')
    eq(request.headers['Authorization'], 'Bot ' .. TOKEN)
    eq(request.headers['Content-Type'], 'application/json')
end)

it('logs nothing when the token convar is unset', function()
    resetConfig()
    Stub.convars.jgrp_discord_token = nil
    eq(Logger.log('admin.ban', 'Bob was banned'), false)
    Stub.runThreads()
    eq(#Stub.requests, 0)
end)

it('refuses a token that could inject an extra header', function()
    resetConfig()
    Stub.convars.jgrp_discord_token = TOKEN .. '\r\nX-Injected: 1'
    eq(Logger.log('admin.ban', 'Bob was banned'), false)
    eq(#Stub.requests, 0)
end)

it('refuses a channel id that is not a snowflake', function()
    resetConfig()
    Config.Channels.admin.id = '12345'
    eq(Logger.log('admin.ban', 'Bob was banned'), false)
    eq(#Stub.requests, 0)
end)

it('refuses a channel id that would escape the API path', function()
    resetConfig()
    Config.Channels.admin.id = '000000000000000001/../../users/@me'
    eq(Logger.log('admin.ban', 'Bob was banned'), false)
    eq(#Stub.requests, 0)
end)

it('never prints the token in a warning', function()
    resetConfig()
    Stub.convars.jgrp_discord_token = 'not a token'
    Logger.log('admin.ban', 'Bob was banned')
    for _, line in ipairs(Stub.prints) do
        excludes(line, 'not a token', 'a warning leaked the token value')
    end
    check(#Stub.prints > 0, 'an unusable token should warn')
end)

--------------------------------------------------------------------------------
print('Message shape')
--------------------------------------------------------------------------------
it('sends the message with the object as a JSON block', function()
    resetConfig()
    Logger.log('money.transfer', 'Bob paid Alice $500', { amount = 500, target = 'Alice' })
    Stub.runThreads()

    local body = lastRequest().body
    contains(body, 'Bob paid Alice $500')
    contains(body, '```json')
    contains(body, '\\"amount\\": 500')
    contains(body, '\\"target\\": \\"Alice\\"')
    contains(body, 'Money Transfer')
end)

it('titles the embed with the activity when none is configured', function()
    resetConfig()
    Logger.log('money.paycheck', 'Payday', { amount = 1 })
    Stub.runThreads()
    contains(lastRequest().body, '"title":"money.paycheck"')
end)

it('logs a message with no object at all', function()
    resetConfig()
    Logger.log('error', 'something broke')
    Stub.runThreads()
    local body = lastRequest().body
    contains(body, 'something broke')
    excludes(body, 'json')
end)

it('logs an object with no message', function()
    resetConfig()
    Logger.log('error', nil, { code = 500 })
    Stub.runThreads()
    contains(lastRequest().body, '```json')
end)

it('routes an unmapped activity to the fallback channel', function()
    resetConfig()
    eq(Logger.log('totally.unmapped', 'hello'), true)
    Stub.runThreads()
    contains(lastRequest().url, channelIds.general)
end)

it('drops an unmapped activity when there is no fallback channel', function()
    resetConfig()
    Config.FallbackChannel = nil
    eq(Logger.log('totally.unmapped', 'hello'), false)
end)

it('drops activities below MinLevel', function()
    resetConfig()
    Config.MinLevel = 'warn'
    eq(Logger.log('chat.message', 'hi'), false)
    eq(Logger.log('admin.ban', 'banned'), true)
end)

it('drops everything when disabled', function()
    resetConfig()
    Config.Enabled = false
    eq(Logger.log('admin.ban', 'banned'), false)
    Config.Enabled = true
end)

--------------------------------------------------------------------------------
print('Player attribution')
--------------------------------------------------------------------------------
it('merges the player into the logged object', function()
    resetConfig()
    Stub.players[3] = { name = 'Bob', identifiers = { 'license:abc123', 'discord:42' } }
    Logger.logPlayer(3, 'money.transfer', 'Bob paid Alice', { amount = 500 })
    Stub.runThreads()

    local body = lastRequest().body
    contains(body, '\\"name\\": \\"Bob\\"')
    contains(body, '\\"license\\": \\"abc123\\"')
    contains(body, '\\"discord\\": \\"42\\"')
    contains(body, '\\"amount\\": 500')
end)

it('omits the endpoint unless it is switched on', function()
    resetConfig()
    Stub.players[3] = { name = 'Bob', identifiers = {}, endpoint = '203.0.113.7' }
    Logger.logPlayer(3, 'player.joined', 'Bob joined')
    Stub.runThreads()
    excludes(lastRequest().body, '203.0.113.7')

    resetConfig()
    Config.Player.includeEndpoint = true
    Stub.players[3] = { name = 'Bob', identifiers = {}, endpoint = '203.0.113.7' }
    Logger.logPlayer(3, 'player.joined', 'Bob joined')
    Stub.runThreads()
    contains(lastRequest().body, '203.0.113.7')
    Config.Player.includeEndpoint = false
end)

it('never lets a caller-supplied player override the real one', function()
    resetConfig()
    Stub.players[3] = { name = 'Bob', identifiers = { 'license:bob' } }
    Logger.logPlayer(3, 'admin.ban', 'ban', { player = { name = 'Somebody Else' } })
    Stub.runThreads()
    excludes(lastRequest().body, 'Somebody Else')
end)

it('never mutates the caller data table', function()
    resetConfig()
    Stub.players[3] = { name = 'Bob', identifiers = {} }
    local data = { amount = 1 }
    Logger.logPlayer(3, 'money.transfer', 'paid', data)
    eq(data.player, nil)
end)

--------------------------------------------------------------------------------
print('Escaping')
--------------------------------------------------------------------------------
it('defuses a mention hidden in the message', function()
    resetConfig()
    Logger.log('error', 'ping @everyone now')
    Stub.runThreads()
    excludes(lastRequest().body, '@everyone')
end)

it('defuses a mention hidden inside the object', function()
    resetConfig()
    Logger.log('error', 'boom', { note = '@everyone' })
    Stub.runThreads()
    excludes(lastRequest().body, '@everyone')
end)

it('stops a value breaking out of the JSON code fence', function()
    resetConfig()
    Logger.log('error', 'boom', { note = '``` **markdown**' })
    Stub.runThreads()
    local body = lastRequest().body
    local _, fences = body:gsub('```', '')
    eq(fences, 2, 'exactly the opening and closing fence should survive')
end)

it('keeps the object when the message is too long for one embed', function()
    resetConfig()
    Logger.log('error', string.rep('x', 6000), { code = 500 })
    Stub.runThreads()
    local body = lastRequest().body
    contains(body, '```json')
    contains(body, '\\"code\\": 500')
end)

--------------------------------------------------------------------------------
print('Queue')
--------------------------------------------------------------------------------
it('batches at most 10 embeds per request', function()
    resetConfig()
    for i = 1, 12 do
        Logger.log('error', 'boom ' .. i)
    end
    Stub.runThreads()
    eq(#Stub.requests, 2)
    local _, count = Stub.requests[1].body:gsub('"title"', '')
    eq(count, 10, 'first request should carry 10 embeds')
    contains(Stub.requests[2].body, 'boom 12')
end)

it('sends no content and no ping permission when no mention is configured', function()
    resetConfig()
    Logger.log('error', 'boom')
    Stub.runThreads()
    local body = lastRequest().body
    excludes(body, '"content"', 'no mention should mean no content field')
    excludes(body, 'allowed_mentions',
        'with no content there is nothing that could ping, so the key is omitted')
end)

it('honours a channel mention and permits exactly that role', function()
    resetConfig()
    Config.Channels.errors.mention = '<@&999888777666555444>'
    Logger.log('error', 'boom')
    Stub.runThreads()
    contains(lastRequest().body, '"content"')
    contains(lastRequest().body, '"roles":["999888777666555444"]')
    Config.Channels.errors.mention = nil
end)

it('allows only operator-authored mentions', function()
    -- nil, not an empty object: an empty Lua table would encode as `{}`, which
    -- Discord rejects for allowed_mentions.parse.
    eq(Embed.allowedMentions({}), nil)
    eq(Embed.allowedMentions({ 'no mention syntax here' }), nil)

    local role = Embed.allowedMentions({ '<@&123456789012345678>' })
    eq(role.roles[1], '123456789012345678')
    eq(role.parse, nil)
    eq(role.users, nil)

    eq(Embed.allowedMentions({ '@here' }).parse[1], 'everyone')
end)

it('retries after a 429 and honours retry_after', function()
    resetConfig()
    Stub.responses = { { status = 429, body = '{"retry_after":0.5}' } }
    Logger.log('error', 'boom')
    Stub.runThreads()
    eq(#Stub.requests, 2, 'should have retried once')
end)

it('gives up without retrying on a 400', function()
    resetConfig()
    Stub.responses = { { status = 400, body = '{"message":"Invalid Form Body"}' } }
    Logger.log('error', 'boom')
    Stub.runThreads()
    eq(#Stub.requests, 1, 'a 400 is not retryable')
end)

it('explains a 403 instead of retrying it', function()
    resetConfig()
    Stub.responses = { { status = 403, body = '{"message":"Missing Permissions"}' } }
    Logger.log('error', 'boom')
    Stub.runThreads()
    eq(#Stub.requests, 1)
    local warned = false
    for _, line in ipairs(Stub.prints) do
        if line:find('Send Messages', 1, true) then warned = true end
    end
    check(warned, 'a 403 should name the permissions the bot needs')
end)

it('paces separate channels independently', function()
    resetConfig()
    Logger.log('error', 'boom')
    Logger.log('money.paycheck', 'payday')
    Stub.runThreads()
    eq(#Stub.requests, 2)
    check(Stub.requests[1].url ~= Stub.requests[2].url, 'each channel has its own endpoint')
end)

it('reports queue depth and delivery counts', function()
    resetConfig()
    Logger.log('error', 'boom')
    Stub.runThreads()
    eq(Queue.stats().errors.sent, 1)
end)

--------------------------------------------------------------------------------
print('No client entry point')
--------------------------------------------------------------------------------
--- Client-triggered logging was removed: a client picked the activity, wrote the
--- message and filled the object an admin then read as fact, and no amount of
--- allowlisting or rate limiting changes who authored that text. These two guard
--- the removal — a net event, or a client_script, would put it straight back.
it('registers no net event, so a client cannot reach the logger', function()
    -- Self-check first: an empty table would also be what you'd see if the stub
    -- had stopped recording registrations, which would make this vacuous.
    RegisterNetEvent('jgrp-logging:spec-canary', function() end)
    check(Stub.netEvents['jgrp-logging:spec-canary'], 'the stub should record a registration')
    Stub.netEvents['jgrp-logging:spec-canary'] = nil

    local names = {}
    for name in pairs(Stub.netEvents) do names[#names + 1] = name end
    eq(#names, 0, 'a net event is reachable by any client: ' .. table.concat(names, ', '))
end)

it('ships no client script', function()
    local manifest = io.open('fxmanifest.lua')
    check(manifest, 'fxmanifest.lua should be readable from the resource root')
    -- Comments are stripped first: the manifest explains in prose why it has
    -- neither of these, and that prose isn't a declaration.
    local body = manifest:read('a'):gsub('%-%-[^\n]*', '')
    manifest:close()
    excludes(body, 'client_script', 'the resource must not ship a client script')
    excludes(body, 'shared_script', 'shared_scripts are downloaded by every client')
end)

--------------------------------------------------------------------------------
print('Attachments')
--------------------------------------------------------------------------------
--- An object big enough that it can't be rendered inline, carrying a marker
--- deeper than the inline maxDepth so the two renderings are distinguishable.
local function oversizedObject()
    local items = {}
    for i = 1, 200 do items[i] = ('entry number %d in a long list'):format(i) end
    return { items = items, deep = { a = { b = { c = { marker = 'FOUND-IN-FILE' } } } } }
end

it('uploads an oversized object as payload.json', function()
    resetConfig()
    Logger.log('error', 'big object', oversizedObject())
    Stub.runThreads()

    local request = lastRequest()
    contains(request.headers['Content-Type'], 'multipart/form-data; boundary=')
    contains(request.body, 'name="payload_json"')
    contains(request.body, 'filename="payload.json"')
    contains(request.body, '"attachments":[{"filename":"payload.json","id":0}]')
    eq(request.headers['Authorization'], 'Bot ' .. TOKEN, 'auth header survives the multipart path')
end)

it('keeps in the file what the inline preview had to drop', function()
    resetConfig()
    Logger.log('error', 'big object', oversizedObject())
    Stub.runThreads()

    local body = lastRequest().body
    local preview = body:sub(1, body:find('filename="payload.json"', 1, true))
    contains(preview, '<truncated>')
    excludes(preview, 'FOUND-IN-FILE', 'the deep value cannot fit the inline preview')
    contains(body, 'FOUND-IN-FILE')
    contains(body, 'attached as `payload.json`')
end)

it('truncates instead of attaching when attachOversized is off', function()
    resetConfig()
    Config.Json.attachOversized = false
    Logger.log('error', 'big object', oversizedObject())
    Stub.runThreads()

    local request = lastRequest()
    eq(request.headers['Content-Type'], 'application/json')
    excludes(request.body, 'payload.json')
    Config.Json.attachOversized = true
end)

it('never batches an attachment with other entries', function()
    resetConfig()
    Logger.log('error', 'one')
    Logger.log('error', 'two')
    Logger.log('error', 'big', oversizedObject())
    Logger.log('error', 'three')
    Stub.runThreads()

    eq(#Stub.requests, 3, 'the attachment must be sent on its own')
    excludes(Stub.requests[1].body, 'payload.json')
    contains(Stub.requests[1].body, 'one')
    contains(Stub.requests[1].body, 'two')
    contains(Stub.requests[2].body, 'filename="payload.json"')
    contains(Stub.requests[3].body, 'three')
end)

it('picks a boundary that does not appear in the body', function()
    resetConfig()
    local data = oversizedObject()
    data.sneaky = '----jgrpLoggingBoundary'
    Logger.log('error', 'big object', data)
    Stub.runThreads()

    local body = lastRequest().body
    local boundary = lastRequest().headers['Content-Type']:match('boundary=(.+)$')
    check(boundary ~= '----jgrpLoggingBoundary', 'a colliding boundary should have been replaced')
    local count, at = 0, 1
    while true do
        local found = body:find(boundary, at, true)   -- plain find: the boundary is not a pattern
        if not found then break end
        count = count + 1
        at = found + #boundary
    end
    eq(count, 3, 'the boundary should appear exactly three times: two parts and the terminator')
end)

--------------------------------------------------------------------------------
print('Rate limits')
--------------------------------------------------------------------------------
it('waits for the channel bucket to reset before the next send', function()
    resetConfig()
    Stub.responses = {
        { status = 204, headers = { ['X-RateLimit-Remaining'] = '0', ['X-RateLimit-Reset-After'] = '2' } },
    }
    Config.Channels.errors.maxEmbedsPerMessage = 1
    Logger.log('error', 'one')
    Logger.log('error', 'two')
    Stub.runThreads()

    eq(#Stub.requests, 2)
    check(Stub.requests[2].at - Stub.requests[1].at >= 2000,
        'the second send should have waited out the bucket, waited only '
            .. (Stub.requests[2].at - Stub.requests[1].at) .. 'ms')
    Config.Channels.errors.maxEmbedsPerMessage = nil
end)

it('holds every channel back after a global 429', function()
    resetConfig()
    Stub.responses = {
        { status = 429, body = '{"retry_after":3,"global":true}',
          headers = { ['X-RateLimit-Scope'] = 'global' } },
    }
    Logger.log('error', 'boom')

    -- Freeze the clock at the moment of the 429 so the cooldown is observable:
    -- it is module-level state in the queue, read by every channel's worker
    -- through the one awaitSendSlot path.
    local at429 = nil
    Stub.runThreads()
    at429 = Stub.requests[1].at

    eq(#Stub.requests, 2, 'the entry should have been retried after the cooldown')
    check(Stub.requests[2].at - at429 >= 3000,
        'the retry should wait out retry_after, waited only '
            .. (Stub.requests[2].at - at429) .. 'ms')

    local warned = false
    for _, line in ipairs(Stub.prints) do
        if line:find('globally rate limited', 1, true) then warned = true end
    end
    check(warned, 'a global rate limit should say so')
end)

it('reports the global cooldown so silence is explainable', function()
    resetConfig()
    Stub.responses = { { status = 429, body = '{"retry_after":30,"global":true}' } }
    Config.Queue.maxRetries = 0
    -- Cut the worker's idle budget short: its flush loop advances the fake
    -- clock every tick, and a 30s cooldown has to still be running when the
    -- assertion below reads it.
    Stub.maxWaits = 5
    Logger.log('error', 'boom')
    Stub.runThreads()
    Stub.maxWaits = 200

    check(Queue.globalPauseRemaining() > 0,
        'the cooldown every channel waits on should be visible to the operator')
    Stub.prints = {}
    Stub.commands['jgrplog'](0, { 'stats' })
    local said = false
    for _, line in ipairs(Stub.prints) do
        if line:find('globally rate limited', 1, true) then said = true end
    end
    check(said, 'jgrplog stats should say the bot is globally throttled')
    Config.Queue.maxRetries = 3
end)

it('stays under the global requests-per-second ceiling', function()
    resetConfig()
    Config.Queue.globalMaxPerSecond = 2
    Config.Channels.errors.maxEmbedsPerMessage = 1
    Config.Channels.errors.minIntervalMs = 0

    for i = 1, 5 do Logger.log('error', 'boom ' .. i) end
    Stub.runThreads()

    eq(#Stub.requests, 5)
    check(Stub.requests[3].at - Stub.requests[1].at >= 1000,
        'the 3rd request must wait for the 1st to age out of the window')
    check(Stub.requests[5].at - Stub.requests[1].at >= 2000,
        '5 requests at 2/s spans at least 2 seconds, spanned '
            .. (Stub.requests[5].at - Stub.requests[1].at) .. 'ms')

    Config.Queue.globalMaxPerSecond = 45
    Config.Channels.errors.maxEmbedsPerMessage = nil
    Config.Channels.errors.minIntervalMs = nil
end)

--------------------------------------------------------------------------------
print('Spool')
--------------------------------------------------------------------------------
it('writes undelivered entries on resource stop', function()
    resetConfig()
    Logger.log('error', 'never sent')          -- queued, workers not run
    Stub.fireEvent('onResourceStop', 0, 'jgrp-logging')

    local spooled = Stub.files['spool.json']
    check(spooled, 'the spool file should have been written')
    local entries = json.decode(spooled)
    eq(#entries, 1)
    eq(entries[1].channel, 'errors')
    contains(entries[1].embed.description, 'never sent')
end)

it('ignores another resource stopping', function()
    resetConfig()
    Logger.log('error', 'never sent')
    Stub.fireEvent('onResourceStop', 0, 'some-other-resource')
    eq(Stub.files['spool.json'], nil)
end)

it('re-queues spooled entries on the next start', function()
    resetConfig()
    Logger.log('error', 'survived the restart')
    Stub.fireEvent('onResourceStop', 0, 'jgrp-logging')

    -- A fresh start: queues empty, spool file still on disk.
    Queue.reset()
    Stub.requests = {}
    Spool.restore()
    Stub.runThreads()

    contains(lastRequest().body, 'survived the restart')
    eq(Stub.files['spool.json'], '', 'the spool should be cleared so it cannot replay forever')
end)

it('drops a spooled entry whose channel no longer exists', function()
    resetConfig()
    Stub.files['spool.json'] = json.encode({
        { channel = 'a-channel-that-was-deleted', embed = { title = 'orphan' } },
    })
    Spool.restore()
    Stub.runThreads()
    eq(#Stub.requests, 0)

    local warned = false
    for _, line in ipairs(Stub.prints) do
        if line:find('unknown channel', 1, true) then warned = true end
    end
    check(warned, 'an orphaned entry should say why it was dropped')
end)

it('discards a spool file it cannot parse', function()
    resetConfig()
    Stub.files['spool.json'] = 'not json at all'
    Spool.restore()
    eq(Stub.files['spool.json'], '')
    eq(#Stub.requests, 0)
end)

it('keeps the newest entries when the spool is capped', function()
    resetConfig()
    Config.Queue.maxSpoolEntries = 2
    for i = 1, 5 do Logger.log('error', 'entry ' .. i) end
    Stub.fireEvent('onResourceStop', 0, 'jgrp-logging')

    local entries = json.decode(Stub.files['spool.json'])
    eq(#entries, 2)
    contains(entries[2].embed.description, 'entry 5')
    Config.Queue.maxSpoolEntries = 200
end)

--------------------------------------------------------------------------------
print('Config reload')
--------------------------------------------------------------------------------
local realConfig = nil
local function withFakeConfig(source, fn)
    realConfig = realConfig or Config
    Stub.files['config/config.lua'] = source
    fn()
    -- Put the real config back for the rest of the suite.
    dofile('config/config.lua')
    Logger.reset()
    Queue.reset()
end

it('reloads config/config.lua in place', function()
    resetConfig()
    withFakeConfig([[
        Config = {
            Enabled = true, MinLevel = 'debug', FallbackChannel = 'general',
            Defaults = {}, Json = {}, Queue = {},
            Channels = { general = { id = '100000000000000099' } },
            Activities = { ['reloaded.activity'] = { channel = 'general', title = 'Reloaded' } },
        }
    ]], function()
        Stub.commands['jgrplog'](0, { 'reload' })
        eq(Config.Activities['reloaded.activity'].title, 'Reloaded')
        eq(Logger.resolveActivity('reloaded.activity').title, 'Reloaded',
            'the resolution cache must be dropped by a reload')
        eq(Config.Activities['admin.ban'], nil, 'the old config should be gone')
    end)
end)

it('keeps the running config when the new one does not compile', function()
    resetConfig()
    local before = Config
    withFakeConfig('Config = { this is not lua', function()
        Stub.commands['jgrplog'](0, { 'reload' })
        eq(Config, before, 'a broken config must not replace a working one')
    end)
end)

it('keeps the running config when the new one throws halfway', function()
    resetConfig()
    local before = Config
    withFakeConfig("Config = { Channels = {} }\nerror('boom')", function()
        Stub.commands['jgrplog'](0, { 'reload' })
        eq(Config, before, 'a half-built config must be rolled back')
    end)
end)

it('rejects a file that runs but is not a config', function()
    resetConfig()
    local before = Config
    withFakeConfig('Config = { nothing = true }', function()
        Stub.commands['jgrplog'](0, { 'reload' })
        eq(Config, before)
    end)
end)

it('reports a reload failure without claiming success', function()
    resetConfig()
    withFakeConfig('Config = { this is not lua', function()
        Stub.commands['jgrplog'](0, { 'reload' })
        local said = false
        for _, line in ipairs(Stub.prints) do
            if line:find('config reload failed', 1, true) then said = true end
        end
        check(said, 'a failed reload has to say so')
    end)
end)

--------------------------------------------------------------------------------
io.write(('\n%d passed, %d failed\n'):format(passed, failed))
os.exit(failed == 0 and 0 or 1)

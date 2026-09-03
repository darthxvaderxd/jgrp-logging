--- Per-channel delivery queue.
---
--- Every channel gets its own FIFO and its own worker coroutine, so a busy
--- channel (chat) can't stall a quiet, important one (errors), and each channel
--- is paced independently — Discord's message rate limit buckets are per
--- channel, not per bot.
Queue = {}

local channels = {}

--- Shared across every channel: Discord's 50-requests/second global limit and
--- the global cooldown a 429 with `global: true` imposes on the whole bot.
local globalSends = {}
local globalResumeAt = 0

--- Channel-level override, else the Config.Queue default. An explicit `0` or
--- `false` in a channel entry must win over the default, which is why this
--- checks for nil instead of using `or`.
local function setting(cfg, name)
    local value = cfg and cfg[name]
    if value == nil then value = Config.Queue[name] end
    return value
end

local function debug(fmt, ...)
    if Config.Debug then
        print(('[jgrp-logging] ' .. fmt):format(...))
    end
end

local function warn(fmt, ...)
    print(('[jgrp-logging] ^3WARN^7 ' .. fmt):format(...))
end

local function state(channelKey, channelCfg)
    local existing = channels[channelKey]
    if existing then
        existing.cfg = channelCfg
        return existing
    end
    local created = {
        key = channelKey,
        cfg = channelCfg,
        items = {},
        endpoint = nil,
        remaining = nil,        -- x-ratelimit-remaining from the last response
        resetAfterMs = nil,     -- x-ratelimit-reset-after from the last response
        sent = 0,
        dropped = 0,
        failed = 0,
        worker = false,
    }
    channels[channelKey] = created
    return created
end

--- Take the next sendable batch off the front of the queue. One API call
--- carries up to 10 embeds; mentions from every entry in the batch are merged
--- into the single `content` the message can have.
---
--- An entry with an attachment is sent alone: a file belongs to a message, not
--- to an embed, so batching one in would silently associate `payload.json`
--- with whichever other entries happened to share the request.
local function takeBatch(st)
    local max = setting(st.cfg, 'maxEmbedsPerMessage')
    if max > Embed.LIMITS.embedsPerMessage then max = Embed.LIMITS.embedsPerMessage end

    local head = st.items[1]
    if not head then return nil end

    if head.attachment then
        table.remove(st.items, 1)
        return { embeds = { head.embed }, mentions = { head.mention }, attachment = head.attachment }
    end

    local batch = { embeds = {}, mentions = {} }
    local seenMention = {}

    while #batch.embeds < max do
        local item = st.items[1]
        if not item or item.attachment then break end

        table.remove(st.items, 1)
        batch.embeds[#batch.embeds + 1] = item.embed
        if item.mention and not seenMention[item.mention] then
            seenMention[item.mention] = true
            batch.mentions[#batch.mentions + 1] = item.mention
        end
    end

    if #batch.embeds == 0 then return nil end
    return batch
end

--- Seconds to wait after a 429, from the JSON body (preferred — Discord always
--- sends it there) or the Retry-After header.
local function retryAfterSeconds(decodedBody, headers)
    if type(decodedBody) == 'table' and tonumber(decodedBody.retry_after) then
        return tonumber(decodedBody.retry_after)
    end
    local header = Http.header(headers, 'retry-after')
    if header and tonumber(header) then return tonumber(header) end
    return 1
end

local function decodeBody(body)
    if type(body) ~= 'string' or #body == 0 then return nil end
    local ok, decoded = pcall(json.decode, body)
    if ok and type(decoded) == 'table' then return decoded end
    return nil
end

--- Remember what the response said about this channel's bucket, so the next
--- send can wait for the window instead of discovering it with a 429.
local function updateBucket(st, headers)
    local remaining = tonumber(Http.header(headers, 'x-ratelimit-remaining'))
    local resetAfter = tonumber(Http.header(headers, 'x-ratelimit-reset-after'))
    if remaining then st.remaining = remaining end
    if resetAfter then st.resetAfterMs = math.ceil(resetAfter * 1000) + 50 end
end

--- Block until this channel is allowed to send: the global cooldown, then the
--- global requests-per-second ceiling, then this channel's own bucket.
local function awaitSendSlot(st)
    while GetGameTimer() < globalResumeAt do
        Wait(math.min(500, globalResumeAt - GetGameTimer() + 10))
    end

    local perSecond = setting(st.cfg, 'globalMaxPerSecond')
    if perSecond and perSecond > 0 then
        while true do
            local now = GetGameTimer()
            local kept = {}
            for _, stamp in ipairs(globalSends) do
                if now - stamp < 1000 then kept[#kept + 1] = stamp end
            end
            globalSends = kept
            if #kept < perSecond then break end
            Wait(math.max(50, 1000 - (now - kept[1]) + 10))
        end
    end

    if st.remaining and st.remaining <= 0 and st.resetAfterMs then
        debug('%s: bucket empty, waiting %dms for the window to reset', st.key, st.resetAfterMs)
        Wait(st.resetAfterMs)
        st.remaining = nil
    end
end

local function send(st, batch)
    local mentions = batch.mentions
    local content = #mentions > 0 and Util.truncate(table.concat(mentions, ' '), Embed.LIMITS.content) or nil

    local payload = {
        embeds = batch.embeds,
        content = content,
        allowed_mentions = Embed.allowedMentions(mentions),
    }

    if batch.attachment then
        -- Links the file to the message; the id matches the files[0] part.
        payload.attachments = { { id = 0, filename = batch.attachment.filename } }
    end

    local maxRetries = setting(st.cfg, 'maxRetries')
    local backoff = setting(st.cfg, 'retryBackoffMs')
    local timeout = setting(st.cfg, 'httpTimeoutMs')

    for attempt = 0, maxRetries do
        awaitSendSlot(st)

        local perSecond = setting(st.cfg, 'globalMaxPerSecond')
        if perSecond and perSecond > 0 then
            -- Only tracked while the limiter is on; otherwise this list would
            -- grow for the lifetime of the server with nothing pruning it.
            globalSends[#globalSends + 1] = GetGameTimer()
        end

        local status, body, headers
        if batch.attachment then
            status, body, headers = Http.postJsonWithFile(
                st.endpoint.url, payload, batch.attachment, st.endpoint.headers, timeout)
        else
            status, body, headers = Http.postJson(
                st.endpoint.url, payload, st.endpoint.headers, timeout)
        end

        updateBucket(st, headers)

        if status == 200 or status == 204 then
            st.sent = st.sent + #batch.embeds
            debug('%s: sent %d embed(s)%s', st.key, #batch.embeds,
                batch.attachment and ' with an attachment' or '')
            return true
        end

        if status == 429 then
            local decoded = decodeBody(body)
            local wait = retryAfterSeconds(decoded, headers)
            local isGlobal = (decoded and decoded.global == true)
                or Http.header(headers, 'x-ratelimit-scope') == 'global'

            if isGlobal then
                -- Every channel has to back off, not just this one.
                globalResumeAt = GetGameTimer() + math.ceil(wait * 1000) + 100
                warn('globally rate limited by Discord; pausing all channels for %.2fs', wait)
            else
                debug('%s: rate limited, waiting %.2fs', st.key, wait)
                Wait(math.ceil(wait * 1000) + 100)
            end
        elseif status == -1 or status >= 500 then
            debug('%s: transport/server failure (status %s), retrying', st.key, tostring(status))
            Wait(backoff * (2 ^ attempt))
        elseif status == 401 or status == 403 then
            -- A bad token, or the bot can't post here. Neither is fixable by
            -- retrying, and both are configuration problems worth naming.
            st.failed = st.failed + #batch.embeds
            warn('%s: Discord refused the request (status %s) — check the bot token and that the bot has View Channel / Send Messages / Embed Links on channel %s',
                st.key, tostring(status), tostring(st.cfg.id))
            return false
        else
            -- 400/404: a malformed payload or a channel that doesn't exist.
            -- Retrying can't help, and the body says what's wrong.
            st.failed = st.failed + #batch.embeds
            warn('%s: Discord rejected %d embed(s) with status %s: %s',
                st.key, #batch.embeds, tostring(status), tostring(body))
            return false
        end
    end

    st.failed = st.failed + #batch.embeds
    warn('%s: gave up on %d embed(s) after %d retries', st.key, #batch.embeds, maxRetries)
    return false
end

local function startWorker(st)
    if st.worker then return end
    st.worker = true

    CreateThread(function()
        while not st.stale do
            Wait(setting(st.cfg, 'flushIntervalMs'))
            while #st.items > 0 and not st.stale do
                local batch = takeBatch(st)
                if not batch then break end
                send(st, batch)
                Wait(setting(st.cfg, 'minIntervalMs'))
            end
        end
    end)
end

--- Enqueue one embed for delivery.
--- `endpoint` = { url = <string>, headers = <table> } as resolved by the logger.
--- `item` = { embed = <table>, mention = <string?>, attachment = <table?> }
function Queue.push(channelKey, channelCfg, endpoint, item)
    local st = state(channelKey, channelCfg)
    st.endpoint = endpoint

    local limit = setting(st.cfg, 'maxQueueLength')
    if #st.items >= limit then
        -- Backpressure: shed the oldest entry. Newer events are the ones an
        -- operator is watching for, and an unbounded queue would just grow
        -- until the server ran out of memory.
        table.remove(st.items, 1)
        st.dropped = st.dropped + 1
        if st.dropped == 1 or st.dropped % 50 == 0 then
            warn('%s: queue full (%d), dropped %d entr%s so far',
                st.key, limit, st.dropped, st.dropped == 1 and 'y' or 'ies')
        end
    end

    st.items[#st.items + 1] = item
    startWorker(st)
    return true
end

--- Remove every queued entry and return it as plain data, oldest first, for
--- spooling to disk. Entries are ordered by their embed timestamp so that a
--- cap keeps the newest across all channels, not just the newest of whichever
--- channel `pairs` happened to visit last.
function Queue.drain(maxEntries)
    local out = {}
    for key, st in pairs(channels) do
        for _, item in ipairs(st.items) do
            out[#out + 1] = {
                channel = key,
                embed = item.embed,
                mention = item.mention,
                attachment = item.attachment,
            }
        end
        st.items = {}
    end

    table.sort(out, function(a, b)
        return tostring(a.embed and a.embed.timestamp) < tostring(b.embed and b.embed.timestamp)
    end)

    if maxEntries and #out > maxEntries then
        local trimmed = {}
        for i = #out - maxEntries + 1, #out do trimmed[#trimmed + 1] = out[i] end
        return trimmed
    end
    return out
end

--- Drop every channel's state and queued entries. Workers belonging to the old
--- state exit on their next tick rather than lingering against a detached
--- queue. Used by the tests, and by anything that reloads Config at runtime.
function Queue.reset()
    for _, st in pairs(channels) do st.stale = true end
    channels = {}
    globalSends = {}
    globalResumeAt = 0
end

--- Milliseconds left on the global cooldown a `global: true` 429 imposed on
--- the whole bot, or 0. Every channel's worker waits this out before sending,
--- so a non-zero value here explains silence across all of them at once.
function Queue.globalPauseRemaining()
    return math.max(0, globalResumeAt - GetGameTimer())
end

--- Snapshot for the `jgrplog stats` console command.
function Queue.stats()
    local out = {}
    for key, st in pairs(channels) do
        out[key] = {
            pending = #st.items,
            sent = st.sent,
            dropped = st.dropped,
            failed = st.failed,
        }
    end
    return out
end

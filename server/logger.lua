--- Activity resolution, filtering and dispatch. This is the single funnel every
--- public entry point (exports, net event, built-in hooks, console command)
--- goes through, so a rule added here applies to all of them.
Logger = {}

local resolveCache = {}
local wildcardKeys = nil
local warnedChannel = {}
local warnedToken = false

local function debug(fmt, ...)
    if Config.Debug then
        print(('[jgrp-logging] ' .. fmt):format(...))
    end
end

local function warn(fmt, ...)
    print(('[jgrp-logging] ^3WARN^7 ' .. fmt):format(...))
end

--------------------------------------------------------------------------------
-- Activity -> config resolution
--------------------------------------------------------------------------------

--- Wildcard keys ('money.*'), longest prefix first, so 'money.bank.*' wins over
--- 'money.*'. Built once and reused; Logger.reset() clears it.
local function orderedWildcards()
    if wildcardKeys then return wildcardKeys end
    wildcardKeys = {}
    for key in pairs(Config.Activities or {}) do
        if key == '*' or key:sub(-2) == '.*' then
            wildcardKeys[#wildcardKeys + 1] = key
        end
    end
    table.sort(wildcardKeys, function(a, b) return #a > #b end)
    return wildcardKeys
end

--- The Config.Activities entry governing `activity`: exact match first, then
--- the longest matching wildcard, then nil.
function Logger.resolveActivity(activity)
    local cached = resolveCache[activity]
    if cached ~= nil then
        if cached == false then return nil end
        return cached
    end

    local activities = Config.Activities or {}
    local entry = activities[activity]

    if not entry then
        for _, key in ipairs(orderedWildcards()) do
            if key == '*' then
                entry = activities[key]
                break
            end
            local prefix = key:sub(1, #key - 1)   -- 'money.*' -> 'money.'
            if activity:sub(1, #prefix) == prefix then
                entry = activities[key]
                break
            end
        end
    end

    resolveCache[activity] = entry or false
    return entry
end

--- Drop the resolution caches and one-time warnings. Call after mutating
--- Config at runtime.
function Logger.reset()
    resolveCache = {}
    wildcardKeys = nil
    warnedChannel = {}
    warnedToken = false
end

--------------------------------------------------------------------------------
-- Discord endpoint resolution
--------------------------------------------------------------------------------

--- The bot token, or nil (warning once) when it isn't usable.
---
--- The charset check is not cosmetic: this value is interpolated into an
--- Authorization header, and a token containing CR/LF would let whatever
--- wrote the convar inject further headers into every request this resource
--- makes. Real tokens are base64url with dots, so the allowlist costs nothing.
--- Nothing here ever prints the token itself.
local function resolveToken()
    local convar = (Config.Discord and Config.Discord.tokenConvar) or 'jgrp_discord_token'
    local token = GetConvar(convar, '')

    if Util.isBlank(token) then
        if not warnedToken then
            warnedToken = true
            warn("convar '%s' is not set; nothing will be logged to Discord", convar)
        end
        return nil
    end

    if not token:match('^[%w%._%-]+$') then
        if not warnedToken then
            warnedToken = true
            warn("convar '%s' does not look like a bot token (unexpected characters); refusing to use it", convar)
        end
        return nil
    end

    return token
end

--- A Discord snowflake: 17-20 digits, and nothing else.
---
--- Validated because it is interpolated into the request path — an id carrying
--- `/` or `..` would address a different API endpoint entirely, not just a
--- different channel.
local function isSnowflake(id)
    return type(id) == 'string' and id:match('^%d+$') ~= nil and #id >= 17 and #id <= 20
end

--- { url, headers } for a channel, or nil (warning once per channel).
local function resolveEndpoint(channelKey, channelCfg)
    if not isSnowflake(channelCfg.id) then
        if not warnedChannel[channelKey] then
            warnedChannel[channelKey] = true
            warn("channel '%s' has no valid Discord channel id (expected a quoted 17-20 digit snowflake, got %s); its logs are being discarded",
                channelKey, channelCfg.id == nil and 'nothing' or ('%q'):format(tostring(channelCfg.id)))
        end
        return nil
    end

    local token = resolveToken()
    if not token then return nil end

    local version = (Config.Discord and Config.Discord.apiVersion) or 10
    return {
        url = ('https://discord.com/api/v%d/channels/%s/messages'):format(version, channelCfg.id),
        headers = { ['Authorization'] = 'Bot ' .. token },
    }
end

--------------------------------------------------------------------------------
-- Dispatch
--------------------------------------------------------------------------------

--- Route one already-built entry to its channel's queue.
---
--- Shared by log() and by the spool restore on resource start, which has an
--- embed already and only needs it routed — including the case where the
--- channel it was queued for no longer exists in a config that has been edited
--- since.
--- @param item table  { embed, mention?, attachment? }
--- @param context string|nil  what to name in a warning about an unknown channel
function Logger.dispatch(channelKey, item, context)
    local channelCfg = channelKey and Config.Channels[channelKey]
    if not channelCfg then
        local warnKey = tostring(channelKey)
        if not warnedChannel[warnKey] then
            warnedChannel[warnKey] = true
            warn('%s maps to unknown channel %q', context or 'an entry', warnKey)
        end
        return false
    end

    local endpoint = resolveEndpoint(channelKey, channelCfg)
    if not endpoint then return false end

    return Queue.push(channelKey, channelCfg, endpoint, item)
end

--------------------------------------------------------------------------------
-- Logging
--------------------------------------------------------------------------------

--- Log an activity.
---
--- @param activity string  key into Config.Activities (e.g. 'admin.ban')
--- @param message string|nil  the human-readable line
--- @param data any|nil     the object logged with it, rendered as a JSON block
--- @param overrides table|nil  per-call presentation overrides (title, color,
---        level, mention, channel)
--- @return boolean  true when the entry was queued for delivery
function Logger.log(activity, message, data, overrides)
    if not Config.Enabled then return false end

    if type(activity) ~= 'string' or activity == '' then
        warn('log() called with a %s activity; ignored', type(activity))
        return false
    end

    local entry = Logger.resolveActivity(activity)
    if not entry and not Config.FallbackChannel then
        debug("no mapping for activity '%s' and no fallback channel; dropped", activity)
        return false
    end
    entry = entry or {}

    local channelKey = (overrides and overrides.channel) or entry.channel or Config.FallbackChannel
    -- An unknown channel is caught by dispatch below, which owns that warning;
    -- merge tolerates the nil until then.
    local channelCfg = channelKey and Config.Channels[channelKey]

    local spec = Util.merge(Config.Defaults, channelCfg, entry, overrides)
    if spec.enabled == false then return false end
    if Util.levelValue(spec.level) < Util.levelValue(Config.MinLevel) then
        debug("activity '%s' below MinLevel; dropped", activity)
        return false
    end

    -- Without a configured title the activity name is the most useful label,
    -- and it keeps an entry identifiable even when the message is empty.
    if Util.isBlank(spec.title) then spec.title = activity end

    local embed, attachment = Embed.build(spec, message, data)
    if not embed then
        debug("activity '%s' produced an empty message; dropped", activity)
        return false
    end

    return Logger.dispatch(channelKey, {
        embed = embed,
        mention = Util.isBlank(spec.mention) and nil or spec.mention,
        attachment = attachment,
    }, ("activity '%s'"):format(activity))
end

--- Log an activity attributed to a player. The player's id, name and
--- identifiers are merged into the logged object under `player`, where the
--- server's copy always wins over anything the caller passed.
function Logger.logPlayer(source, activity, message, data, overrides)
    local payload = type(data) == 'table' and Util.merge(data) or {}
    if type(data) ~= 'table' and data ~= nil then payload.value = data end
    payload.player = Embed.playerInfo(source)
    return Logger.log(activity, message, payload, overrides)
end

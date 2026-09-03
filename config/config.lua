--- jgrp-logging configuration.
---
--- Server-side only (see fxmanifest.lua): the bot token is a secret and must
--- never be shipped to clients.
---
--- Two things are configured here:
---   1. Config.Channels   — the Discord channels you log to, by id, and how
---                          their messages look.
---   2. Config.Activities — the activity -> channel map.
---
--- A log entry is a message plus an object; the object is rendered as a JSON
--- block under the message. Presentation merges in this order, later winning:
---     Config.Defaults  <  channel entry  <  activity entry  <  call-site overrides
Config = {}

--- Master switch. `false` makes every log call a cheap no-op.
Config.Enabled = true

--- Print resolution/queue detail to the server console. Leave off in production.
Config.Debug = false

--- Activities below this level are dropped before a message is even built.
--- One of: debug, info, warn, error, critical.
Config.MinLevel = 'info'

--------------------------------------------------------------------------------
-- Discord connection
--------------------------------------------------------------------------------
Config.Discord = {
    --- Convar holding the bot token. Set it in server.cfg with `set` — NOT
    --- `setr`/`sets`, which replicate the value to every connecting client:
    ---
    ---     set jgrp_discord_token "MTIzNDU2Nzg5..."
    ---
    --- The bot must be in the guild and hold "View Channel", "Send Messages"
    --- and "Embed Links" on every channel listed below.
    tokenConvar = 'jgrp_discord_token',

    --- Discord REST API version used for POST /channels/{id}/messages.
    apiVersion = 10,
}

--------------------------------------------------------------------------------
-- Defaults applied to every message
--------------------------------------------------------------------------------
Config.Defaults = {
    color = 0x5865F2,                -- Discord blurple
    footer = 'jgrp-logging',
    timestamp = true,
    level = 'info',
    enabled = true,
}

--------------------------------------------------------------------------------
-- Channels
--------------------------------------------------------------------------------
--- `id` is the Discord channel id (Developer Mode on -> right-click a channel ->
--- Copy Channel ID). It's a snowflake: 17-20 digits, quoted so Lua keeps it
--- exact — an unquoted 19-digit number loses precision as a float.
---
--- A channel whose id isn't a well-formed snowflake is skipped with a one-time
--- console warning, so a typo degrades to "this channel doesn't log" rather
--- than firing malformed requests at the API.
Config.Channels = {
    connections = {
        id = '000000000000000001',
        color = 0x3498DB,
    },

    chat = {
        id = '000000000000000002',
        color = 0x95A5A6,
        -- Chat is high volume: batch harder and pace slower than the default.
        maxEmbedsPerMessage = 10,
        minIntervalMs = 1500,
    },

    admin = {
        id = '000000000000000003',
        color = 0xE67E22,
    },

    economy = {
        id = '000000000000000004',
        color = 0x2ECC71,
    },

    vehicles = {
        id = '000000000000000005',
        color = 0x9B59B6,
    },

    errors = {
        id = '000000000000000006',
        color = 0xE74C3C,
        -- Mentions must be operator-authored: they land in the message content,
        -- and only the ids named here are added to allowed_mentions. Never
        -- build one out of player-supplied data.
        mention = nil,               -- e.g. '<@&123456789012345678>' or '@here'
    },

    general = {
        id = '000000000000000007',
    },
}

--- Where an activity with no match in Config.Activities goes. Set to nil to
--- drop unmapped activities instead.
Config.FallbackChannel = 'general'

--------------------------------------------------------------------------------
-- Activity -> channel map
--------------------------------------------------------------------------------
--- Keys are activity names. `foo.*` matches any activity starting with `foo.`;
--- the longest matching prefix wins, exact keys beat every wildcard, and a bare
--- `*` is the catch-all. Recognised fields per entry:
---
---   channel  (string, required)  key into Config.Channels
---   title    (string)            embed title; defaults to the activity name
---   color    (number|string)     0xRRGGBB or '#RRGGBB'
---   level    (string)            debug|info|warn|error|critical
---   mention  (string)            operator-authored mention for this activity
---   enabled  (bool)              per-activity kill switch
---
--- Message text and the JSON object come from the call site, not from here.
Config.Activities = {
    ['player.connecting'] = { channel = 'connections', title = 'Player Connecting', level = 'debug' },
    ['player.joined'] = { channel = 'connections', title = 'Player Joined', color = 0x2ECC71 },
    ['player.dropped'] = { channel = 'connections', title = 'Player Left', color = 0xE74C3C },

    ['chat.message'] = { channel = 'chat', title = 'Chat', level = 'debug' },

    ['admin.command'] = { channel = 'admin', title = 'Admin Command', level = 'warn' },
    ['admin.ban'] = { channel = 'admin', title = 'Player Banned', level = 'warn', color = 0xC0392B },
    ['admin.kick'] = { channel = 'admin', title = 'Player Kicked', level = 'warn' },
    ['admin.*'] = { channel = 'admin', level = 'warn' },

    ['money.transfer'] = { channel = 'economy', title = 'Money Transfer' },
    ['money.*'] = { channel = 'economy' },
    ['shop.*'] = { channel = 'economy' },
    ['bank.*'] = { channel = 'economy' },

    ['vehicle.spawn'] = { channel = 'vehicles', title = 'Vehicle Spawned' },
    ['vehicle.*'] = { channel = 'vehicles' },

    ['error'] = { channel = 'errors', title = 'Server Error', level = 'error', color = 0xE74C3C },
    ['error.*'] = { channel = 'errors', level = 'error', color = 0xE74C3C },
}

--------------------------------------------------------------------------------
-- The JSON block
--------------------------------------------------------------------------------
Config.Json = {
    indent = 2,                    -- 0 renders the object on one line
    maxDepth = 4,                  -- deeper values render as "<truncated>"
    maxStringLength = 500,         -- per string value inside the object
    maxChars = 3000,               -- whole block; keeps room for the message

    --- When the object doesn't fit in maxChars, upload the whole thing as a
    --- payload.json attachment instead of only showing the truncated preview.
    --- These caps are much looser than the inline ones because the file has a
    --- 25MB budget, not a 4096-character one.
    attachOversized = true,
    attachMaxDepth = 8,
    attachMaxStringLength = 20000,
    attachMaxChars = 200000,
}

--------------------------------------------------------------------------------
-- Player data attached by logPlayer()
--------------------------------------------------------------------------------
Config.Player = {
    --- Identifier prefixes copied into the logged object under
    --- `player.identifiers`.
    identifiers = { 'license', 'discord', 'steam', 'fivem' },

    --- Endpoint (IP) is PII and is off by default.
    includeEndpoint = false,
}

--------------------------------------------------------------------------------
-- Delivery queue (per channel)
--------------------------------------------------------------------------------
Config.Queue = {
    flushIntervalMs = 1000,        -- how often a channel's worker looks for work
    maxEmbedsPerMessage = 10,      -- Discord's hard cap is 10
    minIntervalMs = 500,           -- floor between two sends to one channel
    maxQueueLength = 500,          -- past this, oldest entries are dropped
    maxRetries = 3,                -- for 429/5xx/transport failures
    retryBackoffMs = 1000,         -- doubled per attempt
    httpTimeoutMs = 15000,

    --- Ceiling on requests per second across every channel, staying under
    --- Discord's global 50/s. Per-channel buckets are read from the response
    --- headers and don't need configuring.
    globalMaxPerSecond = 45,

    --- Entries still queued when the resource stops are written here and
    --- re-queued on the next start, so a restart doesn't silently eat them.
    --- Set spoolFile to nil to turn that off.
    spoolFile = 'spool.json',
    maxSpoolEntries = 200,
}

--------------------------------------------------------------------------------
-- Built-in hooks
--------------------------------------------------------------------------------
--- Wire the framework's own handlers for these. Turn one off if another
--- resource already logs it.
Config.BuiltinEvents = {
    playerConnecting = true,
    playerJoining = true,
    playerDropped = true,
    chatMessage = false,
}

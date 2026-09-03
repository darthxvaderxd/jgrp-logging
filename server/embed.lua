--- Builds the Discord embed for one log entry: a message, and the JSON of the
--- object that came with it.
Embed = {}

--- Discord's documented limits. Exceeding any of them is a 400, so everything
--- built here is truncated to fit rather than sent and rejected.
Embed.LIMITS = {
    title = 256,
    description = 4096,
    footer = 2048,
    content = 2000,
    embedsPerMessage = 10,
}

local LIMITS = Embed.LIMITS

--- The ```json block rendered under the message, plus the attachment carrying
--- the full object when it didn't fit inline. Both nil when there's no object.
---
--- Two layers of escaping matter here and they are not the same thing:
--- fenceSafe stops a value closing the code fence and writing raw markdown
--- after it, sanitize stops mention syntax surviving into the message at all.
--- Neither applies to the attachment: it is a file, not markdown, and a
--- reader's whole reason for opening it is to see the object verbatim.
function Embed.jsonBlock(data)
    if data == nil then return nil, nil end

    local options = Config.Json or {}
    local inlineLimit = options.maxChars or 3000

    local encoded = Util.encodeJson(data, {
        indent = options.indent,
        maxDepth = options.maxDepth,
        maxStringLength = options.maxStringLength,
    })

    local attachment = nil
    local note = ''

    if #encoded > inlineLimit and options.attachOversized then
        local full = Util.encodeJson(data, {
            indent = options.indent,
            maxDepth = options.attachMaxDepth or 8,
            maxStringLength = options.attachMaxStringLength or 20000,
        })
        full = Util.truncate(full, options.attachMaxChars or 200000)
        attachment = { filename = 'payload.json', content = full }
        note = ('\n_Truncated above; the full object (%d characters) is attached as `payload.json`._')
            :format(#full)
    end

    encoded = Util.truncate(encoded, inlineLimit)
    encoded = Util.sanitize(Util.fenceSafe(encoded))

    return '```json\n' .. encoded .. '\n```' .. note, attachment
end

--- Build one embed.
--- @param spec table    merged presentation (title, color, footer, level, ...)
--- @param message string|nil  the human-readable line
--- @param data any|nil        the object logged alongside it
--- @return table|nil embed  nil when there is nothing to show
--- @return table|nil attachment  { filename, content } when the object was too
---         large to render inline
function Embed.build(spec, message, data)
    local embed = {}

    local title = spec.title
    if not Util.isBlank(title) then
        embed.title = Util.truncate(Util.sanitize(title), LIMITS.title)
    end

    local parts = {}
    if not Util.isBlank(message) then
        parts[#parts + 1] = Util.sanitize(Util.stringify(message))
    end

    local block, attachment = Embed.jsonBlock(data)
    if block then parts[#parts + 1] = block end

    if #parts > 0 then
        local description = table.concat(parts, '\n')
        if #description > LIMITS.description then
            -- Trim the message rather than the object: the object is the log
            -- record, the message is the label on it.
            local blockLength = block and (#block + 1) or 0
            local room = LIMITS.description - blockLength
            if #parts == 2 and room > 32 then
                parts[1] = Util.truncate(parts[1], room)
                description = table.concat(parts, '\n')
            end
            description = Util.truncate(description, LIMITS.description)
        end
        embed.description = description
    end

    embed.color = Util.color(spec.color)
    if spec.timestamp ~= false then embed.timestamp = Util.isoTimestamp() end

    if not Util.isBlank(spec.footer) then
        embed.footer = { text = Util.truncate(Util.sanitize(spec.footer), LIMITS.footer) }
    end

    if embed.title == nil and embed.description == nil then return nil, nil end
    return embed, attachment
end

--- allowed_mentions for a set of operator-authored mention strings, or nil when
--- the message contains no mention syntax at all.
---
--- Data-derived text never reaches this, so a player name containing
--- "@everyone" can't earn itself a ping.
---
--- Only non-empty lists are included, and nil is returned rather than an
--- all-empty object, because an empty Lua table has no unambiguous JSON
--- encoding — `{}` and `[]` are the same value, and Discord rejects
--- `allowed_mentions.parse` as an object. Omitting the key is safe here
--- precisely because `content` is built only from these same mention strings:
--- no mention syntax in, nothing for Discord to ping out. Embeds never ping
--- regardless.
function Embed.allowedMentions(mentions)
    local parse, users, roles = {}, {}, {}

    for _, mention in ipairs(mentions or {}) do
        if type(mention) == 'string' then
            if mention:find('@everyone', 1, true) or mention:find('@here', 1, true) then
                parse[#parse + 1] = 'everyone'
            end
            for roleId in mention:gmatch('<@&(%d+)>') do
                roles[#roles + 1] = roleId
            end
            for userId in mention:gmatch('<@!?(%d+)>') do
                users[#users + 1] = userId
            end
        end
    end

    if #parse == 0 and #users == 0 and #roles == 0 then return nil end

    local allowed = {}
    if #parse > 0 then allowed.parse = parse end
    if #users > 0 then allowed.users = users end
    if #roles > 0 then allowed.roles = roles end
    return allowed
end

--- The subset of a player's data worth putting in a log object.
function Embed.playerInfo(source)
    local playerId = tonumber(source)
    if not playerId or playerId <= 0 then return nil end

    local info = {
        id = playerId,
        name = GetPlayerName(playerId) or 'Unknown',
        identifiers = {},
    }

    local wanted = (Config.Player and Config.Player.identifiers) or {}
    for _, identifier in ipairs(GetPlayerIdentifiers(playerId) or {}) do
        for _, prefix in ipairs(wanted) do
            local value = identifier:match('^' .. prefix .. ':(.+)$')
            if value then info.identifiers[prefix] = value end
        end
    end

    if Config.Player and Config.Player.includeEndpoint then
        info.endpoint = GetPlayerEndpoint(playerId)
    end

    return info
end

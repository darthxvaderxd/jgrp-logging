--- Public surface: exports, built-in hooks and the console command. Everything
--- here funnels into Logger.log.
---
--- This resource registers no net event and ships no client script: a log line
--- is raised by server-side code only. A client has no way to name an activity,
--- write the message, or put anything into the object an admin reads as fact.

--------------------------------------------------------------------------------
-- Exports (other resources)
--------------------------------------------------------------------------------
-- exports['jgrp-logging']:log('admin.ban', 'Bob was banned', { reason = 'RDM' })
exports('log', function(activity, message, data, overrides)
    return Logger.log(activity, message, data, overrides)
end)

-- exports['jgrp-logging']:logPlayer(src, 'money.transfer', 'Paid Alice $500',
--                                   { amount = 500, target = 'Alice' })
exports('logPlayer', function(source, activity, message, data, overrides)
    return Logger.logPlayer(source, activity, message, data, overrides)
end)

exports('stats', function()
    return Queue.stats()
end)

--------------------------------------------------------------------------------
-- Server-side event (other resources, without a hard dependency on this one)
--------------------------------------------------------------------------------
--- Registered with AddEventHandler and deliberately NOT with RegisterNetEvent:
--- that is what keeps a client from triggering it.
AddEventHandler('jgrp-logging:server:log', function(activity, message, data, overrides)
    Logger.log(activity, message, data, overrides)
end)

--------------------------------------------------------------------------------
-- Built-in hooks
--------------------------------------------------------------------------------
local builtin = Config.BuiltinEvents or {}

if builtin.playerConnecting then
    AddEventHandler('playerConnecting', function(name)
        Logger.logPlayer(source, 'player.connecting', ('%s is connecting.'):format(name or 'Unknown'))
    end)
end

if builtin.playerJoining then
    AddEventHandler('playerJoining', function(oldId)
        Logger.logPlayer(source, 'player.joined',
            ('%s joined the server.'):format(GetPlayerName(source) or 'Unknown'),
            { previousId = oldId })
    end)
end

if builtin.playerDropped then
    AddEventHandler('playerDropped', function(reason)
        Logger.logPlayer(source, 'player.dropped',
            ('%s left the server.'):format(GetPlayerName(source) or 'Unknown'),
            { reason = reason })
    end)
end

if builtin.chatMessage then
    AddEventHandler('chatMessage', function(src, name, message)
        Logger.logPlayer(src, 'chat.message', message, { author = name })
    end)
end

--------------------------------------------------------------------------------
-- Config reload
--------------------------------------------------------------------------------

--- Re-read config/config.lua without restarting the resource.
---
--- The chunk is run only after it compiles, and the previous Config is put back
--- if it throws or produces something that isn't a config — otherwise a typo
--- halfway down the file would leave the resource running on a half-built
--- table, which is worse than not reloading at all.
local function reloadConfig()
    local source = LoadResourceFile(GetCurrentResourceName(), 'config/config.lua')
    if not source then return false, 'could not read config/config.lua' end

    local chunk, compileError = load(source, '@config/config.lua')
    if not chunk then return false, compileError end

    local previous = Config
    local ok, runError = pcall(chunk)

    if not ok then
        Config = previous
        return false, runError
    end

    if type(Config) ~= 'table' or type(Config.Channels) ~= 'table' or type(Config.Activities) ~= 'table' then
        Config = previous
        return false, 'the file ran but did not define Config.Channels and Config.Activities'
    end

    Logger.reset()
    Queue.reset()
    return true
end

--------------------------------------------------------------------------------
-- Spool wiring (see server/spool.lua)
--------------------------------------------------------------------------------
AddEventHandler('onResourceStop', function(resource)
    if resource == GetCurrentResourceName() then Spool.save() end
end)

CreateThread(Spool.restore)

--------------------------------------------------------------------------------
-- Console command
--------------------------------------------------------------------------------
--- Restricted: server console always, in-game only with the `command.jgrplog`
--- ace permission.
RegisterCommand('jgrplog', function(source, args)
    local sub = (args[1] or 'help'):lower()

    if sub == 'stats' then
        local paused = Queue.globalPauseRemaining()
        if paused > 0 then
            print(('[jgrp-logging] globally rate limited by Discord; every channel resumes in %.1fs')
                :format(paused / 1000))
        end
        for channel, stat in pairs(Queue.stats()) do
            print(('[jgrp-logging] %-14s pending=%d sent=%d failed=%d dropped=%d')
                :format(channel, stat.pending, stat.sent, stat.failed, stat.dropped))
        end
        return
    end

    if sub == 'reload' then
        local ok, err = reloadConfig()
        if ok then
            local channels, activities = 0, 0
            for _ in pairs(Config.Channels) do channels = channels + 1 end
            for _ in pairs(Config.Activities) do activities = activities + 1 end
            print(('[jgrp-logging] config reloaded: %d channels, %d activities')
                :format(channels, activities))
        else
            print(('[jgrp-logging] ^1config reload failed^7 (keeping the running config): %s')
                :format(tostring(err)))
        end
        return
    end

    if sub == 'test' then
        local activity = args[2] or 'error'
        local message = table.concat(args, ' ', math.min(3, #args + 1))
        local queued = Logger.log(activity,
            message ~= '' and message or 'Test log from the jgrplog console command.',
            { activity = activity, issuedBy = source == 0 and 'console' or source })
        print(('[jgrp-logging] test %s: %s'):format(activity,
            queued and 'queued' or 'not queued (see warnings above)'))
        return
    end

    print('[jgrp-logging] usage: jgrplog stats | jgrplog reload | jgrplog test <activity> [message]')
end, true)

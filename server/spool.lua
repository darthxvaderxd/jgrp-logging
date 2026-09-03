--- Entries still queued when the resource stops.
---
--- Delivery is asynchronous, and an in-flight HTTP callback cannot survive the
--- resource being torn down — so the only way not to lose queued entries is to
--- write them down and pick them up next start.
Spool = {}

local function spoolPath()
    return Config.Queue and Config.Queue.spoolFile
end

function Spool.save()
    local path = spoolPath()
    if not path then return end

    local pending = Queue.drain(Config.Queue.maxSpoolEntries or 200)
    if #pending == 0 then return end

    SaveResourceFile(GetCurrentResourceName(), path, json.encode(pending), -1)
    print(('[jgrp-logging] spooled %d undelivered entr%s to %s')
        :format(#pending, #pending == 1 and 'y' or 'ies', path))
end

function Spool.restore()
    local path = spoolPath()
    if not path then return end

    local contents = LoadResourceFile(GetCurrentResourceName(), path)
    if not contents or contents == '' then return end

    -- Clear the file first: a restore that crashes must not replay forever.
    SaveResourceFile(GetCurrentResourceName(), path, '', -1)

    local ok, entries = pcall(json.decode, contents)
    if not ok or type(entries) ~= 'table' then
        print('[jgrp-logging] ^3WARN^7 could not read the spool file; discarding it')
        return
    end

    local restored = 0
    for _, entry in ipairs(entries) do
        if type(entry) == 'table' and type(entry.embed) == 'table' then
            local queued = Logger.dispatch(entry.channel, {
                embed = entry.embed,
                mention = entry.mention,
                attachment = entry.attachment,
            }, 'a spooled entry')
            if queued then restored = restored + 1 end
        end
    end

    if restored > 0 then
        print(('[jgrp-logging] re-queued %d entr%s from the previous run')
            :format(restored, restored == 1 and 'y' or 'ies'))
    end
end

fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'jgrp-logging'
description 'Config-driven Discord activity logging framework for FiveM'
author 'Judgement RP'
version '0.1.0'

-- Server only, on purpose. config.lua names the bot-token convar and the
-- channel ids, so it must never be a shared_script — anything in shared_scripts
-- (or client_scripts) is downloaded by every connecting client. This resource
-- ships no client script at all: logging is a server-side concern, and a client
-- gets no way to ask for a log line.
server_scripts {
    'shared/util.lua',
    'config/config.lua',
    'server/http.lua',
    'server/embed.lua',
    'server/queue.lua',
    'server/logger.lua',
    'server/spool.lua',
    'server/api.lua',
}

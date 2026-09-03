# jgrp-logging

A small FiveM framework for logging server activity to Discord, where **which
activity goes to which channel is configuration, not code**.

A log entry is a **message and an object**:

```lua
exports['jgrp-logging']:log('admin.ban', 'Bob was banned by Admin', {
    target = 'Bob',
    reason = 'RDM',
    duration = '7d',
})
```

The message becomes the embed text; the object is rendered as a JSON block
underneath it. `config/config.lua` decides which Discord channel that lands in,
what colour it is, and whether it's logged at all.

```
config/config.lua   bot token convar, channel ids, activity -> channel map
shared/util.lua     JSON rendering, sanitization, truncation
server/http.lua     PerformHttpRequest wrapper, JSON and multipart
server/embed.lua    builds the embed (and its attachment) within Discord's limits
server/queue.lua    per-channel batching, pacing, rate limits, retry
server/logger.lua   resolution + filtering + dispatch (the one funnel)
server/spool.lua    saves undelivered entries across a restart
server/api.lua      exports, built-in hooks, console command
tests/spec.lua      test suite (see Tests)
```

Messages are posted by **your bot** (`POST /channels/{id}/messages`), so channels
are configured by id. One token, one secret, and no webhook management.

## Install

1. Drop the folder in your resources directory.
2. Invite your bot to the guild with **View Channel**, **Send Messages** and
   **Embed Links** on every channel you'll log to.
3. Turn on Developer Mode in Discord (Settings → Advanced), right-click each
   channel → **Copy Channel ID**, and put the ids in `Config.Channels`.
4. Put the token in `server.cfg`:

```cfg
set jgrp_discord_token "MTIzNDU2Nzg5MDEyMzQ1Njc4.Gh1jK2..."

ensure jgrp-logging
```

Use `set`, never `setr`/`sets` — those replicate the value to every connected
client, which would hand your bot token to anyone who joins.

5. Check it: `jgrplog test admin.ban hello` in the server console.

## Logging something

From another server-side resource:

```lua
-- log(activity, message, object)
exports['jgrp-logging']:log('vehicle.spawn', 'Adder spawned at the docks', {
    model = 'adder',
    plate = '55XYZ123',
})

-- Same, attributed to a player: id, name and identifiers are merged into the
-- object under `player`.
exports['jgrp-logging']:logPlayer(source, 'money.transfer', 'Bob paid Alice $500', {
    amount = 500,
    target = 'Alice',
    account = 'bank',
})
```

Renders as:

> **Money Transfer**
> Bob paid Alice $500
> ```json
> {
>   "account": "bank",
>   "amount": 500,
>   "player": {
>     "id": 3,
>     "identifiers": { "discord": "42", "license": "abc123" },
>     "name": "Bob"
>   },
>   "target": "Alice"
> }
> ```

Either argument can be omitted — a message with no object, or an object with no
message, both work.

Without an export dependency:

```lua
TriggerEvent('jgrp-logging:server:log', 'error', 'inventory desync', { player = src })
```

There is no client-side call. See [No client-side logging](#no-client-side-logging).

Every call returns `true` when the entry was queued, `false` when it was
filtered, unmapped, or the channel isn't usable.

## API reference

Everything returns to the caller immediately; delivery happens on a background
worker. **`true` means queued, not delivered** — a delivery failure shows up in
the server console and in `stats()`, not in the return value.

### Server

| Call | Returns |
| --- | --- |
| `exports['jgrp-logging']:log(activity, message, data, overrides)` | `boolean` — queued? |
| `exports['jgrp-logging']:logPlayer(source, activity, message, data, overrides)` | `boolean` — queued? |
| `exports['jgrp-logging']:stats()` | `{ [channel] = { pending, sent, dropped, failed } }` |
| `TriggerEvent('jgrp-logging:server:log', activity, message, data, overrides)` | — (no return; not a net event) |

| Argument | Type | Notes |
| --- | --- | --- |
| `activity` | `string`, required | Key into `Config.Activities`. Anything unmatched uses `Config.FallbackChannel`. |
| `message` | `string` or `nil` | The embed text. Sanitized before it's sent. |
| `data` | any or `nil` | Usually a table; rendered as the JSON block. Non-tables are encoded as-is. |
| `overrides` | `table` or `nil` | Per-call presentation. See below. |
| `source` | player id | `logPlayer` only. Its `player` block always wins over anything in `data`. |

`log` returns `false` when logging is disabled, the activity is below
`Config.MinLevel`, the entry is `enabled = false`, the activity is unmapped with
no fallback, the channel is unknown, or the token/channel id isn't usable.
A configuration cause (bad token, unknown channel, bad channel id) is warned
about once rather than once per call; a per-entry drop (below `MinLevel`,
unmapped with no fallback) is only visible with `Config.Debug = true`.

`overrides` accepts exactly the keys the merge chain uses — `channel`, `title`,
`color`, `level`, `mention`, `footer`, `timestamp`, `enabled`. Anything else is
ignored.

## Configuration

### Channels

```lua
Config.Channels = {
    admin = {
        id = '1234567890123456789',            -- quoted: an unquoted snowflake
        color = 0xE67E22,                      -- loses precision as a float
        mention = '<@&123456789012345678>',    -- optional, pinged on every entry
        minIntervalMs = 1500,                  -- optional per-channel queue tuning
    },
}
```

A channel whose id isn't a well-formed snowflake is skipped with a single
console warning, so a typo (or a channel you haven't filled in yet) degrades to
"this channel doesn't log" rather than firing bad requests at the API.

### Activity → channel

Keys are activity names. `money.*` matches anything starting with `money.`, the
longest matching prefix wins, an exact key beats every wildcard, and a bare `*`
is a catch-all. Anything unmatched goes to `Config.FallbackChannel` (set it to
`nil` to drop unmapped activities instead).

```lua
Config.Activities = {
    ['admin.ban']  = { channel = 'admin', title = 'Player Banned', level = 'warn', color = 0xC0392B },
    ['admin.*']    = { channel = 'admin', level = 'warn' },
    ['money.*']    = { channel = 'economy' },
    ['error.*']    = { channel = 'errors', level = 'error' },
}
```

An entry sets `channel`, and optionally `title` (defaults to the activity name),
`color`, `level`, `mention` and `enabled`. Presentation merges **defaults →
channel → activity → per-call overrides**, so a call site can override anything:

```lua
exports['jgrp-logging']:log('admin.ban', msg, obj, { channel = 'errors', color = '#FF0000' })
```

### Adding an activity

1. Pick a dotted name (`inventory.item.moved`). Nothing needs to declare it —
   an unmapped name already logs to `Config.FallbackChannel`.
2. Map it, if it belongs somewhere specific:
   `['inventory.*'] = { channel = 'economy' }`, or give it its own entry with a
   `title`, `color` and `level`.
3. Call it: `exports['jgrp-logging']:logPlayer(src, 'inventory.item.moved',
   ('%s moved %s'):format(name, item), { item = item, from = from, to = to })`.
4. `jgrplog reload` — no restart needed unless you changed
   `Config.BuiltinEvents`.

You can do 3 before 2. An activity with no mapping still logs, so instrument
first and sort the routing out once you can see what you're producing.

### Levels

`Config.MinLevel` filters by severity — `debug`, `info`, `warn`, `error`,
`critical`. Chat and connection spam sits at `debug`, so raising `MinLevel` to
`info` silences it without touching the mapping.

### The JSON block

`Config.Json` controls how the object renders: `indent` (0 puts it on one line),
`maxDepth`, `maxStringLength` per value, and `maxChars` for the whole block.
Keys are sorted, so the same object always renders the same way and two entries
diff cleanly by eye.

An object too big for `maxChars` isn't just cut off: the truncated preview stays
in the message and the **whole object is uploaded as `payload.json`**, under the
looser `attachMaxDepth` / `attachMaxStringLength` / `attachMaxChars` caps. So the
message stays readable and nothing is lost. Set `attachOversized = false` to go
back to truncating. An entry with an attachment is sent as its own message —
a file belongs to a message, not to an embed, so batching one in would associate
`payload.json` with whichever entries happened to share the request.

## No client-side logging

This resource ships **no client script and registers no net event**. Every log
line is raised by server-side code; a client has no way to ask for one.

That is a deliberate removal, not a gap. A client-triggered path existed and was
allowlisted, rate limited and payload-capped, and it still meant an
attacker-controlled machine chose the activity, wrote the message and filled the
object an admin then reads as fact — indistinguishable, once it's in Discord,
from a line the server wrote. Validating that text bounds the damage; it doesn't
change who authored it.

If a client-facing feature needs to produce a log line (a `/report` command, a
UI button), log it from the **server** handler that already receives the
interaction — that handler knows the real `source`, and `logPlayer` attributes
it:

```lua
RegisterNetEvent('myresource:report', function(text)
    -- validate `text` for your own feature's purposes, then:
    exports['jgrp-logging']:logPlayer(source, 'ui.report', 'Player report',
        { text = text })
end)
```

The log line then says what your resource decided to record, attributed to the
sender the server resolved — not what the client asked to have written.

`jgrp-logging:server:log` is registered with `AddEventHandler` and deliberately
*not* with `RegisterNetEvent`, so a client can't reach it either. Two tests in
`tests/spec.lua` guard this: one asserts no net event is registered, one asserts
the manifest declares no `client_scripts` or `shared_scripts`.

## What the framework guards against

- **Header injection through the token.** The token is interpolated into an
  `Authorization` header, so a value carrying CR/LF is refused rather than sent.
  Nothing ever prints the token, including in warnings.
- **Path injection through a channel id.** The id goes into the request path, so
  only a 17-20 digit snowflake is accepted — an id carrying `/` or `..` would
  address a different API endpoint entirely.
- **Mention injection.** Text from the message and from the object is sanitized,
  and the payload only ever grants ping permission for mentions you wrote in the
  config. A player named `@everyone` cannot ping your server.
- **Markdown escape from the JSON block.** A value containing ``` can't close
  the fence and write raw markdown after it.
- **Runaway objects.** The JSON encoder is depth-capped, cycle-safe and
  truncated per string and in total, so a cyclic or enormous object logs a
  bounded record instead of hanging or blowing the embed limit.
- **Discord's limits.** Titles, descriptions and footers are truncated to fit,
  and messages carry at most 10 embeds. When a message and object together
  exceed the limit the message is trimmed first — the object is the record, the
  message is the label on it.
- **Rate limits and outages.** Each channel has its own queue and worker, so a
  busy chat channel can't stall the errors channel. Per-channel buckets are read
  from the `x-ratelimit-remaining` / `-reset-after` response headers and waited
  out before the next send; a `global: true` 429 pauses *every* channel, and
  `globalMaxPerSecond` keeps the bot under Discord's global ceiling. 429s honour
  `retry_after`, 5xx and transport failures back off exponentially, 401/403 name
  the token or permission problem once instead of retrying forever, and a queue
  over `maxQueueLength` sheds its oldest entries rather than growing without
  bound.
- **Restarts.** Entries still queued when the resource stops are written to
  `spool.json` and re-queued on the next start — an in-flight HTTP callback
  can't survive teardown, so durability is the only real answer. The spool is
  capped at `maxSpoolEntries` (newest kept), cleared as soon as it's read so a
  bad entry can't replay forever, and an entry whose channel has since been
  removed from the config is dropped with a warning.

## Console

```
jgrplog stats                      queue depth / sent / failed / dropped per channel,
                                   and whether a global rate limit is holding everything
jgrplog reload                     re-read config/config.lua without a restart
jgrplog test <activity> [message]  send one entry through the whole pipeline
```

Restricted to the server console and to players with the `command.jgrplog` ace.

`reload` re-runs the config file and drops every cache derived from it (activity
resolution, channel queues). If the file doesn't compile,
throws halfway, or doesn't define `Config.Channels` and `Config.Activities`, the
running config is kept and the command says so — a typo can't leave the resource
on a half-built config.

## Troubleshooting

Configuration problems are warned about once rather than once per log call, so
the first place to look is the server console at resource start.

| Console says | Meaning |
| --- | --- |
| `convar '...' is not set` | No bot token. `set jgrp_discord_token "..."` in server.cfg, above `ensure jgrp-logging`. |
| `does not look like a bot token` | The convar holds something with characters a token can't contain — usually quotes or a stray newline from a paste. |
| `channel 'x' has no valid Discord channel id` | The id isn't a quoted 17-20 digit snowflake. Copy Channel ID, and keep the quotes — an unquoted one loses precision. |
| `maps to unknown channel "x"` | An activity (or a spooled entry) names a channel that isn't in `Config.Channels`. |
| `Discord refused the request (status 401/403)` | 401: the token is wrong. 403: the bot isn't in the guild, or lacks View Channel / Send Messages / Embed Links **on that channel**. |
| `Discord rejected N embed(s) with status 404` | The channel id is well-formed but doesn't exist, or the bot can't see it. |
| `globally rate limited by Discord` | Every channel is paused; `jgrplog stats` shows how long is left. |
| `queue full (N), dropped M entries` | Entries are arriving faster than they can be delivered. Raise `Config.MinLevel`, or move a chatty activity to its own channel so it isn't behind the others. |
| Nothing at all | The activity is below `Config.MinLevel`, or `Config.Enabled` is `false`. Set `Config.Debug = true` to see per-entry drop reasons. |

`jgrplog test <activity> [message]` sends one entry through the whole pipeline —
resolution, filtering, endpoint, queue — and prints whether it was queued. It's
the fastest way to tell a config problem from a call-site one.

## Tests

`tests/spec.lua` runs the real resource files against `tests/fivem_stubs.lua`,
which stands in for the FiveM natives (HTTP, threads, players, convars, events).
It covers JSON rendering, sanitization and escaping, activity resolution, token
and channel-id validation, embed building and truncation, queue batching and
retry, and the absence of any client-reachable entry point. Stdlib only — no
busted, no luarocks:

```sh
lua tests/spec.lua      # run from the resource root
```

## Known gaps

- `jgrplog reload` covers **config only**. The built-in event handlers are wired
  from `Config.BuiltinEvents` at resource start, so turning one on or off still
  needs `ensure jgrp-logging`.
- The spool has no expiry: entries from a server that has been down for a week
  are still delivered when it comes back. The embeds carry their original
  timestamps, so they arrive dated rather than misleading — but if you want a
  maximum age, that's a policy call worth making deliberately.
- Rate-limit buckets are *learned* from response headers, so the first request
  into a bucket can still take a 429. It's handled (honoured and retried), just
  not avoided.
- An object over `attachMaxChars` (200k by default) is still truncated inside
  the attachment. Discord's file limit is far higher; the cap is there to bound
  what one log line can cost, not because the API refuses more.

# Halo Race Leaderboard (HRL) - `hrl.lua`

A SAPP Lua script for Halo PC/CE dedicated
servers that tracks race lap times, submits them to the HRL web leaderboard,
and manages dynamic race-length policy. Single-file, table-based module
architecture.

## Requirements

- A SAPP Halo PC or Halo CE dedicated server.
- A `halo_http` native library providing `http_post`/`http_poll`/`http_free`/
  `http_active` (loaded via `ffi.load`).
- `json.lua` present alongside the haloded.exe or haloceded.exe (loaded via `loadfile`).

## Configuration

Top-of-file globals:

| Variable            | Purpose                                                                 |
|----------------------|-------------------------------------------------------------------------|
| `server_port`         | Fallback port reported to the API if memory auto-detection fails.      |
| `api_version`         | Reported API version string.                                           |
| `debug`               | `1` submits to the `dev` API and tags submissions `test = true`; also enables the `logtime` chat command. |
| `ping_ema_enabled`    | Toggles ping-spike (warp) detection between an EMA-smoothed baseline and the older raw-delta check. |

### Automatic port detection

The dedicated server's actual listening port is read directly out of process
memory at script load (`HRLApp:detect_server_port`), using a build-specific
static address (`CONSTANTS.SERVER_PORT_ADDR_PC` / `SERVER_PORT_ADDR_CE`,
selected by the `halo_type` global). Both addresses were located with
`scanmem` and cross-checked against a real port change before being trusted.

If the read fails or returns something outside `1-65535`, the script silently
falls back to the manual `server_port` value at the top of the file - so
that value should still be kept roughly in sync as a safety net.

## Features

- **Lap tracking** - checkpoint bitset decoding (supports AnyOrder gametypes),
  per-checkpoint split times, idempotent lap submission.
- **Duplicate-slot protection** - ignores a lap-in-progress on a second slot
  that shares the same `$hash`/`$name` as an already-tracked slot (handles
  brief disconnect/reconnect on maps with a client-side download handshake).
- **Warp / ping-spike detection** - flags a lap as invalid if a player warps
  or their ping spikes past a threshold (raw delta or EMA-based, see
  `ping_ema_enabled`).
- **Dynamic lap limits** - per-map profiles (`technical`, `medium`, `large`,
  `very_long`, `medium_long`, `default`) scale the score limit to the current
  player count. A separate **grind mode** (vote-activated via saying `grind`)
  overrides this with a long, fixed lap count for grinding sessions.
- **HRL query token** - publishes a rotating token (`hrl_token`/
  `hrl_token_prev`) via `query_add` so the web leaderboard can verify which
  server a submission came from.
- **HTTP submission** - lap times and player claims are POSTed to the HRL API
  asynchronously; responses are polled and matched back to the request every
  tick, with a wall-clock timeout for requests that never come back.

## Chat / server commands

Available both in chat and as server commands:

| Command              | Effect                                                     |
|-----------------------|-------------------------------------------------------------|
| `help` / `info`       | Shows a short help message and current lap-limit status.   |
| `grind`               | Casts a vote to start/stop grind mode (auto-approved solo). |
| `claimplayer`         | Currently disabled - replies with a fixed message.          |

## Module overview

| Module            | Responsibility                                                |
|--------------------|----------------------------------------------------------------|
| `LapLimitManager`  | Dynamic/grind score-limit policy.                              |
| `Encoding`         | Windows-1252 <-> UTF-8 conversion for player names.            |
| `HrlToken`         | Query-field token generation/rotation/cleanup.                 |
| `ApiClient`        | HTTP request bookkeeping, polling, timeout, response dispatch. |
| `PlayerState`      | Per-player lap/warp/checkpoint state.                          |
| `LapTracker`       | Checkpoint reading, split recording, lap finish/submission.    |
| `PingChecker`      | Ping-spike (warp) detection.                                   |
| `HRLApp`           | Top-level lifecycle and SAPP callback wiring.                  |

## Known limitations

- Rally gametypes (`race_type == 2`) are intentionally not tracked - there's
  no reliable completion trigger, so tracking would start but never resolve.
- `server_port` auto-detection addresses are tied to specific server builds;
  a future patched build may require re-locating them via `scanmem`.

## Credits

Dynamic lap-limit logic adapted from `dynamic_race_laps.lua` by Jericho
Crosby (Chalwk), MIT licensed -
https://github.com/Chalwk/HALO-SCRIPT-PROJECTS

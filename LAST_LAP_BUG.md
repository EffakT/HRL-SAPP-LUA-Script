# Last lap of a map not being recorded

**Status:** diagnosed, not fixed.

## Symptom

The final lap of a map/game (the one that ends the race) does not get submitted to the leaderboard, even though earlier laps in the same session record fine.

## Likely cause

A race condition between `OnGameEnd()` and `OnPlayerScore()`.

- `OnGameEnd()` unconditionally calls `resetPlayerData(i)` for **every player** the instant the game ends. This wipes `player_checkpoints[i].started`, `.started_time`, and `.checkpoints`.
- `OnPlayerScore(playerIndex)` - the handler that actually calls `logTime()` - starts with:
  ```lua
  if not player_checkpoints[playerIndex].started then
      return
  end
  ```
- The lap that *wins the race* (hits the score/fraglimit) is exactly the lap whose `EVENT_SCORE` is most likely to fire at essentially the same moment as `EVENT_GAME_END`. If `OnGameEnd`'s reset runs first - or `OnPlayerScore` for that final score is processed after the reset - the guard above sees `started == false` and silently returns. No `logTime()`, no HTTP submission, no in-game confirmation message.

Supporting detail: `EVENT_SCORE` is registered in `CheckMapAndGametype()` and is never unregistered in `OnGameEnd()`, so nothing prevents `OnPlayerScore` from still firing (and hitting the just-reset state) right as/after the game ends.

This explains why it's specifically the *last* lap that's affected, rather than lap-logging being unreliable in general - it's the one lap that structurally coincides with the game-end reset, not a general race/timing bug in the checkpoint tracking itself.

## Not investigated / not fixed

- Exact firing order of `EVENT_SCORE` vs `EVENT_GAME_END` in the underlying SAPP/Halo engine (would need to confirm empirically or in SAPP's docs).
- Whether the fix should be "finalize/flush any in-progress score before resetting" in `OnGameEnd`, "defer the reset by a tick," or something else - deliberately not designed here per request.

-- API Requests run through http instead of https due to dependency issue
server_port = "2302" -- update this with your port. If port is invalid, your server will not be included.

api_version = "1.11.0.0"

debug = 0

current_map = nil
race = false
mode = 0
player_warps = {}
game_started = false
allow_warps = false
player_ping = {}
last_ping_check = 0
ping_threshold = 100
player_ping_stability = {}

-- HRL query verification. hrl.effakt.info's webhook cross-checks every lap submission against
-- a live UDP \query response from this same server, requiring these hrl_* fields alongside the
-- standard query fields, plus the matching hrl_token in the HTTP submission body. Not a durable
-- secret (query responses are publicly readable by anyone who queries the server) - just binds
-- "this HTTP submission" to "this server is actually running an HRL-aware script right now," so
-- hrl_token only needs to be unpredictable and rotated, not cryptographically secret.
local HRL_PROTOCOL = "1"
local HRL_TOKEN_ROTATE_INTERVAL_SECONDS = 300
local hrl_token = nil
local hrl_token_prev = nil
local hrl_token_last_rotated = 0

ffi = require("ffi")

ffi.cdef[[
    void http_post(uint32_t id, const char* url, const char* body);
    char* http_poll(uint32_t* out_id);
    void http_free(char* ptr);
    bool http_active();
]]

local http_client = ffi.load("halo_http")

-- Load json library
local json_file = loadfile("json.lua")
if not json_file then
    error("Failed to load json.lua - check file path")
end
local json = json_file()

-- Constants
local GAMETYPE_BASE_PC = 0x671340
local GAMETYPE_BASE_CE = 0x5F5498
local GAMETYPE_MODE_OFFSET_PC = 0x7C - 32
local GAMETYPE_MODE_OFFSET_CE = 0x7C
local PLAYER_VEHICLE_OFFSET = 0x11C
local VEHICLE_DRIVER_OFFSET = 0x324
local PLAYER_TIME_OFFSET = 0xC4
local INVALID_OBJECT_ID = 0xFFFFFFFF
local MAX_PLAYERS = 16
local PING_CHECK_INTERVAL = 30
local RACE_GLOBALS_OFFSET = 0x44  -- Checkpoint tracking offset


local race_globals

local active_requests = {}  -- player_index -> start_time
local REQUEST_TIMEOUT_TICKS = 5 * 30   -- Seconds before considering a request stuck

-- Player checkpoint tracking
local player_checkpoints = {}
for i = 1, MAX_PLAYERS do
    player_checkpoints[i] = {
        current = 0,
        previous = 0,
        started = false,
        start_checkpoint = 0,
        started_time = nil,
        checkpoints = {}
    }
end

-- API URLs
local API_URLS = {
    dev = {
        -- newtime = "http://dev.haloraceleaderboard.effakt.info/api/newtime",
        -- claimplayer = "http://dev.haloraceleaderboard.effakt.info/api/claimplayer"
        newtime = "https://redesign.hrl.effakt.info/api/v1/laps",
        claimplayer = "https://redesign.hrl.effakt.info/api/v1/claimplayer"
    },
    prod = {
        newtime = "https://redesign.hrl.effakt.info/api/v1/laps",
        claimplayer = "https://redesign.hrl.effakt.info/api/v1/claimplayer"
    }
}

local function get_time()
    return tonumber(get_var(1, "$ticks")) / 30
end

-- A short, unpredictable-enough token; freshness/rotation is what matters here, not cryptographic
-- strength (see the block comment above where these are declared).
local function random_hex(length)
    local chars = "0123456789abcdef"
    local out = {}
    for i = 1, length do
        local idx = math.random(1, #chars)
        out[i] = chars:sub(idx, idx)
    end
    return table.concat(out)
end

-- Publishes the current hrl_* fields via SAPP's query_add console command (run through
-- execute_command, same as every other console-command invocation from Lua) so the webhook's
-- live UDP \query cross-check can read them. hrl_token_prev is always published too - an
-- empty string when there isn't one yet - so a submission racing a rotation boundary against
-- the *previous* token still verifies (LapSubmissionVerifier accepts either).
local function PublishHrlQueryFields()
    execute_command("query_add hrl_enabled 1")
    execute_command("query_add hrl_protocol " .. HRL_PROTOCOL)
    execute_command("query_add hrl_token " .. hrl_token)
    execute_command("query_add hrl_token_prev " .. (hrl_token_prev or ""))
end

function RotateHrlToken()
    hrl_token_prev = hrl_token
    hrl_token = random_hex(32)
    -- os.time() (wall clock), not get_time() ($ticks/30) $ticks are match-relative
    -- (resets on every map/game transition), which would make `now - hrl_token_last_rotated`
    -- go negative across a map change and stall rotation indefinitely. os.time() is monotonic 
    -- cross map transitions (already used for the initial math.randomseed()), so this survives
    -- them correctly.
    hrl_token_last_rotated = os.time()
    PublishHrlQueryFields()
end

-- Fresh per submission - this script doesn't itself retry a timed-out request (see
-- pollHttpResponses's timeout handling, which just logs and drops it), so there's no need for
-- submission_id to stay stable across attempts; it only needs to uniquely identify one actual
-- HTTP POST for the webhook's idempotency guard.
local function GenerateSubmissionId(playerIndex)
    return string.format("%d-%d-%d", math.floor(get_time() * 1000), playerIndex, math.random(100000, 999999999))
end


function SendTime(URL, json, player_index)
    --http_client.http_post_with_player(URL, json, player_index or -1)
active_requests[player_index] = {
        start_time = get_time(),
        request_type = "newtime"
    }  
      http_client.http_post(player_index, URL, json)
end

function SendClaim(URL, json, player_index)
active_requests[player_index] = {
        start_time = get_time(),
        request_type = "claimplayer"
    }
        http_client.http_post(player_index, URL, json)
end

function poll_http()
    local id_buf = ffi.new("uint32_t[1]")
    local ptr = http_client.http_poll(id_buf)

    --print("polling for response")

    if ptr ~= nil then
        local body = ffi.string(ptr)
        http_client.http_free(ptr)
        
        local escaped = body:gsub("\n", "\\n"):gsub("\r", "\\r")
        -- print("DEBUG: id=" .. id_buf[0] .. " body=[" .. escaped .. "]")

        return id_buf[0], body
    end

    return nil
end

local gametype_base = (halo_type == "PC") and GAMETYPE_BASE_PC or GAMETYPE_BASE_CE


function OnScriptLoad()
    -- local found_offset = find_ip_offset(known_ip)
    -- TODO: Find this offset
    --local server_ip = read_string(0x0063EE28)
    --server_ip = get_var(0, "$ip")
    
    --server_ip = os.getenv("SERVER_IP") or "localhost"
    --print("Server IP: " .. server_ip)
    
    race_globals = read_dword(sig_scan("BF??????00F3ABB952000000") + 0x1)
 

    register_callback(cb['EVENT_COMMAND'], "OnServerCommand")
    register_callback(cb['EVENT_GAME_START'], "OnGameStart")
    register_callback(cb['EVENT_GAME_END'], "OnGameEnd")
    register_callback(cb['EVENT_JOIN'], "OnPlayerJoin")
    register_callback(cb['EVENT_LEAVE'], 'OnPlayerQuit')
    register_callback(cb['EVENT_WARP'], "OnWarp")
    register_callback(cb['EVENT_TICK'], "OnTick")

    CheckMapAndGametype(true)

    for i = 1, MAX_PLAYERS do
        player_warps[i] = 0
        player_ping[i] = 0
        player_ping_stability[i] = {}
    end

    -- Seed once per script load, then rotate on a timer (OnTick).
    math.randomseed(os.time())
    RotateHrlToken()

    print("HRL Loaded")
end

local function tokenizestring(inputstr, sep)
    sep = sep or "%s"
    local t = {}
    local i = 1
    for str in string.gmatch(inputstr, "([^" .. sep .. "]+)") do
        t[i] = str
        i = i + 1
    end
    return t
end

function OnServerCommand(playerIndex, Command)
    local t = tokenizestring(Command)
    local cmd = t[1]
    
    if cmd == "claimplayer" then
        claimPlayer(playerIndex, t[2])
        return false
    elseif debug == 1 and cmd == "logtime" then
        logTime(1, t[2])
        return false
    end
end

function OnPlayerScore(playerIndex)
    if not player_checkpoints[playerIndex].started then
        return
    end

    --print(string.format("DEBUG: SCORE EVENT player %d", playerIndex))
    player_ping_stability[playerIndex] = {}

    local player_address = get_dynamic_player(playerIndex)
    local vehicle_objectid = read_dword(player_address + PLAYER_VEHICLE_OFFSET)
    local is_driver = true
    local current_time = get_time()
    
    if tonumber(vehicle_objectid) ~= INVALID_OBJECT_ID then
        --print(string.format("DEBUG: Player %d in vehicle %s", playerIndex, vehicle_objectid))
        local vehicle = get_object_memory(tonumber(vehicle_objectid))
        local driver = get_object_memory(read_dword(vehicle + VEHICLE_DRIVER_OFFSET))
        is_driver = (driver == player_address)
    end
    
    --print(string.format("DEBUG: Player %d is_driver=%s, warps=%d", 
    --    playerIndex, tostring(is_driver), player_warps[playerIndex]))
    
    if is_driver and player_warps[playerIndex] == 0 then
        --print(string.format("DEBUG: Player %d LOGGING TIME", playerIndex))
        
        -- Finalize any remaining checkpoints before logging the time
        local checkpoint_data = player_checkpoints[playerIndex]
        if checkpoint_data and checkpoint_data.checkpoints then
            local last_cp = checkpoint_data.checkpoints[#checkpoint_data.checkpoints]
            if last_cp and last_cp.end_time == nil then
                last_cp.end_time = current_time
                -- Display final split if it's not checkpoint 0
                if last_cp.checkpoint_id ~= 0 then
                    local split_duration = last_cp.end_time - last_cp.start
                    say(playerIndex, string.format("CP %d->Finish - Split: %.2f sec", last_cp.checkpoint_id, split_duration))
                end
            end
        end
        
        local player = get_player(playerIndex)
        -- local best_time = read_word(player + PLAYER_TIME_OFFSET) / 30
        -- local best_time = current_time - player_checkpoints[playerIndex].started_time
        local start_time = player_checkpoints[playerIndex].started_time
        if not start_time then
            return
        end
        local best_time = current_time - start_time

        logTime(playerIndex, best_time)
    elseif player_warps[playerIndex] == 1 then
        --print(string.format("DEBUG: Player %d has warps, rejecting", playerIndex))
        say(playerIndex, "We detected a warp or a lag spike, your lap time was not recorded")
    end



    player_warps[playerIndex] = 0
end

function claimPlayer(playerIndex, claim_code)
    local player_hash = get_var(playerIndex, "$hash")
    
    local data = {
        player_hash = player_hash,
        code = claim_code
    }
    
    if debug == 1 then
        data.test = true
    end
    
    local json_str = json:encode(data)
    --print(json_str)
    
    local api_env = debug == 1 and "dev" or "prod"
    say(playerIndex, "Your player claim request has been submitted.")
    SendClaim(API_URLS[api_env].claimplayer, json_str, playerIndex)
end

function logTime(playerIndex, best_time)
    local player_hash = get_var(playerIndex, "$hash")
    local current_name = string.toutf8(get_var(playerIndex, "$name"))
    local is_debug = debug == 1
    
    local data = {
        port = server_port,
        player_hash = player_hash,
        player_name = current_name,
        map_name = current_map,
        map_label = "",
        race_type = mode,
        player_time = best_time,
        -- Must match the hrl_token this same server is currently publishing via query_add, and
        -- submission_id is this exact HTTP POST's idempotency key.
        hrl_token = hrl_token,
        submission_id = GenerateSubmissionId(playerIndex)
    }

    -- Attach splits if available
    local cp_data = player_checkpoints[playerIndex] and player_checkpoints[playerIndex].checkpoints
    if cp_data and #cp_data > 0 then
        local splits = {}
        for _, entry in ipairs(cp_data) do
            if entry and entry.checkpoint_id and entry.checkpoint_id ~= 0 and entry.start and entry.end_time then
                table.insert(splits, {
                    checkpoint_id = entry.checkpoint_id,
                    startTime = entry.start,
                    endTime = entry.end_time,
                    duration = entry.end_time - entry.start
                })
            end
        end
        if #splits > 0 then
            data.splits = splits
        end
    end
    
    if is_debug then
        data.test = "true"
    end
    
    local json_str = json:encode(data)
    print(json_str)
    
    local api_env = is_debug and "dev" or "prod"
    --if is_debug then
        say(playerIndex, "Your time of " .. best_time .. " has been recorded.")
    --end

    SendTime(API_URLS[api_env].newtime, json_str, playerIndex)
end

function OnWarp(PlayerIndex)
    if not allow_warps then
        player_warps[PlayerIndex] = 1
        say(PlayerIndex, "We just detected a warp. This lap will not count")
    end
end

function OnPlayerJoin(playerIndex)
    if not race then
        CheckMapAndGametype(false)
    end

    -- Initialize player data
    resetPlayerData(playerIndex)

    player_ping[playerIndex] = tonumber(GetPlayerPing(playerIndex))

    say(playerIndex, "This server runs Halo Race Leaderboard.")
    say(playerIndex, "For more information, or to see the leaderboard, go to hrl.effakt.info")
end

function resetPlayerData(playerIndex)
    player_warps[playerIndex] = 0
    player_ping[playerIndex] = 0
    player_ping_stability[playerIndex] = {}
    player_checkpoints[playerIndex] = {
        current = 0,
        previous = 0,
        started = false,
        start_checkpoint = 0,
        started_time = nil,
        checkpoints = {}
    }
end

function OnPlayerQuit(playerIndex)
    resetPlayerData(playerIndex)
    print(string.format("Player %d quit, reset their data", playerIndex))
end

function CheckMapAndGametype(NewGame)
    if get_var(1, "$gt") == "race" then
        if not NewGame and race then
            return false
        end
        
        current_map = get_var(1, "$map")
        race = true
        register_callback(cb['EVENT_SCORE'], "OnPlayerScore")

        safe_read(true)
        local offset = (halo_type == "PC") and GAMETYPE_MODE_OFFSET_PC or GAMETYPE_MODE_OFFSET_CE
        mode = read_byte(gametype_base + offset)
        safe_read(false)
    else
        race = false
        unregister_callback(cb['EVENT_SCORE'])
    end
end

function OnGameStart()
    CheckMapAndGametype(true)

    for i = 1, MAX_PLAYERS do
        resetPlayerData(i)
        player_ping[i] = tonumber(GetPlayerPing(i))
    end
end

function OnGameEnd()
    for i = 1, MAX_PLAYERS do
        resetPlayerData(i)
    end
    if not race or mode == 2 then
        return false
    end
end

function OnScriptUnload()
    execute_command("query_del hrl_enabled")
    execute_command("query_del hrl_protocol")
    execute_command("query_del hrl_token")
    execute_command("query_del hrl_token_prev")
end

function OnTick()
    local now = get_time()
    if not allow_warps then
        CheckPings()
    end

    if next(active_requests) ~= nil then
        pollHttpResponses()
    end

    -- Periodic token rotation, not tied to any game event. Compared against os.time() (wall clock), matching what RotateHrlToken() now stores
    if os.time() - hrl_token_last_rotated >= HRL_TOKEN_ROTATE_INTERVAL_SECONDS then
        RotateHrlToken()
    end

    TrackCheckpoints(now)
end

function pollHttpResponses()
    local now = get_time()
    local responses_processed = 0
    
    -- Check for timed out requests first
    for player_idx, request_info in pairs(active_requests) do
        if now - request_info.start_time > (REQUEST_TIMEOUT_TICKS / 30) then
            print(string.format("%s request for player %d timed out after %.1f seconds", 
                  request_info.request_type, player_idx, (REQUEST_TIMEOUT_TICKS / 30)))
            active_requests[player_idx] = nil
        end
    end
    
    -- Process any available responses
    while true do
        local player_index, response_body = poll_http()
        if not player_index then break end
        
        responses_processed = responses_processed + 1
        
        -- Get request info before removing
        local request_info = active_requests[player_index]
        active_requests[player_index] = nil
        
        if not request_info then
            print(string.format("Received response for player %d but no active request found", player_index))
            print("Response body: " .. response_body)
            goto continue
        end

        print(response_body)
        
        -- Parse the JSON response using json:decode()
        local success, response = pcall(function()
            return json:decode(response_body)
        end)
        
        if not success then
            print(string.format("Failed to parse %s response for player %d: %s", 
                  request_info.request_type, player_index, response_body))
            say(player_index, "Error processing server response")
            goto continue
        end
        
        -- Handle based on request type
        if request_info.request_type == "newtime" then
           -- Normalize response shapes: accept [obj], { data = obj } or direct obj
            local resp = response
            if type(resp) == "table" and #resp > 0 and resp[1] then
                resp = resp[1]
            end
            local payload = resp
            if type(resp) == "table" and resp.data then
                payload = resp.data
            end

            local ok = (type(resp) == "table" and resp.success) or (type(payload) == "table" and payload.success)

            if ok then
                local message = (type(resp) == "table" and resp.message) or (type(payload) == "table" and payload.message)
                if message then
                    say(player_index, message)
                else
                    say(player_index, "Time recorded successfully!")
                end

                -- leaderboardPosition may be nested in payload
                local lb = (type(payload) == "table" and payload.leaderboardPosition) or resp.position or payload.position
                if type(lb) == "table" and lb.position then
                    if lb.position == 1 then
                        local player_name = string.toutf8(get_var(player_index, "$name"))
                        local time_val = lb.top_time or "?"
                        say_all(player_name .. " set a new lap record: " .. time_val .. " seconds!")
                        -- say(player_index, "New lap time record set!")
                    else
                        local diff_str = tostring(lb.difference or "?")
                        say(player_index, string.format("Leaderboard position: #%d (%.2f sec behind #1)", lb.position, tonumber(lb.difference) or 0))
                    end
                elseif type(lb) == "number" then
                    say(player_index, "Leaderboard position: #" .. lb)
                end
            else
                local error_msg = (type(resp) == "table" and (resp.error or resp.message)) or (type(payload) == "table" and (payload.error or payload.message)) or "Unknown error"
                say(player_index, "Failed to record time: " .. error_msg)
            end
            
        elseif request_info.request_type == "claimplayer" then
            if response.success then
                say(player_index, response.message or "Player claimed successfully! You can now view your stats online.")
            else
                local error_msg = response.error or response.message or "Unknown error"
                say(player_index, "Claim failed: " .. error_msg)
            end
        end
        
        ::continue::
    end
    
    -- Log if we processed any responses
    if responses_processed > 0 then
        local active_count = 0
        for _ in pairs(active_requests) do active_count = active_count + 1 end
        print(string.format("Processed %d responses, %d requests still pending", 
              responses_processed, active_count))
    end
end



-- Normalize checkpoint IDs from game format (0,1,3,7,15,31,...) to sequential (0,1,2,3,4,5,...)
local function NormalizeCheckpointId(raw_id)
    if raw_id == 0 then return 0 end
    -- Game uses pattern: 2^n - 1, so normalize by: log2(raw_id + 1)
    local normalized = 0
    local temp = raw_id + 1
    while temp > 1 do
        temp = math.floor(temp / 2)
        normalized = normalized + 1
    end
    return normalized
end

local function GetCurrentCheckpoint(playerIndex)
    if not player_present(playerIndex) then return 0 end
    if race_globals == 0 then
        safe_read(false)
        --print("DEBUG: race_globals is 0 for player " .. playerIndex)
        return 0
    end

    local checkpoint_address = race_globals + to_real_index(playerIndex) * 4 + 0x44
    local checkpoint_id = read_dword(checkpoint_address)

    -- print(string.format("DEBUG: Player %d checkpoint address: 0x%X, id: %d", playerIndex, checkpoint_address, checkpoint_id))
    
    local cp = tonumber(checkpoint_id) or 0
    if cp > 0 then
        -- print(string.format("DEBUG: Player %d checkpoint: %d", playerIndex, cp))
    end
    -- Normalize checkpoint ID to sequential numbering
    return NormalizeCheckpointId(cp)
end

function TrackCheckpoints(now)
    local player_present_loc = player_present
    local get_cp = GetCurrentCheckpoint
    local pcs = player_checkpoints
    local say_loc = say
    local fmt = string.format

    for i = 1, MAX_PLAYERS do
        if player_present_loc(i) then
            local current_cp = get_cp(i)
            local checkpoint = pcs[i]

            checkpoint.previous = checkpoint.current
            checkpoint.current = current_cp

            -- Reset if at checkpoint 0 (not on track) - finish lap
            if current_cp == 0 and checkpoint.started then
                -- finalize previous checkpoint's end_time if missing
                local last_cp = checkpoint.checkpoints[#checkpoint.checkpoints]
                if last_cp and last_cp.end_time == nil then
                    last_cp.end_time = now
                    local split_duration = last_cp.end_time - last_cp.start
                    if last_cp.checkpoint_id ~= 0 then
                        say_loc(i, fmt("CP %d->0 - Split: %.2f sec", last_cp.checkpoint_id, split_duration))
                    end
                end
                checkpoint.started = false
                checkpoint.start_checkpoint = 0
            end

            -- Start lap on first checkpoint
            if current_cp >= 1 and not checkpoint.started then
                checkpoint.started = true
                checkpoint.start_checkpoint = current_cp
                checkpoint.started_time = now
                checkpoint.checkpoints = {
                    {
                        checkpoint_id = 0,
                        start = now,
                        end_time = nil
                    }
                }
            end

            -- Record split time if checkpoint advanced
            if checkpoint.started and current_cp > 0 and current_cp ~= checkpoint.previous then
                -- Update previous checkpoint's end_time
                local last_cp_data = checkpoint.checkpoints[#checkpoint.checkpoints]
                if last_cp_data then
                    last_cp_data.end_time = now
                    local split_duration = now - last_cp_data.start
                    -- Display split to player (skip logging 0->1 transitions)
                    if last_cp_data.checkpoint_id ~= 0 then
                        say(i, fmt("CP %d->%d - Split: %.2f sec", last_cp_data.checkpoint_id, current_cp, split_duration))
                    end
                end

                -- Add new checkpoint
                table.insert(checkpoint.checkpoints, {
                    checkpoint_id = current_cp,
                    start = now,
                    end_time = nil
                })
            end
        end
    end
end

function CheckPings()
    local current_ticks = get_var(1, "$ticks")
    
    if (current_ticks - last_ping_check) < PING_CHECK_INTERVAL then
        return
    end

    for i = 1, MAX_PLAYERS do
        if player_present(i) then
            local ping = tonumber(GetPlayerPing(i))
            local prev_ping = player_ping[i]

            if prev_ping and prev_ping > 0 and (ping - prev_ping) > ping_threshold then
                player_warps[i] = 1
                say(i, "We just detected a ping spike. This lap will not count")
            end

            player_ping[i] = ping
        end
    end

    last_ping_check = current_ticks
end

function GetPlayerPing(PlayerIndex)
    if (player_present(PlayerIndex)) then
        return get_var(PlayerIndex, "$ping")
    else
        return 0
    end
end

local char, byte, pairs, floor = string.char, string.byte, pairs, math.floor
local table_insert, table_concat = table.insert, table.concat
local unpack = table.unpack or unpack

local function unicode_to_utf8(code)
    -- converts numeric UTF code (U+code) to UTF-8 string
    local t, h = {}, 128
    while code >= h do
        t[#t + 1] = 128 + code % 64
        code = floor(code / 64)
        h = h > 32 and 32 or h / 2
    end
    t[#t + 1] = 256 - 2 * h + code
    return char(unpack(t)):reverse()
end

local function utf8_to_unicode(utf8str, pos)
    -- pos = starting byte position inside input string (default 1)
    pos = pos or 1
    local code, size = utf8str:byte(pos), 1
    if code >= 0xC0 and code < 0xFE then
        local mask = 64
        code = code - 128
        repeat
            local next_byte = utf8str:byte(pos + size) or 0
            if next_byte >= 0x80 and next_byte < 0xC0 then
                code, size = (code - mask - 2) * 64 + next_byte, size + 1
            else
                code, size = utf8str:byte(pos), 1
            end
            mask = mask * 32
        until code < mask
    end
    -- returns code, number of bytes in this utf8 char
    return code, size
end

local map_1252_to_unicode = {
    [0x80] = 0x20AC,
    [0x81] = 0x81,
    [0x82] = 0x201A,
    [0x83] = 0x0192,
    [0x84] = 0x201E,
    [0x85] = 0x2026,
    [0x86] = 0x2020,
    [0x87] = 0x2021,
    [0x88] = 0x02C6,
    [0x89] = 0x2030,
    [0x8A] = 0x0160,
    [0x8B] = 0x2039,
    [0x8C] = 0x0152,
    [0x8D] = 0x8D,
    [0x8E] = 0x017D,
    [0x8F] = 0x8F,
    [0x90] = 0x90,
    [0x91] = 0x2018,
    [0x92] = 0x2019,
    [0x93] = 0x201C,
    [0x94] = 0x201D,
    [0x95] = 0x2022,
    [0x96] = 0x2013,
    [0x97] = 0x2014,
    [0x98] = 0x02DC,
    [0x99] = 0x2122,
    [0x9A] = 0x0161,
    [0x9B] = 0x203A,
    [0x9C] = 0x0153,
    [0x9D] = 0x9D,
    [0x9E] = 0x017E,
    [0x9F] = 0x0178,
    [0xA0] = 0x00A0,
    [0xA1] = 0x00A1,
    [0xA2] = 0x00A2,
    [0xA3] = 0x00A3,
    [0xA4] = 0x00A4,
    [0xA5] = 0x00A5,
    [0xA6] = 0x00A6,
    [0xA7] = 0x00A7,
    [0xA8] = 0x00A8,
    [0xA9] = 0x00A9,
    [0xAA] = 0x00AA,
    [0xAB] = 0x00AB,
    [0xAC] = 0x00AC,
    [0xAD] = 0x00AD,
    [0xAE] = 0x00AE,
    [0xAF] = 0x00AF,
    [0xB0] = 0x00B0,
    [0xB1] = 0x00B1,
    [0xB2] = 0x00B2,
    [0xB3] = 0x00B3,
    [0xB4] = 0x00B4,
    [0xB5] = 0x00B5,
    [0xB6] = 0x00B6,
    [0xB7] = 0x00B7,
    [0xB8] = 0x00B8,
    [0xB9] = 0x00B9,
    [0xBA] = 0x00BA,
    [0xBB] = 0x00BB,
    [0xBC] = 0x00BC,
    [0xBD] = 0x00BD,
    [0xBE] = 0x00BE,
    [0xBF] = 0x00BF,
    [0xC0] = 0x00C0,
    [0xC1] = 0x00C1,
    [0xC2] = 0x00C2,
    [0xC3] = 0x00C3,
    [0xC4] = 0x00C4,
    [0xC5] = 0x00C5,
    [0xC6] = 0x00C6,
    [0xC7] = 0x00C7,
    [0xC8] = 0x00C8,
    [0xC9] = 0x00C9,
    [0xCA] = 0x00CA,
    [0xCB] = 0x00CB,
    [0xCC] = 0x00CC,
    [0xCD] = 0x00CD,
    [0xCE] = 0x00CE,
    [0xCF] = 0x00CF,
    [0xD0] = 0x00D0,
    [0xD1] = 0x00D1,
    [0xD2] = 0x00D2,
    [0xD3] = 0x00D3,
    [0xD4] = 0x00D4,
    [0xD5] = 0x00D5,
    [0xD6] = 0x00D6,
    [0xD7] = 0x00D7,
    [0xD8] = 0x00D8,
    [0xD9] = 0x00D9,
    [0xDA] = 0x00DA,
    [0xDB] = 0x00DB,
    [0xDC] = 0x00DC,
    [0xDD] = 0x00DD,
    [0xDE] = 0x00DE,
    [0xDF] = 0x00DF,
    [0xE0] = 0x00E0,
    [0xE1] = 0x00E1,
    [0xE2] = 0x00E2,
    [0xE3] = 0x00E3,
    [0xE4] = 0x00E4,
    [0xE5] = 0x00E5,
    [0xE6] = 0x00E6,
    [0xE7] = 0x00E7,
    [0xE8] = 0x00E8,
    [0xE9] = 0x00E9,
    [0xEA] = 0x00EA,
    [0xEB] = 0x00EB,
    [0xEC] = 0x00EC,
    [0xED] = 0x00ED,
    [0xEE] = 0x00EE,
    [0xEF] = 0x00EF,
    [0xF0] = 0x00F0,
    [0xF1] = 0x00F1,
    [0xF2] = 0x00F2,
    [0xF3] = 0x00F3,
    [0xF4] = 0x00F4,
    [0xF5] = 0x00F5,
    [0xF6] = 0x00F6,
    [0xF7] = 0x00F7,
    [0xF8] = 0x00F8,
    [0xF9] = 0x00F9,
    [0xFA] = 0x00FA,
    [0xFB] = 0x00FB,
    [0xFC] = 0x00FC,
    [0xFD] = 0x00FD,
    [0xFE] = 0x00FE,
    [0xFF] = 0x00FF
}
local map_unicode_to_1252 = {}
for code1252, code in pairs(map_1252_to_unicode) do
    map_unicode_to_1252[code] = code1252
end

function string.fromutf8(utf8str)
    local pos, result_1252 = 1, {}
    while pos <= #utf8str do
        local code, size = utf8_to_unicode(utf8str, pos)
        pos = pos + size
        code = code < 128 and code or map_unicode_to_1252[code] or ('?'):byte()
        table_insert(result_1252, char(code))
    end
    return table_concat(result_1252)
end

function string.toutf8(str1252)
    local result_utf8 = {}
    for pos = 1, #str1252 do
        local code = str1252:byte(pos)
        table_insert(result_utf8, unicode_to_utf8(map_1252_to_unicode[code] or code))
    end
    return table_concat(result_utf8)
end

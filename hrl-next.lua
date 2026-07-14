-- Halo Race Leaderboard (HRL) - Refactored
-- Single-file, table-based module architecture for SAPP deployment
-- Addresses: Final lap race condition, AnyOrder bitset tracking,
--            HTTP request ID collision, tick-relative timeout bugs

-- Auto-detected from memory at script load (see HRLApp:detect_server_port) with this
-- manual value kept as the fallback if detection fails or the address is stale on a
-- given build. If port is invalid, your server will not be included.
server_port = "2302"

api_version = "1.11.0.0"

debug = 0

-- Ping-spike (warp) detection: compare each check against an EMA-smoothed baseline
-- (CONSTANTS.PING_EMA_ALPHA/PING_EMA_SPIKE_THRESHOLD) instead of the previous raw sample
-- (CONSTANTS.PING_THRESHOLD). Toggle here to A/B the two without editing PingChecker itself.
ping_ema_enabled = false

-- =============================================================================
-- FFI & JSON Setup
-- =============================================================================

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


-- =============================================================================
-- Global Utility: Time
-- =============================================================================

function get_time()
    return tonumber(get_var(1, "$ticks")) / 30
end

-- Matches the web UI's own time format exactly (LapTime::formatSeconds() - "%d:%05.2f" -
-- minutes, then seconds zero-padded to 2 decimal places, e.g. 69.87 -> "1:09.87").
function format_time(seconds)
    seconds = tonumber(seconds) or 0
    local minutes = math.floor(seconds / 60)
    local remainder = seconds - (minutes * 60)
    return string.format("%d:%05.2f", minutes, remainder)
end


-- =============================================================================
-- Constants
-- =============================================================================

local CONSTANTS = {
    GAMETYPE_BASE_PC = 0x671340,
    GAMETYPE_BASE_CE = 0x5F5498,
    GAMETYPE_MODE_OFFSET_PC = 0x7C - 32,
    GAMETYPE_MODE_OFFSET_CE = 0x7C,
    PLAYER_VEHICLE_OFFSET = 0x11C,
    VEHICLE_DRIVER_OFFSET = 0x324,
    PLAYER_TIME_OFFSET = 0xC4,
    INVALID_OBJECT_ID = 0xFFFFFFFF,
    MAX_PLAYERS = 16,
    PING_CHECK_INTERVAL = 30,
    RACE_GLOBALS_OFFSET = 0x44,
    SERVER_PORT_ADDR_PC = 0x6a1c80, -- verified via scanmem
    SERVER_PORT_ADDR_CE = 0x626100, -- verified via scanmem across an INTERNAL_PORT change
    PING_THRESHOLD = 100,
    PING_EMA_ALPHA = 0.15,
    PING_EMA_SPIKE_THRESHOLD = 35,
    REQUEST_TIMEOUT_SECONDS = 5,
    HRL_TOKEN_ROTATE_INTERVAL_SECONDS = 300,
    HRL_PROTOCOL = "1",
}

local API_URLS = {
    dev = {
        newtime = "http://redesign.hrl.effakt.info/api/v1/laps",
        claimplayer = "http://redesign.hrl.effakt.info/api/v1/claimplayer"
    },
    prod = {
        newtime = "http://redesign.hrl.effakt.info/api/v1/laps",
        claimplayer = "http://redesign.hrl.effakt.info/api/v1/claimplayer"
    }
}


-- =============================================================================
-- LapLimitManager Module: Dynamic race length / grinding policy
-- =============================================================================
-- Based on dynamic_race_laps.lua by Jericho Crosby (Chalwk), MIT licensed:
-- https://github.com/Chalwk/HALO-SCRIPT-PROJECTS
--
-- HRL integration and subsequent modifications are kept in this isolated module so
-- alternative policies (for example long-running "grinding" sessions) can be added
-- without coupling score-limit decisions to lap tracking or API submission logic.

local LAP_LIMIT_CONFIG = {
    enabled = true,
    announce_changes = true,
    message = "Score limit changed to %s lap%s",

    profiles = {
        default = {
            { 1,  4,  3 },
            { 5,  8,  6 },
            { 9, 12,  9 },
            { 13, 16, 12 },
        },
        technical = {
            { 1,  4, 12 },
            { 5, 16, 15 },
        },
        medium = {
            { 1,  4,  8 },
            { 5,  8, 12 },
            { 9, 16, 15 },
        },
        large = {
            { 1,  4,  5 },
            { 5,  8,  8 },
            { 9, 12, 10 },
            { 13, 16, 12 },
        },
        very_long = {
            { 1,  4,  3 },
            { 5,  8,  5 },
            { 9, 12,  8 },
            { 13, 16, 10 },
        },
        medium_long = {
            { 1,  4,  6 },
            { 5,  8,  8 },
            { 9, 12, 10 },
            { 13, 16, 12 },
        },
    },

    maps = {
        ['bc_raceway_final_mp'] = 'technical',
        ['Camtrack-Arena-Race'] = 'technical',

        ['cliffhanger'] = 'medium',
        ['islandthunder_race'] = 'medium',
        ['LostCove_Race'] = 'medium',

        ['bloodgulch'] = 'large',
        ['sidewinder'] = 'large',
        ['icefields'] = 'large',
        ['infinity'] = 'large',

        ['gephyrophobia'] = 'very_long',
        ['New_Mombasa_Race_v2'] = 'very_long',

        ['dangercanyon'] = 'medium_long',
        ['Gauntlet_Race'] = 'medium_long',
        ['hypothermia_race'] = 'medium_long',
        ['mercury_falling'] = 'medium_long',
        ['Mongoose_Point'] = 'medium_long',
        ['Cityscape-Adrenaline'] = 'medium_long',
        ['mystic_mod'] = 'medium_long',
        ['timberland'] = 'medium_long',
        ['tsce_multiplayerv1'] = 'medium_long',
    },

    -- Initial grinding behaviour. This is deliberately a separate policy rather
    -- than a special case inside dynamic resolution, ready for future additions
    -- such as time-based rotation, minimum players, or no-win/endless sessions.
    grinding = {
        score_limit = 50,
        vote_timeout_seconds = 30,
        leave_grace_seconds = 30,
    },
}

local LapLimitManager = {}
LapLimitManager.__index = LapLimitManager

function LapLimitManager:new(config)
    local obj = {
        config = config,
        active = false,
        current_map = nil,
        current_limit = nil,
        grind_enabled = false,
        vote = nil, -- { action = "start"|"stop", player_index, player_hash, expires_at }
        leave_grace_expires_at = nil,
    }
    setmetatable(obj, self)
    return obj
end

function LapLimitManager:get_player_count(player_delta)
    local count = tonumber(get_var(0, "$pn")) or 0
    return math.max(0, count + (player_delta or 0))
end

function LapLimitManager:clear_vote()
    self.vote = nil
end

function LapLimitManager:clear_leave_grace()
    self.leave_grace_expires_at = nil
end

function LapLimitManager:reset_grind_state()
    self.grind_enabled = false
    self:clear_vote()
    self:clear_leave_grace()
end

function LapLimitManager:set_grinding(enabled, actor_name)
    self.grind_enabled = enabled and true or false
    self:clear_vote()
    self:clear_leave_grace()
    self.current_limit = nil

    if self.active then
        self:update()
    end

    if self.grind_enabled then
        say_all((actor_name and actor_name .. " started the grind." or "Grinding enabled."))
    else
        say_all((actor_name and actor_name .. " ended the grind." or "Grinding disabled."))
    end
end

function LapLimitManager:get_dynamic_profile(map_name)
    local profile_name = self.config.maps[map_name] or "default"
    return self.config.profiles[profile_name] or self.config.profiles.default
end

function LapLimitManager:resolve_dynamic_limit(player_count)
    local profile = self:get_dynamic_profile(self.current_map)
    for _, range in ipairs(profile) do
        local min_players, max_players, score_limit = unpack(range)
        if player_count >= min_players and player_count <= max_players then
            return score_limit
        end
    end
    return nil
end

function LapLimitManager:resolve_limit(player_count)
    if self.grind_enabled then
        return tonumber(self.config.grinding.score_limit)
    end
    return self:resolve_dynamic_limit(player_count)
end

function LapLimitManager:announce(limit)
    if not self.config.announce_changes then return end
    say_all(string.format(self.config.message, limit, limit ~= 1 and "s" or ""))
end

function LapLimitManager:update(player_delta)
    if not self.config.enabled or not self.active then return end

    local limit = self:resolve_limit(self:get_player_count(player_delta))
    if limit and limit ~= self.current_limit then
        self.current_limit = limit
        execute_command("scorelimit " .. limit)
        self:announce(limit)
    end
end

function LapLimitManager:on_game_start(map_name, is_race)
    self.current_map = map_name
    self.current_limit = nil
    self.active = self.config.enabled and is_race or false
    self:reset_grind_state()
    self:update()
end

function LapLimitManager:on_game_end()
    self.active = false
    self.current_limit = nil
    self:reset_grind_state()
end

function LapLimitManager:on_player_join(playerIndex)
    self:update()

    if not self.active then
        return
    end

    if self.grind_enabled then
        say(playerIndex, "A grind is currently running. Say 'grind' to vote to stop it.")
    elseif self.current_limit then
        say(playerIndex, string.format(
            "This race is set to %d lap%s.",
            self.current_limit,
            self.current_limit ~= 1 and "s" or ""
        ))
    end
end

function LapLimitManager:on_player_quit()
    local remaining = self:get_player_count(-1)
    self:clear_vote()

    if self.grind_enabled then

        if remaining <= 0 then
            self:reset_grind_state()
            return
        end

        local seconds = tonumber(self.config.grinding.leave_grace_seconds) or 30
        self.leave_grace_expires_at = os.time() + seconds
        say_all(string.format("Grind will end in %d seconds; say 'grind' to continue.", seconds))
        return
    end

    self:update(-1)
end

function LapLimitManager:begin_vote(playerIndex, action)
    local name = get_var(playerIndex, "$name")
    local hash = get_var(playerIndex, "$hash")
    local timeout = tonumber(self.config.grinding.vote_timeout_seconds) or 30

    self.vote = {
        action = action,
        player_index = playerIndex,
        player_hash = hash,
        expires_at = os.time() + timeout,
    }

    if action == "start" then
        say_all(name .. " wants to start a grind; say 'grind' to vote yes.")
    else
        say_all(name .. " wants to stop the grind; say 'grind' to vote yes.")
    end
end

function LapLimitManager:handle_grind_chat(playerIndex)
    if not self.active then
        say(playerIndex, "Grinding is only available during race games.")
        return false
    end

    local now = os.time()
    local name = get_var(playerIndex, "$name")
    local hash = get_var(playerIndex, "$hash")

    if self.leave_grace_expires_at then
        self:clear_leave_grace()
        say_all(name .. " continued the grind.")
        return false
    end

    if self.vote and now >= self.vote.expires_at then
        self:clear_vote()
    end

    local player_count = self:get_player_count()
    local action = self.grind_enabled and "stop" or "start"

    if player_count <= 1 then
        self:set_grinding(not self.grind_enabled, name)
        return false
    end

    if not self.vote or self.vote.action ~= action then
        self:begin_vote(playerIndex, action)
        return false
    end

    if self.vote.player_hash == hash then
        say(playerIndex, "Another player must say 'grind' to confirm the vote.")
        return false
    end

    self:set_grinding(action == "start", name)
    return false
end

function LapLimitManager:show_status(playerIndex)
    if not self.active then
        say(playerIndex, "Current mode: HRL is inactive for this gametype.")
    elseif self.grind_enabled then
        local limit = tonumber(self.current_limit) or tonumber(self.config.grinding.score_limit) or 50
        say(playerIndex, string.format("Current mode: Grind (%d laps)", limit))
    elseif self.current_limit then
        say(playerIndex, string.format(
            "Current mode: Race (%d lap%s)",
            self.current_limit,
            self.current_limit ~= 1 and "s" or ""
        ))
    else
        say(playerIndex, "Current mode: Race")
    end
end

function LapLimitManager:on_tick()
    local now = os.time()

    if self.vote and now >= self.vote.expires_at then
        local action = self.vote.action
        self:clear_vote()
        say_all("The vote to " .. action .. " the grind expired.")
    end

    if self.leave_grace_expires_at and now >= self.leave_grace_expires_at then
        self:clear_leave_grace()
        if self.grind_enabled then
            self:set_grinding(false)
        end
    end
end

-- =============================================================================
-- Encoding Module: Windows-1252 <-> UTF-8
-- =============================================================================

local Encoding = {}

local char, byte, pairs, floor = string.char, string.byte, pairs, math.floor
local table_insert, table_concat = table.insert, table.concat
local unpack = table.unpack or unpack

local function unicode_to_utf8(code)
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
    return code, size
end

local map_1252_to_unicode = {
    [0x80] = 0x20AC, [0x81] = 0x81,   [0x82] = 0x201A, [0x83] = 0x0192,
    [0x84] = 0x201E, [0x85] = 0x2026, [0x86] = 0x2020, [0x87] = 0x2021,
    [0x88] = 0x02C6, [0x89] = 0x2030, [0x8A] = 0x0160, [0x8B] = 0x2039,
    [0x8C] = 0x0152, [0x8D] = 0x8D,   [0x8E] = 0x017D, [0x8F] = 0x8F,
    [0x90] = 0x90,   [0x91] = 0x2018, [0x92] = 0x2019, [0x93] = 0x201C,
    [0x94] = 0x201D, [0x95] = 0x2022, [0x96] = 0x2013, [0x97] = 0x2014,
    [0x98] = 0x02DC, [0x99] = 0x2122, [0x9A] = 0x0161, [0x9B] = 0x203A,
    [0x9C] = 0x0153, [0x9D] = 0x9D,   [0x9E] = 0x017E, [0x9F] = 0x0178,
    [0xA0] = 0x00A0, [0xA1] = 0x00A1, [0xA2] = 0x00A2, [0xA3] = 0x00A3,
    [0xA4] = 0x00A4, [0xA5] = 0x00A5, [0xA6] = 0x00A6, [0xA7] = 0x00A7,
    [0xA8] = 0x00A8, [0xA9] = 0x00A9, [0xAA] = 0x00AA, [0xAB] = 0x00AB,
    [0xAC] = 0x00AC, [0xAD] = 0x00AD, [0xAE] = 0x00AE, [0xAF] = 0x00AF,
    [0xB0] = 0x00B0, [0xB1] = 0x00B1, [0xB2] = 0x00B2, [0xB3] = 0x00B3,
    [0xB4] = 0x00B4, [0xB5] = 0x00B5, [0xB6] = 0x00B6, [0xB7] = 0x00B7,
    [0xB8] = 0x00B8, [0xB9] = 0x00B9, [0xBA] = 0x00BA, [0xBB] = 0x00BB,
    [0xBC] = 0x00BC, [0xBD] = 0x00BD, [0xBE] = 0x00BE, [0xBF] = 0x00BF,
    [0xC0] = 0x00C0, [0xC1] = 0x00C1, [0xC2] = 0x00C2, [0xC3] = 0x00C3,
    [0xC4] = 0x00C4, [0xC5] = 0x00C5, [0xC6] = 0x00C6, [0xC7] = 0x00C7,
    [0xC8] = 0x00C8, [0xC9] = 0x00C9, [0xCA] = 0x00CA, [0xCB] = 0x00CB,
    [0xCC] = 0x00CC, [0xCD] = 0x00CD, [0xCE] = 0x00CE, [0xCF] = 0x00CF,
    [0xD0] = 0x00D0, [0xD1] = 0x00D1, [0xD2] = 0x00D2, [0xD3] = 0x00D3,
    [0xD4] = 0x00D4, [0xD5] = 0x00D5, [0xD6] = 0x00D6, [0xD7] = 0x00D7,
    [0xD8] = 0x00D8, [0xD9] = 0x00D9, [0xDA] = 0x00DA, [0xDB] = 0x00DB,
    [0xDC] = 0x00DC, [0xDD] = 0x00DD, [0xDE] = 0x00DE, [0xDF] = 0x00DF,
    [0xE0] = 0x00E0, [0xE1] = 0x00E1, [0xE2] = 0x00E2, [0xE3] = 0x00E3,
    [0xE4] = 0x00E4, [0xE5] = 0x00E5, [0xE6] = 0x00E6, [0xE7] = 0x00E7,
    [0xE8] = 0x00E8, [0xE9] = 0x00E9, [0xEA] = 0x00EA, [0xEB] = 0x00EB,
    [0xEC] = 0x00EC, [0xED] = 0x00ED, [0xEE] = 0x00EE, [0xEF] = 0x00EF,
    [0xF0] = 0x00F0, [0xF1] = 0x00F1, [0xF2] = 0x00F2, [0xF3] = 0x00F3,
    [0xF4] = 0x00F4, [0xF5] = 0x00F5, [0xF6] = 0x00F6, [0xF7] = 0x00F7,
    [0xF8] = 0x00F8, [0xF9] = 0x00F9, [0xFA] = 0x00FA, [0xFB] = 0x00FB,
    [0xFC] = 0x00FC, [0xFD] = 0x00FD, [0xFE] = 0x00FE, [0xFF] = 0x00FF
}

local map_unicode_to_1252 = {}
for code1252, code in pairs(map_1252_to_unicode) do
    map_unicode_to_1252[code] = code1252
end

function Encoding.fromutf8(utf8str)
    local pos, result_1252 = 1, {}
    while pos <= #utf8str do
        local code, size = utf8_to_unicode(utf8str, pos)
        pos = pos + size
        code = code < 128 and code or map_unicode_to_1252[code] or ('?'):byte()
        table_insert(result_1252, char(code))
    end
    return table_concat(result_1252)
end

function Encoding.toutf8(str1252)
    local result_utf8 = {}
    for pos = 1, #str1252 do
        local code = str1252:byte(pos)
        table_insert(result_utf8, unicode_to_utf8(map_1252_to_unicode[code] or code))
    end
    return table_concat(result_utf8)
end

-- =============================================================================
-- HrlToken Module: Query field publishing and rotation
-- =============================================================================

local HrlToken = {}
HrlToken.__index = HrlToken

function HrlToken:new()
    local obj = {
        token = nil,
        token_prev = nil,
        last_rotated = 0,
        rotate_interval = CONSTANTS.HRL_TOKEN_ROTATE_INTERVAL_SECONDS,
        protocol = CONSTANTS.HRL_PROTOCOL,
    }
    setmetatable(obj, self)
    return obj
end

function HrlToken:random_hex(length)
    local chars = "0123456789abcdef"
    local out = {}
    for i = 1, length do
        local idx = math.random(1, #chars)
        out[i] = chars:sub(idx, idx)
    end
    return table.concat(out)
end

function HrlToken:publish()
    execute_command("query_add hrl_enabled 1")
    execute_command("query_add hrl_protocol " .. self.protocol)
    execute_command("query_add hrl_token " .. (self.token or ""))
    execute_command("query_add hrl_token_prev " .. (self.token_prev or ""))
end

function HrlToken:rotate()
    self.token_prev = self.token
    self.token = self:random_hex(32)
    self.last_rotated = os.time()
    self:publish()
end

function HrlToken:cleanup()
    execute_command("query_del hrl_enabled")
    execute_command("query_del hrl_protocol")
    execute_command("query_del hrl_token")
    execute_command("query_del hrl_token_prev")
end

function HrlToken:should_rotate()
    return os.time() - self.last_rotated >= self.rotate_interval
end

-- =============================================================================
-- ApiClient Module: HTTP requests, polling, timeouts
-- =============================================================================

local ApiClient = {}
ApiClient.__index = ApiClient

function ApiClient:new()
    local obj = {
        active_requests = {},  -- request_id -> { player_index, start_wall_time, request_type }
        next_request_id = 1,
    }
    setmetatable(obj, self)
    return obj
end

function ApiClient:generate_request_id()
    local id = self.next_request_id
    self.next_request_id = self.next_request_id + 1
    return id
end

function ApiClient:generate_submission_id(playerIndex)
    return string.format("%d-%d-%d", math.floor(get_time() * 1000), playerIndex, math.random(100000, 999999999))
end

function ApiClient:post(url, body, player_index, request_type)
    local req_id = self:generate_request_id()
    self.active_requests[req_id] = {
        player_index = player_index,
        start_wall_time = os.time(),
        request_type = request_type,
    }
    http_client.http_post(req_id, url, body)
    return req_id
end

function ApiClient:poll()
    local id_buf = ffi.new("uint32_t[1]")
    local ptr = http_client.http_poll(id_buf)
    if ptr ~= nil then
        local body = ffi.string(ptr)
        http_client.http_free(ptr)
        return id_buf[0], body
    end
    return nil, nil
end

function ApiClient:process_responses(json_decoder, say_fn, say_all_fn, get_var_fn)
    local now = os.time()
    local responses_processed = 0

    -- Timeout check (wall-clock based, survives map transitions)
    for req_id, req_info in pairs(self.active_requests) do
        if now - req_info.start_wall_time > CONSTANTS.REQUEST_TIMEOUT_SECONDS then
            print(string.format("%s request for player %d timed out after %d seconds",
                  req_info.request_type, req_info.player_index, CONSTANTS.REQUEST_TIMEOUT_SECONDS))
            self.active_requests[req_id] = nil
        end
    end

    -- Process available responses
    while true do
        local req_id, response_body = self:poll()
        if not req_id then break end

        responses_processed = responses_processed + 1

        local req_info = self.active_requests[req_id]
        self.active_requests[req_id] = nil

        if not req_info then
            print(string.format("Received response for req_id %d but no active request found", req_id))
            print("Response body: " .. response_body)
        else
            self:handle_response(req_info, response_body, json_decoder, say_fn, say_all_fn, get_var_fn)
        end
    end

    if responses_processed > 0 then
        local active_count = 0
        for _ in pairs(self.active_requests) do active_count = active_count + 1 end
        print(string.format("Processed %d responses, %d requests still pending",
              responses_processed, active_count))
    end
end

function ApiClient:handle_response(req_info, response_body, json_decoder, say_fn, say_all_fn, get_var_fn)
    print(response_body)

    local success, response = pcall(function()
        return json_decoder:decode(response_body)
    end)

    if not success then
        print(string.format("Failed to parse %s response for player %d: %s",
              req_info.request_type, req_info.player_index, response_body))
        say_fn(req_info.player_index, "Error processing server response")
        return
    end

    if req_info.request_type == "newtime" then
        self:handle_newtime_response(req_info.player_index, response, say_fn, say_all_fn, get_var_fn)
    elseif req_info.request_type == "claimplayer" then
        self:handle_claim_response(req_info.player_index, response, say_fn)
    end
end

function ApiClient:handle_newtime_response(player_index, response, say_fn, say_all_fn, get_var_fn)
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
            say_fn(player_index, message)
        else
            say_fn(player_index, "Time recorded successfully!")
        end

        -- is_new_record/server_lb are server-scoped (the submitting server only); global_lb and
        -- pb (personal_best) are computed across every server the player has played on - see
        -- docs/api.md's 2026-07-14 note. Priority for the ONE announcement below: a global
        -- record beats a server record beats a plain personal best.
        local is_new_record = (type(resp) == "table" and resp.isNewRecord) or (type(payload) == "table" and payload.isNewRecord)
        local lap_time = (type(resp) == "table" and resp.lapTime) or (type(payload) == "table" and payload.lapTime)
        local lap_time_str = format_time(lap_time)

        local server_lb = (type(payload) == "table" and payload.leaderboardPosition) or resp.position or payload.position
        local global_lb = type(payload) == "table" and payload.globalLeaderboardPosition or nil
        local pb = type(payload) == "table" and payload.personalBest or nil

        local is_global_record = type(global_lb) == "table" and global_lb.position == 1
                                  and type(pb) == "table" and pb.isNewRecord
        local is_server_record = type(server_lb) == "table" and server_lb.position == 1 and is_new_record
        local is_new_pb = type(pb) == "table" and pb.isNewRecord

        if is_global_record then
            local player_name = Encoding.toutf8(get_var_fn(player_index, "$name"))
            say_all_fn(player_name .. " set a new GLOBAL record: " .. lap_time_str .. " seconds!")
        elseif is_server_record then
            local player_name = Encoding.toutf8(get_var_fn(player_index, "$name"))
            say_all_fn(player_name .. " set a new SERVER record: " .. lap_time_str .. " seconds!")
        elseif is_new_pb then
            if pb.improvement then
                say_fn(player_index, string.format("New personal best: %s seconds (-%.2f)", lap_time_str, tonumber(pb.improvement) or 0))
            else
                say_fn(player_index, "New personal best: " .. lap_time_str .. " seconds")
            end
        elseif type(server_lb) == "table" and server_lb.position then
            -- Not a record/PB this time - the same informational rank line as before,
            -- just formatted with format_time() now.
            if server_lb.position == 1 then
                say_fn(player_index, "Leaderboard position: #1 (your record stands at " .. format_time(server_lb.top_time or 0) .. ")")
            else
                say_fn(player_index, string.format("Leaderboard position: #%d (%.2f sec behind #1)",
                        server_lb.position, tonumber(server_lb.difference) or 0))
            end
        elseif type(server_lb) == "number" then
            say_fn(player_index, "Leaderboard position: #" .. server_lb)
        end
    else
        local error_msg = (type(resp) == "table" and (resp.error or resp.message)) or
                          (type(payload) == "table" and (payload.error or payload.message)) or "Unknown error"
        say_fn(player_index, "Failed to record time: " .. error_msg)
    end
end

function ApiClient:handle_claim_response(player_index, response, say_fn)
    if response.success then
        say_fn(player_index, response.message or "Player claimed successfully! You can now view your stats online.")
    else
        local error_msg = response.error or response.message or "Unknown error"
        say_fn(player_index, "Claim failed: " .. error_msg)
    end
end

-- =============================================================================
-- PlayerState Module: Per-player lap, warp, ping tracking
-- =============================================================================

local PlayerState = {}
PlayerState.__index = PlayerState

function PlayerState:new(playerIndex)
    local obj = {
        index = playerIndex,
        warps = 0,
        ping = 0,
        ping_stability = {},
        -- Checkpoint/lap state
        current_cp = 0,
        previous_cp = 0,
        started = false,
        start_checkpoint = 0,
        started_time = nil,
        checkpoints = {},
        seen_checkpoints = {},  -- For AnyOrder: track which checkpoint IDs have been visited
        lap_submitted = false,  -- Idempotency guard against duplicate submissions
        lap_completed = false, -- TRUE only when player actually finished the lap (score)
    }
    setmetatable(obj, self)
    return obj
end

function PlayerState:reset()
    self.warps = 0
    self.ping = 0
    self.ping_stability = {}
    self.current_cp = 0
    self.previous_cp = 0
    self.started = false
    self.start_checkpoint = 0
    self.started_time = nil
    self.checkpoints = {}
    self.seen_checkpoints = {}
    self.lap_submitted = false
    self.lap_completed = false
end

function PlayerState:has_valid_lap()
    return self.started and self.started_time ~= nil and not self.lap_submitted
end

function PlayerState:mark_submitted()
    self.lap_submitted = true
end

function PlayerState:is_warped()
    return self.warps > 0
end

-- =============================================================================
-- LapTracker Module: Checkpoint reading, bitset decoding, split recording, lap finish
-- =============================================================================

local LapTracker = {}
LapTracker.__index = LapTracker

function LapTracker:new(race_globals_addr, api_client, hrl_token)
    local obj = {
        race_globals = race_globals_addr,
        api_client = api_client,
        hrl_token = hrl_token,
        players = {},
        allow_warps = false,
        current_map = nil,
        race_type = 0,  -- 0=normal, 1=AnyOrder, 2=Rally
        game_started = false,
    }
    for i = 1, CONSTANTS.MAX_PLAYERS do
        obj.players[i] = PlayerState:new(i)
    end
    setmetatable(obj, self)
    return obj
end

function LapTracker:set_map(map_name)
    self.current_map = map_name
end

function LapTracker:set_race_type(race_type)
    self.race_type = race_type
end

function LapTracker:set_game_started(started)
    self.game_started = started
end

function LapTracker:reset_all()
    for i = 1, CONSTANTS.MAX_PLAYERS do
        self.players[i]:reset()
    end
end

function LapTracker:reset_player(playerIndex)
    if self.players[playerIndex] then
        self.players[playerIndex]:reset()
    end
end

-- Decode raw checkpoint bits into individual checkpoint IDs
-- Game uses bitset pattern: bit N set = checkpoint N+1 visited
-- raw_id values: 0=none, 1=cp1, 3=cp1+cp2, 7=cp1+cp2+cp3, etc.
function LapTracker:decode_checkpoint_bits(raw_id)
    local checkpoints = {}
    if raw_id == 0 then
        return checkpoints
    end
    local temp = raw_id
    local bit_index = 0
    while temp > 0 do
        if temp % 2 == 1 then
            table.insert(checkpoints, bit_index + 1)
        end
        temp = math.floor(temp / 2)
        bit_index = bit_index + 1
    end
    return checkpoints
end

-- Legacy normalize for reference (not used in bitset tracking)
function LapTracker:normalize_checkpoint_id(raw_id)
    if raw_id == 0 then return 0 end
    local normalized = 0
    local temp = raw_id + 1
    while temp > 1 do
        temp = math.floor(temp / 2)
        normalized = normalized + 1
    end
    return normalized
end

function LapTracker:get_raw_checkpoint(playerIndex)
    if not player_present(playerIndex) then return 0 end
    if self.race_globals == 0 then
        safe_read(false)
        return 0
    end
    local checkpoint_address = self.race_globals + to_real_index(playerIndex) * 4 + CONSTANTS.RACE_GLOBALS_OFFSET
    local checkpoint_id = read_dword(checkpoint_address)
    return tonumber(checkpoint_id) or 0
end

function LapTracker:record_split(playerIndex, cp_id, now)
    local player = self.players[playerIndex]

    -- Finalize previous checkpoint
    local last_cp = player.checkpoints[#player.checkpoints]
    if last_cp and last_cp.end_time == nil then
        last_cp.end_time = now
        if last_cp.checkpoint_id ~= 0 then
            local split_duration = last_cp.end_time - last_cp.start
            say(playerIndex, string.format("CP %d->%d - Split: %.2f sec", last_cp.checkpoint_id, cp_id, split_duration))
        end
    end

    -- Add new checkpoint entry
    table.insert(player.checkpoints, {
        checkpoint_id = cp_id,
        start = now,
        end_time = nil,
    })
end

-- Core idempotent lap finalization
-- Called from OnPlayerScore (normal finish) or OnGameEnd (cleanup). Says nothing itself about
-- the outcome - the actual HTTP response (once it arrives, see handle_newtime_response) is the
-- single source of truth for what the player is told (record/PB/rank), so nothing gets said
-- here before we even know whether the submission succeeded.
function LapTracker:finish_lap(playerIndex, now)
    local player = self.players[playerIndex]

    -- Guard: must have started, not already submitted
    if not player:has_valid_lap() then
        return false
    end

    -- Guard: warped laps are finalized but not submitted
    if player:is_warped() then
        say(playerIndex, "We detected a warp or a lag spike, your lap time was not recorded")
        player:mark_submitted()  -- Mark as handled so we don't retry
        player:reset()
        return false
    end

    -- Finalize any open split
    local last_cp = player.checkpoints[#player.checkpoints]
    if last_cp and last_cp.end_time == nil then
        last_cp.end_time = now
        if last_cp.checkpoint_id ~= 0 then
            local split_duration = last_cp.end_time - last_cp.start
            say(playerIndex, string.format("CP %d->Finish - Split: %.2f sec", last_cp.checkpoint_id, split_duration))
        end
    end

    local best_time = now - player.started_time

    -- Build splits payload
    local splits = {}
    for _, entry in ipairs(player.checkpoints) do
        if entry.checkpoint_id ~= 0 and entry.start and entry.end_time then
            table.insert(splits, {
                checkpoint_id = entry.checkpoint_id,
                startTime = entry.start,
                endTime = entry.end_time,
                duration = entry.end_time - entry.start,
            })
        end
    end

    -- Submit via API
    self:submit_lap(playerIndex, best_time, splits)

    player:mark_submitted()

    return true
end

function LapTracker:submit_lap(playerIndex, best_time, splits)
    local player_hash = get_var(playerIndex, "$hash")
    local current_name = Encoding.toutf8(get_var(playerIndex, "$name"))
    local is_debug = debug == 1

    local data = {
        port = server_port,
        player_hash = player_hash,
        player_name = current_name,
        map_name = self.current_map,
        map_label = "",
        race_type = self.race_type,
        player_time = best_time,
        hrl_token = self.hrl_token.token,
        submission_id = self.api_client:generate_submission_id(playerIndex),
    }

    if splits and #splits > 0 then
        data.splits = splits
    end

    if is_debug then
        data.test = "true"
    end

    local json_str = json:encode(data)
    print(json_str)

    local api_env = is_debug and "dev" or "prod"
    self.api_client:post(API_URLS[api_env].newtime, json_str, playerIndex, "newtime")
end

-- Detects whether another slot already tracking a lap (started == true, still present)
-- shares this slot's real identity ($hash + $name). A brief disconnect/reconnect - e.g.
-- during a custom map's download handshake - can momentarily give the same physical player
-- two separate player indices, both independently reading checkpoints for the same real
-- race (confirmed against real data: two slots, same hash/name, same tick, identical lap
-- time, on New_Mombasa_Race_v2 - a non-stock map requiring a client-side download). Checked
-- fresh every tick at the single point a slot's lap tracking begins (see track_checkpoints
-- below), so it doesn't matter which slot's raw_cp goes nonzero first or how many ticks
-- later the duplicate shows up - only the earliest slot to start tracking ever starts.
function LapTracker:find_active_slot_for_identity(hash, name, exclude_index)
    for i = 1, CONSTANTS.MAX_PLAYERS do
        if i ~= exclude_index and player_present(i) and self.players[i].started then
            if get_var(i, "$hash") == hash and get_var(i, "$name") == name then
                return i
            end
        end
    end
    return nil
end

function LapTracker:track_checkpoints(now)
    if not self.game_started then
        return
    end

    -- Rally (race_type 2) is not supported (see docs/decisions.md) - there's no CP0-completion
    -- trigger anymore, and Rally rounds may not fire EVENT_SCORE the same way a normal race
    -- does, so tracking would start (splits, "CP X->Y" messages) but nothing would ever finish
    -- or submit it. Skip tracking entirely rather than half-track a race that can never
    -- complete; player.started staying false also means on_player_score/on_game_end's
    -- has_valid_lap() guards naturally no-op for these players too.
    if self.race_type == 2 then
        return
    end

    for i = 1, CONSTANTS.MAX_PLAYERS do
        if player_present(i) then
            local raw_cp = self:get_raw_checkpoint(i)
            local player = self.players[i]

            player.previous_cp = player.current_cp
            player.current_cp = raw_cp

            -- Decode all checkpoint bits from raw value
            local checkpoint_bits = self:decode_checkpoint_bits(raw_cp)

            -- Start lap on first checkpoint (any mode) - but never for a slot that looks like
            -- a duplicate/ghost connection of another slot already tracking this same player.
            -- Suppressing it HERE (rather than only at submission) means it never starts, so
            -- it never emits ANY event for this lap either - no split messages, no
            -- lap-finish message, no HTTP submission. Trade-off, accepted: if the slot we
            -- kept then drops out mid-race while the suppressed slot would have gone on to
            -- finish, that lap is lost - preferred over double-counting every event, which
            -- was the actual reported bug.
            if raw_cp >= 1 and not player.started then
                local hash = get_var(i, "$hash")
                local name = get_var(i, "$name")
                local duplicate_of = self:find_active_slot_for_identity(hash, name, i)

                if duplicate_of then
                    print(string.format(
                        "Slot %d looks like a duplicate connection for '%s' (already tracked by slot %d) - ignoring all events for this slot's lap",
                        i, Encoding.toutf8(name), duplicate_of))
                else
                    player.started = true
                    player.start_checkpoint = checkpoint_bits[1] or 1
                    player.started_time = now
                    player.checkpoints = {
                        {
                            checkpoint_id = 0,
                            start = now,
                            end_time = nil,
                        }
                    }
                    player.seen_checkpoints = {}
                    player.lap_submitted = false
                end
            end

            -- Track newly seen checkpoints
            if player.started then
                for _, cp_id in ipairs(checkpoint_bits) do
                    if not player.seen_checkpoints[cp_id] then
                        player.seen_checkpoints[cp_id] = true
                        self:record_split(i, cp_id, now)
                    end
                end
            end
        end
    end
end

function LapTracker:check_vehicle_driver(playerIndex)
    local player_address = get_dynamic_player(playerIndex)
    if not player_address then
        return false
    end

    local vehicle_objectid = read_dword(player_address + CONSTANTS.PLAYER_VEHICLE_OFFSET)

    if tonumber(vehicle_objectid) ~= CONSTANTS.INVALID_OBJECT_ID then
        local vehicle = get_object_memory(tonumber(vehicle_objectid))
        if not vehicle then
            return false
        end
        local driver = get_object_memory(read_dword(vehicle + CONSTANTS.VEHICLE_DRIVER_OFFSET))
        return (driver == player_address)
    end

    return true  -- Not in vehicle = considered driver (on foot)
end

-- Called from OnPlayerScore - handles normal/score-based lap completion
function LapTracker:on_player_score(playerIndex, now)
    local player = self.players[playerIndex]

    if not player:has_valid_lap() then
        return
    end

    player.ping_stability = {}

    local is_driver = self:check_vehicle_driver(playerIndex)

    if is_driver then
        player.lap_completed = true
        self:finish_lap(playerIndex, now)
    end

    -- Always reset warp flag after score event
    player.warps = 0
end

-- Called from OnGameEnd - submit any pending laps before cleanup
function LapTracker:on_game_end(now)
    for i = 1, CONSTANTS.MAX_PLAYERS do
        -- Only auto-submit if the lap was actually completed (score event)
        -- but not yet submitted. Do NOT submit incomplete laps just because game ended
        -- (e.g. a skip vote ending the map mid-race).
        if player_present(i) and self.players[i]:has_valid_lap() and self.players[i].lap_completed then
            self:finish_lap(i, now)
        end
        -- Deliberately NOT resetting player state here (see LAST-LAP-BUG.md): the lap that
        -- wins the race is exactly the lap whose EVENT_SCORE is most likely still in flight
        -- when EVENT_GAME_END fires. Resetting immediately would wipe .started/.started_time
        -- out from under that still-pending OnPlayerScore call, silently dropping the one
        -- lap that actually finished. Leaving state intact lets a late OnPlayerScore still
        -- finalize and submit normally; OnGameStart's reset_all() (and OnPlayerJoin's
        -- reset_player()) clears any leftover never-finished lap before the next race.
    end
end

-- =============================================================================
-- PingChecker Module: Warp detection via ping spikes
-- =============================================================================

local PingChecker = {}
PingChecker.__index = PingChecker

function PingChecker:new()
    local obj = {
        last_ping_check = 0,
        player_ping = {},
        ema_ping = {},  -- Only populated/consulted when ping_ema_enabled is true
    }
    for i = 1, CONSTANTS.MAX_PLAYERS do
        obj.player_ping[i] = 0
    end
    setmetatable(obj, self)
    return obj
end

function PingChecker:reset()
    for i = 1, CONSTANTS.MAX_PLAYERS do
        self.player_ping[i] = 0
        self.ema_ping[i] = nil
    end
    self.last_ping_check = 0
end

-- Clears one player's baseline without disturbing anyone else's (join/rejoin) so a
-- reused player slot doesn't inherit the previous occupant's raw ping or EMA baseline.
function PingChecker:reset_player(playerIndex)
    self.player_ping[playerIndex] = self:get_player_ping(playerIndex)
    self.ema_ping[playerIndex] = nil
end

function PingChecker:get_player_ping(playerIndex)
    if player_present(playerIndex) then
        return tonumber(get_var(playerIndex, "$ping")) or 0
    end
    return 0
end

-- Decides whether this tick's ping counts as a spike, and returns the updated EMA baseline
-- to store. Computes the delta against the OLD baseline before folding this sample in -
-- comparing against the already-updated baseline would understate the true jump by
-- (1 - PING_EMA_ALPHA), since it'd already include a slice of the very sample being tested.
function PingChecker:check_ema_spike(playerIndex, ping)
    local ema = self.ema_ping[playerIndex]
    local is_spike = false

    if ema then
        local delta = math.floor(ping - ema + 0.5)
        is_spike = delta >= CONSTANTS.PING_EMA_SPIKE_THRESHOLD
    end

    local updated_ema = ema and (ema * (1 - CONSTANTS.PING_EMA_ALPHA) + ping * CONSTANTS.PING_EMA_ALPHA) or ping
    return is_spike, updated_ema
end

function PingChecker:check(lap_tracker)
    local current_ticks = tonumber(get_var(1, "$ticks")) or 0

    if (current_ticks - self.last_ping_check) < CONSTANTS.PING_CHECK_INTERVAL then
        return
    end

    for i = 1, CONSTANTS.MAX_PLAYERS do
        if player_present(i) then
            local ping = self:get_player_ping(i)
            local is_spike

            if ping_ema_enabled then
                local updated_ema
                is_spike, updated_ema = self:check_ema_spike(i, ping)
                self.ema_ping[i] = updated_ema
            else
                local prev_ping = self.player_ping[i]
                is_spike = prev_ping and prev_ping > 0 and (ping - prev_ping) > CONSTANTS.PING_THRESHOLD
            end

            if is_spike then
                lap_tracker.players[i].warps = 1
                say(i, "We just detected a ping spike. This lap will not count")
            end

            self.player_ping[i] = ping
        end
    end

    self.last_ping_check = current_ticks
end

-- =============================================================================
-- HRLApp Module: Top-level lifecycle, config, callbacks
-- =============================================================================

local HRLApp = {}
HRLApp.__index = HRLApp

function HRLApp:new()
    local obj = {
        current_map = nil,
        race = false,
        mode = 0,
        game_started = false,
        allow_warps = false,
        race_globals = 0,
        gametype_base = (halo_type == "PC") and CONSTANTS.GAMETYPE_BASE_PC or CONSTANTS.GAMETYPE_BASE_CE,
    }

    obj.hrl_token = HrlToken:new()
    obj.api_client = ApiClient:new()
    obj.lap_tracker = LapTracker:new(obj.race_globals, obj.api_client, obj.hrl_token)
    obj.ping_checker = PingChecker:new()
    obj.lap_limits = LapLimitManager:new(LAP_LIMIT_CONFIG)

    setmetatable(obj, self)
    return obj
end

function HRLApp:check_map_and_gametype(is_new_game)
    if get_var(1, "$gt") == "race" then
        if not is_new_game and self.race then
            return false
        end

        self.current_map = get_var(1, "$map")
        self.race = true
        self.game_started = true

        register_callback(cb['EVENT_SCORE'], "OnPlayerScore")

        safe_read(true)
        local offset = (halo_type == "PC") and CONSTANTS.GAMETYPE_MODE_OFFSET_PC or CONSTANTS.GAMETYPE_MODE_OFFSET_CE
        self.mode = read_byte(self.gametype_base + offset)
        safe_read(false)

        self.lap_tracker:set_map(self.current_map)
        self.lap_tracker:set_race_type(self.mode)
        self.lap_tracker:set_game_started(true)

        -- Re-scan race globals in case they changed
        self.race_globals = read_dword(sig_scan("BF??????00F3ABB952000000") + 0x1)
        self.lap_tracker.race_globals = self.race_globals
    else
        self.race = false
        self.game_started = false
        unregister_callback(cb['EVENT_SCORE'])
        self.lap_tracker:set_game_started(false)
    end
end

-- Validates the read looks like a real port before trusting it, so a stale/wrong address
-- on some future build just falls back to the manual server_port instead of submitting
-- garbage.
function HRLApp:detect_server_port()
    local address = (halo_type == "PC") and CONSTANTS.SERVER_PORT_ADDR_PC or CONSTANTS.SERVER_PORT_ADDR_CE
    local ok, value = pcall(read_dword, address)

    if ok and type(value) == "number" and value > 0 and value <= 65535 then
        print(string.format("server_port auto-detected as %d at 0x%X (manual value was %s)",
              value, address, tostring(server_port)))
        server_port = tostring(value)
    else
        print(string.format("server_port auto-detect failed at 0x%X, keeping manual value %s",
              address, tostring(server_port)))
    end
end

function HRLApp:on_script_load()
    register_callback(cb['EVENT_COMMAND'], "OnServerCommand")
    register_callback(cb['EVENT_CHAT'], "OnChat")
    register_callback(cb['EVENT_GAME_START'], "OnGameStart")
    register_callback(cb['EVENT_GAME_END'], "OnGameEnd")
    register_callback(cb['EVENT_JOIN'], "OnPlayerJoin")
    register_callback(cb['EVENT_LEAVE'], "OnPlayerQuit")
    register_callback(cb['EVENT_WARP'], "OnWarp")
    register_callback(cb['EVENT_TICK'], "OnTick")

    self:detect_server_port()

    self:check_map_and_gametype(true)
    self.lap_limits:on_game_start(self.current_map, self.race)

    self.ping_checker:reset()

    math.randomseed(os.time())
    self.hrl_token:rotate()

    print("HRL Loaded (refactored)")
end

function HRLApp:on_script_unload()
    self.hrl_token:cleanup()
end

function HRLApp:on_game_start()
    self:check_map_and_gametype(true)
    self.lap_limits:on_game_start(self.current_map, self.race)
    self.lap_tracker:reset_all()
    self.ping_checker:reset()

    for i = 1, CONSTANTS.MAX_PLAYERS do
        self.ping_checker.player_ping[i] = self.ping_checker:get_player_ping(i)
    end
end

function HRLApp:on_game_end()
    self.lap_limits:on_game_end()

    local now = get_time()
    -- Submit pending laps BEFORE resetting state
    self.lap_tracker:on_game_end(now)

    -- Stop ping-spike watching (and checkpoint tracking) until the next game actually
    -- starts - otherwise players get warned for a "ping spike" during the post-game
    -- PGCR/lobby, when no lap is even being timed. on_game_start's ping_checker:reset()
    -- (plus its baseline re-priming loop) means re-enabling this later is always a clean
    -- start, not a stale comparison against pre-PGCR readings.
    self.game_started = false
    self.lap_tracker:set_game_started(false)

    -- Only reset if not race or mode == 2 (per original logic)
    if not self.race or self.mode == 2 then
        return false
    end
end

function HRLApp:on_player_join(playerIndex)
    if not self.race then
        self:check_map_and_gametype(false)
    end

    self.lap_tracker:reset_player(playerIndex)
    self.ping_checker:reset_player(playerIndex)
    self.lap_limits:on_player_join(playerIndex)

    say(playerIndex, "This server runs Halo Race Leaderboard.")
    say(playerIndex, "For more information, or to see the leaderboard, go to hrl.effakt.info")
end

function HRLApp:on_player_quit(playerIndex)
    self.lap_limits:on_player_quit()
    self.lap_tracker:reset_player(playerIndex)
    print(string.format("Player %d quit, reset their data", playerIndex))
end

function HRLApp:on_player_score(playerIndex)
    if not self.race then
        return
    end
    local now = get_time()
    self.lap_tracker:on_player_score(playerIndex, now)
end

function HRLApp:on_warp(playerIndex)
    if not self.allow_warps then
        self.lap_tracker.players[playerIndex].warps = 1
        say(playerIndex, "We just detected a warp. This lap will not count")
    end
end

function HRLApp:on_tick()
    local now = get_time()

    self.lap_limits:on_tick()

    if not self.allow_warps and self.game_started then
        self.ping_checker:check(self.lap_tracker)
    end

    if self.race and self.game_started then
        self.lap_tracker:track_checkpoints(now)
    end

    -- Process HTTP responses
    if next(self.api_client.active_requests) ~= nil then
        self.api_client:process_responses(json, say, say_all, get_var)
    end

    -- Periodic token rotation
    if self.hrl_token:should_rotate() then
        self.hrl_token:rotate()
    end
end


function HRLApp:show_help(playerIndex)
    say(playerIndex, "=== Halo Race Leaderboard ===")
    say(playerIndex, "grind - Vote to start or stop a grinding session")
    self.lap_limits:show_status(playerIndex)
    say(playerIndex, "Leaderboard: hrl.effakt.info")
end

function HRLApp:on_chat(playerIndex, message)
    local normalized = tostring(message or ""):lower():match("^%s*(.-)%s*$")

    if normalized == "grind" then
        return self.lap_limits:handle_grind_chat(playerIndex)
    elseif normalized == "help" or normalized == "info" then
        self:show_help(playerIndex)
        return false
    end

    return true
end

function HRLApp:on_server_command(playerIndex, command)
    local t = {}
    local i = 1
    for str in string.gmatch(command, "([^%s]+)") do
        t[i] = str
        i = i + 1
    end

    local cmd = t[1] and t[1]:lower() or ""

    if cmd == "help" or cmd == "info" then
        self:show_help(playerIndex)
        return false
    elseif cmd == "grind" then
        return self.lap_limits:handle_grind_chat(playerIndex)
    elseif cmd == "claimplayer" then
        say(playerIndex, "Player claims are currently disabled.")
        return false
    elseif debug == 1 and cmd == "logtime" then
        -- Debug command: force log time for player 1
        self.lap_tracker:submit_lap(1, tonumber(t[2]) or 0, {})
        return false
    end
end

function HRLApp:claim_player(playerIndex, claim_code)
    local player_hash = get_var(playerIndex, "$hash")

    local data = {
        player_hash = player_hash,
        code = claim_code
    }

    if debug == 1 then
        data.test = true
    end

    local json_str = json:encode(data)

    local api_env = debug == 1 and "dev" or "prod"
    say(playerIndex, "Your player claim request has been submitted.")
    self.api_client:post(API_URLS[api_env].claimplayer, json_str, playerIndex, "claimplayer")
end

-- =============================================================================
-- Global Instance & SAPP Callbacks
-- =============================================================================

local app = HRLApp:new()

function OnScriptLoad()
    app:on_script_load()
end

function OnScriptUnload()
    app:on_script_unload()
end

function OnGameStart()
    app:on_game_start()
end

function OnGameEnd()
    app:on_game_end()
end

function OnPlayerJoin(playerIndex)
    app:on_player_join(playerIndex)
end

function OnPlayerQuit(playerIndex)
    app:on_player_quit(playerIndex)
end

function OnPlayerScore(playerIndex)
    app:on_player_score(playerIndex)
end

function OnWarp(playerIndex)
    app:on_warp(playerIndex)
end

function OnTick()
    app:on_tick()
end

function OnChat(playerIndex, message, chat_type)
    return app:on_chat(playerIndex, message, chat_type)
end

function OnServerCommand(playerIndex, command)
    return app:on_server_command(playerIndex, command)
end
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

ffi = require("ffi")
ffi.cdef [[
    typedef void http_response;
    http_response *http_post(const char *url, const char *json);
]]
http_client = ffi.load("hrl_api")


function SendTime(URL, json)
    http_client.http_post(URL, json)
end

function SendClaim(URL, json)
   http_client.http_post(URL, json)
end


function OnScriptLoad()

	register_callback(cb['EVENT_COMMAND'], "OnServerCommand")

	if (halo_type == "PC") then
        gametype_base = 0x671340
    else
        gametype_base = 0x5F5498
    end
	register_callback(cb['EVENT_GAME_START'], "OnGameStart")
	register_callback(cb['EVENT_GAME_END'], "OnGameEnd")
	register_callback(cb['EVENT_JOIN'], "OnPlayerJoin")
   register_callback(cb['EVENT_WARP'],"OnWarp")
   register_callback(cb['EVENT_TICK'], "OnTick")

	CheckMapAndGametype(true)

	for i = 1,16 do--	Reset personal stats
		player_warps[i] = 0
		player_ping[i] = 0
		player_ping_stability[i] = {}
	end
end

function tokenizestring(inputstr, sep)
    if sep == nil then
        sep = "%s"
    end
    local t = {};
    i = 1
    for str in string.gmatch(inputstr, "([^" .. sep .. "]+)") do
        t[i] = str
        i = i + 1
    end
    return t
end

function OnServerCommand(playerIndex, Command)
    local t = tokenizestring(Command)
    count = #t
    -- /logtime time
    if debug == 1 then

        if t[1] == "logtime" then
        	logTime(playerIndex, t[2])
		   return false;
        end
    end

    if t[1] == "claimplayer" then
         claimPlayer(playerIndex, t[2])
      return false;
     end
end



function OnPlayerScore(playerIndex)


   --check ping stability

   -- Reset ping stability
	player_ping_stability[playerIndex] = {}

	-- Only record if user is driver, or walking
	local player_address = get_dynamic_player(playerIndex)
	local vehicle_objectid = read_dword(player_address + 0x11C)
  local seat = 0
	if(tonumber(vehicle_objectid) ~= 0xFFFFFFFF) then
		local vehicle = get_object_memory(tonumber(vehicle_objectid))
		local driver = read_dword(vehicle + 0x324)
		driver = get_object_memory(tonumber(driver))

		if(driver == player_address) then
      seat = 0
    else
      seat = 1
    end
  end
  if (seat == 0 and player_warps[playerIndex] == 0) then
		player = get_player(playerIndex)
		best_time = read_word(player + 0xC4)--	Player's current time
		best_time = best_time/30
		logTime(playerIndex, best_time)

	elseif (player_warps[playerIndex] == 1) then
		say(playerIndex, "We detected a warp or a lag spike, your lap time was not recorded")
	end

   -- Reset Player warps after lap
   player_warps[playerIndex] = 0
end

function claimPlayer(playerIndex, claim_code)
   current_name =  string.toutf8(get_var(playerIndex, "$name"))
   player_hash = get_var(playerIndex, "$hash")
   player_hash = player_hash

   if (debug == 1) then
      json = '{"player_hash": "'..player_hash..'", "code": "'..claim_code..'", "test": true}'
   else
      json = '{"player_hash": "'..player_hash..'", "code": "'..claim_code..'"}'
   end
   cprint(json);

   if (debug == 1) then
      URL = "http://dev.haloraceleaderboard.effakt.info/api/claimplayer"
   else
      URL = "http://haloraceleaderboard.effakt.info/api/claimplayer"
   end

   say(playerIndex, "Your player claim request has been submitted.")
   SendClaim(URL, json)

end

function logTime(playerIndex, best_time)
	

   current_name =  string.toutf8(get_var(playerIndex, "$name"))
		player_hash = get_var(playerIndex, "$hash")
		player_hash = player_hash

		-- Need to find correct addresses for these!
		--server_port = read_word(0x625230)
		--map_slug = read_string(0x63BC78)
		--map_name = read_string(0x698F21)
		map_name = ""

		if (debug == 1) then
			json = '{"port":"'..server_port..'", "player_hash": "'..player_hash..'", "player_name":"'..current_name..'", "map_name": "'..current_map..'", "map_label": "'..map_name..'", "race_type": "'..mode..'", "player_time":"'..best_time..'", "test":"true"}'
		else
			json = '{"port":"'..server_port..'", "player_hash": "'..player_hash..'", "player_name":"'..current_name..'", "map_name": "'..current_map..'", "map_label": "'..map_name..'", "race_type": "'..mode..'", "player_time":"'..best_time..'"}'
		end

      if (debug == 1) then
         URL = "http://dev.haloraceleaderboard.effakt.info/api/newtime"
      else
         URL = "http://haloraceleaderboard.effakt.info/api/newtime"
      end

	    if (debug == 1) then
         say(playerIndex, "Your time of "..best_time.." has been recorded.")
	    end

		SendTime(URL, json)
end

function OnWarp(PlayerIndex)
	if (allow_warps == false) then
		player_warps[PlayerIndex] = 1
      say(playerIndex, "We just detected a warp. This lap will not count")
	end
end

function OnPlayerJoin(playerIndex)
	if(race == false) then
		CheckMapAndGametype(false)
   end
   
   --on player join, set their ping
	player_ping[playerIndex] = GetPlayerPing(playerIndex)

	say(playerIndex, "This server runs Halo Race Leaderboard.")
	say(playerIndex, "For more information, or to see the leaderboard, go to hrl.effakt.info")
end

function CheckMapAndGametype(NewGame)
	if(get_var(1, "$gt") == "race") then--	Check if gametype is race
		current_map = get_var(1, "$map")--	Set current map
		if(NewGame == false and race == true) then
			return false
		end
		race = true
		register_callback(cb['EVENT_SCORE'], "OnPlayerScore")--  Triggers on player score, this way we don't spam the tick query.

		safe_read(true)--    Prevent server crash if no map
		if (halo_type == "PC") then
			mode = read_byte(gametype_base + 0x7C - 32)
		else
			mode = read_byte(gametype_base + 0x7C)
		end
		safe_read(false)

	else
		race = false
		unregister_callback(cb['EVENT_SCORE'])
	end
end

function OnGameStart()
	CheckMapAndGametype(true)
	game_started = true

   --at game start, we set their ping
   for i = 1,16 do
		player_ping[i] = GetPlayerPing(i)
	end

end

function ResetGameStarted()
	game_started = false
end

function OnGameEnd()
	for i = 1,16 do
      player_warps[i] = 0
		player_ping[i] = 0
		player_ping_stability[i] = {}
	end
	if(race == false or mode == 2) then
		return false
	end
end

function OnScriptUnload()
end

function OnTick()
   --only check pings if warping is not allowed
   if (allow_warps == false) then
      CheckPings()
   end
end

function CheckPings()
   current_ticks = get_var(1, "$ticks")
   time_since_last = (current_ticks - last_ping_check)


   --We check the player's pings
   if (time_since_last >= 30) then

      --loop 1 - 16
      for i = 1,16 do
         if player_present(i) then

            ping = GetPlayerPing(i)

            --only count if previous ping was not 0
            if (player_ping[i] > "0") then
               --if ping spikes higher than the thresholg
               if ((ping-player_ping[i]) > ping_threshold) then
                  player_warps[i] = 1
                  say(playerIndex, "We just detected a ping spike. This lap will not count")
               end
            end

            --set their ping to this
            player_ping[i] = ping
         end
      end

      last_ping_check = current_ticks
   end
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
      t[#t+1] = 128 + code%64
      code = floor(code/64)
      h = h > 32 and 32 or h/2
   end
   t[#t+1] = 256 - 2*h + code
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
   [0xFF] = 0x00FF,
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

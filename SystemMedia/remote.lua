------------------------------------------------------------------------------
-- System Media  (Me.System Media)
--
-- System-wide media transport + precise volume/mute + live now-playing.
-- Windows only. State is read/set via the bundled audio.ps1 helper, which uses
-- the Windows Core Audio API (IAudioEndpointVolume) for exact volume/mute and
-- the GSMTC WinRT API (GlobalSystemMediaTransportControlsSessionManager) for
-- system-wide now-playing. No external binary or installed module required.
--
-- Read model  = Pattern A: poll every POLL_MS while focused, push into layout.
-- Write model = one-shot set actions (+ optimistic echo, + quick poll-after-set).
-- The integration consumes the layout controls (np_*, volume, mute) as a
-- Home Assistant media_player.
--
-- Docs: http://www.unifiedremote.com/api
------------------------------------------------------------------------------

local fs     = libs.fs
local script = libs.script
local data   = libs.data
local kb     = libs.keyboard
local tmr    = require("timer")

-- Bundled helper; fs.absolute resolves it wherever the remote is installed.
local PS1 = fs.absolute("audio.ps1")

local POLL_MS    = 2500   -- Pattern A poll cadence (only while focused)
local CONFIRM_MS = 400    -- quick re-poll after a set (poll-after-set)

local pollId = nil
local cur    = { volume = 0, muted = false }  -- cached state (layout is write-only)

------------------------------------------------------------------------------
-- Helper invocation:  & 'audio.ps1' -Cmd <cmd> [-Value <n>]  -> stdout
------------------------------------------------------------------------------
local function run(cmd, value)
	local call = "& '" .. PS1 .. "' -Cmd '" .. cmd .. "'"
	if value ~= nil then
		call = call .. " -Value " .. tostring(value)
	end
	return script.powershell(call)
end

-- Read current state from the helper and push it into the layout controls.
-- Layout updates stream to connected clients (the integration) as events.
local function refresh()
	local ok, out = pcall(run, "getstate")
	if not ok or not out then return end
	local ok2, st = pcall(data.fromjson, out)
	if not ok2 or type(st) ~= "table" then return end

	if type(st.volume) == "number" then
		cur.volume = st.volume
		layout.volume.progress = st.volume
	end
	if type(st.muted) == "boolean" then
		cur.muted = st.muted
		layout.mute.checked = st.muted
	end

	local title = st.title or ""
	layout.np_title.text  = (title ~= "" and title) or "[Nothing playing]"
	layout.np_artist.text = st.artist or ""
	layout.np_status.text = st.status or ""
end

local function confirmSoon()
	tmr.timeout(refresh, CONFIRM_MS)
end

------------------------------------------------------------------------------
-- Lifecycle: only poll while the remote is focused.
------------------------------------------------------------------------------
events.focus = function ()
	refresh()
	pollId = tmr.interval(refresh, POLL_MS)
end

events.blur = function ()
	if pollId then
		tmr.cancel(pollId)
		pollId = nil
	end
end

------------------------------------------------------------------------------
-- Actions (write path). Optimistic echo keeps the UR layout responsive; the
-- Home Assistant side also updates optimistically on set.
------------------------------------------------------------------------------

--@help Set system volume (0-100)
--@param vol:number Volume percent (0-100)
actions.set_volume = function (vol)
	vol = math.max(0, math.min(100, math.floor((tonumber(vol) or 0) + 0.5)))
	run("setvol", vol)
	cur.volume = vol
	layout.volume.progress = vol   -- optimistic echo
	confirmSoon()
end

--@help Raise system volume
actions.volume_up = function ()
	actions.set_volume(cur.volume + 2)
end

--@help Lower system volume
actions.volume_down = function ()
	actions.set_volume(cur.volume - 2)
end

--@help Set mute state (true/false)
--@param muted:bool Mute on or off
actions.set_mute = function (muted)
	if muted then run("mute") else run("unmute") end
	cur.muted = muted and true or false
	layout.mute.checked = cur.muted   -- optimistic echo
	confirmSoon()
end

--@help Toggle mute
actions.toggle_mute = function ()
	run("togglemute")
	confirmSoon()
end

--@help Play / pause the active media session
actions.play_pause = function ()
	kb.press("mediaplaypause")
	confirmSoon()
end

--@help Next track
actions.next = function ()
	kb.press("medianext")
	confirmSoon()
end

--@help Previous track
actions.previous = function ()
	kb.press("mediaprevious")
	confirmSoon()
end

--@help Stop playback
actions.stop = function ()
	kb.press("mediastop")
	confirmSoon()
end

--@help Force an immediate state refresh
actions.update = function ()
	refresh()
end

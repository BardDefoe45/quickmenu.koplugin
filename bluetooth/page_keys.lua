-- Page turner keys for Bluetooth HID remotes.
--
-- A remote sends the standard HID keys KEY_PAGEUP / KEY_PAGEDOWN (evdev 104 /
-- 109). Kindles without hardware page buttons (PW5/PW6, Scribe, Colorsoft, …)
-- don't declare those keycodes in KOReader's event map, so without this the
-- remote's presses are dropped before they reach the reader.
--
-- Models with page buttons already declare them (with their own left/right
-- sense), so existing mappings are never overwritten; disable() restores
-- whatever was there before.

local PageKeys = {}

local KEY_PAGEUP   = 104
local KEY_PAGEDOWN = 109

local saved = nil

local function event_map()
    local Device = require("device")
    if not (Device and Device:isKindle()) then return nil end
    local input = Device.input
    if not input then return nil end
    input.event_map = input.event_map or {}
    return input.event_map
end

function PageKeys.install()
    local map = event_map()
    if not map then return false end

    if not saved then
        saved = { up = map[KEY_PAGEUP], down = map[KEY_PAGEDOWN] }
    end

    local changed = false
    if map[KEY_PAGEUP] == nil then
        map[KEY_PAGEUP] = "LPgBack"
        changed = true
    end
    if map[KEY_PAGEDOWN] == nil then
        map[KEY_PAGEDOWN] = "LPgFwd"
        changed = true
    end
    return changed
end

function PageKeys.disable()
    local map = event_map()
    if not map then return false end
    if saved then
        map[KEY_PAGEUP] = saved.up
        map[KEY_PAGEDOWN] = saved.down
        saved = nil
    end
    return true
end

function PageKeys.mapped()
    local map = event_map()
    return map ~= nil and map[KEY_PAGEUP] ~= nil and map[KEY_PAGEDOWN] ~= nil
end

return PageKeys

-- Bluetooth toggle for Kindle (Lab126 com.lab126.btfd over LIPC).
--
-- KOReader already ships the Lua bindings it uses for the Kindle Wi-Fi stack:
-- libopenlipclua (scalars, and the hasharray API) and liblipclua (scalars
-- only). The lipc-* CLI tools are the last resort.
--
-- Properties used here:
--   BTstate                int  0 = radio down, 1 = radio up
--   BTenable               str  "1:<mode>" / "0:<mode>" turn the radio on/off
--   currentBTOperatingMode int  1 = non-audio (HID remotes), 2 = audio
--   BTconnectedDevName     str  name of the connected device ("" when none)
--
-- Nothing waits synchronously: the radio takes a moment to follow BTenable, so
-- transitions poll on a UIManager timer before reporting back.

local InfoMessage  = require("ui/widget/infomessage")

local UIManager    = require("ui/uimanager")
local logger       = require("logger")

local Utils        = require("common/utils")
local _            = require("common/i18n").gettext

local Bluetooth = {}

local SERVICE = "com.lab126.btfd"

Bluetooth.STATE_OFF = 0
Bluetooth.STATE_ON  = 1

local STATE_POLL    = 0.4
local STATE_TIMEOUT = 12

-- Set while a radio transition is in flight so a second tap cannot start a
-- competing sequence.
Bluetooth.busy = false

-- ============================================================
-- LIPC plumbing
-- ============================================================
local open_lipc, scalar_lipc
local plumbed = false

local function plumb()
    if plumbed then return end
    plumbed = true

    local ok, lipc = pcall(require, "libopenlipclua")
    if ok and type(lipc) == "table" and lipc.open_no_name then
        open_lipc = lipc
    end
    if not open_lipc then
        local ok2, lipc2 = pcall(require, "liblipclua")
        if ok2 and type(lipc2) == "table" and lipc2.init then
            scalar_lipc = lipc2
        end
    end
end

local function with_open(cb)
    plumb()
    if not open_lipc then return nil end
    local ok, handle = pcall(open_lipc.open_no_name)
    if not ok or not handle then
        logger.warn("[quickmenu] bluetooth: could not open a lipc handle:", handle)
        return nil
    end
    local ok_call, result = pcall(cb, handle)
    pcall(handle.close, handle)
    if not ok_call then
        logger.warn("[quickmenu] bluetooth: lipc call failed:", result)
        return nil
    end
    return result
end

local function cli_get_int(prop)
    local f = io.popen(string.format("lipc-get-prop -i %s %s 2>/dev/null", SERVICE, prop), "r")
    if not f then return nil end
    local out = f:read("*a") or ""
    f:close()
    return tonumber(out:match("%-?%d+"))
end

local function cli_get_str(prop)
    local f = io.popen(string.format("lipc-get-prop %s %s 2>/dev/null", SERVICE, prop), "r")
    if not f then return nil end
    local out = f:read("*a") or ""
    f:close()
    out = out:gsub("%s+$", "")
    -- LIPC prints values wrapped in square brackets.
    out = out:gsub("^%[(.*)%]$", "%1")
    if out == "" then return nil end
    return out
end

local function cli_set(prop, value, is_int)
    local flag = is_int and "-i" or "-s"
    local ok = os.execute(string.format("lipc-set-prop %s %s %s %q 2>/dev/null",
        flag, SERVICE, prop, tostring(value)))
    return ok == true or ok == 0
end

local function get_int(prop)
    plumb()
    if open_lipc then
        local value = with_open(function(h) return h:get_int_property(SERVICE, prop) end)
        if value ~= nil then return value end
    end
    if scalar_lipc then
        local ok, handle = pcall(scalar_lipc.init, "com.github.koreader.quickmenu.bt")
        if ok and handle then
            local ok_get, value = pcall(handle.get_int_property, handle, SERVICE, prop)
            pcall(handle.close, handle)
            if ok_get and value ~= nil then return value end
        end
    end
    return cli_get_int(prop)
end

local function get_str(prop)
    plumb()
    if open_lipc then
        local value = with_open(function(h) return h:get_string_property(SERVICE, prop) end)
        if value ~= nil then return value end
    end
    if scalar_lipc then
        local ok, handle = pcall(scalar_lipc.init, "com.github.koreader.quickmenu.bt")
        if ok and handle then
            local ok_get, value = pcall(handle.get_string_property, handle, SERVICE, prop)
            pcall(handle.close, handle)
            if ok_get and value ~= nil then return value end
        end
    end
    return cli_get_str(prop)
end

local function set_str(prop, value)
    plumb()
    if open_lipc then
        local done = with_open(function(h)
            h:set_string_property(SERVICE, prop, value)
            return true
        end)
        if done then return true end
    end
    if scalar_lipc then
        local ok, handle = pcall(scalar_lipc.init, "com.github.koreader.quickmenu.bt")
        if ok and handle then
            local ok_set = pcall(handle.set_string_property, handle, SERVICE, prop, value)
            pcall(handle.close, handle)
            if ok_set then return true end
        end
    end
    return cli_set(prop, value, false)
end

-- ============================================================
-- State
-- ============================================================
local cache = { time = -1, status = nil }

-- -> { available, state, name }
-- Cached for a second so the menu tab (icon + label + active color) pays for a
-- single LIPC round trip per render.
function Bluetooth.status(force)
    local now = os.time()
    if not force and cache.status and now - cache.time <= 1 then
        return cache.status
    end

    local state = get_int("BTstate")
    local status = { available = state ~= nil, state = state }
    if state ~= nil and state ~= Bluetooth.STATE_OFF then
        local name = get_str("BTconnectedDevName")
        if name == "" then name = nil end
        status.name = name
    end

    cache.time, cache.status = now, status
    return status
end

function Bluetooth.available()
    return Bluetooth.status().available
end

function Bluetooth.is_on()
    local state = Bluetooth.status().state
    return state ~= nil and state ~= Bluetooth.STATE_OFF
end

function Bluetooth.invalidate()
    cache.time, cache.status = -1, nil
end

-- ============================================================
-- Radio control
-- ============================================================
-- Writes BTenable with the second field matching the radio's current operating
-- mode, so switching the radio does not move a page-turner/HID setup (mode 1)
-- into the audio profile (mode 2) or vice versa.
local function write_radio(on)
    local mode = get_int("currentBTOperatingMode")
    if mode ~= 1 and mode ~= 2 then mode = 1 end
    local ok = set_str("BTenable", (on and "1:" or "0:") .. mode)
    Bluetooth.invalidate()
    return ok
end

local function await_state(target, done)
    local deadline = os.time() + STATE_TIMEOUT
    local function poll()
        local state = Bluetooth.status(true).state
        if state == target then
            done(true)
        elseif os.time() >= deadline then
            logger.warn("[quickmenu] bluetooth: radio did not reach state " .. tostring(target))
            done(false, "timeout")
        else
            UIManager:scheduleIn(STATE_POLL, poll)
        end
    end
    UIManager:scheduleIn(STATE_POLL, poll)
end

-- set_enabled(on, done)
--   done(ok, reason)
function Bluetooth.set_enabled(on, done)
    done = done or function() end

    if not Bluetooth.available() then return false, "unavailable" end
    if Bluetooth.busy then return done(false, "busy") end

    local target = on and Bluetooth.STATE_ON or Bluetooth.STATE_OFF
    if Bluetooth.status(true).state == target then
        done(true)
        return true
    end

    Bluetooth.busy = true
    if not write_radio(on) then
        Bluetooth.busy = false
        done(false, "write failed")
        return false
    end

    await_state(target, function(ok, err)
        Bluetooth.busy = false
        done(ok, err)
    end)
    return true
end

-- ============================================================
-- Quick action (tap toggles, with progress feedback)
-- ============================================================
local ICON_ON        = "\u{E7AE}" -- bluetooth
local ICON_CONNECTED = "\u{E7B0}" -- bluetooth-connect
local ICON_OFF       = "\u{E7B1}" -- bluetooth-off

function Bluetooth.action_icon()
    local status = Bluetooth.status()
    if not status.available then return ICON_OFF end
    if status.state == Bluetooth.STATE_OFF then return ICON_OFF end
    if status.name then return ICON_CONNECTED end
    return ICON_ON
end

function Bluetooth.action_label()
    local status = Bluetooth.status()
    if not status.available then return _("n/a") end
    if status.state == Bluetooth.STATE_OFF then return _("Off") end
    if status.name then return status.name end
    return _("On")
end

function Bluetooth.is_active()
    local status = Bluetooth.status()
    return status.available and status.state ~= Bluetooth.STATE_OFF
end

local function toast(text)
    UIManager:show(InfoMessage:new{ text = text, timeout = 3 })
end

function Bluetooth.toggle(ctx)
    local status = Bluetooth.status(true)
    if not status.available then
        toast(_("Bluetooth control is not available on this device."))
        return false
    end
    if Bluetooth.busy then return false end

    local on = status.state == Bluetooth.STATE_OFF
    local progress = InfoMessage:new{
        text = on and _("Bluetooth: turning on…") or _("Bluetooth: turning off…"),
    }
    UIManager:show(progress)

    Bluetooth.set_enabled(on, function(ok, reason)
        UIManager:close(progress)
        if not ok then
            logger.warn("[quickmenu] bluetooth toggle failed:", reason)
            toast(_("Could not switch Bluetooth. Try again from the system menu."))
        end
        if ctx and ctx.touch_menu then
            Utils.updateMenu(ctx.touch_menu, { delay = 0.5 })
        end
    end)
    return true
end

return Bluetooth

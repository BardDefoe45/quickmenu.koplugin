-- Bluetooth backend for Kindle (Lab126 com.lab126.btfd over LIPC).
--
-- The Kindle Bluetooth daemon is reachable over LIPC; KOReader already ships
-- the Lua bindings it uses for the Wi-Fi stack:
--   * libopenlipclua: scalars and hasharray properties (device lists)
--   * liblipclua:     scalars only (fallback)
-- and the lipc-* CLI tools as a last resort.
--
-- Property semantics (verified on-device, see the reverse-engineering notes in
-- KinAMP's kinamp_bt.lua and the KindleModding wiki):
--
--   BTstate               int   0 = radio down, 1 = radio up
--   BTenable              str   "1:<mode>" / "0:<mode>" turn the radio on/off
--   currentBTOperatingMode int 1 = non-audio (HID remotes), 2 = audio
--   ensureBTconnection    int   inhibits the idle disconnect (read at radio init)
--   BTconnectedDevName    str   name of the connected device ("" when none)
--   ListPaired            hash  paired devices
--   ListConnected         hash  currently connected devices
--   ListDiscovered        hash  devices seen by the last scan
--   triggerBTscan         int   start a scan
--   Connect / Disconnect  str   MAC address to act on
--   Bond / Unbond         str   MAC address to pair / forget
--
-- Nothing here waits synchronously: the radio takes a second or two to follow
-- BTenable, so transitions poll on a UIManager timer and report back through a
-- callback.

local logger    = require("logger")
local UIManager = require("ui/uimanager")

local Backend = {}

local SERVICE = "com.lab126.btfd"

Backend.STATE_OFF = 0
Backend.STATE_ON  = 1

-- Polling for radio transitions / connect results.
local STATE_POLL    = 0.4
local STATE_TIMEOUT = 12
local LINK_POLL     = 1
local LINK_TIMEOUT  = 15

-- Set while a radio transition is in flight so a second tap can't start a
-- competing sequence.
Backend.busy = false

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
    local cmd = string.format("lipc-set-prop %s %s %s %q 2>/dev/null", flag, SERVICE, prop, tostring(value))
    local ok = os.execute(cmd)
    return ok == true or ok == 0
end

function Backend.get_int(prop)
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

function Backend.get_str(prop)
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

local function set_int(prop, value)
    plumb()
    if open_lipc then
        local done = with_open(function(h)
            h:set_int_property(SERVICE, prop, value)
            return true
        end)
        if done then return true end
    end
    if scalar_lipc then
        local ok, handle = pcall(scalar_lipc.init, "com.github.koreader.quickmenu.bt")
        if ok and handle then
            local ok_set = pcall(handle.set_int_property, handle, SERVICE, prop, value)
            pcall(handle.close, handle)
            if ok_set then return true end
        end
    end
    return cli_set(prop, value, true)
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
-- Device lists (hasharray properties)
-- ============================================================
local ADDRESS_KEYS = { "address", "bdaddr", "bdAddr", "mac", "deviceAddress", "addr", "id" }
local NAME_KEYS    = { "name", "deviceName", "friendlyName", "displayName" }
local MAC_PATTERN  = "^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$"

local function normalize_mac(value)
    if type(value) ~= "string" then return nil end
    value = value:gsub("-", ":"):upper()
    if value:match(MAC_PATTERN) then return value end
end

local function first_field(row, keys)
    for _, key in ipairs(keys) do
        local value = row[key]
        if type(value) == "string" and value ~= "" then
            return value
        end
    end
end

-- The hash key names inside ListPaired/ListConnected differ between firmware
-- versions, so both the MAC and the display name are discovered at read time.
local function normalize_device(row, source)
    if type(row) ~= "table" then return nil end

    local mac = normalize_mac(first_field(row, ADDRESS_KEYS))
    if not mac then
        for _, value in pairs(row) do
            mac = normalize_mac(value)
            if mac then break end
        end
    end
    if not mac then return nil end

    local name = first_field(row, NAME_KEYS)
    if not name then
        -- A device name is the only free text in these records, so take the
        -- longest string that isn't the address itself.
        for _, value in pairs(row) do
            if type(value) == "string" and value ~= "" and not value:match(MAC_PATTERN) then
                if not name or #value > #name then name = value end
            end
        end
    end

    return { mac = mac, name = name or mac, source = source, raw = row }
end

local function read_list(prop)
    local entries = with_open(function(h)
        local ha_in = h:new_hasharray()
        local got, ha_out = pcall(h.access_hash_property, h, SERVICE, prop, ha_in)
        if not got or not ha_out then
            pcall(ha_in.destroy, ha_in)
            return nil
        end
        local parsed, table_out = pcall(ha_out.to_table, ha_out)
        if ha_out ~= ha_in then pcall(ha_out.destroy, ha_out) end
        pcall(ha_in.destroy, ha_in)
        if not parsed then return nil end
        return table_out or {}
    end)
    return entries
end

local function device_list(prop, source)
    local entries = read_list(prop)
    if not entries then return nil end
    local devices = {}
    for _, entry in ipairs(entries) do
        local device = normalize_device(entry, source)
        if device then devices[#devices + 1] = device end
    end
    return devices
end

function Backend.paired()     return device_list("ListPaired", "paired") end
function Backend.connected()  return device_list("ListConnected", "connected") end
function Backend.discovered() return device_list("ListDiscovered", "discovered") end

-- ============================================================
-- State
-- ============================================================
local cache = { time = -1, status = nil }

-- ::status() -> { available, state, name }
-- Cached for a second so the menu tab (icon + label + active color) only pays
-- for one LIPC round trip per render.
function Backend.status(force)
    local now = os.time()
    if not force and cache.status and now - cache.time <= 1 then
        return cache.status
    end

    local state = Backend.get_int("BTstate")
    local status = { available = state ~= nil, state = state }
    if state ~= nil and state ~= Backend.STATE_OFF then
        local name = Backend.get_str("BTconnectedDevName")
        if name == "" then name = nil end
        status.name = name
    end

    cache.time, cache.status = now, status
    return status
end

function Backend.state() return Backend.status().state end

function Backend.is_on()
    local state = Backend.status().state
    return state ~= nil and state ~= Backend.STATE_OFF
end

function Backend.invalidate()
    cache.time, cache.status = -1, nil
end

-- A btfd that answers is what "Bluetooth control available" means: the
-- 11th generation Kindles drive libace_bt instead and answer nothing.
function Backend.available()
    return Backend.status().available
end

function Backend.radio_mode()
    local mode = Backend.get_int("currentBTOperatingMode")
    if mode ~= 1 and mode ~= 2 then mode = 1 end
    return mode
end

-- btfd documents ensureBTconnection as an int but the stock sequence writes it
-- with lipc-set-prop -i, and some firmwares only take the string form.
local function set_keepalive(on)
    local value = on and 1 or 0
    if set_int("ensureBTconnection", value) then return true end
    return set_str("ensureBTconnection", tostring(value))
end

-- Writes BTenable with the second field matching the radio's current operating
-- mode, so a page-turner/HID setup (mode 1) is not silently pushed into the
-- audio profile (mode 2) and vice versa.
local function write_radio(on)
    local ok = set_str("BTenable", (on and "1:" or "0:") .. Backend.radio_mode())
    Backend.invalidate()
    return ok
end

local function await_state(target, done)
    local deadline = os.time() + STATE_TIMEOUT
    local function poll()
        local state = Backend.status(true).state
        if state == target then
            Backend.invalidate()
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

-- set_enabled(on, opts, done)
--   opts.keepalive  write the idle-disconnect inhibitor around the transition
--                   (btfd only reads it while the radio initialises)
--   done(ok, reason)
function Backend.set_enabled(on, opts, done)
    done = done or function() end
    opts = opts or {}

    if not Backend.available() then return false, "unavailable" end
    if Backend.busy then return done(false, "busy") end

    local target = on and Backend.STATE_ON or Backend.STATE_OFF
    if Backend.state() == target then
        -- Flag can still be lowered for a radio that is already up; raising it
        -- there would be ignored, so it is applied at the next transition.
        if not on and opts.keepalive then set_keepalive(false) end
        done(true)
        return true
    end

    Backend.busy = true
    if opts.keepalive then
        -- Written while the radio is still down (turning on) or about to go
        -- down (turning off), which is the only point btfd reads it.
        set_keepalive(on)
    end

    if not write_radio(on) then
        Backend.busy = false
        done(false, "write failed")
        return false
    end

    await_state(target, function(ok, err)
        Backend.busy = false
        done(ok, err)
    end)
    return true
end

-- ============================================================
-- Scan / pair / connect
-- ============================================================
function Backend.scan()
    if not Backend.available() then return false, "unavailable" end
    local ok = set_int("triggerBTscan", 1)
    if not ok then ok = set_int("DiscoverA2DP", 1) end
    return ok
end

local function connected_macs()
    local set = {}
    for _, device in ipairs(Backend.connected() or {}) do
        set[device.mac] = true
    end
    return set
end

function Backend.connect(mac, done)
    if not mac then
        if done then done(false, "no address") end
        return false
    end
    if not set_str("Connect", mac) then
        if done then done(false, "write failed") end
        return false
    end
    if not done then return true end

    local wanted = mac:upper()
    local deadline = os.time() + LINK_TIMEOUT
    local function poll()
        if connected_macs()[wanted] then
            Backend.invalidate()
            done(true, Backend.status(true).name)
        elseif os.time() >= deadline then
            logger.warn("[quickmenu] bluetooth: " .. mac .. " did not connect")
            done(false, "timeout")
        else
            UIManager:scheduleIn(LINK_POLL, poll)
        end
    end
    UIManager:scheduleIn(LINK_POLL, poll)
    return true
end

function Backend.disconnect(mac, done)
    if not mac then
        if done then done(false, "no address") end
        return false
    end
    if not set_str("Disconnect", mac) then
        if done then done(false, "write failed") end
        return false
    end
    if not done then return true end

    local wanted = mac:upper()
    local deadline = os.time() + LINK_TIMEOUT
    local function poll()
        if not connected_macs()[wanted] then
            Backend.invalidate()
            done(true)
        elseif os.time() >= deadline then
            done(false, "timeout")
        else
            UIManager:scheduleIn(LINK_POLL, poll)
        end
    end
    UIManager:scheduleIn(LINK_POLL, poll)
    return true
end

function Backend.bond(mac)
    if not mac then return false end
    local ok = set_str("Bond", mac)
    Backend.invalidate()
    return ok
end

function Backend.unbond(mac)
    if not mac then return false end
    local ok = set_str("Unbond", mac)
    Backend.invalidate()
    return ok
end

-- ============================================================
-- HID / page turner helpers
-- ============================================================
-- A Bluetooth HID remote shows up as a new /dev/input/event* device once it is
-- connected (either the raw HID node or the "kindle-input-pt" virtual device
-- that input_manager creates for it). KOReader only enumerates input devices at
-- startup, so after a (re)connect those devices have to be opened on demand.
--
-- Kindle:openInputDevices() is not reusable here: it runs a fresh FBInk scan
-- plus self.input:open("fake_events"), and the latter forks another fake event
-- generator each time. Instead, only devices that actually report the page turn
-- keys are opened, whatever else appears on the bus is left alone.

local PAGE_KEY_CODES = { 104, 109 } -- KEY_PAGEUP / KEY_PAGEDOWN

-- Overridable so the scan can be exercised off-device.
Backend.SYSFS_INPUT = "/sys/class/input"

-- Sysfs prints the key capability bitmap as space-separated longs, most
-- significant word first (linux/drivers/input/input.c::input_print_bitmap), so
-- the word size has to come from ffi to index it correctly. Real devices hang
-- the file off "device/", uinput (and the kindle-input-pt virtual device) off
-- the event node itself, so both are tried.
local CAPABILITY_PATHS = {
    "/device/capabilities/key",
    "/capabilities/key",
}

local function read_capability(sys_event_path)
    for _, suffix in ipairs(CAPABILITY_PATHS) do
        local f = io.open(sys_event_path .. suffix, "r")
        if f then
            local hex = f:read("*l") or ""
            f:close()
            return hex
        end
    end
end

local function key_capability_set(sys_event_path, code)
    local hex = read_capability(sys_event_path)
    if not hex then return nil end
    local words = {}
    for token in hex:gmatch("%x+") do
        table.insert(words, 1, tonumber(token, 16) or 0)
    end
    if #words == 0 then return nil end

    local ok_size, word_size = pcall(function()
        local ffi = require("ffi")
        return ffi.sizeof("long") * 8
    end)
    if not ok_size then return nil end

    local word = words[math.floor(code / word_size) + 1]
    if not word then return false end
    local bit = require("bit")
    return bit.band(word, bit.lshift(1, code % word_size)) ~= 0
end

local function find_new_key_devices()
    local lfs = require("libs/libkoreader-lfs")
    local Input = require("device/input")
    local opened = Input and Input.opened_devices or {}

    local paths = {}
    local ok, iter = pcall(lfs.dir, "/dev/input")
    if not ok or not iter then return paths end
    for name in iter do
        if name:match("^event%d+$") then
            local path = "/dev/input/" .. name
            if not opened[path] then
                local sys_path = Backend.SYSFS_INPUT .. "/" .. name
                local wanted = false
                for _, code in ipairs(PAGE_KEY_CODES) do
                    if key_capability_set(sys_path, code) then
                        wanted = true
                        break
                    end
                end
                if wanted then paths[#paths + 1] = path end
            end
        end
    end
    return paths
end

-- Opens any newly appeared page turner device. Returns opened_count, or
-- false + reason when this cannot work on the current platform.
function Backend.rescan_input()
    local Device = require("device")
    if not (Device and Device.input and Device.input.open) then
        return false, "unsupported"
    end
    if not Device:isKindle() then
        return false, "unsupported"
    end

    local ok, paths = pcall(find_new_key_devices)
    if not ok then
        logger.warn("[quickmenu] bluetooth: input scan failed:", paths)
        return false, paths
    end

    local opened = 0
    for _, path in ipairs(paths) do
        local ok_open, err = pcall(Device.input.open, Device.input, path)
        if ok_open then
            opened = opened + 1
            logger.info("[quickmenu] bluetooth: opened input device", path)
        else
            logger.warn("[quickmenu] bluetooth: could not open", path, err)
        end
    end
    return true, opened
end

return Backend

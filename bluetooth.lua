-- Native Kindle Bluetooth toggle.
--
-- The panel button is the whole feature; everything else here exists because
-- "turn the radio on/off" is not one API on Kindle, it is three:
--
--   * 8th-10th gen (Broadcom): com.lab126.btfd over LIPC,
--       BTstate (read) / BTenable "1:1" / "0:1" (write)
--   * 11th-12th gen (MediaTek): the same btfd LIPC facade, but the radio is
--     actually driven by the ace_bt stack (acsbtfd / btmanagerd,
--     /usr/bin/ace_bt_cli enable|disable|radiostate)
--   * the MediaTek CONSYS power switch, /usr/bin/wmt_cli bluetooth on|off
--
-- On some firmwares the btfd write is accepted yet nothing follows (wrong
-- value format "0:2" vs "0:1", or btfd only proxies), so a toggle walks a
-- strategy chain and verifies the state after every step instead of trusting
-- the write. When everything fails the chain's trace is what the diagnostics
-- report is for.

local InfoMessage = require("ui/widget/infomessage")

local DataStorage = require("datastorage")
local UIManager   = require("ui/uimanager")
local logger      = require("logger")

local Utils       = require("common/utils")
local _           = require("common/i18n").gettext

local Bluetooth = {}

local BTFD = "com.lab126.btfd"

Bluetooth.STATE_OFF = 0
Bluetooth.STATE_ON  = 1

local POLL_INTERVAL = 0.5
local POLL_TRIES    = 12 -- 6s per strategy

Bluetooth.busy = false

-- ============================================================
-- Debug / trace
-- ============================================================
local debug_enabled = false
local trace = {}

local function trace_line(fmt, ...)
    local msg
    if select("#", ...) > 0 then msg = string.format(fmt, ...) else msg = fmt end
    trace[#trace + 1] = os.date("%H:%M:%S") .. "  " .. msg
    if #trace > 100 then table.remove(trace, 1) end
    if debug_enabled then
        logger.warn("[quickmenu][bt] " .. msg)
    else
        logger.dbg("[quickmenu][bt] " .. msg)
    end
end

function Bluetooth.set_debug(on)
    debug_enabled = on == true
    trace_line("debug logging " .. (debug_enabled and "enabled" or "disabled"))
end

function Bluetooth.is_debug()
    return debug_enabled
end

-- ============================================================
-- Last known state
-- ============================================================
-- Set once btfd has answered, so its write strategies stay in the chain even
-- while the stack is down.
local btfd_seen = false
-- Set once a control mechanism was found on this device.
local sticky_capable = false

-- With the radio off the Bluetooth stack may be down entirely, and then the
-- current state cannot be read at all. The last state we saw is remembered
-- (and persisted by the plugin) so the button can still say on/off and know
-- which way to toggle.
local state_hint = Bluetooth.STATE_OFF
local persist_state = nil
local config = nil
local save_config = nil

function Bluetooth.set_state_hint(state)
    if state == Bluetooth.STATE_ON or state == Bluetooth.STATE_OFF then
        state_hint = state
    end
end

function Bluetooth.set_state_persister(fn)
    persist_state = fn
end

-- The plugin hands over its config so the last known state and the "this
-- device can switch Bluetooth" fact survive a restart: with the radio off the
-- stack can be down, and then neither is readable from the device.
function Bluetooth.attach_config(cfg, save)
    config = cfg
    save_config = save
    if type(cfg) == "table" then
        Bluetooth.set_state_hint(cfg.bluetooth_state)
        if cfg.bluetooth_capable == true then sticky_capable = true end
    end
end

local function save_now()
    if save_config then pcall(save_config) end
end

local function remember_state(on)
    state_hint = on and Bluetooth.STATE_ON or Bluetooth.STATE_OFF
    if type(config) == "table" then config.bluetooth_state = state_hint end
    if persist_state then pcall(persist_state, state_hint) end
    save_now()
end

-- ============================================================
-- LIPC plumbing
-- ============================================================
local open_lipc, scalar_lipc
local plumbed = false

local master_handle   -- libopenlipclua anonymous handle (reads + writes)
local master_tried = false
local scalar_handle   -- liblipclua named handle (writes)
local scalar_tried = false

local function plumb()
    if plumbed then return end
    plumbed = true
    local ok, lipc = pcall(require, "libopenlipclua")
    if ok and type(lipc) == "table" and lipc.open_no_name then open_lipc = lipc end
    local ok2, lipc2 = pcall(require, "liblipclua")
    if ok2 and type(lipc2) == "table" and lipc2.init then scalar_lipc = lipc2 end
    trace_line("libopenlipclua=%s liblipclua=%s",
        tostring(open_lipc ~= nil), tostring(scalar_lipc ~= nil))
end

local function get_master()
    if master_handle then return master_handle end
    if master_tried then return nil end
    master_tried = true
    plumb()
    if not open_lipc then return nil end
    local ok, handle = pcall(open_lipc.open_no_name)
    if ok and handle then
        master_handle = handle
    else
        trace_line("open_no_name failed: %s", tostring(handle))
    end
    return master_handle
end

local function get_scalar()
    if scalar_handle then return scalar_handle end
    if scalar_tried then return nil end
    scalar_tried = true
    plumb()
    if not scalar_lipc then return nil end
    local ok, handle = pcall(scalar_lipc.init, "com.github.koreader.quickmenu")
    if ok and handle then
        scalar_handle = handle
    else
        trace_line("liblipclua init failed: %s", tostring(handle))
    end
    return scalar_handle
end

local function sh(cmd)
    local f = io.popen(cmd .. " 2>&1 < /dev/null", "r")
    if not f then
        trace_line("$ %s  (no shell)", cmd)
        return nil
    end
    local out = f:read("*a") or ""
    f:close()
    out = out:gsub("%s+$", "")
    trace_line("$ %s\n%s", cmd, out)
    return out
end

local function read_int(prop)
    local h = get_master()
    if h then
        local ok, value = pcall(h.get_int_property, h, BTFD, prop)
        if ok and value ~= nil then
            trace_line("btfd.%s = %s (openlipc)", prop, tostring(value))
            return value
        end
        trace_line("btfd.%s read failed (openlipc): %s", prop, tostring(value))
    end
    local s = get_scalar()
    if s then
        local ok, value = pcall(s.get_int_property, s, BTFD, prop)
        if ok and value ~= nil then
            trace_line("btfd.%s = %s (liblipclua)", prop, tostring(value))
            return value
        end
        trace_line("btfd.%s read failed (liblipclua): %s", prop, tostring(value))
    end
    local out = sh(string.format("lipc-get-prop -i %s %s", BTFD, prop))
    -- Strict: a shell error ("sh: 1: lipc-get-prop: not found") must not be
    -- mistaken for a value.
    local value = out and tonumber(out:match("^%s*(%-?%d+)%s*$"))
    if value ~= nil then trace_line("btfd.%s = %s (lipc CLI)", prop, tostring(value)) end
    return value
end

local function read_str(prop)
    local h = get_master()
    if h then
        local ok, value = pcall(h.get_string_property, h, BTFD, prop)
        if ok and value ~= nil then
            trace_line("btfd.%s = %q (openlipc)", prop, tostring(value))
            return value
        end
        trace_line("btfd.%s read failed (openlipc): %s", prop, tostring(value))
    end
    local out = sh(string.format("lipc-get-prop %s %s", BTFD, prop))
    if out then
        out = out:gsub("^%[(.*)%]$", "%1")
        trace_line("btfd.%s = %q (lipc CLI)", prop, out)
        return out
    end
end

-- Raises nothing; returns true only when the binding accepted the write.
local function write_str(prop, value)
    local h = get_master()
    if h then
        local ok, err = pcall(h.set_string_property, h, BTFD, prop, value)
        trace_line("%s = %q (openlipc) -> %s", prop, value, ok and "ok" or tostring(err))
        if ok then return true, "openlipc" end
    end
    local s = get_scalar()
    if s then
        local ok, err = pcall(s.set_string_property, s, BTFD, prop, value)
        trace_line("%s = %q (liblipclua) -> %s", prop, value, ok and "ok" or tostring(err))
        if ok then return true, "liblipclua" end
    end
    -- The stock scripts (LARKPlayer, KinAMP, kindle-hid-passthrough) all use
    -- lipc-set-prop, so the CLI is the authoritative form.
    local out = sh(string.format("lipc-set-prop -s %s %s %q", BTFD, prop, value))
    -- lipc-set-prop prints nothing on success; a non-empty reply is an error.
    if out ~= nil then
        trace_line("%s = %q (lipc CLI) -> %s", prop, value,
            out == "" and "ok" or ("error: " .. out))
        return out == "", "cli"
    end
    return false
end

local function write_int(prop, value)
    local h = get_master()
    if h then
        local ok, err = pcall(h.set_int_property, h, BTFD, prop, value)
        trace_line("%s = %s (openlipc) -> %s", prop, tostring(value), ok and "ok" or tostring(err))
        if ok then return true end
    end
    local out = sh(string.format("lipc-set-prop -i %s %s %s", BTFD, prop, tostring(value)))
    return out == ""
end

-- ============================================================
-- State readers
-- ============================================================
local function binary(path)
    local lfs = require("libs/libkoreader-lfs")
    return lfs.attributes(path, "mode") == "file"
end

-- Overridable so the paths can be pointed elsewhere (and so the test harness
-- can substitute them).
Bluetooth.ACE_CLI  = "/usr/bin/ace_bt_cli"
Bluetooth.WMT_CLI  = "/usr/bin/wmt_cli"
Bluetooth.BCM_PROC = "/proc/bluetooth/btenable"
Bluetooth.INITCTL  = "/sbin/initctl"
Bluetooth.INIT_CONF_DIRS = { "/etc/init", "/etc/upstart" }
Bluetooth.INIT_JOBS = { "acsbtfd", "btmanagerd" }

local ace_present = nil

local function has_ace()
    if ace_present == nil then ace_present = binary(Bluetooth.ACE_CLI) end
    return ace_present
end

-- `ace_bt_cli radiostate` -> "ACEBTCLI getRadioState() state:1 status:0".
-- The tool also has a REPL, so fall back to feeding the command over stdin.
local function ace_state()
    if not has_ace() then return nil end
    local s = sh(Bluetooth.ACE_CLI .. " radiostate")
    s = s and s:match("state%s*:%s*(%d)")
    if not s then
        s = sh(string.format("printf 'radiostate\\n' | %s", Bluetooth.ACE_CLI))
        s = s and s:match("state%s*:%s*(%d)")
    end
    if s then return tonumber(s) end
end

local function ace_write(on)
    if not has_ace() then return false end
    local cmd = on and "enable" or "disable"
    local out = sh(Bluetooth.ACE_CLI .. " " .. cmd)
    if out ~= nil and out:find("state", 1, true) then return true end
    -- REPL form, used when the argument form is not understood.
    sh(string.format("printf '%s\\n' | %s", cmd, Bluetooth.ACE_CLI))
    return true
end

local function wmt_present()
    return binary(Bluetooth.WMT_CLI)
end

local function wmt_write(on)
    if not wmt_present() then return false end
    sh(string.format("%s bluetooth %s", Bluetooth.WMT_CLI, on and "on" or "off"))
    return true
end

-- Status for the button: btfd's BTstate when it answers, ace_bt_cli otherwise.
-- Cached for a second so a panel render costs one LIPC call at most.
--
-- state_source remembers which backend actually moved the radio last time:
-- on some firmwares btfd answers but its BTstate does not follow the radio,
-- and then the button would show a stale state.
local cache = { time = -1, status = nil }
local state_source = nil

local function read_state_ace()
    local astate = ace_state()
    if astate == nil then return nil end
    return (astate ~= 0) and Bluetooth.STATE_ON or Bluetooth.STATE_OFF
end

local function read_state_btfd()
    local v = read_int("BTstate")
    if v == nil then return nil end
    btfd_seen = true
    return (v ~= 0) and Bluetooth.STATE_ON or Bluetooth.STATE_OFF
end

function Bluetooth.status(force)
    local now = os.time()
    if not force and cache.status and now - cache.time <= 1 then
        return cache.status
    end

    local status = { available = false, readable = false }
    local state
    if state_source == "ace" then
        state = read_state_ace() or read_state_btfd()
        status.source = "ace"
    else
        state = read_state_btfd()
        status.source = "btfd"
        if state == nil then
            state = read_state_ace()
            status.source = "ace_bt_cli"
        end
    end
    if state ~= nil then
        status.available = true
        status.readable = true
        status.state = state
        state_hint = state
    else
        -- The stack is down: we cannot read the radio, so the last known
        -- state is what the button shows.
        status.state = state_hint
    end

    if status.state == Bluetooth.STATE_ON and status.readable then
        local name = read_str("BTconnectedDevName")
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
    return Bluetooth.status().state == Bluetooth.STATE_ON
end

function Bluetooth.invalidate()
    cache.time, cache.status = -1, nil
end

-- ============================================================
-- Can this device be asked to switch Bluetooth at all?
-- ============================================================
-- Deliberately not the same question as "is the radio on right now": with the
-- radio off the Bluetooth stack can be down entirely, and then nothing
-- answers. Hiding the button in that state would leave no way to turn the
-- radio back on, so the button stays whenever a control mechanism exists.
local function has_initctl_jobs()
    if not binary(Bluetooth.INITCTL) then return false end
    for _, dir in ipairs(Bluetooth.INIT_CONF_DIRS) do
        for _, job in ipairs(Bluetooth.INIT_JOBS) do
            if binary(dir .. "/" .. job .. ".conf") then return true end
        end
    end
    return false
end

function Bluetooth.can_control()
    if sticky_capable then return true end
    local found = has_ace() or wmt_present() or binary(Bluetooth.BCM_PROC) or has_initctl_jobs()
    if not found and (btfd_seen or read_int("BTstate") ~= nil) then
        found = true
        btfd_seen = true
    end
    if found then
        sticky_capable = true
        if type(config) == "table" and config.bluetooth_capable ~= true then
            config.bluetooth_capable = true
            save_now()
        end
        return true
    end
    return false
end

-- ============================================================
-- Strategies
-- ============================================================
-- Each one: apply(on) performs the write, read() returns 0/1/nil, ok reports
-- whether the strategy is usable on this device at all.
--
-- The order differs per direction: turning the radio on may need the stock
-- daemons up first (they are down once the radio was switched off), while
-- turning it off is cleanest through the daemon that owns the radio.
local function btfd_strategies(on)
    local value_pair = on and "1:1" or "0:1"
    local value_plain = on and "1" or "0"
    return {
        {
            name = "btfd BTenable pair (" .. value_pair .. ")",
            source = "btfd",
            ok = function() return btfd_seen or read_int("BTstate") ~= nil end,
            apply = function() write_str("BTenable", value_pair) end,
            read = function() local v = read_int("BTstate"); return v and ((v ~= 0) and 1 or 0) end,
        },
        {
            name = "btfd BTenable plain (" .. value_plain .. ")",
            source = "btfd",
            ok = function() return btfd_seen or read_int("BTstate") ~= nil end,
            apply = function() write_str("BTenable", value_plain) end,
            read = function() local v = read_int("BTstate"); return v and ((v ~= 0) and 1 or 0) end,
        },
    }
end

local function upstart_strategy(on)
    return {
        name = on and "upstart start acsbtfd / btmanagerd"
                or "upstart stop acsbtfd / btmanagerd",
        source = "ace",
        ok = function() return has_initctl_jobs() end,
        apply = function()
            local action = on and "start" or "stop"
            for _, job in ipairs(Bluetooth.INIT_JOBS) do
                sh(string.format("%s %s %s", Bluetooth.INITCTL, action, job))
            end
        end,
        read = ace_state,
    }
end

local ace_strategy = {
    name = "ace_bt_cli enable/disable",
    source = "ace",
    ok = has_ace,
    apply = function(on) ace_write(on) end,
    read = ace_state,
}

local wmt_strategy = {
    name = "wmt_cli bluetooth on/off",
    source = "ace",
    ok = wmt_present,
    apply = function(on) wmt_write(on) end,
    read = ace_state,
}

local btenabled_strategy = {
    name = "btfd btEnabled (int)",
    source = "btfd",
    ok = function()
        -- Some firmwares expose btEnabled instead of BTstate/BTenable.
        local out = sh(string.format("lipc-get-prop %s btEnabled", BTFD))
        return out ~= nil and out:match("^%s*%d") ~= nil
    end,
    apply = function(on) write_int("btEnabled", on and 1 or 0) end,
    read = function()
        local out = sh(string.format("lipc-get-prop %s btEnabled", BTFD))
        local v = out and tonumber(out:match("^%s*(%d+)"))
        return v and ((v ~= 0) and 1 or 0)
    end,
}

local bcm_strategy = {
    name = "/proc/bluetooth/btenable (Broadcom chip power)",
    source = "btfd",
    ok = function() return binary(Bluetooth.BCM_PROC) end,
    apply = function(on)
        local f = io.open(Bluetooth.BCM_PROC, "w")
        if not f then
            trace_line("%s write failed", Bluetooth.BCM_PROC)
            return
        end
        f:write(on and "1\n" or "0\n")
        f:close()
        trace_line("%s = %d", Bluetooth.BCM_PROC, on and 1 or 0)
    end,
    read = function()
        local f = io.open(Bluetooth.BCM_PROC, "r")
        if not f then return nil end
        local v = tonumber((f:read("*l") or ""):match("%d"))
        f:close()
        return v
    end,
}

local function strategy_list(on)
    local list = {}
    for _, s in ipairs(btfd_strategies(on)) do list[#list + 1] = s end
    if on then
        -- The stock daemons may be down: bring them up before asking the
        -- stack to enable the radio.
        list[#list + 1] = upstart_strategy(true)
        list[#list + 1] = ace_strategy
        list[#list + 1] = wmt_strategy
    else
        list[#list + 1] = ace_strategy
        list[#list + 1] = wmt_strategy
        list[#list + 1] = upstart_strategy(false)
    end
    list[#list + 1] = btenabled_strategy
    list[#list + 1] = bcm_strategy
    return list
end

local function poll_state(read, target, tries, done)
    local function tick(n)
        local state = read()
        if state == target then
            done(true)
        elseif n <= 0 then
            done(false)
        else
            UIManager:scheduleIn(POLL_INTERVAL, function() tick(n - 1) end)
        end
    end
    tick(tries)
end

-- set_enabled(on, done) -> walks the strategy chain, done(ok, how)
function Bluetooth.set_enabled(on, done)
    done = done or function() end

    if Bluetooth.busy then return false, "busy" end
    local target = on and 1 or 0
    if not Bluetooth.can_control() then
        trace_line("no Bluetooth control mechanism on this device")
        return false, "unavailable"
    end

    local status = Bluetooth.status(true)
    if status.readable and status.state == (on and Bluetooth.STATE_ON or Bluetooth.STATE_OFF) then
        done(true, "already there")
        return true
    end

    Bluetooth.busy = true
    trace_line("set_enabled(%s)", tostring(on))

    local strategies = strategy_list(on)
    local index = 0
    local function next_strategy()
        index = index + 1
        local strategy = strategies[index]
        if not strategy then
            Bluetooth.busy = false
            trace_line("all strategies failed")
            return done(false, "all failed")
        end

        local usable = false
        local ok_check, result = pcall(strategy.ok)
        if ok_check then usable = result == true end
        if not usable then
            trace_line("skip: %s", strategy.name)
            return next_strategy()
        end

        trace_line("try: %s", strategy.name)
        pcall(strategy.apply, on)
        poll_state(strategy.read, target, POLL_TRIES, function(ok)
            if ok then
                Bluetooth.busy = false
                Bluetooth.invalidate()
                state_source = strategy.source
                remember_state(on)
                trace_line("ok: %s", strategy.name)
                return done(true, strategy.name)
            end
            trace_line("no change after: %s", strategy.name)
            next_strategy()
        end)
    end

    next_strategy()
    return true
end

-- ============================================================
-- Diagnostics report
-- ============================================================
local function read_file(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local content = f:read("*l")
    f:close()
    return content
end

function Bluetooth.diagnostics()
    plumb()
    local Device = require("device")
    local function device_is_kindle()
        if type(Device.isKindle) ~= "function" then return false end
        local ok, res = pcall(Device.isKindle, Device)
        return ok and res == true
    end
    local lines = {}
    local function add(fmt, ...)
        lines[#lines + 1] = select("#", ...) > 0 and string.format(fmt, ...) or fmt
    end

    local ok_ver, version = pcall(function() return require("version").short_version end)
    add("quick-menu bluetooth diagnostics  (%s)",
        ok_ver and tostring(version) or "?")
    add("model=%s  isKindle=%s  isMTK=%s",
        tostring(Device.model),
        tostring(device_is_kindle()),
        tostring(Device.isMTK))

    add("")
    add("-- libraries")
    add("libopenlipclua=%s  liblipclua=%s",
        tostring(open_lipc ~= nil), tostring(scalar_lipc ~= nil))
    add("handle=%s  scalar-handle=%s",
        tostring(master_handle ~= nil), tostring(scalar_handle ~= nil))

    add("")
    add("-- binaries / files")
    add("ace_bt_cli=%s  wmt_cli=%s  /proc/bluetooth/btenable=%s",
        tostring(has_ace()), tostring(wmt_present()), tostring(binary(Bluetooth.BCM_PROC)))
    add("btenable=%s  /dev/stpbt=%s  /dev/ttymxc2=%s",
        tostring(read_file(Bluetooth.BCM_PROC)), tostring(binary("/dev/stpbt")),
        tostring(binary("/dev/ttymxc2")))
    add("kaf bt/power=%s",
        tostring(read_file("/var/local/kaf/bt/power")))

    add("")
    add("-- btfd properties")
    add("BTstate=%s  currentBTOperatingMode=%s  isAudibleAvailable=%s",
        tostring(read_int("BTstate")),
        tostring(read_int("currentBTOperatingMode")),
        tostring(read_int("isAudibleAvailable")))
    add("hasNeverPaired=%s  BTconnectedDevName=%q",
        tostring(read_int("hasNeverPaired")),
        tostring(read_str("BTconnectedDevName")))
    add("lipc-get-prop com.lab126.btfd BTstate -> %s",
        tostring(sh("lipc-get-prop -i com.lab126.btfd BTstate")))
    add("lipc-get-prop com.lab126.btfd btEnabled -> %s",
        tostring(sh("lipc-get-prop com.lab126.btfd btEnabled")))

    add("")
    add("-- ace_bt_cli")
    add("radiostate -> %s", tostring(sh(Bluetooth.ACE_CLI .. " radiostate")))

    add("")
    add("-- processes / jobs")
    add("%s", tostring(sh("ps | grep -E 'acsbtfd|btmanagerd|btfd|btd|bsa_server|ace_bt' | grep -v grep")))
    add("%s", tostring(sh("initctl list 2>/dev/null | grep -i bt")))

    add("")
    add("-- recent operations")
    for i = math.max(1, #trace - 40), #trace do
        add("%s", trace[i])
    end

    return table.concat(lines, "\n")
end

-- Writes the report next to the plugin settings and returns its path.
function Bluetooth.save_diagnostics()
    local report = Bluetooth.diagnostics()
    local path = DataStorage:getSettingsDir() .. "/quickmenu_bluetooth_debug.txt"
    local f = io.open(path, "w")
    if f then
        f:write(report)
        f:write("\n")
        f:close()
    end
    return report, path
end

local function toast(text, timeout)
    UIManager:show(InfoMessage:new{ text = text, timeout = timeout or 3 })
end

function Bluetooth.show_diagnostics()
    local report, path = Bluetooth.save_diagnostics()
    UIManager:show(InfoMessage:new{
        text = report .. "\n\n" .. _("Saved to:") .. "\n" .. path,
        height = math.floor(require("device").screen:getHeight() * 0.8),
        monospace_font = true,
    })
end

-- ============================================================
-- Quick action
-- ============================================================
local ICON_ON        = "\u{E7AE}" -- bluetooth
local ICON_CONNECTED = "\u{E7B0}" -- bluetooth-connect
local ICON_OFF       = "\u{E7B1}" -- bluetooth-off

function Bluetooth.action_icon()
    local status = Bluetooth.status()
    if not Bluetooth.can_control() then return ICON_OFF end
    if status.state == Bluetooth.STATE_OFF then return ICON_OFF end
    if status.name then return ICON_CONNECTED end
    return ICON_ON
end

function Bluetooth.action_label()
    local status = Bluetooth.status()
    if not Bluetooth.can_control() then return _("n/a") end
    if status.state == Bluetooth.STATE_OFF then return _("Off") end
    if status.name then return status.name end
    return _("On")
end

function Bluetooth.is_active()
    local status = Bluetooth.status()
    return Bluetooth.can_control() and status.state == Bluetooth.STATE_ON
end

function Bluetooth.toggle(ctx)
    local status = Bluetooth.status(true)
    if not Bluetooth.can_control() then
        toast(_("No Bluetooth control was found on this device."), 4)
        return false
    end
    if Bluetooth.busy then return false end

    local on = status.state == Bluetooth.STATE_OFF
    local progress = InfoMessage:new{
        text = on and _("Bluetooth: turning on…") or _("Bluetooth: turning off…"),
    }
    UIManager:show(progress)

    Bluetooth.set_enabled(on, function(ok, how)
        UIManager:close(progress)
        if ok then
            trace_line("toggle done (%s)", tostring(how))
        else
            logger.warn("[quickmenu][bt] toggle failed:", tostring(how))
            Bluetooth.save_diagnostics()
            toast(_("Could not switch Bluetooth. Long-press the button for diagnostics."), 5)
        end
        if ctx and ctx.touch_menu then
            Utils.updateMenu(ctx.touch_menu, { delay = 0.5 })
        end
    end)
    return true
end

return Bluetooth

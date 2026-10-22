-- Bluetooth UI: the quick action and the device manager dialogs.
--
-- Kept separate from bluetooth/backend.lua so the lipc plumbing stays free of
-- widgets, and separate from action_defs.lua because the manager dialogs are
-- too big to live in the action table.

local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox   = require("ui/widget/confirmbox")
local InfoMessage  = require("ui/widget/infomessage")

local UIManager    = require("ui/uimanager")
local logger       = require("logger")

local Backend      = require("bluetooth/backend")
local Config       = require("config")
local Utils        = require("common/utils")
local _            = require("common/i18n").gettext

local Dialog = {}

local WIDTHFACTOR = 0.8

-- Glyphs from the Nerd Font set already bundled for the action buttons.
local ICON_ON        = "\u{E7AE}" -- bluetooth
local ICON_CONNECTED = "\u{E7B0}" -- bluetooth-connect
local ICON_OFF       = "\u{E7B1}" -- bluetooth-off

-- ============================================================
-- Helpers
-- ============================================================
local function ensure_cfg(ctx)
    ctx.config.bluetooth = ctx.config.bluetooth or {}
    return ctx.config.bluetooth
end

local function save_cfg(ctx)
    Config.save(ctx.config)
end

local function status_text(status)
    if not status.available then return _("Not available") end
    if status.state == Backend.STATE_OFF then return _("Off") end
    if status.name then
        return _("Connected") .. " : " .. status.name
    end
    return _("On")
end

local function device_label(device, connected)
    local label = device.name .. "\n" .. device.mac
    if connected then label = label .. "  \u{2714}" end
    return label
end

local function toast(text, timeout)
    UIManager:show(InfoMessage:new{
        text = text,
        timeout = timeout or 3,
    })
end

local function refresh_menu(ctx)
    if ctx and ctx.touch_menu then
        Utils.updateMenu(ctx.touch_menu, { delay = 0.5 })
    end
end

-- ============================================================
-- Action hooks (used by action_defs.lua)
-- ============================================================
function Dialog.available()
    return Backend.available()
end

function Dialog.action_icon()
    local status = Backend.status()
    if not status.available then return ICON_OFF end
    if status.state == Backend.STATE_OFF then return ICON_OFF end
    if status.name then return ICON_CONNECTED end
    return ICON_ON
end

function Dialog.action_label()
    local status = Backend.status()
    if not status.available then return _("n/a") end
    if status.state == Backend.STATE_OFF then return _("Off") end
    if status.name then return status.name end
    return _("On")
end

function Dialog.is_active()
    local status = Backend.status()
    return status.available and status.state ~= Backend.STATE_OFF
end

-- Turns the radio on or off, with progress feedback and the page-turner
-- conveniences (auto-connect the last device, rescan input devices).
function Dialog.toggle(ctx, force_on, done)
    local status = Backend.status(true)
    if not status.available then
        toast(_("Bluetooth control is not available on this device."))
        return false
    end
    if Backend.busy then return false end

    local cfg = ensure_cfg(ctx)
    local on = force_on
    if on == nil then on = status.state == Backend.STATE_OFF end

    local progress = InfoMessage:new{
        text = on and _("Bluetooth: turning on…") or _("Bluetooth: turning off…"),
    }
    UIManager:show(progress)

    local function finish(ok, reason)
        UIManager:close(progress)
        if not ok then
            logger.warn("[quickmenu] bluetooth toggle failed:", reason)
            toast(_("Could not switch Bluetooth. Try again from the system menu."))
        elseif on then
            -- btfd normally reconnects the last device by itself; this is for
            -- when it doesn't, and costs nothing when it already has.
            if cfg.auto_connect ~= false and cfg.last_mac and not Backend.status(true).name then
                Backend.connect(cfg.last_mac)
            end
            -- The HID remote only shows up as an input device after the link is
            -- up, so KOReader has to look for it again.
            UIManager:scheduleIn(3, function() Backend.rescan_input() end)
        end
        refresh_menu(ctx)
        if done then done(ok) end
    end

    Backend.set_enabled(on, { keepalive = cfg.keepalive ~= false }, finish)
    return true
end

-- Called at KOReader startup when "Turn on with KOReader" is enabled.
function Dialog.auto_start(ctx)
    local cfg = ctx and ctx.config and ctx.config.bluetooth
    if not (cfg and cfg.auto_on) then return end
    UIManager:scheduleIn(3, function()
        local status = Backend.status(true)
        if not status.available then return end
        if status.state == Backend.STATE_OFF then
            Dialog.toggle(ctx, true)
        elseif cfg.auto_connect ~= false and cfg.last_mac and not status.name then
            Backend.connect(cfg.last_mac)
            UIManager:scheduleIn(3, function() Backend.rescan_input() end)
        else
            Backend.rescan_input()
        end
    end)
end

-- ============================================================
-- Manager dialog
-- ============================================================
local function build_manager(ctx, reopen)
    local status = Backend.status(true)
    local cfg = ensure_cfg(ctx)
    local buttons = {}

    table.insert(buttons, {{
        text = status_text(status),
        enabled = false,
        align = "left",
    }})

    local radio_off = status.state == Backend.STATE_OFF
    table.insert(buttons, {{
        text = radio_off and _("Turn Bluetooth on") or _("Turn Bluetooth off"),
        enabled = status.available,
        callback = function() Dialog.toggle(ctx, radio_off, reopen.refresh) end,
    }})

    table.insert(buttons, {{
        text = _("Scan for devices…"),
        enabled = status.available,
        callback = function() Dialog.scan(ctx) end,
    }})

    table.insert(buttons, {{
        text = _("Paired devices") .. " (" .. tostring(#(Backend.paired() or {})) .. ")…",
        enabled = status.available,
        callback = function() Dialog.show_paired(ctx) end,
    }})

    table.insert(buttons, {}) -- separator

    table.insert(buttons, {{
        text = _("Keep connection alive (no idle disconnect)"),
        checked_func = function() return cfg.keepalive ~= false end,
        align = "left",
        callback = function()
            cfg.keepalive = not (cfg.keepalive ~= false)
            save_cfg(ctx)
            if status.state ~= Backend.STATE_OFF then
                toast(_("Applied the next time Bluetooth is switched on."), 4)
            end
        end,
    }})

    table.insert(buttons, {{
        text = _("Auto-connect last device"),
        checked_func = function() return cfg.auto_connect ~= false end,
        align = "left",
        callback = function()
            cfg.auto_connect = not (cfg.auto_connect ~= false)
            save_cfg(ctx)
        end,
    }})

    table.insert(buttons, {{
        text = _("Turn on with KOReader"),
        checked_func = function() return cfg.auto_on == true end,
        align = "left",
        callback = function()
            cfg.auto_on = not cfg.auto_on
            save_cfg(ctx)
        end,
    }})

    table.insert(buttons, {{
        text = _("Map page turner keys (PageUp/PageDown)"),
        checked_func = function() return cfg.page_keys ~= false end,
        align = "left",
        callback = function()
            local PageKeys = require("bluetooth/page_keys")
            if cfg.page_keys ~= false then
                PageKeys.disable()
                cfg.page_keys = false
            else
                PageKeys.install()
                cfg.page_keys = true
            end
            save_cfg(ctx)
        end,
    }})

    table.insert(buttons, {{
        text = _("Rescan input devices") .. "\n" .. _("(for page turner keys)"),
        align = "left",
        callback = function()
            local ok = Backend.rescan_input()
            toast(ok and _("Input devices rescanned.") or _("Input rescan not supported on this device."))
        end,
    }})

    table.insert(buttons, {}) -- separator

    table.insert(buttons, {{
        text = _("Close"),
        callback = function()
            if reopen and reopen.close then reopen.close() end
        end,
    }})

    return ButtonDialog:new{
        title = ICON_ON .. " " .. _("Bluetooth") .. " : " .. status_text(status),
        title_align = "left",
        width_factor = WIDTHFACTOR,
        buttons = buttons,
    }
end

function Dialog.show(ctx)
    local dialog
    local reopen = {}
    reopen.close = function()
        if dialog then UIManager:close(dialog); dialog = nil end
    end
    function reopen.refresh()
        reopen.close()
        dialog = build_manager(ctx, reopen)
        UIManager:show(dialog)
    end
    reopen.refresh()
end

-- ============================================================
-- Paired devices
-- ============================================================
local function build_paired(ctx, reopen)
    local devices = Backend.paired()
    local connected = {}
    for _, device in ipairs(Backend.connected() or {}) do connected[device.mac] = true end

    local buttons = {}
    if not devices or #devices == 0 then
        table.insert(buttons, {{ text = _("No paired devices"), enabled = false }})
    else
        for _, device in ipairs(devices) do
            local is_connected = connected[device.mac]
            table.insert(buttons, {{
                text = device_label(device, is_connected),
                align = "left",
                callback = function()
                    if is_connected then
                        Dialog.disconnect(ctx, device, reopen)
                    else
                        Dialog.connect(ctx, device, reopen)
                    end
                end,
                hold_callback = function()
                    Dialog.confirm_forget(ctx, device, reopen)
                end,
            }})
        end
        table.insert(buttons, {{ text = _("Hold a device to forget it"), enabled = false }})
    end

    table.insert(buttons, {}) -- separator
    table.insert(buttons, {{ text = _("Close"), callback = function() if reopen.close then reopen.close() end end }})

    return ButtonDialog:new{
        title = _("Paired devices") .. " :",
        title_align = "left",
        width_factor = WIDTHFACTOR,
        buttons = buttons,
    }
end

function Dialog.show_paired(ctx)
    local dialog
    local reopen = {}
    reopen.close = function()
        if dialog then UIManager:close(dialog); dialog = nil end
    end
    function reopen.refresh()
        reopen.close()
        dialog = build_paired(ctx, reopen)
        UIManager:show(dialog)
    end
    reopen.refresh()
end

function Dialog.connect(ctx, device, reopen)
    local progress = InfoMessage:new{ text = _("Connecting…") }
    UIManager:show(progress)
    Backend.connect(device.mac, function(ok, name)
        UIManager:close(progress)
        if ok then
            local cfg = ensure_cfg(ctx)
            cfg.last_mac, cfg.last_name = device.mac, name or device.name
            save_cfg(ctx)
            toast(_("Connected") .. " : " .. (name or device.name))
            UIManager:scheduleIn(3, function() Backend.rescan_input() end)
        else
            toast(_("Could not connect. Make sure the device is on and in range."))
        end
        if reopen and reopen.refresh then reopen.refresh() end
        refresh_menu(ctx)
    end)
end

function Dialog.disconnect(ctx, device, reopen)
    local progress = InfoMessage:new{ text = _("Disconnecting…") }
    UIManager:show(progress)
    Backend.disconnect(device.mac, function(ok)
        UIManager:close(progress)
        toast(ok and (_("Disconnected") .. " : " .. device.name)
                 or _("Could not disconnect."))
        if reopen and reopen.refresh then reopen.refresh() end
        refresh_menu(ctx)
    end)
end

function Dialog.confirm_forget(ctx, device, reopen)
    UIManager:show(ConfirmBox:new{
        text = _("Forget this device?") .. "\n" .. device.name .. "\n" .. device.mac,
        ok_text = _("Forget"),
        cancel_text = _("Cancel"),
        ok_callback = function()
            Backend.unbond(device.mac)
            local cfg = ensure_cfg(ctx)
            if cfg.last_mac == device.mac then
                cfg.last_mac, cfg.last_name = nil, nil
                save_cfg(ctx)
            end
            toast(_("Device forgotten."))
            if reopen and reopen.refresh then reopen.refresh() end
            refresh_menu(ctx)
        end,
    })
end

-- ============================================================
-- Scan / nearby devices
-- ============================================================
local function build_discovered(ctx, reopen)
    local devices = Backend.discovered() or {}
    local buttons = {}

    if #devices == 0 then
        table.insert(buttons, {{ text = _("No new devices found"), enabled = false }})
    else
        for _, device in ipairs(devices) do
            table.insert(buttons, {{
                text = device_label(device, false),
                align = "left",
                callback = function() Dialog.pair(ctx, device, reopen) end,
            }})
        end
    end

    table.insert(buttons, {}) -- separator
    table.insert(buttons, {{ text = _("Close"), callback = function() if reopen.close then reopen.close() end end }})

    return ButtonDialog:new{
        title = _("Nearby devices") .. " :",
        title_align = "left",
        width_factor = WIDTHFACTOR,
        buttons = buttons,
    }
end

function Dialog.scan(ctx)
    local ok = Backend.scan()
    if not ok then
        toast(_("Could not start a scan."))
        return
    end

    toast(_("Scanning for Bluetooth devices…"), 10)
    UIManager:scheduleIn(10, function()
        local dialog
        local reopen = {}
        reopen.close = function()
            if dialog then UIManager:close(dialog); dialog = nil end
        end
        function reopen.refresh()
            reopen.close()
            dialog = build_discovered(ctx, reopen)
            UIManager:show(dialog)
        end
        reopen.refresh()
    end)
end

function Dialog.pair(ctx, device, reopen)
    if not Backend.bond(device.mac) then
        toast(_("Could not pair with this device."))
        return
    end
    local progress = InfoMessage:new{ text = _("Pairing…") }
    UIManager:show(progress)
    UIManager:scheduleIn(4, function()
        UIManager:close(progress)
        Backend.connect(device.mac, function(ok, name)
            if ok then
                local cfg = ensure_cfg(ctx)
                cfg.last_mac, cfg.last_name = device.mac, name or device.name
                save_cfg(ctx)
                toast(_("Connected") .. " : " .. (name or device.name))
                UIManager:scheduleIn(3, function() Backend.rescan_input() end)
            else
                toast(_("Paired, but not connected. Try it from the paired list."))
            end
            if reopen and reopen.refresh then reopen.refresh() end
            refresh_menu(ctx)
        end)
    end)
end

return Dialog

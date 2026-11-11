-- The visibility buttons next to the weapon slots.
--
-- The XAML side (GUI/Library/Lib_Keyboard.xaml) wraps each weapon slot in
-- VSWS_WeaponEQTemplate: the slot plus a copy of the game's visibility button.
-- The button shows the mode named in a hidden text block of the wrapper.
-- When the wrapper appears, when the mouse enters it and when the button is
-- clicked, it runs three commands in this order:
--
--   VSWS_CharacterCommand  with the character shown;
--   VSWS_SlotCommand       with the slot;
--   VSWS_ShowCommand or VSWS_ToggleCommand  with the text block.
--
-- This side supplies those commands. They live on one object placed in the
-- Tag of ContentRoot - the container of every widget, which pages reach by
-- name - so no panel or data context of the game is touched.
--
-- Script cannot read bound values off UI elements, and references to UI
-- objects are only valid inside the call that received them. Hence the data
-- arrives as command parameters, and nothing but plain strings is kept.

local State = Ext.Require("Shared/State.lua")

local UI = {}
local Applier, requestMode -- handed in by Register

-- A registered type cannot change until the game restarts; rename it when its commands change.
local COMMANDS_TYPE = "VSWS_Commands"

local function get(fn)
    local ok, v = pcall(fn)
    if ok then return v end
    return nil
end

local function log(...)
    State.Warn("[ui]", ...)
end

-- The XAML reports the character, then the slot, then asks for the action.
-- Only plain strings are kept between those calls.
local reportedUuid, pendingSlot

local function onCharacter(character)
    reportedUuid = get(function() return tostring(character.EntityUUID) end)
end

local function onSlot(slotVM)
    pendingSlot = get(function() return tostring(slotVM.SlotType) end)
end

--- The character last reported, and the given slot (or the one last reported).
--- The character is kept: the controller popup reports it once and then
--- sends one command per slot.
---@return string? slot, string? uuid
local function identify(slot)
    if not slot then
        slot, pendingSlot = pendingSlot, nil
    end
    local uuid = reportedUuid
    if not State.IsSlot[slot] then
        log("not a weapon slot:", slot)
        return nil
    end
    if not uuid or uuid == "" or uuid == "nil" then
        log("no character behind slot", slot)
        return nil
    end
    return slot, uuid
end

--- Write a mode name into the state text block the button reads.
local function show(stateText, mode)
    local ok, err = pcall(function()
        if tostring(stateText.Text) ~= mode then stateText.Text = mode end
    end)
    if not ok then log("cannot set the button state:", err) end
end

---@param forSlot string? the slot, when the command itself names it (controller UI)
local function onShow(stateText, forSlot)
    local slot, uuid = identify(forSlot)
    if not slot then return end
    show(stateText, State.ModeOf(Applier.CachedModes(uuid), slot))
end

---@param forSlot string? the slot, when the command itself names it (controller UI)
local function onToggle(stateText, forSlot)
    local slot, uuid = identify(forSlot)
    if not slot then return end
    local modes = {}
    for k, v in pairs(Applier.CachedModes(uuid) or {}) do modes[k] = v end
    local mode = State.NextMode(State.ModeOf(modes, slot))
    modes[slot] = mode

    -- Show and apply at once; the server confirms to everybody a moment later.
    show(stateText, mode)
    Applier.SetModes(uuid, modes)
    requestMode(uuid, slot, mode)
    State.Debug("ui: toggled", slot, "of", uuid:sub(1, 8), "->", mode)
end

-- A command handler is called with the command and then its parameter.
local function handler(fn, what, slot)
    return function(_, parameter)
        if parameter == nil then log(what, "called without a parameter") end
        local ok, err = pcall(fn, parameter, slot)
        if not ok then log(what, "failed:", err) end
    end
end

--- Create the object holding the commands and hang it on ContentRoot.
local function install(root)
    -- Keyboard UI: character, slot, then show/toggle.
    -- Controller UI: character once, then one show/toggle command per slot.
    local fields = {
        VSWS_CharacterCommand = { Type = "Command" },
        VSWS_SlotCommand = { Type = "Command" },
        VSWS_ShowCommand = { Type = "Command" },
        VSWS_ToggleCommand = { Type = "Command" },
    }
    for _, slot in ipairs(State.SLOTS) do
        fields["VSWS_Show" .. slot .. "Command"] = { Type = "Command" }
        fields["VSWS_Toggle" .. slot .. "Command"] = { Type = "Command" }
    end
    -- A registered type survives until the game restarts, so "already there" is fine.
    pcall(Ext.UI.RegisterType, COMMANDS_TYPE, fields)

    local commands
    for _, typeId in ipairs({ "se::" .. COMMANDS_TYPE, COMMANDS_TYPE }) do
        commands = get(function() return Ext.UI.Instantiate(typeId) end)
        if commands then break end
    end
    if not commands then
        log("cannot create the commands object; the visibility buttons will not respond")
        return
    end
    commands.VSWS_CharacterCommand:SetHandler(handler(onCharacter, "character"))
    commands.VSWS_SlotCommand:SetHandler(handler(onSlot, "slot"))
    commands.VSWS_ShowCommand:SetHandler(handler(onShow, "show"))
    commands.VSWS_ToggleCommand:SetHandler(handler(onToggle, "toggle"))
    for _, slot in ipairs(State.SLOTS) do
        commands["VSWS_Show" .. slot .. "Command"]:SetHandler(handler(onShow, "show", slot))
        commands["VSWS_Toggle" .. slot .. "Command"]:SetHandler(handler(onToggle, "toggle", slot))
    end

    root.Tag = commands
    State.Debug("ui: commands installed")
end

--- ContentRoot, reached by its fixed place in the tree (canvas > viewbox >
--- decorator > ContentRoot): three direct steps instead of a search by name.
local function contentRoot()
    local canvas = Ext.UI.GetRoot()
    local root = get(function() return canvas:VisualChild(1):VisualChild(1):VisualChild(1) end)
    if root and get(function() return tostring(root.Name) end) == "ContentRoot" then return root end
    return get(function() return canvas:Find("ContentRoot") end)
end

--- Make sure the commands are on ContentRoot. The game rebuilds its whole UI
--- when the player switches between keyboard and controller, and the new
--- ContentRoot starts out empty.
local function ensure()
    local root = contentRoot()
    if not root then return end
    local current = get(function() return root.Tag end)
    if current ~= nil then
        local currentType = get(function() return tostring(current.Type) end) or type(current)
        if currentType:find(COMMANDS_TYPE, 1, true) then return end -- already ours
        -- Nothing in the game uses this Tag; another mod might.
        log("ContentRoot.Tag was already in use by", currentType, "- replacing it")
    end
    install(root)
end

local CHECK_MS = 1000

local function check()
    Ext.UI.Defer(function()
        local ok, err = pcall(ensure)
        if not ok then log("install failed:", err) end
    end)
    Ext.Timer.WaitFor(CHECK_MS, check)
end

--- Call once per session (a Lua reset starts a new one).
function UI.Register(applier, request)
    Applier, requestMode = applier, request
    check()
end

return UI

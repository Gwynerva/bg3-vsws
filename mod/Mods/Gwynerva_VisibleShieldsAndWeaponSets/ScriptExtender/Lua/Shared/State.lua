-- Shared definitions: slots, modes, the per-character variable and channel names.

local State = {}

State.VAR = "VSWS_SlotModes"

-- Network channels (Ext.Net.CreateChannel), one name per message kind.
State.CH_SET = "SetMode"       -- client -> server: { Entity, Slot, Mode? }
State.CH_CHANGED = "Changed"   -- server -> clients: { Entity, Modes }
State.CH_HELLO = "Hello"       -- client -> server: send me everyone's modes

State.SLOTS = { "MeleeMainHand", "MeleeOffHand", "RangedMainHand", "RangedOffHand" }
-- In the order the buttons cycle through them:
--   Visible           stowed weapon always shown, whichever weapon set is in use
--   ActiveSet         shown only while its weapon set is the one in use (the game's own behaviour)
--   CinematicsHidden  as Visible, but hidden in dialogues and cutscenes
--   Hidden            stowed weapon never shown
-- A weapon in the hands is always shown.
State.MODES = { "Visible", "ActiveSet", "CinematicsHidden", "Hidden" }
State.DEFAULT_MODE = "Visible"

-- Also draw the stowed weapons of the set that is not in use. The engine
-- draws only the set in use; see Applier.lua (world, photo mode) and
-- Timeline.lua (dialogues, cutscenes) for how it is asked for the other one.
State.SHOW_BOTH_SETS = true

-- Set to true for step-by-step messages in the Script Extender console.
State.DEBUG = false

State.USAGE = "usage: !vsws <main|shield|ranged|rangedoff|all> [visible|set|dialog|hidden]"

State.IsSlot, State.IsMode = {}, {}
for _, s in ipairs(State.SLOTS) do State.IsSlot[s] = true end
for _, m in ipairs(State.MODES) do State.IsMode[m] = true end

local SLOT_ALIASES = {
    main = "MeleeMainHand", shield = "MeleeOffHand", off = "MeleeOffHand",
    ranged = "RangedMainHand", rangedoff = "RangedOffHand",
}
local MODE_ALIASES = {
    visible = "Visible", show = "Visible",
    set = "ActiveSet", active = "ActiveSet",
    dialog = "CinematicsHidden", cinematic = "CinematicsHidden",
    hidden = "Hidden", hide = "Hidden",
}

--- Console argument -> list of slots, or nil if it names none.
function State.ParseSlots(arg)
    if arg == "all" then return State.SLOTS end
    local slot = SLOT_ALIASES[arg or ""] or arg
    if State.IsSlot[slot] then return { slot } end
    return nil
end

--- Console argument -> mode, or nil (meaning "the next mode").
function State.ParseMode(arg)
    local mode = MODE_ALIASES[arg or ""] or arg
    if State.IsMode[mode] then return mode end
    return nil
end

-- Must run at script load on both sides, before any save data is read.
function State.RegisterVariable()
    Ext.Vars.RegisterUserVariable(State.VAR, {
        Server = true,
        Client = true,
        WriteableOnServer = true,
        WriteableOnClient = false,
        SyncToClient = true,
        Persistent = true,
    })
end

---@param modes table<string,string>?
---@param slot string
function State.ModeOf(modes, slot)
    local m = modes and modes[slot]
    return State.IsMode[m] and m or State.DEFAULT_MODE
end

--- Whether a stowed weapon is hidden.
---@param cinematic boolean shown in a dialogue or cutscene
---@param setInUse boolean the slot belongs to the weapon set in use
function State.IsHidden(mode, cinematic, setInUse)
    if mode == "Hidden" then return true end
    if mode == "CinematicsHidden" then return cinematic end
    if mode == "ActiveSet" then return not setInUse end
    return false
end

function State.NextMode(mode)
    for i, m in ipairs(State.MODES) do
        if m == mode then return State.MODES[i % #State.MODES + 1] end
    end
    return State.DEFAULT_MODE
end

local function join(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
    return table.concat(parts, " ")
end

function State.Log(...)
    Ext.Utils.Print("[Gwynerva VSWS] " .. join(...))
end

local debugLines = {}

--- Step-by-step messages while State.DEBUG is on: to the console, and to
--- Script Extender/Gwynerva_VisibleShields/debug.log for reading after the fact.
function State.Debug(...)
    if not State.DEBUG then return end
    State.Log(...)
    debugLines[#debugLines + 1] = join(...)
    if #debugLines > 400 then table.remove(debugLines, 1) end
    pcall(Ext.IO.SaveFile, "Gwynerva_VisibleShields/debug.log", table.concat(debugLines, "\n"))
end

local warned = {}

--- Report a problem once: most of this code runs every frame or on a timer.
function State.Warn(...)
    local line = join(...)
    if warned[line] then return end
    warned[line] = true
    local print = Ext.Log and Ext.Log.PrintWarning or Ext.Utils.Print
    print("[Gwynerva VSWS] " .. line)
end

return State

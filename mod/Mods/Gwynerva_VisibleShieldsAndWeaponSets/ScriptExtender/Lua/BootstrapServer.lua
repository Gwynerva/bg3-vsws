local State = Ext.Require("Shared/State.lua")

State.RegisterVariable()

local changed = Ext.Net.CreateChannel(ModuleUUID, State.CH_CHANGED)

--- Store one slot's mode on a character (saved with the game) and tell every client.
---@param mode string? nil moves to the next mode
---@return string? mode the mode now in effect, nil if refused
local function setMode(entity, slot, mode)
    if not entity or not State.IsSlot[slot] then return nil end
    -- Only party members carry a toggle; NPCs keep the defaults.
    if not entity.PartyMember then
        State.Debug("ignored: not a party member")
        return nil
    end
    local uuid = entity.Uuid and entity.Uuid.EntityUuid
    if not uuid then return nil end

    local modes = {}
    for k, v in pairs(entity.Vars[State.VAR] or {}) do modes[k] = v end
    if not State.IsMode[mode] then mode = State.NextMode(State.ModeOf(modes, slot)) end
    modes[slot] = mode
    entity.Vars[State.VAR] = modes

    changed:Broadcast({ Entity = uuid, Modes = modes })
    return mode
end

-- A client asks to change one slot's mode on one character.
Ext.Net.CreateChannel(ModuleUUID, State.CH_SET, function(msg)
    if type(msg) ~= "table" or type(msg.Entity) ~= "string" then return end
    if msg.Mode ~= nil and not State.IsMode[msg.Mode] then return end
    setMode(Ext.Entity.Get(msg.Entity), msg.Slot, msg.Mode)
end)

-- A client that has just loaded asks for the current modes: the synced
-- variable reaches it later than the characters appear on screen.
Ext.Net.CreateChannel(ModuleUUID, State.CH_HELLO, function()
    for _, entity in ipairs(Ext.Entity.GetAllEntitiesWithComponent("PartyMember")) do
        local modes = entity.Vars[State.VAR]
        local uuid = entity.Uuid and entity.Uuid.EntityUuid
        if modes and uuid then changed:Broadcast({ Entity = uuid, Modes = modes }) end
    end
end)

-- The same command as on the client, so it works whichever console is open.
-- Here it acts on the host's character.
Ext.RegisterConsoleCommand("vsws", function(_, slotArg, modeArg)
    local slots = State.ParseSlots(slotArg)
    if not slots then State.Log(State.USAGE) return end
    local entity = Ext.Entity.Get(Osi.GetHostCharacter())
    for _, slot in ipairs(slots) do
        local mode = setMode(entity, slot, State.ParseMode(modeArg))
        if mode then State.Log(slot, "->", mode) end
    end
end)

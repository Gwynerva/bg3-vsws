-- Characters in the world and their copies in photo mode.
--
-- ClientEquipmentVisibilityState.Equipment is the engine's own table of slots
-- to draw: a slot without a row is not drawn. This module edits that table
-- right after the engine has filled it in, and the engine does the rest:
--
--   * the shield's row, which the engine leaves out since Patch 8 while
--     weapons are sheathed, is put back;
--   * rows are added for the weapon set that is not in use, marked as stowed;
--   * the row of a slot hidden by its mode is taken out.
--
-- Dialogues and cutscenes are handled in Timeline.lua: their dummies do not
-- have this component.

local State = Ext.Require("Shared/State.lua")
local Layers = Ext.Require("Client/Layers.lua")

local Applier = {}

local COMPONENT = "ClientEquipmentVisibilityState"
local SHIELD_SLOT = "MeleeOffHand"

-- Photo-mode dummies: bits of DummyEquipmentVisualsState.field_0 and values
-- of DummyUnsheath.field_0. (Placeholder names in Script Extender.)
local DUMMY_HIDE_WEAPONS = 1 << 16
local DUMMY_UNSHEATH = { [0] = "Instrument", [1] = "Melee", [2] = "Ranged", [3] = "Sheathed" }

-- A row taken out before the engine has built the slot's model does not stop
-- the model from appearing, so hiding waits for the model: this often, this
-- many times at most.
local MODEL_RETRY_MS = 250
local MODEL_MAX_WAITS = 20

-- After an entity's rows change, its models are rebuilt over the next moments
-- (a weapon being put away takes about a second). For that long its stowed
-- weapons are arranged in layers again, this often.
local SETTLE_FRAMES = 240
local ARRANGE_EVERY_FRAMES = 6

local tracked = {}   -- entities that have the component
local pending = {}   -- entities to bring in line (and flag as changed) this frame
local stash = {}     -- stash[entity][slot] = a row taken out, to be put back
local waited = {}    -- waited[entity][slot] = times hiding was put off for a model still loading
local settling = {}  -- settling[entity] = frames left in which its stowed weapons are still arranged
local modeCache = {} -- uuid -> modes, as last told by the server
local modesVersion = 0

local function get(fn)
    local ok, v = pcall(fn)
    if ok then return v end
    return nil
end

local function uuidOf(entity)
    return get(function() return entity.Uuid.EntityUuid end)
end

-- ---------------------------------------------------------------- characters

--- The character an entity stands for, and where it is shown.
---@return EntityHandle owner, string context "world" or "photo"
function Applier.Resolve(entity)
    local owner = get(function() return entity.Dummy.Entity end)
    if owner then return owner, "photo" end
    return entity, "world"
end

--- A character's modes: slot -> mode. May be nil.
function Applier.ModesOf(owner)
    local uuid = uuidOf(owner)
    if uuid and modeCache[uuid] then return modeCache[uuid] end
    return get(function() return owner.Vars[State.VAR] end)
end

--- Modes as last told by the server, without touching the entity: safe to
--- call from UI callbacks.
function Applier.CachedModes(uuid)
    return modeCache[uuid]
end

--- Changes whenever any character's modes do.
function Applier.ModesVersion()
    return modesVersion
end

--- The item in one of a character's equipment slots, if any.
function Applier.EquippedItem(owner, slot)
    return get(function()
        for _, inv in ipairs(owner.InventoryOwner.Inventories) do
            if inv.InventoryData.Type == Ext.Enums.InventoryType.Equipment then
                local data = inv.InventoryContainer.Items[Ext.Enums.ItemSlot[slot].Value]
                local item = data and data.Item
                if item and not item.DisabledEquipment then return item end
                return nil
            end
        end
    end)
end

--- The weapon set in use ("Melee" or "Ranged"), or nil if it cannot be told.
function Applier.SetInUse(owner)
    local set = get(function() return tostring(owner.WeaponSet.WeaponSet) end)
    if set == "Melee" or set == "Ranged" then return set end
    return nil
end

--- Whether a slot belongs to the given weapon set. With the set unknown
--- every slot counts as in use, which is how the game itself would draw it.
function Applier.SlotInSet(slot, set)
    return set == nil or slot:sub(1, #set) == set
end

--- "Melee" / "Ranged" while that set is in the hands, otherwise "Sheathed" or "Instrument".
function Applier.UnsheathState(entity)
    local dummy = get(function() return entity.DummyUnsheath.field_0 end)
    if dummy ~= nil then return DUMMY_UNSHEATH[dummy] end
    return get(function() return tostring(entity.Unsheath.State) end)
end

-- ---------------------------------------------------------------------- rows

--- Whether the engine is showing this entity's weapons at all: not while it
--- wears camp clothes, and not on a photo-mode dummy with weapons turned off.
local function weaponsShown(entity, context)
    if context == "photo" then
        local flags = get(function() return entity.DummyEquipmentVisualsState.field_0 end)
        return flags ~= nil and flags & DUMMY_HIDE_WEAPONS == 0
    end
    local armorSet = get(function() return tostring(entity.ArmorSetState.State) end)
    return armorSet == nil or armorSet == "Normal"
end

--- A stowed weapon, as a row. (field_8: in the hands; field_9: is a weapon.
--- Placeholder names in Script Extender.)
local function stowedRow(item)
    return { Item = item, field_8 = 0, field_9 = 1 }
end

--- A drawn weapon is never hidden: the modes only concern stowed gear. The
--- row says so itself; the character's Unsheath state changes a moment later
--- and cannot be relied on here.
local function inHand(row)
    return row.field_8 == 1
end

local function modelLoaded(entity, slot)
    return get(function() return entity.ClientEquipmentVisuals.Equipment[slot].Loaded end) == true
end

--- The item whose row the engine leaves out but which is to be drawn, if any.
local function missingItem(entity, owner, context, slot, inUse)
    if not weaponsShown(entity, context) then return nil end

    if not Applier.SlotInSet(slot, inUse) then
        -- The weapon set that is not in use: always stowed.
        return State.SHOW_BOTH_SETS and Applier.EquippedItem(owner, slot) or nil
    end

    if slot == SHIELD_SLOT and inUse == "Melee" then
        -- The shield, while the melee set is put away.
        local unsheath = Applier.UnsheathState(entity)
        if unsheath == "Sheathed" or unsheath == "Instrument" then
            local item = Applier.EquippedItem(owner, slot)
            if item and get(function() return item.Armor.Shield end) then return item end
        end
    end
    return nil
end

--- Take a hidden slot's row out. Waits for the model first.
---@return boolean changed
local function hide(entity, rows, slot)
    local row = rows[slot]
    if not row or inHand(row) then return false end

    local waits = waited[entity] and waited[entity][slot] or 0
    if not modelLoaded(entity, slot) and waits < MODEL_MAX_WAITS then
        waited[entity] = waited[entity] or {}
        waited[entity][slot] = waits + 1
        Ext.Timer.WaitFor(MODEL_RETRY_MS, function()
            if tracked[entity] then pending[entity] = true end
        end)
        return false
    end

    if waited[entity] then waited[entity][slot] = nil end
    stash[entity] = stash[entity] or {}
    stash[entity][slot] = { Item = row.Item, field_8 = row.field_8, field_9 = row.field_9 }
    rows[slot] = nil
    return true
end

--- Give a slot that is to be drawn its row, if the engine left it out.
---@return boolean changed
local function show(entity, owner, context, rows, slot, inUse)
    if rows[slot] then return false end

    local kept = stash[entity] and stash[entity][slot]
    if kept then
        -- Put back what was taken out, unless the item has since left the slot.
        stash[entity][slot] = nil
        if Applier.EquippedItem(owner, slot) == kept.Item then
            rows[slot] = kept
            return true
        end
    end

    local item = missingItem(entity, owner, context, slot, inUse)
    if item then
        rows[slot] = stowedRow(item)
        return true
    end
    return false
end

--- Bring one entity's rows in line with its owner's modes.
function Applier.Apply(entity)
    local component = entity[COMPONENT]
    if not component then return end
    local owner, context = Applier.Resolve(entity)
    local modes = Applier.ModesOf(owner)
    local inUse = Applier.SetInUse(owner)
    local rows = component.Equipment

    for _, slot in ipairs(State.SLOTS) do
        if State.IsHidden(State.ModeOf(modes, slot), false, Applier.SlotInSet(slot, inUse)) then
            hide(entity, rows, slot)
        else
            show(entity, owner, context, rows, slot, inUse)
        end
    end
end

local function safeApply(entity)
    local ok, err = pcall(Applier.Apply, entity)
    if not ok then State.Warn("apply failed:", err) end
    settling[entity] = SETTLE_FRAMES
end

--- Arrange the stowed weapons of the entities whose models may still be changing.
local function arrangeSettling()
    for entity, left in pairs(settling) do
        if not tracked[entity] then
            settling[entity] = nil
        else
            if left % ARRANGE_EVERY_FRAMES == 0 then
                local ok, err = pcall(Layers.Arrange, entity)
                if not ok then State.Warn("arranging failed:", err) end
            end
            settling[entity] = left > 1 and left - 1 or nil
        end
    end
end

-- -------------------------------------------------------------------- events

--- The server's word on a character's modes: remember it and re-apply every
--- entity that stands for that character.
function Applier.SetModes(uuid, modes)
    modeCache[uuid] = modes
    modesVersion = modesVersion + 1
    for entity in pairs(tracked) do
        if uuidOf(Applier.Resolve(entity)) == uuid then pending[entity] = true end
    end
end

--- Arrange everybody's stowed weapons again (after the layer settings changed).
function Applier.Rearrange()
    for entity in pairs(tracked) do settling[entity] = ARRANGE_EVERY_FRAMES end
end

--- Every entity being looked after (for the diagnostic dump).
function Applier.Tracked()
    return tracked
end

function Applier.RegisterListeners()
    Ext.Entity.OnCreateDeferred(COMPONENT, function(entity)
        pending[entity] = true
    end)

    Ext.Entity.OnDestroyDeferred(COMPONENT, function(entity)
        tracked[entity], pending[entity], stash[entity], waited[entity], settling[entity] = nil, nil, nil, nil, nil
    end)

    -- Right after the engine has decided what to draw: the only point where
    -- an edit is picked up in the same frame.
    Ext.Entity.OnSystemPostUpdate("ClientVisualsVisibilityState", function()
        -- The engine rewrote an entity's rows: put ours back.
        for entity in pairs(tracked) do
            if not pending[entity] and entity:WasChanged(COMPONENT) then safeApply(entity) end
        end
        -- Something of ours changed (a new entity, new modes): apply, and tell the engine.
        if next(pending) then
            local batch = pending
            pending = {}
            for entity in pairs(batch) do
                tracked[entity] = true
                safeApply(entity)
                pcall(function() entity:MarkChanged(COMPONENT) end)
            end
        end
        if next(settling) then arrangeSettling() end
    end)

    Ext.Events.ResetCompleted:Subscribe(function()
        for _, entity in ipairs(Ext.Entity.GetAllEntitiesWithComponent(COMPONENT)) do
            pending[entity] = true
        end
    end)
end

return Applier

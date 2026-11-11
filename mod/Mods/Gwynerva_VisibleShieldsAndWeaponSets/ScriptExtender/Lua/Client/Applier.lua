-- Decides, per entity and slot, whether a weapon/shield is drawn, by editing
-- ClientEquipmentVisibilityState.Equipment: the engine's own table of slots
-- to draw. A slot without a row is not drawn.
--
-- Since Patch 8 the engine leaves the shield's row out while weapons are
-- sheathed; we put it back. For a hidden slot we take the row out.

local State = Ext.Require("Shared/State.lua")

local Applier = {}

local COMPONENT = "ClientEquipmentVisibilityState"
local SHIELD_SLOT = "MeleeOffHand"
local DUMMY_HIDE_WEAPONS = 1 << 16   -- DummyEquipmentVisualsState.field_0
local DUMMY_SHEATHED = 3             -- DummyUnsheath.field_0

local pending = {}   -- entities to apply (and flag as changed) this frame
local tracked = {}   -- entities with the component
local stash = {}     -- stash[entity][slot] = row we removed, to put back on unhide
local modeCache = {} -- uuid -> modes, from server broadcasts
local waited = {}    -- waited[entity][slot] = times we held back for a model still loading

local RETRY_MS = 250
local MAX_WAITS = 20

local function get(fn)
    local ok, v = pcall(fn)
    if ok then return v end
    return nil
end

local function uuidOf(entity)
    return get(function() return entity.Uuid.EntityUuid end)
end

--- The character an entity stands for, and the context it is shown in.
--- Dialogue and photo mode show copies ("dummies") of the real character.
---@return EntityHandle owner, string context "world"|"cinematic"|"photo"
function Applier.Resolve(entity)
    local owner = get(function() return entity.Dummy.Entity end)
    local isTimeline = get(function() return entity.TLPreviewDummy ~= nil end)
    if isTimeline then
        owner = owner or get(function() return entity.TLPreviewDummy.Entity end)
        return owner or entity, "cinematic"
    end
    if owner then return owner, "photo" end
    return entity, "world"
end

function Applier.ModesOf(owner)
    local uuid = uuidOf(owner)
    if uuid and modeCache[uuid] then return modeCache[uuid] end
    return get(function() return owner.Vars[State.VAR] end)
end

local function equippedItem(owner, slot)
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

Applier.EquippedItem = equippedItem

local function equippedShield(owner)
    local item = equippedItem(owner, SHIELD_SLOT)
    if item and get(function() return item.Armor.Shield end) then return item end
    return nil
end

--- Whether the engine has the weapons put away on this entity.
local function shieldBelongsOnBack(entity, context)
    if context ~= "world" and get(function() return entity.Dummy ~= nil end) then
        local flags = get(function() return entity.DummyEquipmentVisualsState.field_0 end)
        local unsheath = get(function() return entity.DummyUnsheath.field_0 end)
        return flags ~= nil and flags & DUMMY_HIDE_WEAPONS == 0 and unsheath == DUMMY_SHEATHED
    end
    local armorSet = get(function() return tostring(entity.ArmorSetState.State) end)
    if armorSet ~= nil and armorSet ~= "Normal" then return false end
    if get(function() return tostring(entity.WeaponSet.WeaponSet) end) ~= "Melee" then return false end
    local state = get(function() return tostring(entity.Unsheath.State) end)
    return state == "Sheathed" or state == "Instrument"
end

--- Whether a slot belongs to the weapon set that is not in use, and stowed
--- weapons are being shown at all. The engine draws only the set in use; a
--- row for the other set, marked as stowed, makes it draw that one as well.
local function otherSetStowed(entity, owner, context, slot)
    if context ~= "world" and get(function() return entity.Dummy ~= nil end) then
        local flags = get(function() return entity.DummyEquipmentVisualsState.field_0 end)
        if flags == nil or flags & DUMMY_HIDE_WEAPONS ~= 0 then return false end
    else
        local armorSet = get(function() return tostring(entity.ArmorSetState.State) end)
        if armorSet ~= nil and armorSet ~= "Normal" then return false end
    end
    local inUse = get(function() return tostring(owner.WeaponSet.WeaponSet) end)
    if inUse ~= "Melee" and inUse ~= "Ranged" then return false end
    return slot:sub(1, #inUse) ~= inUse
end

--- Whether the engine has finished building the slot's model. A row taken
--- out earlier than that does not stop the model from appearing afterwards.
local function modelLoaded(entity, slot)
    return get(function() return entity.ClientEquipmentVisuals.Equipment[slot].Loaded end) == true
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

local DUMMY_UNSHEATH = { [0] = "Instrument", [1] = "Melee", [2] = "Ranged", [3] = "Sheathed" }

--- "Melee" / "Ranged" when that set is in the hands, otherwise "Sheathed" / "Instrument".
function Applier.UnsheathState(entity)
    local dummy = get(function() return entity.DummyUnsheath.field_0 end)
    if dummy ~= nil then return DUMMY_UNSHEATH[dummy] end
    return get(function() return tostring(entity.Unsheath.State) end)
end

--- A drawn weapon is never hidden: the modes only concern stowed gear.
--- The row says so itself (field_8 = 1 while in the hands); the character's
--- Unsheath state changes a moment later and cannot be relied on here.
local function inHand(row)
    return row.field_8 == 1
end

--- Bring one entity's rows in line with its owner's modes.
---@return boolean changed
function Applier.Apply(entity)
    local vis = entity[COMPONENT]
    if not vis then return false end
    local owner, context = Applier.Resolve(entity)
    local modes = Applier.ModesOf(owner)
    local rows = vis.Equipment
    local changed = false
    local inUse = Applier.SetInUse(owner)

    for _, slot in ipairs(State.SLOTS) do
        local row = rows[slot]
        local hidden = State.IsHidden(State.ModeOf(modes, slot), context == "cinematic", Applier.SlotInSet(slot, inUse))
        if hidden then
            local waits = waited[entity] and waited[entity][slot] or 0
            if row and not inHand(row) and not modelLoaded(entity, slot) and waits < MAX_WAITS then
                -- Come back once the model is there (or give up waiting and hide anyway).
                waited[entity] = waited[entity] or {}
                waited[entity][slot] = waits + 1
                Ext.Timer.WaitFor(RETRY_MS, function()
                    if tracked[entity] then pending[entity] = true end
                end)
            elseif row and not inHand(row) then
                if waited[entity] then waited[entity][slot] = nil end
                stash[entity] = stash[entity] or {}
                stash[entity][slot] = { Item = row.Item, field_8 = row.field_8, field_9 = row.field_9 }
                rows[slot] = nil
                changed = true
            end
        elseif not row then
            local kept = stash[entity] and stash[entity][slot]
            if kept then
                -- Put back what we took out, unless the item has since left the slot.
                stash[entity][slot] = nil
                if equippedItem(owner, slot) == kept.Item then
                    rows[slot] = kept
                    changed = true
                end
            elseif slot == SHIELD_SLOT and shieldBelongsOnBack(entity, context) then
                local shield = equippedShield(owner)
                if shield then
                    rows[slot] = { Item = shield, field_8 = 0, field_9 = 1 }
                    changed = true
                end
            elseif State.SHOW_BOTH_SETS and otherSetStowed(entity, owner, context, slot) then
                local item = equippedItem(owner, slot)
                if item then
                    rows[slot] = { Item = item, field_8 = 0, field_9 = 1 }
                    changed = true
                end
            end
        end
    end
    return changed
end

local function safeApply(entity)
    local ok, err = pcall(Applier.Apply, entity)
    if not ok then State.Warn("apply failed:", err) end
end

--- Ask for an entity to be re-applied on the next frame.
function Applier.Refresh(entity)
    pending[entity] = true
end

--- Re-apply every tracked entity that stands for this character.
function Applier.RefreshCharacter(uuid)
    for entity in pairs(tracked) do
        local owner = Applier.Resolve(entity)
        if uuidOf(owner) == uuid then pending[entity] = true end
    end
end

function Applier.SetModes(uuid, modes)
    modeCache[uuid] = modes
    Applier.RefreshCharacter(uuid)
end

--- Modes as last told by the server, without touching the entity: safe to
--- call from UI callbacks.
function Applier.CachedModes(uuid)
    return modeCache[uuid]
end

function Applier.Tracked()
    return tracked
end

function Applier.RegisterListeners()
    Ext.Entity.OnCreateDeferred(COMPONENT, function(entity)
        pending[entity] = true
    end)

    Ext.Entity.OnDestroyDeferred(COMPONENT, function(entity)
        tracked[entity], pending[entity], stash[entity], waited[entity] = nil, nil, nil, nil
    end)

    -- Right after the engine has decided what to draw: the only point where
    -- an edit is picked up in the same frame.
    Ext.Entity.OnSystemPostUpdate("ClientVisualsVisibilityState", function()
        for entity in pairs(tracked) do
            if not pending[entity] and entity:WasChanged(COMPONENT) then
                safeApply(entity)
            end
        end
        if next(pending) then
            local batch = pending
            pending = {}
            for entity in pairs(batch) do
                tracked[entity] = true
                safeApply(entity)
                pcall(function() entity:MarkChanged(COMPONENT) end)
            end
        end
    end)

    Ext.Events.ResetCompleted:Subscribe(function()
        for _, entity in ipairs(Ext.Entity.GetAllEntitiesWithComponent(COMPONENT)) do
            pending[entity] = true
        end
    end)
end

return Applier

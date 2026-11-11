-- Console commands (Script Extender console, client context):
--   !vsws <slot|all> [mode]   set a mode on the controlled character (no mode = next mode)
--   !vsws_dump                write what the mod sees to a file, for bug reports
--   !vsws_layers [melee] [ranged]   how far, in centimetres, the melee and the ranged layer
--                             push out what is stowed on top of them (until the game restarts)

local State = Ext.Require("Shared/State.lua")
local Layers = Ext.Require("Client/Layers.lua")

local Console = {}

local function get(fn)
    local ok, v = pcall(fn)
    if ok then return v end
    return nil
end

local function controlled()
    local all = get(function() return Ext.Entity.GetAllEntitiesWithComponent("ClientControl") end)
    return all and all[1]
end

local function describe(Applier, entity)
    local owner, context = Applier.Resolve(entity)
    local rows = {}
    for slot, row in pairs(get(function() return entity.ClientEquipmentVisibilityState.Equipment end) or {}) do
        rows[tostring(slot)] = { field_8 = row.field_8, field_9 = row.field_9 }
    end
    -- Per weapon slot: what is equipped, what the engine was asked to draw, and whether it built it.
    local weapons = {}
    for _, slot in ipairs(State.SLOTS) do
        local request = get(function() return entity.ClientVisualsDesiredState.Slots[slot] end)
        local visual = get(function() return entity.ClientEquipmentVisuals.Equipment[slot] end)
        weapons[slot] = {
            Equipped = Applier.EquippedItem(owner, slot) ~= nil,
            HasRow = rows[slot] ~= nil,
            RequestBone = request and tostring(request.Bone) or nil,
            RequestSourceBone = request and tostring(request.SourceBone) or nil,
            RequestTemplates = request and get(function() return #request.VisualTemplates end) or nil,
            VisualLoaded = visual and get(function() return visual.Loaded end) or nil,
            VisualSubVisuals = visual and get(function() return #visual.SubVisuals end) or nil,
        }
    end
    return {
        Owner = get(function() return owner.Uuid.EntityUuid end),
        Context = context,
        IsPartyMember = get(function() return owner.PartyMember ~= nil end) or false,
        Unsheath = Applier.UnsheathState(entity),
        WeaponSet = get(function() return tostring(entity.WeaponSet.WeaponSet) end),
        ArmorSet = get(function() return tostring(entity.ArmorSetState.State) end),
        DummyVisualsFlags = get(function() return entity.DummyEquipmentVisualsState.field_0 end),
        Modes = Applier.ModesOf(owner),
        Rows = rows,
        Weapons = weapons,
    }
end

function Console.Register(Applier, requestMode)
    Ext.RegisterConsoleCommand("vsws", function(_, slotArg, modeArg)
        local entity = controlled()
        local uuid = entity and get(function() return entity.Uuid.EntityUuid end)
        if not uuid then State.Log("no controlled character") return end
        local slots = State.ParseSlots(slotArg)
        if not slots then State.Log(State.USAGE) return end
        for _, slot in ipairs(slots) do
            requestMode(uuid, slot, State.ParseMode(modeArg))
        end
    end)

    Ext.RegisterConsoleCommand("vsws_layers", function(_, melee, ranged)
        local t = Layers.Thickness
        t.Melee = (tonumber(melee) or t.Melee * 100) / 100
        t.Ranged = (tonumber(ranged) or t.Ranged * 100) / 100
        Applier.Rearrange()
        State.Log(("layers: melee %.1f cm, ranged %.1f cm"):format(t.Melee * 100, t.Ranged * 100))
    end)

    Ext.RegisterConsoleCommand("vsws_dump", function()
        local out = {}
        for entity in pairs(Applier.Tracked()) do
            local d = get(function() return describe(Applier, entity) end)
            -- Skip the crowd: party members and anything shown as a copy of one.
            if d and (d.IsPartyMember or d.Context ~= "world") then out[#out + 1] = d end
        end
        Ext.IO.SaveFile("Gwynerva_VisibleShields/dump.json", Ext.Json.Stringify(out))
        State.Log(("dump: %d entities -> Script Extender/Gwynerva_VisibleShields/dump.json"):format(#out))
    end)
end

return Console

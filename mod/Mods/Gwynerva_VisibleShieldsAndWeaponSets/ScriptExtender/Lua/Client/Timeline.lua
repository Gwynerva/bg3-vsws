-- Dialogues and cutscenes show copies of the characters ("timeline dummies").
-- A dummy has no ClientEquipmentVisibilityState: its gear is a list of models
-- attached to bones. Stowed weapons sit on their sheath bones, so a hidden
-- slot is found by its bone and its model is switched off.
--
-- The game keeps a pool of blank dummies and fills them in when a scene
-- starts, without any event a script could wait for. A scene is therefore
-- noticed on the real character (it carries TimelineActorData for the scene's
-- duration), and its dummies are then looked up in the pool. A dummy is
-- usually found empty within the first frames; its models arrive a little
-- later and are switched off in the frame they appear.

local State = Ext.Require("Shared/State.lua")

local Timeline = {}
local Applier -- handed in by Register

local SHIELD_BONE = "Dummy_Sheath_Shield"

-- Going through the whole pool costs milliseconds, so it is rationed:
-- every frame at the very start, every few frames until the models are
-- there, and a few times a second for the rest of the scene. Dummies already
-- found are cheap and are checked every frame - the engine now and then
-- switches a model back on in the middle of a scene.
local EAGER_FRAMES = 3
local SEARCH_EVERY_FRAMES = 4
local SLOW_SEARCH_SECONDS = 0.25

local actors = {}   -- uuid -> party character currently in a scene
local dummies = {}  -- uuid -> set of its dummies
local ready = {}    -- uuid -> true once one of its dummies had models
local frame = 0     -- frames since the newest scene started
local sinceSearch = 0
local searchedFrame = -1

local function get(fn)
    local ok, v = pcall(fn)
    if ok then return v end
    return nil
end

local function uuidOf(entity)
    return get(function() return entity.Uuid.EntityUuid end)
end

--- The character a dummy copies.
function Timeline.OwnerOf(dummy)
    local tl = dummy.TLPreviewDummy
    local ids = {}
    for _, id in ipairs(get(function() return tl.Speakers end) or {}) do ids[#ids + 1] = tostring(id) end
    ids[#ids + 1] = get(function() return tostring(tl.OriginalCharacterTemplate) end)
    for i = #ids, 1, -1 do
        local entity = get(function() return Ext.Entity.Get(ids[i]) end)
        if entity and get(function() return entity.InventoryOwner ~= nil end) then return entity end
    end
    return nil
end

--- Which sheath bone each of the owner's weapon slots is stowed on.
local function bonesOf(owner)
    local map = {}
    for _, slot in ipairs(State.SLOTS) do
        local item = Applier.EquippedItem(owner, slot)
        local eqType = item and get(function()
            return Ext.StaticData.Get(item.Equipable.EquipmentTypeID, "EquipmentType")
        end)
        if eqType then
            local fields = slot:find("OffHand")
                and { "BoneOffHandSheathed" }
                or { "BoneMainSheathed", "BoneVersatileSheathed" }
            for _, f in ipairs(fields) do
                local bone = get(function() return tostring(eqType[f]) end)
                if bone and bone ~= "" and not map[bone] then map[bone] = slot end
            end
        end
    end
    map[SHIELD_BONE] = map[SHIELD_BONE] or "MeleeOffHand"
    return map
end

-- RenderPasses is a set of flags: a number, a table or a flags object
-- depending on how it is read. Empty means the model is not drawn.
local function passesEmpty(passes)
    if type(passes) == "number" then return passes == 0 end
    if type(passes) == "table" then return next(passes) == nil end
    local n = get(function() return #passes end)
    if n ~= nil then return n == 0 end
    return get(function() return Ext.Json.Stringify(passes) end) == "[]"
end

local function isHidden(attachment)
    local any = false
    for _, od in ipairs(attachment.Visual.ObjectDescs) do
        any = true
        if not passesEmpty(od.Renderable.PropertyList.RenderPasses) then return false end
    end
    return any
end

-- What a model was drawn with before it was switched off, kept per dummy and
-- attachment so it can be switched back on.
local saved = {} -- dummy -> { [attachmentIndex] = { RenderPasses per object } }

local function hide(dummy, index, attachment)
    local passes = {}
    for i, od in ipairs(attachment.Visual.ObjectDescs) do
        local list = od.Renderable.PropertyList
        passes[i] = list.RenderPasses
        if not pcall(function() list.RenderPasses = 0 end) then
            pcall(function() list.RenderPasses = {} end)
        end
    end
    saved[dummy] = saved[dummy] or {}
    saved[dummy][index] = saved[dummy][index] or passes
end

local function show(dummy, index, attachment)
    local passes = saved[dummy] and saved[dummy][index]
    if not passes then return end
    for i, od in ipairs(attachment.Visual.ObjectDescs) do
        if passes[i] ~= nil then pcall(function() od.Renderable.PropertyList.RenderPasses = passes[i] end) end
    end
    saved[dummy][index] = nil
end

-- The other weapon set on a dummy.
--
-- The game puts on a dummy only the weapon set in use. A dummy has the same
-- equipment-visuals component as a character, with the other set's slots left
-- empty, but no "desired visuals" list above it - the game fills the slots
-- directly. Given such a list, the engine's own equipment loader builds what
-- is missing. So: create the list on the dummy, put in it everything the
-- dummy already wears (so nothing is taken off) plus the other set's requests
-- copied from the character (the engine made those; only the parent changes)
-- and flag it as changed once. The engine needs the list only to load the
-- weapons: once they are on the dummy it is removed again, and the weapons
-- stay. So for the rest of the scene the dummy is an ordinary one - nothing
-- is left to interfere when the game itself moves a dummy's weapons around,
-- or when the dummy is reused for another character.
local DESIRED = "ClientVisualsDesiredState"
local LOAD_TIMEOUT_FRAMES = 300

local DRESS_TIMEOUT_FRAMES = 600

-- How long after the load the list is removed again.
local CLEANUP_DELAY_FRAMES = 60

local otherSet = {}  -- dummy -> { Slots = {...}, Created = bool, Since = frame }, or "done"
local firstSeen = {} -- dummy -> frame it was first looked at, while waiting for it to be dressed

local function dropDesired(dummy, state)
    if type(state) == "table" and state.Created then
        pcall(function() dummy:RemoveComponent(DESIRED) end)
    end
end

--- Slots of the set not in use that should be added to this dummy, or nil
--- while the dummy is still being dressed and it is too early to tell.
local function missingSlots(owner, dummy, modes)
    local equipment = get(function() return dummy.ClientEquipmentVisuals.Equipment end)
    if not equipment then return nil end
    local inUse = get(function() return tostring(owner.WeaponSet.WeaponSet) end)
    if inUse ~= "Melee" and inUse ~= "Ranged" then return {} end

    -- Everything the game is putting on the dummy must have arrived: the list
    -- given to the engine names what the dummy wears, and a slot still loading
    -- would be left out of it.
    for _, worn in pairs(equipment) do
        if get(function() return worn.Item ~= nil end) and get(function() return worn.Loaded end) ~= true then
            return nil
        end
    end

    -- The dummy's own weapons come after its body and clothes. Until they are
    -- there, a scene that shows no weapons cannot be told from one that has
    -- not got to them yet (the caller gives up waiting after a while).
    local hasAny, shownAny = false, false
    for _, slot in ipairs(State.SLOTS) do
        if slot:sub(1, #inUse) == inUse and Applier.EquippedItem(owner, slot) then
            hasAny = true
            if get(function() return equipment[slot].Item ~= nil end) then shownAny = true end
        end
    end
    if hasAny and not shownAny then return nil end

    local slots = {}
    for _, slot in ipairs(State.SLOTS) do
        if slot:sub(1, #inUse) ~= inUse
            and State.ModeOf(modes, slot) == "Visible"
            and get(function() return equipment[slot].Item == nil end)
            and Applier.EquippedItem(owner, slot) then
            -- The character's own request for the stowed weapon, made by the engine.
            local request = get(function() return owner[DESIRED].Slots[slot] end)
            if request and (get(function() return tostring(request.Bone) end) or "") ~= "" then
                slots[#slots + 1] = slot
            end
        end
    end
    return slots
end

local function requestOtherSet(owner, dummy, modes)
    local slots = missingSlots(owner, dummy, modes)
    if slots == nil then
        -- Not dressed yet: look again next frame, for a limited time.
        firstSeen[dummy] = firstSeen[dummy] or frame
        if frame - firstSeen[dummy] > DRESS_TIMEOUT_FRAMES then
            otherSet[dummy] = "done"
            State.Debug("timeline: the dummy shows no weapons, leaving it alone")
        end
        return
    end
    if #slots == 0 then
        otherSet[dummy] = "done"
        State.Debug("timeline: nothing to add to the dummy")
        return
    end
    local created = get(function() return dummy[DESIRED] == nil end) or false
    if created and not pcall(function() dummy:CreateComponent(DESIRED) end) then
        otherSet[dummy] = "done"
        return
    end
    local desired = get(function() return dummy[DESIRED] end)
    if not desired then
        otherSet[dummy] = "done"
        return
    end
    local state = { Slots = slots, Created = created, Since = frame }
    local ok, err = pcall(function()
        for slot, worn in pairs(dummy.ClientEquipmentVisuals.Equipment) do
            if worn.VisualData ~= nil then desired.Slots[slot] = worn.VisualData end
        end
        for _, slot in ipairs(slots) do
            desired.Slots[slot] = owner[DESIRED].Slots[slot]
            desired.Slots[slot].Parent = dummy
        end
        dummy:MarkChanged(DESIRED)
    end)
    if not ok then
        State.Warn("cannot request the other weapon set on a dummy:", err)
        dropDesired(dummy, state)
        otherSet[dummy] = "done"
        return
    end
    otherSet[dummy] = state
    State.Debug("timeline: requested", table.concat(slots, ", "), "on a dummy")
end

--- Add the other weapon set to a dummy once, then clean up after the load.
local function ensureOtherSet(owner, dummy, modes)
    if not State.SHOW_BOTH_SETS then return end
    local state = otherSet[dummy]
    if state == "done" then return end
    if state == nil then
        requestOtherSet(owner, dummy, modes)
        return
    end
    local loaded = true
    for _, slot in ipairs(state.Slots) do
        if get(function() return dummy.ClientEquipmentVisuals.Equipment[slot].Loaded end) ~= true then loaded = false end
    end
    if state.Settled then
        -- A moment after the load the list is taken away again; the weapons
        -- built from it stay on the dummy.
        if frame - state.Settled > CLEANUP_DELAY_FRAMES then
            dropDesired(dummy, state)
            otherSet[dummy] = "done"
            State.Debug("timeline: list removed after the load")
        end
        return
    end
    if loaded then
        state.Settled = frame
        State.Debug("timeline: other weapon set loaded")
    elseif frame - state.Since > LOAD_TIMEOUT_FRAMES then
        dropDesired(dummy, state)
        otherSet[dummy] = "done"
        State.Debug("timeline: other weapon set timed out")
    end
end

--- Forget a dummy that is no longer ours, removing what was put on it.
local function release(dummy)
    dropDesired(dummy, otherSet[dummy])
    otherSet[dummy], saved[dummy], firstSeen[dummy] = nil, nil, nil
end

--- Bring one dummy's stowed weapons in line with its owner's modes.
---@return boolean hasModels
local function applyDummy(owner, dummy)
    local attachments = get(function() return dummy.Visual.Visual.Attachments end)
    if not attachments or #attachments == 0 then return false end
    local modes = Applier.ModesOf(owner)
    local bones = bonesOf(owner)
    local inUse = Applier.SetInUse(owner)
    ensureOtherSet(owner, dummy, modes)

    for index, attachment in ipairs(attachments) do
        local slot = bones[get(function() return tostring(attachment.Bone1) end) or ""]
        if not slot then
            -- A scene may draw a weapon: once it leaves its sheath bone it is shown again.
            if saved[dummy] and saved[dummy][index] then pcall(show, dummy, index, attachment) end
        else
            -- On a sheath bone the weapon is stowed, so its mode applies.
            local wantHidden = State.IsHidden(State.ModeOf(modes, slot), true, Applier.SlotInSet(slot, inUse))
            local ok, hiddenNow = pcall(isHidden, attachment)
            if not ok then
                State.Warn("cannot read a dummy's model:", hiddenNow)
            elseif wantHidden and not hiddenNow then
                pcall(hide, dummy, index, attachment)
            elseif not wantHidden and hiddenNow then
                pcall(show, dummy, index, attachment)
            end
        end
    end
    return true
end

local function allReady()
    for uuid in pairs(actors) do
        if not ready[uuid] then return false end
    end
    return true
end

--- Look through the pool for dummies of the characters in a scene.
local function search()
    if searchedFrame == frame then return end
    local due
    if frame <= EAGER_FRAMES then
        due = true
    elseif not allReady() then
        due = frame % SEARCH_EVERY_FRAMES == 0
    else
        due = sinceSearch >= SLOW_SEARCH_SECONDS
    end
    if not due then return end
    searchedFrame, sinceSearch = frame, 0

    for _, dummy in ipairs(get(function() return Ext.Entity.GetAllEntitiesWithComponent("TLPreviewDummy") end) or {}) do
        if get(function() return dummy.TLPreviewDummy.ActiveDummy end) then
            local owner = Timeline.OwnerOf(dummy)
            local uuid = owner and uuidOf(owner)
            if uuid and actors[uuid] and not dummies[uuid][dummy] then
                dummies[uuid][dummy] = true
                State.Debug("timeline: frame", frame, "found a dummy of", uuid:sub(1, 8))
            end
        end
    end
end

local function check()
    pcall(search)
    for uuid, owner in pairs(actors) do
        for dummy in pairs(dummies[uuid]) do
            local stillOurs = get(function() return dummy.TLPreviewDummy ~= nil end)
                and uuidOf(Timeline.OwnerOf(dummy)) == uuid
            if not stillOurs then
                dummies[uuid][dummy] = nil -- handed back to the pool
                release(dummy)
            else
                local ok, hasModels = pcall(applyDummy, owner, dummy)
                if not ok then
                    State.Warn("timeline apply failed:", hasModels)
                elseif hasModels then
                    ready[uuid] = true
                end
            end
        end
    end
end

local function sceneStarted(entity)
    if not get(function() return entity.PartyMember ~= nil end) then return end
    local uuid = uuidOf(entity)
    if not uuid or actors[uuid] then return end
    actors[uuid], dummies[uuid], ready[uuid] = entity, {}, nil
    frame, searchedFrame, sinceSearch = 0, -1, 0
    State.Debug("timeline: scene started for", uuid:sub(1, 8))
end

local function sceneEnded(entity)
    local uuid = uuidOf(entity)
    if not uuid or not actors[uuid] then return end
    -- Models are not switched back on: the dummy is still on screen for a
    -- moment and is discarded with its models right after.
    for dummy in pairs(dummies[uuid]) do release(dummy) end
    actors[uuid], dummies[uuid], ready[uuid] = nil, nil, nil
    State.Debug("timeline: scene ended for", uuid:sub(1, 8))
end

function Timeline.Register(applier)
    Applier = applier

    Ext.Entity.OnCreateDeferred("TimelineActorData", sceneStarted)
    Ext.Entity.OnDestroyDeferred("TimelineActorData", sceneEnded)

    Ext.Events.Tick:Subscribe(function(e)
        if not next(actors) then return end
        frame = frame + 1
        sinceSearch = sinceSearch + (get(function() return e.Time.DeltaTime end) or 0.016)
        check()
    end)

    -- Right after the engine has built models this frame, so a stowed weapon
    -- is switched off before the frame is drawn rather than one frame later.
    for _, system in ipairs({ "ClientEquipmentVisuals", "ClientVisual", "Visual" }) do
        pcall(Ext.Entity.OnSystemPostUpdate, system, function()
            if next(actors) then check() end
        end)
    end

    Ext.Events.ResetCompleted:Subscribe(function()
        for _, entity in ipairs(get(function() return Ext.Entity.GetAllEntitiesWithComponent("TimelineActorData") end) or {}) do
            sceneStarted(entity)
        end
    end)
end

return Timeline

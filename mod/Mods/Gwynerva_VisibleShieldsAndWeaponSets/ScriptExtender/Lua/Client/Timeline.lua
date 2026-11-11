-- Dialogues and cutscenes show copies of the characters ("timeline dummies").
-- A dummy has no ClientEquipmentVisibilityState: its gear is a list of models
-- attached to bones. Stowed weapons sit on their sheath bones, so a hidden
-- slot is found by its bone and its model is switched off.
--
-- The game keeps a pool of blank dummies and fills them in when a scene
-- starts, without any event a script could wait for. A scene is therefore
-- noticed on the real character (it carries TimelineActorData for the scene's
-- duration), and its dummy is then asked from the engine's own table of the
-- scene's actors (see lookup). A dummy is usually found empty within the
-- first frames; its models arrive a little later and are switched off in the
-- frame they appear.
--
-- This runs every frame while a scene is on, so the steady state is kept
-- cheap: a dummy is gone through in full only when something about it has
-- changed, and otherwise only the models switched off earlier are looked at.

local State = Ext.Require("Shared/State.lua")
local Layers = Ext.Require("Client/Layers.lua")

local Timeline = {}
local Applier -- handed in by Register

local SHIELD_BONE = "Dummy_Sheath_Shield"
local DESIRED = "ClientVisualsDesiredState"

-- Asking the engine for a character's dummy: every frame while the scene is
-- being set up, then now and then in case the dummy is replaced.
local LOOKUP_EAGER_FRAMES = 30
local LOOKUP_EVERY_FRAMES = 10

-- The fallback, should the engine's table be out of reach (another Script
-- Extender version) or have no dummy for a character: the pool is searched.
-- Going through all of it (hundreds of dummies) costs milliseconds, so that
-- is done in one go only where a late find would show: every frame at the
-- very start of a scene, then every few frames for a short while if a
-- character still has no dressed dummy. Otherwise the pool is gone through a
-- few dummies per frame, from a list refreshed now and then.
local EAGER_SEARCH_FRAMES = 3
local HURRY_EVERY_FRAMES = 4
local HURRY_FRAMES = 120
local SEARCH_SLICE = 40
local POOL_REFRESH_SECONDS = 5

-- For this many frames after a dummy is found or gains a model, it is also
-- checked right after the engine's visual systems, so that a model is
-- switched off in the frame it appears rather than one frame later.
local SAME_FRAME_FRAMES = 30

-- The other weapon set (see requestOtherSet): how often a dummy is checked
-- for being fully dressed, and the limits on the waiting.
local DRESS_CHECK_EVERY_FRAMES = 3
local DRESS_TIMEOUT_FRAMES = 600
local LOAD_TIMEOUT_FRAMES = 300
local CLEANUP_DELAY_FRAMES = 60

-- How often a dummy's stowed weapons are arranged in layers again.
local ARRANGE_EVERY_FRAMES = 15

local actors = {}   -- uuid -> party character currently in a scene
local records = {}  -- dummy -> what is known about it (see track)
local frame = 0     -- frames since the newest scene started
local pool = {}     -- the dummies in the game's pool, as last listed
local cursor = 1    -- where in the pool the piecemeal search has got to
local sinceListed = 0
local directWorks = false -- whether the engine's own table of actors could be read last time
local searchedFrame = -1
local sameFrameUntil = 0

local function get(fn)
    local ok, v = pcall(fn)
    if ok then return v end
    return nil
end

local function uuidOf(entity)
    return get(function() return entity.Uuid.EntityUuid end)
end

--- The character a dummy copies, if it can be told.
function Timeline.OwnerOf(dummy)
    local tl = dummy.TLPreviewDummy
    if not tl then return nil end
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

local function boneOf(attachment)
    return tostring(attachment.Attach)
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

local function switchOff(attachment)
    for _, od in ipairs(attachment.Visual.ObjectDescs) do
        local list = od.Renderable.PropertyList
        if not pcall(function() list.RenderPasses = 0 end) then
            pcall(function() list.RenderPasses = {} end)
        end
    end
end

--- Switch a model off, remembering how it was drawn and where it was attached.
local function hide(record, index, attachment, bone)
    local entry = record.Hidden[index]
    if not entry then
        local passes = {}
        for i, od in ipairs(attachment.Visual.ObjectDescs) do passes[i] = od.Renderable.PropertyList.RenderPasses end
        entry = { Passes = passes }
        record.Hidden[index] = entry
    end
    entry.Bone = bone
    switchOff(attachment)
end

--- Switch a model back on, if it is one that was switched off here.
local function show(record, index, attachment)
    local entry = record.Hidden[index]
    if not entry then return end
    for i, od in ipairs(attachment.Visual.ObjectDescs) do
        if entry.Passes[i] ~= nil then pcall(function() od.Renderable.PropertyList.RenderPasses = entry.Passes[i] end) end
    end
    record.Hidden[index] = nil
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

--- Remove the list from a dummy, if it was put there by this mod.
local function dropDesired(dummy, record)
    local request = record.OtherSet
    if type(request) == "table" and request.Created then
        pcall(function() dummy:RemoveComponent(DESIRED) end)
        request.Created = false
    end
end

--- Slots of the set not in use that should be added to this dummy, or nil
--- while the dummy is still being dressed and it is too early to tell.
local function missingSlots(owner, dummy, modes)
    local equipment = get(function() return dummy.ClientEquipmentVisuals.Equipment end)
    if not equipment then return nil end
    local inUse = Applier.SetInUse(owner)
    if not inUse then return {} end

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
        if Applier.SlotInSet(slot, inUse) and Applier.EquippedItem(owner, slot) then
            hasAny = true
            if get(function() return equipment[slot].Item ~= nil end) then shownAny = true end
        end
    end
    if hasAny and not shownAny then return nil end

    local slots = {}
    for _, slot in ipairs(State.SLOTS) do
        if not Applier.SlotInSet(slot, inUse)
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

local function requestOtherSet(dummy, record, modes)
    local owner = record.Owner
    local slots = missingSlots(owner, dummy, modes)
    if slots == nil then
        -- Not dressed yet: look again shortly, for a limited time.
        if frame - record.Found > DRESS_TIMEOUT_FRAMES then
            record.OtherSet = "done"
            State.Debug("timeline: the dummy shows no weapons, leaving it alone")
        end
        return
    end
    if #slots == 0 then
        record.OtherSet = "done"
        return
    end

    local created = get(function() return dummy[DESIRED] == nil end) or false
    if created then pcall(function() dummy:CreateComponent(DESIRED) end) end
    local desired = get(function() return dummy[DESIRED] end)
    if not desired then
        record.OtherSet = "done"
        return
    end
    record.OtherSet = { Slots = slots, Created = created, Since = frame }
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
        dropDesired(dummy, record)
        record.OtherSet = "done"
        return
    end
    State.Debug("timeline: requested", table.concat(slots, ", "), "on a dummy")
end

--- Add the other weapon set to a dummy once, then clean up after the load.
local function ensureOtherSet(dummy, record, modes)
    local request = record.OtherSet
    if request == "done" or frame % DRESS_CHECK_EVERY_FRAMES ~= 0 then return end
    if request == nil then
        requestOtherSet(dummy, record, modes)
        return
    end
    if request.Loaded then
        if frame - request.Loaded > CLEANUP_DELAY_FRAMES then
            dropDesired(dummy, record)
            record.OtherSet = "done"
            State.Debug("timeline: other weapon set loaded, list removed")
        end
        return
    end
    local loaded = true
    for _, slot in ipairs(request.Slots) do
        if get(function() return dummy.ClientEquipmentVisuals.Equipment[slot].Loaded end) ~= true then loaded = false end
    end
    if loaded then
        request.Loaded = frame
    elseif frame - request.Since > LOAD_TIMEOUT_FRAMES then
        dropDesired(dummy, record)
        record.OtherSet = "done"
        State.Debug("timeline: other weapon set timed out")
    end
end

--- Start keeping track of a dummy.
local function track(dummy, owner, uuid, direct)
    records[dummy] = {
        Owner = owner,
        Uuid = uuid,
        Direct = direct,    -- found through the engine's table rather than in the pool
        Found = frame,
        Hidden = {},        -- attachment index -> { Passes, Bone } of a model switched off here
        Count = -1,         -- number of attachments at the last full pass
        ModesVersion = -1,  -- Applier.ModesVersion() at the last full pass
        OtherSet = (not State.SHOW_BOTH_SETS) and "done" or nil,
    }
    sameFrameUntil = frame + SAME_FRAME_FRAMES
    State.Debug("timeline: frame", frame, "found a dummy of", uuid:sub(1, 8), direct and "(asked the engine)" or "(in the pool)")
end

--- Forget a dummy, removing what was put on it.
local function release(dummy)
    local record = records[dummy]
    if record then dropDesired(dummy, record) end
    records[dummy] = nil
end

--- Go through all of a dummy's models and bring them in line with the modes.
local function fullPass(dummy, record, attachments, modes)
    local owner = record.Owner
    local bones = bonesOf(owner)
    local inUse = Applier.SetInUse(owner)
    for index, attachment in ipairs(attachments) do
        local bone = boneOf(attachment)
        local slot = bones[bone]
        if not slot then
            -- A scene may draw a weapon: once it leaves its sheath bone it is shown again.
            show(record, index, attachment)
        else
            -- On a sheath bone the weapon is stowed, so its mode applies.
            local wantHidden = State.IsHidden(State.ModeOf(modes, slot), true, Applier.SlotInSet(slot, inUse))
            local hiddenNow = isHidden(attachment)
            if wantHidden and not hiddenNow then
                hide(record, index, attachment, bone)
            elseif not wantHidden and hiddenNow then
                show(record, index, attachment)
            end
        end
    end
    -- Entries for models that are no longer there.
    for index in pairs(record.Hidden) do
        if index > #attachments then record.Hidden[index] = nil end
    end
end

--- Look only at the models switched off earlier.
---@return boolean ok false if something moved and a full pass is needed
local function quickPass(record, attachments)
    for index, entry in pairs(record.Hidden) do
        local attachment = attachments[index]
        if not attachment or boneOf(attachment) ~= entry.Bone then return false end
        -- The engine now and then switches a model back on in the middle of a scene.
        if not isHidden(attachment) then switchOff(attachment) end
    end
    return true
end

--- The dummy the engine has registered for a character in its scene, if any
--- yet. The character names its scene and its part in it; the scene keeps a
--- table of the entities playing each part. Throws if that is out of reach.
local function lookup(actor)
    local data = actor.TimelineActorData
    if not data then return nil end
    local timeline = Ext.System.ClientTimeline.Timelines[tostring(data.Timeline)]
    return timeline and timeline.RegisteredActors[tostring(data.Actor)] or nil
end

--- Whether a tracked dummy still copies the character it was found for.
local function stillOf(dummy, record)
    if record.Direct then
        return get(function() return lookup(record.Owner) end) == dummy
    end
    return uuidOf(Timeline.OwnerOf(dummy)) == record.Uuid
end

--- Bring one dummy in line with its owner's modes.
local function apply(dummy, record)
    -- A dummy is found before it has a model: nothing to do until then.
    local attachments = get(function() return dummy.Visual.Visual.Attachments end)
    local count = attachments and #attachments or 0
    if count == 0 then return end
    local modes = Applier.ModesOf(record.Owner)

    local version = Applier.ModesVersion()
    if count ~= record.Count or version ~= record.ModesVersion or not quickPass(record, attachments) then
        if count ~= record.Count then sameFrameUntil = frame + SAME_FRAME_FRAMES end
        -- Has the pool handed this dummy to another character in the meantime?
        if not stillOf(dummy, record) then
            release(dummy)
            return
        end
        fullPass(dummy, record, attachments, modes)
        record.Count, record.ModesVersion = count, version
        record.Arranged = nil
    end
    -- Stowed weapons in layers: at once after a change, then now and then,
    -- as a model may be swapped without the count changing.
    if not record.Arranged or frame - record.Arranged >= ARRANGE_EVERY_FRAMES then
        record.Arranged = frame
        local ok, err = pcall(Layers.Arrange, dummy, function(index) return record.Hidden[index] ~= nil end)
        if not ok then State.Warn("arranging a dummy failed:", err) end
    end
    ensureOtherSet(dummy, record, modes)
end

--- Whether every character in a scene has a dummy with models on it.
local function allDressed()
    local dressed = {}
    for _, record in pairs(records) do
        if record.Count > 0 then dressed[record.Uuid] = true end
    end
    for uuid in pairs(actors) do
        if not dressed[uuid] then return false end
    end
    return true
end

-- With State.DEBUG on: what the per-frame work costs, reported per scene.
local cost = { Calls = 0, Total = 0, Max = 0, Listing = 0 }

local function listPool()
    local started = State.DEBUG and Ext.Utils.MonotonicTime()
    pool = Ext.Entity.GetAllEntitiesWithComponent("TLPreviewDummy")
    cursor, sinceListed = 1, 0
    if started then cost.Listing = math.max(cost.Listing, Ext.Utils.MonotonicTime() - started) end
end

--- Start tracking a dummy from the pool if it copies a character in a scene.
local function consider(dummy)
    if records[dummy] then return end
    -- Blank dummies in the pool may not give the component to a script at all.
    local tl = dummy.TLPreviewDummy
    if not (tl and tl.ActiveDummy) then return end
    local owner = Timeline.OwnerOf(dummy)
    local uuid = owner and uuidOf(owner)
    if uuid and actors[uuid] then track(dummy, owner, uuid) end
end

--- Whether every character in a scene has a dummy.
local function allFound()
    local found = {}
    for _, record in pairs(records) do found[record.Uuid] = true end
    for uuid in pairs(actors) do
        if not found[uuid] then return false end
    end
    return true
end

--- Ask the engine for the dummies of the characters in a scene.
---@return boolean ok false if the engine's table is out of reach
local function searchDirect()
    for uuid, actor in pairs(actors) do
        local ok, dummy = pcall(lookup, actor)
        if not ok then return false end
        if dummy and not records[dummy] and get(function() return dummy.TLPreviewDummy.ActiveDummy end) then
            track(dummy, actor, uuid, true)
        end
    end
    return true
end

--- Go through the next few dummies of the pool.
local function searchSlice()
    if cursor > #pool then
        if sinceListed >= POOL_REFRESH_SECONDS or #pool == 0 then listPool() else cursor = 1 end
    end
    local last = math.min(cursor + SEARCH_SLICE - 1, #pool)
    for i = cursor, last do pcall(consider, pool[i]) end
    cursor = last + 1
end

--- Find the dummies of the characters in a scene.
local function search()
    if searchedFrame == frame then return end
    searchedFrame = frame

    local everyoneFound = allFound()
    if frame <= LOOKUP_EAGER_FRAMES or frame % LOOKUP_EVERY_FRAMES == 0 or not everyoneFound then
        directWorks = searchDirect()
        everyoneFound = allFound()
    end

    if directWorks then
        -- A character the engine names no dummy for long after the scene has
        -- started: look in the pool as well, a little at a time.
        if not everyoneFound and frame > LOOKUP_EAGER_FRAMES then searchSlice() end
    elseif frame <= EAGER_SEARCH_FRAMES
        or (frame <= HURRY_FRAMES and frame % HURRY_EVERY_FRAMES == 0 and not allDressed()) then
        listPool()
        for _, dummy in ipairs(pool) do pcall(consider, dummy) end
    else
        searchSlice()
    end
end

local function check()
    local started = State.DEBUG and Ext.Utils.MonotonicTime()
    local ok, err = pcall(search)
    if not ok then State.Warn("timeline search failed:", err) end
    for dummy, record in pairs(records) do
        if not actors[record.Uuid] or get(function() return dummy.TLPreviewDummy ~= nil end) ~= true then
            release(dummy) -- the scene is over, or the dummy went back to the pool
        else
            ok, err = pcall(apply, dummy, record)
            if not ok then State.Warn("timeline apply failed:", err) end
        end
    end
    if started then
        local took = Ext.Utils.MonotonicTime() - started
        cost.Calls, cost.Total = cost.Calls + 1, cost.Total + took
        if took > cost.Max then cost.Max = took end
    end
end

local function sceneStarted(entity)
    if not get(function() return entity.PartyMember ~= nil end) then return end
    local uuid = uuidOf(entity)
    if not uuid or actors[uuid] then return end
    actors[uuid] = entity
    frame, searchedFrame, sameFrameUntil = 0, -1, SAME_FRAME_FRAMES
    State.Debug("timeline: scene started for", uuid:sub(1, 8))
end

local function sceneEnded(entity)
    local uuid = uuidOf(entity)
    if not uuid or not actors[uuid] then return end
    actors[uuid] = nil
    -- Models are not switched back on: the dummy is still on screen for a
    -- moment and is discarded with its models right after.
    for dummy, record in pairs(records) do
        if record.Uuid == uuid then release(dummy) end
    end
    State.Debug("timeline: scene ended for", uuid:sub(1, 8))
    if next(actors) then return end
    if cost.Calls > 0 then
        State.Debug(("timeline: %d checks over %d frames, %.3f ms on average, %d ms at most; direct lookup %s, pool listed %d"):format(
            cost.Calls, frame, cost.Total / cost.Calls, cost.Max, tostring(directWorks), #pool))
        cost = { Calls = 0, Total = 0, Max = 0, Listing = 0 }
    end
    pool, cursor = {}, 1
end

function Timeline.Register(applier)
    Applier = applier

    Ext.Entity.OnCreateDeferred("TimelineActorData", sceneStarted)
    Ext.Entity.OnDestroyDeferred("TimelineActorData", sceneEnded)

    Ext.Events.Tick:Subscribe(function(e)
        if not next(actors) then return end
        frame = frame + 1
        sinceListed = sinceListed + (get(function() return e.Time.DeltaTime end) or 0.016)
        check()
    end)

    -- While a dummy is being dressed: also right after the engine has built
    -- models this frame, so a stowed weapon is switched off before the frame
    -- is drawn rather than one frame later.
    for _, system in ipairs({ "ClientEquipmentVisuals", "ClientVisual", "Visual" }) do
        pcall(Ext.Entity.OnSystemPostUpdate, system, function()
            if next(actors) and frame <= sameFrameUntil then check() end
        end)
    end

    Ext.Events.ResetCompleted:Subscribe(function()
        for _, entity in ipairs(get(function() return Ext.Entity.GetAllEntitiesWithComponent("TimelineActorData") end) or {}) do
            sceneStarted(entity)
        end
    end)
end

return Timeline

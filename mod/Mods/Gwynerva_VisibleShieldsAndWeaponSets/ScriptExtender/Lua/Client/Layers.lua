-- Stowed weapons in layers.
--
-- With both weapon sets and the shield shown, several things hang on the back
-- at the same depth and pass through each other: the sheath bones sit within
-- a centimetre or two of one another. So what is stowed on the back is spread
-- out, nearest first: the melee set, then the ranged set, then the shield.
--
-- Every model attached to a character has an offset in the frame of the bone
-- it hangs on, which the engine applies each frame. A layer is pushed out
-- along the bone's axis that points away from the back, by the thickness of
-- the layers actually present beneath it - a shield with nothing under it
-- stays where the game puts it.

local State = Ext.Require("Shared/State.lua")

local Layers = {}

-- The sheath bones on the back, and which way their Y axis points: 1 if away
-- from the back, -1 if towards it. (Measured in game; a bone not listed here
-- is left alone.)
local BACK_BONES = {
    Dummy_Sheath_Upper_R = 1,
    Dummy_Sheath_Upper_L = -1,
    Dummy_Sheath_Lower_R = -1,
    Dummy_Sheath_Lower_L = 1,
    Dummy_Sheath_Ranged = 1,
    Dummy_Sheath_Shield = -1,
}
local SHIELD_BONE = "Dummy_Sheath_Shield"

-- How far, in metres, a layer pushes out what lies on top of it.
-- (The console command !vsws_layers changes these for the session, to try values out.)
local THICKNESS = { Melee = 0.05, Ranged = 0.05 }
Layers.Thickness = THICKNESS

local EPSILON = 0.001

local function get(fn)
    local ok, v = pcall(fn)
    if ok then return v end
    return nil
end

local function layerOf(slot, bone)
    if bone == SHIELD_BONE then return "Shield" end
    return slot:sub(1, 6) == "Ranged" and "Ranged" or "Melee"
end

--- The models of the entity's weapon slots among its attachments.
---@return table[] found { Index, Attachment, Slot, Bone }
function Layers.Find(entity, attachments)
    local found = {}
    local equipment = get(function() return entity.ClientEquipmentVisuals.Equipment end)
    if not equipment then return found end
    for _, slot in ipairs(State.SLOTS) do
        for _, part in ipairs(get(function() return equipment[slot].SubVisuals end) or {}) do
            local visual = get(function() return part.Visual.Visual end)
            if visual then
                for index, attachment in ipairs(attachments) do
                    if attachment.Visual == visual then
                        found[#found + 1] = { Index = index, Attachment = attachment, Slot = slot, Bone = tostring(attachment.Attach) }
                        break
                    end
                end
            end
        end
    end
    return found
end

--- Spread out what an entity has stowed on its back.
---@param isHidden (fun(index: integer): boolean)? whether the attachment at an index is not drawn
function Layers.Arrange(entity, isHidden)
    local attachments = get(function() return entity.Visual.Visual.Attachments end)
    if not attachments or #attachments == 0 then return end
    local found = Layers.Find(entity, attachments)

    local present = {}
    for _, item in ipairs(found) do
        if BACK_BONES[item.Bone] and not (isHidden and isHidden(item.Index)) then
            present[layerOf(item.Slot, item.Bone)] = true
        end
    end
    local depth = { Melee = 0 }
    depth.Ranged = present.Melee and THICKNESS.Melee or 0
    depth.Shield = depth.Ranged + (present.Ranged and THICKNESS.Ranged or 0)

    for _, item in ipairs(found) do
        -- Off a sheath bone the weapon is in the hands: no offset there.
        local direction = BACK_BONES[item.Bone]
        local want = direction and direction * depth[layerOf(item.Slot, item.Bone)] or 0
        local now = item.Attachment.Offset
        if math.abs(now[1]) > EPSILON or math.abs(now[2] - want) > EPSILON or math.abs(now[3]) > EPSILON then
            item.Attachment.Offset = { 0, want, 0 }
        end
    end
end

return Layers

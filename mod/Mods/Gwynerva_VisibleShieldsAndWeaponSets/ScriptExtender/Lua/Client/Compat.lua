-- Load-order check for mods that carry their own copy of the UI templates
-- this mod changes.
--
-- Such a mod does not conflict in content - its copies are the game's own,
-- unmodified - but whichever of the two is loaded later wins. Loaded after
-- this mod, it puts the game's templates back and the visibility buttons
-- silently disappear. The mod keeps working (modes still apply; `!vsws` in the
-- console still sets them), so the player is told how to get the buttons back.

local State = Ext.Require("Shared/State.lua")

local Compat = {}

-- UUID -> name. Checked against the installed version's files; add a mod here
-- only after confirming that its copies of the templates are unmodified.
Compat.TEMPLATE_COPIES = {
    ["6b585be8-ed73-7347-2c58-73146e22b7d4"] = "Better Inventory UI",
}

--- Names of the listed mods that are loaded after this one.
---@param order string[] mod UUIDs in load order
---@param self string this mod's UUID
function Compat.LoadedAfter(order, self)
    local late, seenSelf = {}, false
    for _, uuid in ipairs(order) do
        uuid = tostring(uuid)
        if uuid == self then
            seenSelf = true
        elseif seenSelf and Compat.TEMPLATE_COPIES[uuid] then
            late[#late + 1] = Compat.TEMPLATE_COPIES[uuid]
        end
    end
    return late
end

function Compat.Check()
    local ok, order = pcall(Ext.Mod.GetLoadOrder)
    if not ok or type(order) ~= "table" then return end
    for _, name in ipairs(Compat.LoadedAfter(order, ModuleUUID)) do
        State.Warn(name .. " is loaded after Visible Shields and Weapon Sets and replaces its slot buttons. "
            .. "Move Visible Shields and Weapon Sets below " .. name .. " in the load order.")
    end
end

return Compat

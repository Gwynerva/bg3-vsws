local State = Ext.Require("Shared/State.lua")
local Applier = Ext.Require("Client/Applier.lua")
local Timeline = Ext.Require("Client/Timeline.lua")
local UI = Ext.Require("Client/UI.lua")
local Console = Ext.Require("Client/Console.lua")
local Compat = Ext.Require("Client/Compat.lua")

State.RegisterVariable()

Ext.Net.CreateChannel(ModuleUUID, State.CH_CHANGED, function(msg)
    if type(msg) == "table" and type(msg.Entity) == "string" then
        Applier.SetModes(msg.Entity, msg.Modes or {})
    end
end)
local setChannel = Ext.Net.CreateChannel(ModuleUUID, State.CH_SET)
local helloChannel = Ext.Net.CreateChannel(ModuleUUID, State.CH_HELLO)

--- Ask the server to change a slot's mode (nil mode = the next one).
local function requestMode(uuid, slot, mode)
    setChannel:SendToServer({ Entity = uuid, Slot = slot, Mode = mode })
end

local function askForModes()
    pcall(function() helloChannel:SendToServer({}) end)
end

Console.Register(Applier, requestMode)

Ext.Events.SessionLoaded:Subscribe(function()
    Applier.RegisterListeners()
    Timeline.Register(Applier)
    UI.Register(Applier, requestMode)
    askForModes()
    Compat.Check()
    State.Debug("loaded")
end)

-- Once more when the game is actually running: by then the server answers for sure.
Ext.Events.GameStateChanged:Subscribe(function(e)
    if tostring(e.ToState) == "Running" then askForModes() end
end)
Ext.Events.ResetCompleted:Subscribe(askForModes)

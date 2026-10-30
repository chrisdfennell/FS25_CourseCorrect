-- Guidance: a setting that only matters when the helper starts (start at, refill / unload station...) changed on a
-- vehicle. It goes to the server (which starts helpers from the game's menu and saves it) and from there to the
-- other players; the course is not made again.

GuidanceSettingEvent = {}
local GuidanceSettingEvent_mt = Class(GuidanceSettingEvent, Event)

InitEventClass(GuidanceSettingEvent, "GuidanceSettingEvent")

function GuidanceSettingEvent.emptyNew()
    return Event.new(GuidanceSettingEvent_mt)
end

function GuidanceSettingEvent.new(vehicle, name, value)
    local self = GuidanceSettingEvent.emptyNew()
    self.vehicle = vehicle
    self.name = name
    self.value = value
    return self
end

function GuidanceSettingEvent:writeStream(streamId, connection)
    NetworkUtil.writeNodeObject(streamId, self.vehicle)
    streamWriteString(streamId, self.name)
    streamWriteFloat32(streamId, self.value)
end

function GuidanceSettingEvent:readStream(streamId, connection)
    self.vehicle = NetworkUtil.readNodeObject(streamId)
    self.name = streamReadString(streamId)
    self.value = streamReadFloat32(streamId)
    self:run(connection)
end

function GuidanceSettingEvent:run(connection)
    if self.vehicle ~= nil and self.vehicle.guidanceSetStartSetting ~= nil then
        self.vehicle:guidanceSetStartSetting(self.name, self.value, true)
        -- the server passes it on to the other players
        if not connection:getIsServer() then
            g_server:broadcastEvent(self, false, connection, self.vehicle)
        end
    end
end

function GuidanceSettingEvent.sendEvent(vehicle, name, value)
    if g_server ~= nil then
        g_server:broadcastEvent(GuidanceSettingEvent.new(vehicle, name, value), false, nil, vehicle)
    elseif g_client ~= nil then
        g_client:getServerConnection():sendEvent(GuidanceSettingEvent.new(vehicle, name, value))
    end
end

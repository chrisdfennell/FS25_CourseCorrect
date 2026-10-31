-- Guidance: "go" with a saved course: the server loads it on the vehicle and sends it there (AutoDrive to the course's
-- marker, its helper button on so that it starts us on arrival). Clients send it to the server.

GuidanceGoEvent = {}
local GuidanceGoEvent_mt = Class(GuidanceGoEvent, Event)

InitEventClass(GuidanceGoEvent, "GuidanceGoEvent")

function GuidanceGoEvent.emptyNew()
    return Event.new(GuidanceGoEvent_mt)
end

function GuidanceGoEvent.new(vehicle, entryId)
    local self = GuidanceGoEvent.emptyNew()
    self.vehicle = vehicle
    self.entryId = entryId
    return self
end

function GuidanceGoEvent:writeStream(streamId, connection)
    NetworkUtil.writeNodeObject(streamId, self.vehicle)
    streamWriteInt32(streamId, self.entryId)
end

function GuidanceGoEvent:readStream(streamId, connection)
    self.vehicle = NetworkUtil.readNodeObject(streamId)
    self.entryId = streamReadInt32(streamId)
    self:run(connection)
end

function GuidanceGoEvent:run(connection)
    if self.vehicle ~= nil and self.vehicle.guidanceGoTo ~= nil and not connection:getIsServer() then
        self.vehicle:guidanceGoTo(self.entryId, true)
    end
end

function GuidanceGoEvent.sendEvent(vehicle, entryId)
    if g_server == nil and g_client ~= nil then
        g_client:getServerConnection():sendEvent(GuidanceGoEvent.new(vehicle, entryId))
    end
end

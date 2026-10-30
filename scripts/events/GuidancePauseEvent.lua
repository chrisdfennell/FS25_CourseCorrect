-- Guidance: pause or resume the helper of a vehicle. Clients send it to the server, which runs the helper; the
-- paused state goes back to everyone with the vehicle's updates.

GuidancePauseEvent = {}
local GuidancePauseEvent_mt = Class(GuidancePauseEvent, Event)

InitEventClass(GuidancePauseEvent, "GuidancePauseEvent")

function GuidancePauseEvent.emptyNew()
    return Event.new(GuidancePauseEvent_mt)
end

function GuidancePauseEvent.new(vehicle, paused)
    local self = GuidancePauseEvent.emptyNew()
    self.vehicle = vehicle
    self.paused = paused
    return self
end

function GuidancePauseEvent:writeStream(streamId, connection)
    NetworkUtil.writeNodeObject(streamId, self.vehicle)
    streamWriteBool(streamId, self.paused)
end

function GuidancePauseEvent:readStream(streamId, connection)
    self.vehicle = NetworkUtil.readNodeObject(streamId)
    self.paused = streamReadBool(streamId)
    self:run(connection)
end

function GuidancePauseEvent:run(connection)
    if self.vehicle ~= nil and self.vehicle.guidanceSetPaused ~= nil and not connection:getIsServer() then
        self.vehicle:guidanceSetPaused(self.paused, true)
    end
end

function GuidancePauseEvent.sendEvent(vehicle, paused)
    if g_server == nil and g_client ~= nil then
        g_client:getServerConnection():sendEvent(GuidancePauseEvent.new(vehicle, paused))
    end
end

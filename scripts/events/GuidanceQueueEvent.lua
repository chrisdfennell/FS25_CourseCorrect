-- Guidance: a vehicle's queue of saved courses changed. Clients send it to the server, which passes it on.

GuidanceQueueEvent = {}
local GuidanceQueueEvent_mt = Class(GuidanceQueueEvent, Event)

InitEventClass(GuidanceQueueEvent, "GuidanceQueueEvent")

function GuidanceQueueEvent.emptyNew()
    return Event.new(GuidanceQueueEvent_mt)
end

function GuidanceQueueEvent.new(vehicle, queue)
    local self = GuidanceQueueEvent.emptyNew()
    self.vehicle = vehicle
    self.queue = queue
    return self
end

function GuidanceQueueEvent:writeStream(streamId, connection)
    NetworkUtil.writeNodeObject(streamId, self.vehicle)
    streamWriteUInt8(streamId, math.min(255, #self.queue))
    for i = 1, math.min(255, #self.queue) do streamWriteInt32(streamId, self.queue[i]) end
end

function GuidanceQueueEvent:readStream(streamId, connection)
    self.vehicle = NetworkUtil.readNodeObject(streamId)
    self.queue = {}
    for _ = 1, streamReadUInt8(streamId) do table.insert(self.queue, streamReadInt32(streamId)) end
    self:run(connection)
end

function GuidanceQueueEvent:run(connection)
    if self.vehicle == nil or self.vehicle.guidanceSetQueue == nil then
        return
    end
    self.vehicle:guidanceSetQueue(self.queue, true)
    if not connection:getIsServer() then
        -- from a client: pass it on to the others
        g_server:broadcastEvent(self, false, connection, self.vehicle)
    end
end

function GuidanceQueueEvent.sendEvent(vehicle, queue)
    if g_server ~= nil then
        g_server:broadcastEvent(GuidanceQueueEvent.new(vehicle, queue), false, nil, vehicle)
    elseif g_client ~= nil then
        g_client:getServerConnection():sendEvent(GuidanceQueueEvent.new(vehicle, queue))
    end
end

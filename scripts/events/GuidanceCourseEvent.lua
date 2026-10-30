-- Guidance: a vehicle got a new course plan (or lost it). Sent by the player who made it to the server, which
-- passes it on to everybody else. Every machine makes the course from the plan itself.

GuidanceCourseEvent = {}
local GuidanceCourseEvent_mt = Class(GuidanceCourseEvent, Event)
InitEventClass(GuidanceCourseEvent, "GuidanceCourseEvent")

function GuidanceCourseEvent.emptyNew()
    return Event.new(GuidanceCourseEvent_mt)
end

function GuidanceCourseEvent.new(vehicle, plan)
    local self = GuidanceCourseEvent.emptyNew()
    self.vehicle = vehicle
    self.plan = plan
    return self
end

function GuidanceCourseEvent:writeStream(streamId, connection)
    NetworkUtil.writeNodeObject(streamId, self.vehicle)
    if streamWriteBool(streamId, self.plan ~= nil) then
        self.plan:writeStream(streamId)
    end
end

function GuidanceCourseEvent:readStream(streamId, connection)
    self.vehicle = NetworkUtil.readNodeObject(streamId)
    if streamReadBool(streamId) then
        self.plan = GuidancePlan.readStream(streamId)
    end
    self:run(connection)
end

function GuidanceCourseEvent:run(connection)
    if self.vehicle == nil or self.vehicle.guidanceSetPlan == nil then
        return
    end
    self.vehicle:guidanceSetPlan(self.plan, true)
    if not connection:getIsServer() then
        -- from a client: pass it on to the others
        g_server:broadcastEvent(GuidanceCourseEvent.new(self.vehicle, self.plan), nil, connection, self.vehicle)
    end
end

function GuidanceCourseEvent.sendEvent(vehicle, plan)
    if g_server ~= nil then
        g_server:broadcastEvent(GuidanceCourseEvent.new(vehicle, plan), nil, nil, vehicle)
    else
        g_client:getServerConnection():sendEvent(GuidanceCourseEvent.new(vehicle, plan))
    end
end

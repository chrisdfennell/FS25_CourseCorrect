-- CourseCorrect: the panel's unloader asks the server to set up AutoDrive (a setting, the combine, where it unloads,
-- start, stop: see GuidanceAutoDrive). Clients send it to the server; AutoDrive sends the result to everybody.

GuidanceAutoDriveEvent = {}
local GuidanceAutoDriveEvent_mt = Class(GuidanceAutoDriveEvent, Event)

InitEventClass(GuidanceAutoDriveEvent, "GuidanceAutoDriveEvent")

function GuidanceAutoDriveEvent.emptyNew()
    return Event.new(GuidanceAutoDriveEvent_mt)
end

function GuidanceAutoDriveEvent.new(vehicle, op, other, name, value)
    local self = GuidanceAutoDriveEvent.emptyNew()
    self.vehicle, self.op, self.other, self.name, self.value = vehicle, op, other, name, value
    return self
end

function GuidanceAutoDriveEvent:writeStream(streamId, connection)
    NetworkUtil.writeNodeObject(streamId, self.vehicle)
    streamWriteUInt8(streamId, self.op)
    if streamWriteBool(streamId, self.other ~= nil) then
        NetworkUtil.writeNodeObject(streamId, self.other)
    end
    streamWriteString(streamId, self.name or "")
    streamWriteInt32(streamId, self.value or 0)
end

function GuidanceAutoDriveEvent:readStream(streamId, connection)
    self.vehicle = NetworkUtil.readNodeObject(streamId)
    self.op = streamReadUInt8(streamId)
    if streamReadBool(streamId) then
        self.other = NetworkUtil.readNodeObject(streamId)
    end
    self.name = streamReadString(streamId)
    self.value = streamReadInt32(streamId)
    self:run(connection)
end

function GuidanceAutoDriveEvent:run(connection)
    if self.vehicle ~= nil and not connection:getIsServer() then
        GuidanceAutoDrive.apply(self.vehicle, self.op, self.other, self.name, self.value)
    end
end

function GuidanceAutoDriveEvent.sendEvent(vehicle, op, other, name, value)
    if g_server == nil and g_client ~= nil then
        g_client:getServerConnection():sendEvent(GuidanceAutoDriveEvent.new(vehicle, op, other, name, value))
    end
end

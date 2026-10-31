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

-- the value as what it is: 0 a number, 1 a name, 2 on/off
function GuidanceSettingEvent:writeStream(streamId, connection)
    NetworkUtil.writeNodeObject(streamId, self.vehicle)
    streamWriteString(streamId, self.name)
    local v = self.value
    if type(v) == "boolean" then
        streamWriteUInt8(streamId, 2)
        streamWriteBool(streamId, v)
    elseif type(v) == "string" then
        streamWriteUInt8(streamId, 1)
        streamWriteString(streamId, v)
    else
        streamWriteUInt8(streamId, 0)
        streamWriteFloat32(streamId, tonumber(v) or 0)
    end
end

function GuidanceSettingEvent:readStream(streamId, connection)
    self.vehicle = NetworkUtil.readNodeObject(streamId)
    self.name = streamReadString(streamId)
    local kind = streamReadUInt8(streamId)
    if kind == 2 then
        self.value = streamReadBool(streamId)
    elseif kind == 1 then
        self.value = streamReadString(streamId)
    else
        self.value = streamReadFloat32(streamId)
    end
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

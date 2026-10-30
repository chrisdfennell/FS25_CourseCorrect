-- Guidance: the saved courses over the network. A joining player asks for the whole list (REQUEST, answered with
-- FULL); saving, deleting and renaming go to the server, which does it and tells everybody.

GuidanceLibraryEvent = {
    REQUEST = 1,
    FULL = 2,
    ADD = 3,
    DELETE = 4,
    RENAME = 5,
    ADD_FIELD = 6,
    DELETE_FIELD = 7,
    FIELD_SETTINGS = 8,
    STAT = 9,
    IMPORT = 10,
}
local GuidanceLibraryEvent_mt = Class(GuidanceLibraryEvent, Event)

InitEventClass(GuidanceLibraryEvent, "GuidanceLibraryEvent")

function GuidanceLibraryEvent.emptyNew()
    return Event.new(GuidanceLibraryEvent_mt)
end

--- data: an entry (ADD), {id} (DELETE, DELETE_FIELD), {id, name} (RENAME), a recorded field (ADD_FIELD),
--- {entries, fields} (FULL), nil (REQUEST)
function GuidanceLibraryEvent.new(kind, data)
    local self = GuidanceLibraryEvent.emptyNew()
    self.kind = kind
    self.data = data
    return self
end

function GuidanceLibraryEvent:writeStream(streamId, connection)
    streamWriteUInt8(streamId, self.kind)
    if self.kind == GuidanceLibraryEvent.FULL then
        streamWriteInt32(streamId, #self.data.entries)
        for _, e in ipairs(self.data.entries) do
            GuidanceLibrary.writeEntry(streamId, e)
        end
        streamWriteInt32(streamId, #self.data.fields)
        for _, f in ipairs(self.data.fields) do
            GuidanceLibrary.writeField(streamId, f)
        end
        local settings = {}
        for fieldId, values in pairs(self.data.fieldSettings or {}) do
            table.insert(settings, {fieldId = fieldId, values = values})
        end
        streamWriteInt32(streamId, #settings)
        for _, d in ipairs(settings) do
            GuidanceLibrary.writeFieldSettings(streamId, d)
        end
        streamWriteInt32(streamId, #(self.data.stats or {}))
        for _, e in ipairs(self.data.stats or {}) do
            GuidanceLibrary.writeStat(streamId, e)
        end
    elseif self.kind == GuidanceLibraryEvent.STAT then
        GuidanceLibrary.writeStat(streamId, self.data)
    elseif self.kind == GuidanceLibraryEvent.IMPORT then
        GuidanceLibrary.writeEntry(streamId, self.data.entry)
        local outline = self.data.outline or {}
        streamWriteInt32(streamId, #outline)
        for _, p in ipairs(outline) do
            streamWriteFloat32(streamId, p.x)
            streamWriteFloat32(streamId, p.z)
        end
    elseif self.kind == GuidanceLibraryEvent.FIELD_SETTINGS then
        GuidanceLibrary.writeFieldSettings(streamId, self.data)
    elseif self.kind == GuidanceLibraryEvent.ADD_FIELD then
        GuidanceLibrary.writeField(streamId, self.data)
    elseif self.kind == GuidanceLibraryEvent.DELETE_FIELD then
        streamWriteInt32(streamId, self.data.id)
    elseif self.kind == GuidanceLibraryEvent.ADD then
        GuidanceLibrary.writeEntry(streamId, self.data)
    elseif self.kind == GuidanceLibraryEvent.DELETE then
        streamWriteInt32(streamId, self.data.id)
    elseif self.kind == GuidanceLibraryEvent.RENAME then
        streamWriteInt32(streamId, self.data.id)
        streamWriteString(streamId, self.data.name)
    end
end

function GuidanceLibraryEvent:readStream(streamId, connection)
    self.kind = streamReadUInt8(streamId)
    if self.kind == GuidanceLibraryEvent.FULL then
        self.data = {entries = {}, fields = {}}
        for _ = 1, streamReadInt32(streamId) do
            table.insert(self.data.entries, GuidanceLibrary.readEntry(streamId))
        end
        for _ = 1, streamReadInt32(streamId) do
            table.insert(self.data.fields, GuidanceLibrary.readField(streamId))
        end
        self.data.fieldSettings = {}
        for _ = 1, streamReadInt32(streamId) do
            local d = GuidanceLibrary.readFieldSettings(streamId)
            self.data.fieldSettings[d.fieldId] = d.values
        end
        self.data.stats = {}
        for _ = 1, streamReadInt32(streamId) do
            table.insert(self.data.stats, GuidanceLibrary.readStat(streamId))
        end
    elseif self.kind == GuidanceLibraryEvent.STAT then
        self.data = GuidanceLibrary.readStat(streamId)
    elseif self.kind == GuidanceLibraryEvent.IMPORT then
        local entry = GuidanceLibrary.readEntry(streamId)
        local outline = {}
        for _ = 1, streamReadInt32(streamId) do
            table.insert(outline, {x = streamReadFloat32(streamId), z = streamReadFloat32(streamId)})
        end
        self.data = {entry = entry, outline = #outline >= 3 and outline or nil}
    elseif self.kind == GuidanceLibraryEvent.FIELD_SETTINGS then
        self.data = GuidanceLibrary.readFieldSettings(streamId)
    elseif self.kind == GuidanceLibraryEvent.ADD_FIELD then
        self.data = GuidanceLibrary.readField(streamId)
    elseif self.kind == GuidanceLibraryEvent.DELETE_FIELD then
        self.data = {id = streamReadInt32(streamId)}
    elseif self.kind == GuidanceLibraryEvent.ADD then
        self.data = GuidanceLibrary.readEntry(streamId)
    elseif self.kind == GuidanceLibraryEvent.DELETE then
        self.data = {id = streamReadInt32(streamId)}
    elseif self.kind == GuidanceLibraryEvent.RENAME then
        self.data = {id = streamReadInt32(streamId), name = streamReadString(streamId)}
    end
    self:run(connection)
end

function GuidanceLibraryEvent:run(connection)
    local fromClient = not connection:getIsServer()
    if self.kind == GuidanceLibraryEvent.REQUEST then
        if fromClient then
            connection:sendEvent(GuidanceLibraryEvent.new(GuidanceLibraryEvent.FULL,
                {entries = GuidanceLibrary.entries, fields = GuidanceLibrary.fields,
                 fieldSettings = GuidanceLibrary.fieldSettings, stats = GuidanceLibrary.stats}))
        end
    elseif self.kind == GuidanceLibraryEvent.FULL then
        GuidanceLibrary.entries, GuidanceLibrary.fields = {}, {}
        for _, e in ipairs(self.data.entries) do
            GuidanceLibrary.applyAdd(e)
        end
        for _, f in ipairs(self.data.fields) do
            GuidanceLibrary.applyAddField(f)
        end
        GuidanceLibrary.fieldSettings = self.data.fieldSettings or {}
        GuidanceLibrary.stats = self.data.stats or {}
    elseif fromClient then
        -- a player asks the server: do it, tell everybody (with the id the server gave a new course)
        if self.kind == GuidanceLibraryEvent.ADD then
            GuidanceLibrary.add(self.data)
        elseif self.kind == GuidanceLibraryEvent.DELETE then
            GuidanceLibrary.delete(self.data.id)
        elseif self.kind == GuidanceLibraryEvent.RENAME then
            GuidanceLibrary.rename(self.data.id, self.data.name)
        elseif self.kind == GuidanceLibraryEvent.ADD_FIELD then
            GuidanceLibrary.addField(self.data)
        elseif self.kind == GuidanceLibraryEvent.DELETE_FIELD then
            GuidanceLibrary.deleteField(self.data.id)
        elseif self.kind == GuidanceLibraryEvent.FIELD_SETTINGS then
            GuidanceLibrary.setFieldSettings(self.data.fieldId, self.data.values)
        elseif self.kind == GuidanceLibraryEvent.IMPORT then
            GuidanceLibrary.applyImport(self.data)
        end
    else
        -- the server tells us
        if self.kind == GuidanceLibraryEvent.ADD then
            GuidanceLibrary.applyAdd(self.data)
        elseif self.kind == GuidanceLibraryEvent.DELETE then
            GuidanceLibrary.applyDelete(self.data.id)
        elseif self.kind == GuidanceLibraryEvent.RENAME then
            GuidanceLibrary.applyRename(self.data.id, self.data.name)
        elseif self.kind == GuidanceLibraryEvent.ADD_FIELD then
            GuidanceLibrary.applyAddField(self.data)
        elseif self.kind == GuidanceLibraryEvent.DELETE_FIELD then
            GuidanceLibrary.applyDeleteField(self.data.id)
        elseif self.kind == GuidanceLibraryEvent.FIELD_SETTINGS then
            GuidanceLibrary.applyFieldSettings(self.data)
        elseif self.kind == GuidanceLibraryEvent.STAT then
            GuidanceLibrary.applyStat(self.data)
        end
    end
end

function GuidanceLibraryEvent.toServer(kind, data)
    if g_client ~= nil then
        g_client:getServerConnection():sendEvent(GuidanceLibraryEvent.new(kind, data))
    end
end

function GuidanceLibraryEvent.broadcast(kind, data)
    if g_server ~= nil then
        g_server:broadcastEvent(GuidanceLibraryEvent.new(kind, data))
    end
end

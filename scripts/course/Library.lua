-- Guidance: the saved courses. The server keeps them (in the savegame, guidanceCourses.xml) and every player has a
-- copy: the full list when joining, every change as it happens. A saved course is its plan (field and settings,
-- the course is made from it again when loaded) and a few numbers for the list.

GuidanceLibrary = {
    entries = {},
    nextId = 1,
    -- fields the players recorded themselves (meadows, odd corners, part of a field): {id (below 0), name, farmId,
    -- outline = list of {x, z}}; and fields read from the ground (painted field ground, see GuidanceFieldScan): those
    -- have baseField (the map's field they were read on, 0: none)
    fields = {},
    nextFieldId = -1,
    -- settings that belong to a field, by field id: used whoever makes a course there
    fieldSettings = {},
    FILE = "courseCorrect.xml",
    -- the file's name under the mod's old name (Guidance): read when there is no new one yet
    OLD_FILE = "guidanceCourses.xml",
}

-- which settings belong to a field (not to the tractor): name, kind
GuidanceLibrary.FIELD_KEYS = {
    {"headlands", "INT"}, {"rowAngle", "FLOAT"}, {"clockwise", "BOOL"}, {"headlandsFirst", "BOOL"},
    {"pattern", "INT"}, {"roundedPasses", "INT"},
}
local Library = GuidanceLibrary

--- A new entry: {id, name, farmId, plan, area (m²), length (m), time (s), headlands, rows}
function Library.newEntry(name, farmId, plan, course)
    local st = course and course.stats or {}
    return {
        id = 0,
        name = name,
        farmId = farmId,
        plan = plan:copy(),
        area = st.area or 0,
        length = course and course.length or 0,
        time = st.time or 0,
        headlands = st.headlands or 0,
        rows = st.rows or 0,
    }
end

function Library.getEntry(id)
    for _, e in ipairs(Library.entries) do
        if e.id == id then return e end
    end
    return nil
end

--- The farm's entries, those for fieldId first, then by name
function Library.getForFarm(farmId, fieldId)
    local list = {}
    for _, e in ipairs(Library.entries) do
        if e.farmId == farmId then table.insert(list, e) end
    end
    table.sort(list, function(a, b)
        local fa, fb = a.plan.fieldId == fieldId, b.plan.fieldId == fieldId
        if fa ~= fb then return fa end
        return a.name < b.name
    end)
    return list
end

function Library.countForField(farmId, fieldId)
    local n = 0
    for _, e in ipairs(Library.entries) do
        if e.farmId == farmId and e.plan.fieldId == fieldId then n = n + 1 end
    end
    return n
end

function Library.getField(id)
    for _, f in ipairs(Library.fields) do
        if f.id == id then return f end
    end
    return nil
end

--- The recorded field at a world position (x, z), or nil
function Library.fieldAt(x, z)
    for _, f in ipairs(Library.fields) do
        if f.poly == nil then
            f.poly = {}
            for i, p in ipairs(f.outline) do f.poly[i] = {x = p.x, y = p.z} end
        end
        if GuidanceGeo.pointInPolygon({x = x, y = z}, f.poly) then
            return f
        end
    end
    return nil
end

function Library.getFieldsForFarm(farmId)
    local list = {}
    for _, f in ipairs(Library.fields) do
        if f.farmId == farmId then table.insert(list, f) end
    end
    return list
end

--- Name of a field for the player: the map's number or the recorded field's name
function Library.fieldName(fieldId)
    if fieldId < 0 then
        local f = Library.getField(fieldId)
        return f and f.name or "?"
    end
    return string.format(g_i18n:getText("guidance_folder_title"), fieldId)
end

function Library.isFieldKey(name)
    for _, k in ipairs(Library.FIELD_KEYS) do
        if k[1] == name then return true end
    end
    return false
end

--- The field-scope values of a plan or settings table
function Library.fieldValuesOf(settings)
    local values = {}
    for _, k in ipairs(Library.FIELD_KEYS) do values[k[1]] = settings[k[1]] end
    return values
end

-----------------------------------------------------------------------------------------------------------------------
-- Changes: on the server they happen and go to everybody, on a client they are asked of the server
-----------------------------------------------------------------------------------------------------------------------

function Library.add(entry)
    if g_server ~= nil then
        Library.applyAdd(entry)
        GuidanceLibraryEvent.broadcast(GuidanceLibraryEvent.ADD, entry)
    else
        GuidanceLibraryEvent.toServer(GuidanceLibraryEvent.ADD, entry)
    end
end

function Library.delete(id)
    if g_server ~= nil then
        Library.applyDelete(id)
        GuidanceLibraryEvent.broadcast(GuidanceLibraryEvent.DELETE, {id = id})
    else
        GuidanceLibraryEvent.toServer(GuidanceLibraryEvent.DELETE, {id = id})
    end
end

function Library.rename(id, name)
    if g_server ~= nil then
        Library.applyRename(id, name)
        GuidanceLibraryEvent.broadcast(GuidanceLibraryEvent.RENAME, {id = id, name = name})
    else
        GuidanceLibraryEvent.toServer(GuidanceLibraryEvent.RENAME, {id = id, name = name})
    end
end

function Library.addField(field)
    if g_server ~= nil then
        Library.applyAddField(field)
        GuidanceLibraryEvent.broadcast(GuidanceLibraryEvent.ADD_FIELD, field)
    else
        GuidanceLibraryEvent.toServer(GuidanceLibraryEvent.ADD_FIELD, field)
    end
end

--- (its saved courses go with it)
function Library.deleteField(id)
    if g_server ~= nil then
        Library.applyDeleteField(id)
        GuidanceLibraryEvent.broadcast(GuidanceLibraryEvent.DELETE_FIELD, {id = id})
    else
        GuidanceLibraryEvent.toServer(GuidanceLibraryEvent.DELETE_FIELD, {id = id})
    end
end

--- Settings for a field (values: name -> value), nil forgets them
function Library.setFieldSettings(fieldId, values)
    local data = {fieldId = fieldId, values = values}
    if g_server ~= nil then
        Library.applyFieldSettings(data)
        GuidanceLibraryEvent.broadcast(GuidanceLibraryEvent.FIELD_SETTINGS, data)
    else
        GuidanceLibraryEvent.toServer(GuidanceLibraryEvent.FIELD_SETTINGS, data)
    end
end

function Library.applyFieldSettings(data)
    Library.fieldSettings[data.fieldId] = data.values
end

function Library.writeFieldSettings(streamId, data)
    streamWriteInt32(streamId, data.fieldId)
    if streamWriteBool(streamId, data.values ~= nil) then
        for _, k in ipairs(Library.FIELD_KEYS) do
            local v = data.values[k[1]]
            if k[2] == "INT" then streamWriteInt32(streamId, v or 0)
            elseif k[2] == "FLOAT" then streamWriteFloat32(streamId, v or 0)
            else streamWriteBool(streamId, v == true) end
        end
    end
end

function Library.readFieldSettings(streamId)
    local data = {fieldId = streamReadInt32(streamId)}
    if streamReadBool(streamId) then
        data.values = {}
        for _, k in ipairs(Library.FIELD_KEYS) do
            if k[2] == "INT" then data.values[k[1]] = streamReadInt32(streamId)
            elseif k[2] == "FLOAT" then data.values[k[1]] = streamReadFloat32(streamId)
            else data.values[k[1]] = streamReadBool(streamId) end
        end
    end
    return data
end

function Library.applyAddField(field)
    if g_server ~= nil and (field.id == nil or field.id == 0) then
        field.id = Library.nextFieldId
    end
    Library.nextFieldId = math.min(Library.nextFieldId, field.id - 1)
    field.poly = nil
    -- its islands are looked for again
    if GuidanceCourse then GuidanceCourse.islandCache[field.id] = nil end
    local old = Library.getField(field.id)
    if old then
        for k, v in pairs(field) do old[k] = v end
    else
        table.insert(Library.fields, field)
    end
end

function Library.applyDeleteField(id)
    for i, f in ipairs(Library.fields) do
        if f.id == id then
            table.remove(Library.fields, i)
            break
        end
    end
    for i = #Library.entries, 1, -1 do
        if Library.entries[i].plan.fieldId == id then table.remove(Library.entries, i) end
    end
end

--- (the server gives new entries their id)
function Library.applyAdd(entry)
    if g_server ~= nil and (entry.id == nil or entry.id == 0) then
        entry.id = Library.nextId
    end
    Library.nextId = math.max(Library.nextId, entry.id + 1)
    local old = Library.getEntry(entry.id)
    if old then
        for k, v in pairs(entry) do old[k] = v end
    else
        table.insert(Library.entries, entry)
    end
end

function Library.applyDelete(id)
    for i, e in ipairs(Library.entries) do
        if e.id == id then
            table.remove(Library.entries, i)
            return
        end
    end
end

function Library.applyRename(id, name)
    local e = Library.getEntry(id)
    if e then e.name = name end
end

-----------------------------------------------------------------------------------------------------------------------
-- Network
-----------------------------------------------------------------------------------------------------------------------

function Library.writeEntry(streamId, e)
    streamWriteInt32(streamId, e.id or 0)
    streamWriteString(streamId, e.name or "")
    streamWriteUInt8(streamId, e.farmId or 0)
    streamWriteFloat32(streamId, e.area or 0)
    streamWriteFloat32(streamId, e.length or 0)
    streamWriteFloat32(streamId, e.time or 0)
    streamWriteUInt8(streamId, e.headlands or 0)
    streamWriteInt32(streamId, e.rows or 0)
    e.plan:writeStream(streamId)
end

function Library.readEntry(streamId)
    local e = {}
    e.id = streamReadInt32(streamId)
    e.name = streamReadString(streamId)
    e.farmId = streamReadUInt8(streamId)
    e.area = streamReadFloat32(streamId)
    e.length = streamReadFloat32(streamId)
    e.time = streamReadFloat32(streamId)
    e.headlands = streamReadUInt8(streamId)
    e.rows = streamReadInt32(streamId)
    e.plan = GuidancePlan.readStream(streamId)
    return e
end

function Library.writeField(streamId, f)
    streamWriteInt32(streamId, f.id or 0)
    streamWriteString(streamId, f.name or "")
    streamWriteUInt8(streamId, f.farmId or 0)
    streamWriteInt32(streamId, f.baseField or -1)
    streamWriteInt32(streamId, #f.outline)
    for _, p in ipairs(f.outline) do
        streamWriteFloat32(streamId, p.x)
        streamWriteFloat32(streamId, p.z)
    end
end

function Library.readField(streamId)
    local f = {outline = {}}
    f.id = streamReadInt32(streamId)
    f.name = streamReadString(streamId)
    f.farmId = streamReadUInt8(streamId)
    local base = streamReadInt32(streamId)
    f.baseField = base >= 0 and base or nil
    for _ = 1, streamReadInt32(streamId) do
        table.insert(f.outline, {x = streamReadFloat32(streamId), z = streamReadFloat32(streamId)})
    end
    return f
end

-----------------------------------------------------------------------------------------------------------------------
-- Savegame (server)
-----------------------------------------------------------------------------------------------------------------------

-----------------------------------------------------------------------------------------------------------------------
-- Work log: what each helper job did (field, tractor, area, time, fuel, when). The server keeps it (with the
-- savegame) and tells everybody.
-----------------------------------------------------------------------------------------------------------------------

Library.stats = Library.stats or {}
Library.STATS_MAX = 300

--- The game's date and time now: {day, hour, minute}
function Library.today()
    local env = g_currentMission and g_currentMission.environment
    return {day = env and env.currentDay or 0, hour = env and env.currentHour or 0, minute = env and env.currentMinute or 0}
end

--- Server: a job ended
function Library.addStat(entry)
    if g_server == nil then
        return
    end
    Library.applyStat(entry)
    GuidanceLibraryEvent.broadcast(GuidanceLibraryEvent.STAT, entry)
end

function Library.applyStat(entry)
    table.insert(Library.stats, entry)
    while #Library.stats > Library.STATS_MAX do
        table.remove(Library.stats, 1)
    end
end

function Library.writeStat(streamId, e)
    streamWriteInt32(streamId, e.fieldId or 0)
    streamWriteString(streamId, e.vehicle or "")
    streamWriteUInt8(streamId, e.farmId or 0)
    streamWriteFloat32(streamId, e.area or 0)
    streamWriteFloat32(streamId, e.seconds or 0)
    streamWriteFloat32(streamId, e.fuel or 0)
    streamWriteInt32(streamId, e.day and e.day.day or 0)
    streamWriteUInt8(streamId, e.day and e.day.hour or 0)
    streamWriteUInt8(streamId, e.day and e.day.minute or 0)
end

function Library.readStat(streamId)
    local e = {fieldId = streamReadInt32(streamId), vehicle = streamReadString(streamId), farmId = streamReadUInt8(streamId),
               area = streamReadFloat32(streamId), seconds = streamReadFloat32(streamId), fuel = streamReadFloat32(streamId)}
    e.day = {day = streamReadInt32(streamId), hour = streamReadUInt8(streamId), minute = streamReadUInt8(streamId)}
    return e
end

--- The farm's work log, newest first
function Library.getStats(farmId)
    local list = {}
    for i = #Library.stats, 1, -1 do
        local e = Library.stats[i]
        if farmId == nil or e.farmId == farmId then table.insert(list, e) end
    end
    return list
end

-----------------------------------------------------------------------------------------------------------------------
-- Export / import: a saved course as a file (with its field's outline, so it works on another map or server too),
-- in the player's modSettings/FS25_CourseCorrect/courses (files in the old modSettings/FS25_Guidance/courses too)
-----------------------------------------------------------------------------------------------------------------------

function Library.exportFolder()
    if getUserProfileAppPath == nil then return nil end
    return getUserProfileAppPath() .. "modSettings/FS25_CourseCorrect/courses/"
end

--- The course files folder of the mod's old name (Guidance)
function Library.oldExportFolder()
    if getUserProfileAppPath == nil then return nil end
    return getUserProfileAppPath() .. "modSettings/FS25_Guidance/courses/"
end

local function fileName(name)
    local clean = string.gsub(name or "course", "[^%w%-_ ]", "_")
    return string.sub(clean, 1, 60) .. ".xml"
end

--- Writes a saved course to a file. Returns the file's name, or nil.
function Library.exportCourse(entry)
    local folder = Library.exportFolder()
    if folder == nil then return nil end
    createFolder(getUserProfileAppPath() .. "modSettings/")
    createFolder(getUserProfileAppPath() .. "modSettings/FS25_CourseCorrect/")
    createFolder(folder)
    local name = fileName(entry.name)
    local xml = createXMLFile("guidanceExport", folder .. name, "guidanceCourse")
    if xml == nil or xml == 0 then return nil end
    setXMLString(xml, "guidanceCourse#name", entry.name or "")
    entry.plan:saveToRawXML(xml, "guidanceCourse.plan")
    local outline = GuidanceCourse.getFieldOutline(entry.plan.fieldId)
    for i, p in ipairs(outline or {}) do
        local key = string.format("guidanceCourse.outline.point(%d)", i - 1)
        setXMLFloat(xml, key .. "#x", p.x)
        setXMLFloat(xml, key .. "#z", p.z)
    end
    saveXMLFile(xml)
    delete(xml)
    return name
end

--- The course files there are to import: list of file names
function Library.listExports()
    local folder = Library.exportFolder()
    local list = {}
    if folder == nil or getFiles == nil then return list end
    Library.fileList = list
    getFiles(folder, "onExportFile", Library)
    -- and those still in the old name's folder
    local old = Library.oldExportFolder()
    if old and fileExists(old) then getFiles(old, "onExportFile", Library) end
    Library.fileList = nil
    table.sort(list)
    local out = {}
    for i, name in ipairs(list) do
        if name ~= list[i - 1] then out[#out + 1] = name end
    end
    return out
end

function Library:onExportFile(name, isDirectory)
    if not isDirectory and string.sub(string.lower(name), -4) == ".xml" and Library.fileList then
        table.insert(Library.fileList, name)
    end
end

--- Reads a course file: name, plan, outline (list of {x, z}); nil if it isn't one
function Library.readExport(name)
    local folder = Library.exportFolder()
    if folder ~= nil and not fileExists(folder .. name) then
        local old = Library.oldExportFolder()
        if old and fileExists(old .. name) then folder = old end
    end
    if folder == nil or not fileExists(folder .. name) then return nil end
    local xml = loadXMLFile("guidanceImport", folder .. name)
    if xml == nil or xml == 0 then return nil end
    local plan = GuidancePlan.loadFromRawXML(xml, "guidanceCourse.plan")
    local title = getXMLString(xml, "guidanceCourse#name")
    local outline, i = {}, 0
    while true do
        local key = string.format("guidanceCourse.outline.point(%d)", i)
        local x = getXMLFloat(xml, key .. "#x")
        if x == nil then break end
        table.insert(outline, {x = x, z = getXMLFloat(xml, key .. "#z")})
        i = i + 1
    end
    delete(xml)
    if plan == nil then return nil end
    return title or name, plan, #outline >= 3 and outline or nil
end

local function shapeOf(outline)
    local cx, cz, area, n = 0, 0, 0, #outline
    for i = 1, n do
        local a, b = outline[i], outline[i % n + 1]
        cx, cz = cx + a.x, cz + a.z
        area = area + a.x * b.z - b.x * a.z
    end
    return cx / math.max(n, 1), cz / math.max(n, 1), math.abs(area) / 2
end

--- The field here that is the one of this outline (same place, same size), or nil
function Library.matchField(fieldId, outline)
    local function same(other)
        if other == nil or #other < 3 then return false end
        local x1, z1, a1 = shapeOf(outline)
        local x2, z2, a2 = shapeOf(other)
        return math.sqrt((x1 - x2) ^ 2 + (z1 - z2) ^ 2) < 15 and math.abs(a1 - a2) <= 0.1 * math.max(a1, a2)
    end
    if fieldId and same(GuidanceCourse.getFieldOutline(fieldId)) then
        return fieldId
    end
    for _, f in ipairs(Library.fields) do
        if same(f.outline) then return f.id end
    end
    return nil
end

--- Imports a course (name, plan, outline): goes to the server, which finds its field (or records it) and saves it
function Library.importCourse(name, farmId, plan, outline)
    local entry = {id = 0, name = name, farmId = farmId, plan = plan, area = 0, length = 0, time = 0, headlands = 0,
                   rows = 0}
    local data = {entry = entry, outline = outline}
    if g_server ~= nil then
        Library.applyImport(data)
    else
        GuidanceLibraryEvent.toServer(GuidanceLibraryEvent.IMPORT, data)
    end
end

--- Server: the field of an imported course (this map's, or its outline recorded as a field), then saved
function Library.applyImport(data)
    local entry, outline = data.entry, data.outline
    if outline then
        local fieldId = Library.matchField(entry.plan.fieldId, outline)
        if fieldId == nil then
            local field = {id = 0, name = entry.name, farmId = entry.farmId, outline = outline}
            Library.addField(field)
            fieldId = field.id
        end
        entry.plan.fieldId = fieldId
    end
    Library.add(entry)
end

local function filePath()
    local info = g_currentMission and g_currentMission.missionInfo
    local dir = info and info.savegameDirectory
    if dir == nil then return nil end
    return dir .. "/" .. Library.FILE
end

function Library.save()
    local path = filePath()
    if path == nil or g_server == nil then
        return
    end
    local xml = createXMLFile("guidanceCourses", path, "guidanceCourses")
    if xml == nil or xml == 0 then
        return
    end
    for i, e in ipairs(Library.entries) do
        local key = string.format("guidanceCourses.course(%d)", i - 1)
        setXMLInt(xml, key .. "#id", e.id)
        setXMLString(xml, key .. "#name", e.name)
        setXMLInt(xml, key .. "#farmId", e.farmId)
        setXMLFloat(xml, key .. "#area", e.area)
        setXMLFloat(xml, key .. "#length", e.length)
        setXMLFloat(xml, key .. "#time", e.time)
        setXMLInt(xml, key .. "#headlands", e.headlands)
        setXMLInt(xml, key .. "#rows", e.rows)
        e.plan:saveToRawXML(xml, key .. ".plan")
    end
    -- next free row: the rows done on each field (for when the helpers start again)
    local nt = 0
    for fieldId, f in pairs(GuidanceTeam and GuidanceTeam.fields or {}) do
        local done = {}
        for row in pairs(f.done) do table.insert(done, row) end
        if #done > 0 then
            table.sort(done)
            local key = string.format("guidanceCourses.teamRows(%d)", nt)
            setXMLInt(xml, key .. "#fieldId", fieldId)
            setXMLString(xml, key .. "#rows", f.signature or "")
            setXMLString(xml, key .. "#done", table.concat(done, " "))
            nt = nt + 1
        end
    end
    local n = 0
    for fieldId, values in pairs(Library.fieldSettings) do
        local key = string.format("guidanceCourses.fieldSettings(%d)", n)
        setXMLInt(xml, key .. "#fieldId", fieldId)
        for _, k in ipairs(Library.FIELD_KEYS) do
            local v = values[k[1]]
            if v ~= nil then
                if k[2] == "INT" then setXMLInt(xml, key .. "#" .. k[1], v)
                elseif k[2] == "FLOAT" then setXMLFloat(xml, key .. "#" .. k[1], v)
                else setXMLBool(xml, key .. "#" .. k[1], v) end
            end
        end
        n = n + 1
    end
    for i, f in ipairs(Library.fields) do
        local key = string.format("guidanceCourses.field(%d)", i - 1)
        setXMLInt(xml, key .. "#id", f.id)
        setXMLString(xml, key .. "#name", f.name)
        setXMLInt(xml, key .. "#farmId", f.farmId)
        if f.baseField then setXMLInt(xml, key .. "#baseField", f.baseField) end
        for j, p in ipairs(f.outline) do
            local pkey = string.format("%s.point(%d)", key, j - 1)
            setXMLFloat(xml, pkey .. "#x", p.x)
            setXMLFloat(xml, pkey .. "#z", p.z)
        end
    end
    for i, e in ipairs(Library.stats) do
        local key = string.format("guidanceCourses.stat(%d)", i - 1)
        setXMLInt(xml, key .. "#fieldId", e.fieldId or 0)
        setXMLString(xml, key .. "#vehicle", e.vehicle or "")
        setXMLInt(xml, key .. "#farmId", e.farmId or 0)
        setXMLFloat(xml, key .. "#area", e.area or 0)
        setXMLFloat(xml, key .. "#seconds", e.seconds or 0)
        setXMLFloat(xml, key .. "#fuel", e.fuel or 0)
        setXMLInt(xml, key .. "#day", e.day and e.day.day or 0)
        setXMLInt(xml, key .. "#hour", e.day and e.day.hour or 0)
        setXMLInt(xml, key .. "#minute", e.day and e.day.minute or 0)
    end
    saveXMLFile(xml)
    delete(xml)
end

function Library.load()
    Library.entries, Library.nextId = {}, 1
    Library.fields, Library.nextFieldId = {}, -1
    Library.fieldSettings = {}
    Library.stats = {}
    local path = filePath()
    -- not saved under the new name yet: the old name's file
    if path ~= nil and not fileExists(path) then
        local old = string.sub(path, 1, #path - #Library.FILE) .. Library.OLD_FILE
        if fileExists(old) then
            Guidance.info("reading %s (saved under the old name Guidance)", Library.OLD_FILE)
            path = old
        end
    end
    if path == nil or not fileExists(path) then
        return
    end
    local xml = loadXMLFile("guidanceCourses", path)
    if xml == nil or xml == 0 then
        return
    end
    local i = 0
    while true do
        local key = string.format("guidanceCourses.course(%d)", i)
        if not hasXMLProperty(xml, key) then break end
        local plan = GuidancePlan.loadFromRawXML(xml, key .. ".plan")
        if plan then
            Library.applyAdd({
                id = getXMLInt(xml, key .. "#id") or Library.nextId,
                name = getXMLString(xml, key .. "#name") or "?",
                farmId = getXMLInt(xml, key .. "#farmId") or 1,
                area = getXMLFloat(xml, key .. "#area") or 0,
                length = getXMLFloat(xml, key .. "#length") or 0,
                time = getXMLFloat(xml, key .. "#time") or 0,
                headlands = getXMLInt(xml, key .. "#headlands") or 0,
                rows = getXMLInt(xml, key .. "#rows") or 0,
                plan = plan,
            })
        end
        i = i + 1
    end
    i = 0
    while true do
        local key = string.format("guidanceCourses.stat(%d)", i)
        local fieldId = getXMLInt(xml, key .. "#fieldId")
        if fieldId == nil then break end
        table.insert(Library.stats, {fieldId = fieldId, vehicle = getXMLString(xml, key .. "#vehicle") or "",
            farmId = getXMLInt(xml, key .. "#farmId") or 0, area = getXMLFloat(xml, key .. "#area") or 0,
            seconds = getXMLFloat(xml, key .. "#seconds") or 0, fuel = getXMLFloat(xml, key .. "#fuel") or 0,
            day = {day = getXMLInt(xml, key .. "#day") or 0, hour = getXMLInt(xml, key .. "#hour") or 0,
                   minute = getXMLInt(xml, key .. "#minute") or 0}})
        i = i + 1
    end
    i = 0
    while GuidanceTeam do
        local key = string.format("guidanceCourses.teamRows(%d)", i)
        local fieldId = getXMLInt(xml, key .. "#fieldId")
        if fieldId == nil then break end
        local f = {done = {}, taken = {}, signature = getXMLString(xml, key .. "#rows") or ""}
        for row in string.gmatch(getXMLString(xml, key .. "#done") or "", "%d+") do f.done[tonumber(row)] = true end
        GuidanceTeam.fields[fieldId] = f
        i = i + 1
    end
    i = 0
    while true do
        local key = string.format("guidanceCourses.fieldSettings(%d)", i)
        local fieldId = getXMLInt(xml, key .. "#fieldId")
        if fieldId == nil then break end
        local values = {}
        for _, k in ipairs(Library.FIELD_KEYS) do
            if k[2] == "INT" then values[k[1]] = getXMLInt(xml, key .. "#" .. k[1])
            elseif k[2] == "FLOAT" then values[k[1]] = getXMLFloat(xml, key .. "#" .. k[1])
            else values[k[1]] = getXMLBool(xml, key .. "#" .. k[1]) end
        end
        Library.fieldSettings[fieldId] = values
        i = i + 1
    end
    i = 0
    while true do
        local key = string.format("guidanceCourses.field(%d)", i)
        if not hasXMLProperty(xml, key) then break end
        local f = {id = getXMLInt(xml, key .. "#id"), name = getXMLString(xml, key .. "#name") or "?",
                   farmId = getXMLInt(xml, key .. "#farmId") or 1, baseField = getXMLInt(xml, key .. "#baseField"),
                   outline = {}}
        local j = 0
        while true do
            local pkey = string.format("%s.point(%d)", key, j)
            local px = getXMLFloat(xml, pkey .. "#x")
            if px == nil then break end
            table.insert(f.outline, {x = px, z = getXMLFloat(xml, pkey .. "#z")})
            j = j + 1
        end
        if f.id and #f.outline >= 3 then Library.applyAddField(f) end
        i = i + 1
    end
    delete(xml)
    Guidance.info("%d saved course(s) and %d recorded field(s) loaded", #Library.entries, #Library.fields)
end

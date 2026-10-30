-- Guidance: a course plan and the course generated from it.
--
-- The plan is what we save and send to other players: the field and the generator settings. The generator is
-- deterministic, so every machine builds the same course from the same plan. This keeps savegames and network
-- traffic small (a course for a big field has thousands of waypoints).

GuidancePlan = {}
local GuidancePlan_mt = {__index = GuidancePlan}

-- saved as the index: new ones only at the end
GuidancePlan.PATTERNS = {"adjacent", "racetrack", "auto", "lands", "spiral"}
GuidancePlan.PATTERN_AUTO = 3
-- where Start begins: where it stopped, the nearest stretch, the very beginning
GuidancePlan.START_CONTINUE, GuidancePlan.START_NEAREST, GuidancePlan.START_FIRST = 1, 2, 3

function GuidancePlan.new()
    local self = setmetatable({}, GuidancePlan_mt)
    self.fieldId = 0
    self.workWidth = 6
    self.turnRadius = 6
    self.runOut = 3
    self.headlands = -1
    self.rowAngle = -1 -- -1 = automatic
    self.clockwise = true
    self.headlandsFirst = true
    self.pattern = GuidancePlan.PATTERN_AUTO -- index into PATTERNS
    self.overlap = 0
    self.startX, self.startZ = 0, 0
    -- width and turning radius from the vehicle and its implements, until the player changes them
    self.autoWidth = true
    self.autoRadius = true
    -- from the vehicle: nothing towed, it can back up (three-point turns, square corners)
    self.allowReverse = false
    self.squareCorners = true
    -- in turns on the field: leave the implements down, switched off (saves raising and lowering)
    self.keepLowered = false
    self.startMode = GuidancePlan.START_CONTINUE
    -- the innermost this many headland passes have round corners, the outer ones sharp (-1: all round)
    self.roundedPasses = 1
    -- automatic headlands are at least this wide (m)
    self.minHeadlandWidth = GuidancePlan.MIN_HEADLAND_DEFAULT
    -- 2: saved with automatic headlands at least 40 m (before: 30 m)
    self.headlandRev = 2
    -- metres the implements go down / come up later than on time (negative: earlier)
    self.lowerLate = 0
    self.raiseLate = 0
    -- several tractors on one field: TEAM_ALONE, TEAM_STRIPS, TEAM_CONVOY, TEAM_NEXT_ROW; how many, which one
    self.teamMode = GuidancePlan.TEAM_ALONE
    self.teamSize = 2
    self.teamIndex = 1
    -- a harvester calls its unloader (AutoDrive) this full, percent
    self.callUnloaderAt = 80
    -- metres the work area is to the right of where the game says (negative: left): the helper steers that much
    -- the other way
    self.toolOffsetX = 0
    -- a helper working when the game was saved starts again after loading
    self.autoResume = true
    -- what to work: WORK_WHOLE, WORK_HEADLANDS (only), WORK_ROWS (only); and which rows, counted across the field
    -- (0: from the first / to the last)
    self.workPart = GuidancePlan.WORK_WHOLE
    self.rowFrom = 0
    self.rowTo = 0
    -- km/h: at most this working (0: as fast as the implement may), in turns, backing up
    self.workSpeedMax = 0
    self.turnSpeed = 10
    self.reverseSpeed = 5
    -- lights: LIGHTS_AUTO (on at night, beacons while working) or LIGHTS_OFF (left as they are)
    self.lights = GuidancePlan.LIGHTS_AUTO
    -- lands pattern: rows in a land
    self.rowsPerLand = 6
    -- rows straight (ROWS_STRAIGHT) or along the field's longest edge (ROWS_EDGE)
    self.rowShape = GuidancePlan.ROWS_STRAIGHT
    -- tramlines: the rows where the field's sowing course has them (rowSpacing apart, at rowPhase; 0: not)
    self.tramlines = false
    self.rowPhase = 0
    self.rowSpacing = 0
    -- the course editor: rows left out (their places across the field, "3 7 12") and areas worked round
    -- (rectangles "x1 z1 x2 z2;...")
    self.skipRows = ""
    self.skipZones = ""
    -- lands: the worked ground on the left / right (SIDE_*; auto: the harvester's pipe side, landsPipe, found when
    -- the course is made)
    self.landsSide = 0
    self.landsPipe = 0
    -- refill trips: the loading station (its place; 0, 0: none) a seeder / sprayer drives to when empty
    self.refillX, self.refillZ = 0, 0
    -- the unloader: the unloading station it takes a full trailer to (0, 0: stops when full), how full it goes (%)
    self.unloadX, self.unloadZ, self.unloadFull = 0, 0, 97
    -- 0: the station at unloadX, unloadZ (none: stop when full), 1: a truck at the field edge, 2: a heap
    self.unloadMode = 0
    -- the editor's moved points: "ix x z;ix x z" (the course's waypoint ix moved there; its neighbours along the
    -- course follow, less the further away). Any other change of the course drops them.
    self.moves = ""
    -- the implements attached when the course was made (names; "" unknown): a different one gets a warning
    self.toolSig = ""
    -- from the vehicle: how far back a towed implement works (0: nothing towed), for tight corners
    self.towLength = 0
    return self
end

function GuidancePlan:copy()
    local c = GuidancePlan.new()
    for k, v in pairs(self) do c[k] = v end
    return c
end

function GuidancePlan:getGeneratorSettings()
    return {
        workWidth = self:getCourseWidth(),
        turnRadius = self:getCourseTurnRadius(),
        runOut = self.runOut,
        headlands = self.headlands,
        rowAngle = self.rowAngle >= 0 and self.rowAngle or nil,
        clockwise = self.clockwise,
        headlandsFirst = self.headlandsFirst,
        -- a team in lands: lands, whatever the pattern
        pattern = self.teamMode == GuidancePlan.TEAM_LANDS and "lands" or GuidancePlan.PATTERNS[self.pattern] or "auto",
        landsSide = (self.landsSide or 0) ~= 0 and self.landsSide or self.landsPipe or 0,
        overlap = self.overlap,
        startX = self.startX,
        startZ = self.startZ,
        -- a convoy turns forwards, round (its lanes beside the course can't follow a backing-up manoeuvre)
        allowReverse = self.allowReverse and self.teamMode ~= GuidancePlan.TEAM_CONVOY,
        squareCorners = self.squareCorners,
        roundedPasses = self.teamMode == GuidancePlan.TEAM_CONVOY and -1 or self.roundedPasses,
        minHeadlandWidth = self.minHeadlandWidth,
        -- a convoy works one course as wide as all of them together; strips and next-free-row share the field
        teamSize = (self.teamMode == GuidancePlan.TEAM_STRIPS or self.teamMode == GuidancePlan.TEAM_NEXT_ROW
            or self.teamMode == GuidancePlan.TEAM_LANDS) and self.teamSize or 1,
        teamIndex = self.teamIndex,
        teamShare = self.teamMode == GuidancePlan.TEAM_NEXT_ROW and "nextRow" or "strips",
        workPart = GuidancePlan.WORK_PARTS[self.workPart or 0] or "whole",
        rowFrom = self.rowFrom,
        rowTo = self.rowTo,
        turnSpeed = self.turnSpeed,
        reverseSpeed = self.reverseSpeed,
        rowsPerLand = self.rowsPerLand,
        rowShape = self.rowShape == GuidancePlan.ROWS_EDGE and "edge" or "straight",
        rowPhase = self.tramlines and (self.rowSpacing or 0) > 0 and self.rowPhase or nil,
        rowSpacing = self.tramlines and self.rowSpacing or 0,
        skipRows = self:getSkipRows(),
        towLength = self.towLength,
    }
end

function GuidancePlan:writeStream(streamId)
    streamWriteInt32(streamId, self.fieldId)
    streamWriteFloat32(streamId, self.workWidth)
    streamWriteFloat32(streamId, self.turnRadius)
    streamWriteFloat32(streamId, self.runOut)
    streamWriteInt8(streamId, self.headlands)
    streamWriteFloat32(streamId, self.rowAngle)
    streamWriteBool(streamId, self.clockwise)
    streamWriteBool(streamId, self.headlandsFirst)
    streamWriteUInt8(streamId, self.pattern)
    streamWriteFloat32(streamId, self.overlap)
    streamWriteFloat32(streamId, self.startX)
    streamWriteFloat32(streamId, self.startZ)
    streamWriteBool(streamId, self.autoWidth)
    streamWriteBool(streamId, self.autoRadius)
    streamWriteBool(streamId, self.allowReverse)
    streamWriteBool(streamId, self.squareCorners)
    streamWriteBool(streamId, self.keepLowered)
    streamWriteUInt8(streamId, self.startMode or 1)
    streamWriteInt8(streamId, self.roundedPasses)
    streamWriteFloat32(streamId, self.towLength)
    streamWriteFloat32(streamId, self.minHeadlandWidth)
    streamWriteFloat32(streamId, self.lowerLate)
    streamWriteFloat32(streamId, self.raiseLate)
    streamWriteUInt8(streamId, self.teamMode)
    streamWriteUInt8(streamId, self.teamSize)
    streamWriteUInt8(streamId, self.teamIndex)
    streamWriteUInt8(streamId, self.callUnloaderAt)
    streamWriteFloat32(streamId, self.toolOffsetX)
    streamWriteBool(streamId, self.autoResume ~= false)
    streamWriteUInt8(streamId, self.workPart)
    streamWriteUInt16(streamId, self.rowFrom)
    streamWriteUInt16(streamId, self.rowTo)
    streamWriteFloat32(streamId, self.workSpeedMax)
    streamWriteFloat32(streamId, self.turnSpeed)
    streamWriteFloat32(streamId, self.reverseSpeed)
    streamWriteUInt8(streamId, self.lights)
    streamWriteUInt8(streamId, self.rowsPerLand)
    streamWriteUInt8(streamId, self.rowShape)
    streamWriteBool(streamId, self.tramlines == true)
    streamWriteFloat32(streamId, self.rowPhase)
    streamWriteFloat32(streamId, self.rowSpacing)
    streamWriteString(streamId, self.skipRows or "")
    streamWriteString(streamId, self.skipZones or "")
    streamWriteUInt8(streamId, self.landsSide or 0)
    streamWriteUInt8(streamId, self.landsPipe or 0)
    streamWriteString(streamId, self.toolSig or "")
    streamWriteString(streamId, self.moves or "")
    streamWriteFloat32(streamId, self.refillX or 0)
    streamWriteFloat32(streamId, self.refillZ or 0)
    streamWriteFloat32(streamId, self.unloadX or 0)
    streamWriteFloat32(streamId, self.unloadZ or 0)
    streamWriteUInt8(streamId, self.unloadFull or 97)
    streamWriteUInt8(streamId, self.unloadMode or 0)
end

function GuidancePlan.readStream(streamId)
    local self = GuidancePlan.new()
    self.fieldId = streamReadInt32(streamId)
    self.workWidth = streamReadFloat32(streamId)
    self.turnRadius = streamReadFloat32(streamId)
    self.runOut = streamReadFloat32(streamId)
    self.headlands = streamReadInt8(streamId)
    self.rowAngle = streamReadFloat32(streamId)
    self.clockwise = streamReadBool(streamId)
    self.headlandsFirst = streamReadBool(streamId)
    self.pattern = streamReadUInt8(streamId)
    self.overlap = streamReadFloat32(streamId)
    self.startX = streamReadFloat32(streamId)
    self.startZ = streamReadFloat32(streamId)
    self.autoWidth = streamReadBool(streamId)
    self.autoRadius = streamReadBool(streamId)
    self.allowReverse = streamReadBool(streamId)
    self.squareCorners = streamReadBool(streamId)
    self.keepLowered = streamReadBool(streamId)
    self.startMode = streamReadUInt8(streamId)
    self.roundedPasses = streamReadInt8(streamId)
    self.towLength = streamReadFloat32(streamId)
    self.minHeadlandWidth = streamReadFloat32(streamId)
    self.lowerLate = streamReadFloat32(streamId)
    self.raiseLate = streamReadFloat32(streamId)
    self.teamMode = streamReadUInt8(streamId)
    self.teamSize = streamReadUInt8(streamId)
    self.teamIndex = streamReadUInt8(streamId)
    self.callUnloaderAt = streamReadUInt8(streamId)
    self.toolOffsetX = streamReadFloat32(streamId)
    self.autoResume = streamReadBool(streamId)
    self.workPart = streamReadUInt8(streamId)
    self.rowFrom = streamReadUInt16(streamId)
    self.rowTo = streamReadUInt16(streamId)
    self.workSpeedMax = streamReadFloat32(streamId)
    self.turnSpeed = streamReadFloat32(streamId)
    self.reverseSpeed = streamReadFloat32(streamId)
    self.lights = streamReadUInt8(streamId)
    self.rowsPerLand = streamReadUInt8(streamId)
    self.rowShape = streamReadUInt8(streamId)
    self.tramlines = streamReadBool(streamId)
    self.rowPhase = streamReadFloat32(streamId)
    self.rowSpacing = streamReadFloat32(streamId)
    self.skipRows = streamReadString(streamId)
    self.skipZones = streamReadString(streamId)
    self.landsSide = streamReadUInt8(streamId)
    self.landsPipe = streamReadUInt8(streamId)
    self.toolSig = streamReadString(streamId)
    self.moves = streamReadString(streamId)
    self.refillX = streamReadFloat32(streamId)
    self.refillZ = streamReadFloat32(streamId)
    self.unloadX = streamReadFloat32(streamId)
    self.unloadZ = streamReadFloat32(streamId)
    self.unloadFull = streamReadUInt8(streamId)
    self.unloadMode = streamReadUInt8(streamId)
    return self
end

-- several tractors on one field
GuidancePlan.TEAM_ALONE = 0
GuidancePlan.TEAM_STRIPS = 1
GuidancePlan.TEAM_CONVOY = 2
GuidancePlan.TEAM_NEXT_ROW = 3
GuidancePlan.TEAM_LANDS = 4
GuidancePlan.TEAM_MODES = {[0] = "alone", [1] = "strips", [2] = "convoy", [3] = "nextRow", [4] = "lands"}

-- lands: the worked ground on this side of the vehicle (a harvester's pipe side: carts drive on stubble)
GuidancePlan.SIDE_AUTO = 0
GuidancePlan.SIDE_LEFT = 1
GuidancePlan.SIDE_RIGHT = 2

--- The turning radius the course is made for: a convoy's outermost lane is half its width less one lane beside
--- the course, the course turns that much wider so the inside lane can still drive it
function GuidancePlan:getCourseTurnRadius()
    if self.teamMode == GuidancePlan.TEAM_CONVOY then
        return self.turnRadius + (math.max(1, self.teamSize or 1) - 1) / 2 * self.workWidth
    end
    return self.turnRadius
end

--- The width the course is made for: a convoy's course is as wide as all its tractors together
function GuidancePlan:getCourseWidth()
    if self.teamMode == GuidancePlan.TEAM_CONVOY then
        return self.workWidth * math.max(1, self.teamSize or 1)
    end
    return self.workWidth
end
GuidancePlan.TEAM_MAX = 6

-- which part of the field
GuidancePlan.WORK_WHOLE = 0
GuidancePlan.WORK_HEADLANDS = 1
GuidancePlan.WORK_ROWS = 2
GuidancePlan.WORK_PARTS = {[0] = "whole", [1] = "headlands", [2] = "rows"}

-- automatic headlands are at least this wide (m)
GuidancePlan.MIN_HEADLAND_DEFAULT = 40

GuidancePlan.LIGHTS_OFF = 0
GuidancePlan.LIGHTS_AUTO = 1

GuidancePlan.ROWS_STRAIGHT = 0
GuidancePlan.ROWS_EDGE = 1

--- The rows left out: set of their places across the field
function GuidancePlan:getSkipRows()
    local set = {}
    for n in string.gmatch(self.skipRows or "", "%d+") do set[tonumber(n)] = true end
    return set
end

--- A row left out or taken back
function GuidancePlan:toggleSkipRow(line)
    local set = self:getSkipRows()
    set[line] = (not set[line]) or nil
    local list = {}
    for n in pairs(set) do list[#list + 1] = n end
    table.sort(list)
    return table.concat(list, " ")
end

--- The editor's moved points: list of {ix, x, z}
function GuidancePlan:getMoves()
    local list = {}
    for part in string.gmatch(self.moves or "", "[^;]+") do
        local v = {}
        for n in string.gmatch(part, "-?[%d%.]+") do v[#v + 1] = tonumber(n) end
        if #v == 3 then list[#list + 1] = {ix = math.floor(v[1]), x = v[2], z = v[3]} end
    end
    return list
end

--- The moves with point ix moved to x, z (replacing an earlier move of it): the plan's string
function GuidancePlan:withMove(ix, x, z)
    local out = {}
    for _, m in ipairs(self:getMoves()) do
        if m.ix ~= ix then out[#out + 1] = string.format("%d %.2f %.2f", m.ix, m.x, m.z) end
    end
    out[#out + 1] = string.format("%d %.2f %.2f", ix, x, z)
    return table.concat(out, ";")
end

--- The areas worked round: list of polygons {x, z} (rectangles)
function GuidancePlan:getSkipZones()
    local zones = {}
    for part in string.gmatch(self.skipZones or "", "[^;]+") do
        local v = {}
        for n in string.gmatch(part, "-?[%d%.]+") do v[#v + 1] = tonumber(n) end
        if #v == 4 then
            local x1, z1, x2, z2 = math.min(v[1], v[3]), math.min(v[2], v[4]), math.max(v[1], v[3]), math.max(v[2], v[4])
            table.insert(zones, {{x = x1, z = z1}, {x = x2, z = z1}, {x = x2, z = z2}, {x = x1, z = z2}})
        end
    end
    return zones
end

GuidancePlan.XML_FIELDS = {
    {"fieldId", "INT"}, {"workWidth", "FLOAT"}, {"turnRadius", "FLOAT"}, {"runOut", "FLOAT"}, {"headlands", "INT"},
    {"rowAngle", "FLOAT"}, {"clockwise", "BOOL"}, {"headlandsFirst", "BOOL"}, {"pattern", "INT"},
    {"overlap", "FLOAT"}, {"startX", "FLOAT"}, {"startZ", "FLOAT"}, {"autoWidth", "BOOL"}, {"autoRadius", "BOOL"},
    {"allowReverse", "BOOL"}, {"squareCorners", "BOOL"}, {"keepLowered", "BOOL"},
    {"startMode", "INT"}, {"roundedPasses", "INT"}, {"towLength", "FLOAT"},
    {"minHeadlandWidth", "FLOAT"}, {"headlandRev", "INT"}, {"prefsApplied", "BOOL"}, {"lowerLate", "FLOAT"}, {"raiseLate", "FLOAT"},
    {"teamMode", "INT"}, {"teamSize", "INT"}, {"teamIndex", "INT"},
    {"callUnloaderAt", "INT"}, {"toolOffsetX", "FLOAT"}, {"autoResume", "BOOL"},
    {"workPart", "INT"}, {"rowFrom", "INT"}, {"rowTo", "INT"}, {"workSpeedMax", "FLOAT"}, {"turnSpeed", "FLOAT"},
    {"reverseSpeed", "FLOAT"}, {"lights", "INT"}, {"rowsPerLand", "INT"}, {"rowShape", "INT"}, {"tramlines", "BOOL"},
    {"rowPhase", "FLOAT"}, {"rowSpacing", "FLOAT"}, {"skipRows", "STRING"}, {"skipZones", "STRING"},
    {"landsSide", "INT"}, {"landsPipe", "INT"}, {"toolSig", "STRING"}, {"moves", "STRING"},
    {"refillX", "FLOAT"}, {"refillZ", "FLOAT"}, {"unloadX", "FLOAT"}, {"unloadZ", "FLOAT"}, {"unloadFull", "INT"}, {"unloadMode", "INT"},
}

function GuidancePlan.registerXMLPaths(schema, basePath)
    for _, f in ipairs(GuidancePlan.XML_FIELDS) do
        schema:register(XMLValueType[f[2]], basePath .. "#" .. f[1], "Guidance course plan: " .. f[1])
    end
end

function GuidancePlan:saveToXMLFile(xmlFile, key)
    for _, f in ipairs(GuidancePlan.XML_FIELDS) do
        xmlFile:setValue(key .. "#" .. f[1], self[f[1]])
    end
end

function GuidancePlan.loadFromXMLFile(xmlFile, key)
    if xmlFile:getValue(key .. "#fieldId") == nil then
        return nil
    end
    local self = GuidancePlan.new()
    for _, f in ipairs(GuidancePlan.XML_FIELDS) do
        local v = xmlFile:getValue(key .. "#" .. f[1])
        if v ~= nil then self[f[1]] = v end
    end
    return self
end

--- The plan in an XML file opened with the engine's own functions (the saved course library's file)
function GuidancePlan:saveToRawXML(xml, key)
    for _, f in ipairs(GuidancePlan.XML_FIELDS) do
        local name, kind, v = f[1], f[2], self[f[1]]
        if v ~= nil then
            if kind == "INT" then setXMLInt(xml, key .. "#" .. name, v)
            elseif kind == "FLOAT" then setXMLFloat(xml, key .. "#" .. name, v)
            elseif kind == "BOOL" then setXMLBool(xml, key .. "#" .. name, v)
            elseif kind == "STRING" then setXMLString(xml, key .. "#" .. name, v) end
        end
    end
end

function GuidancePlan.loadFromRawXML(xml, key)
    if getXMLInt(xml, key .. "#fieldId") == nil then
        return nil
    end
    local self = GuidancePlan.new()
    for _, f in ipairs(GuidancePlan.XML_FIELDS) do
        local name, kind, v = f[1], f[2], nil
        if kind == "INT" then v = getXMLInt(xml, key .. "#" .. name)
        elseif kind == "FLOAT" then v = getXMLFloat(xml, key .. "#" .. name)
        elseif kind == "BOOL" then v = getXMLBool(xml, key .. "#" .. name)
        elseif kind == "STRING" then v = getXMLString(xml, key .. "#" .. name) end
        if v ~= nil then self[name] = v end
    end
    return self
end

-----------------------------------------------------------------------------------------------------------------------

GuidanceCourse = {}
local GuidanceCourse_mt = {__index = GuidanceCourse}

--- The outline of a field of the map, list of {x, z}, or nil
function GuidanceCourse.getField(fieldId)
    if g_fieldManager == nil then
        return nil
    end
    for _, field in pairs(g_fieldManager:getFields() or {}) do
        if field.getId and field:getId() == fieldId then
            return field
        end
    end
    return nil
end

function GuidanceCourse.getFieldOutline(fieldId)
    -- a field a player recorded
    if fieldId < 0 then
        local recorded = GuidanceLibrary.getField(fieldId)
        return recorded and recorded.outline or nil
    end
    local field = GuidanceCourse.getField(fieldId)
    if field == nil or field.getDensityMapPolygon == nil then
        return nil
    end
    local polygon = field:getDensityMapPolygon()
    if polygon == nil then
        return nil
    end
    local flat = polygon:getVerticesList()
    local pts = {}
    for i = 1, #flat - 1, 2 do
        table.insert(pts, {x = flat[i], z = flat[i + 1]})
    end
    return pts
end

--- Islands of a field: places inside its outline that are not field (trees, ponds, buildings), as convex
--- polygons {x, z}. Found by sampling the game's field ground map on a grid; remembered per field.
GuidanceCourse.islandCache = {}
GuidanceCourse.ISLAND_STEP = 3 -- m between samples
GuidanceCourse.ISLAND_MIN_CELLS = 2 -- smaller spots are left alone

function GuidanceCourse.findIslands(fieldId, outline)
    local cached = GuidanceCourse.islandCache[fieldId]
    if cached then
        return cached
    end
    local islands = {}
    -- a recorded field may be meadow, not field ground: no islands there (one read from the ground has them)
    if fieldId < 0 then
        local f = GuidanceLibrary.getField(fieldId)
        if f == nil or f.baseField == nil then
            return islands
        end
    end
    if GuidanceFieldScan == nil or not GuidanceFieldScan.isAvailable() or outline == nil or #outline < 3 then
        return islands
    end
    local isField = GuidanceFieldScan.isFieldAt or GuidanceFieldScan.isField
    local Geo = GuidanceGeo
    local poly = {}
    for i, p in ipairs(outline) do poly[i] = {x = p.x, y = p.z} end
    poly = Geo.ensureCCW(poly)
    local index = Geo.outlineIndex(poly, 10)
    local step = GuidanceCourse.ISLAND_STEP
    local minX, minY, maxX, maxY = Geo.bounds(poly)
    local margin = 4 -- the edge of a field is never quite where its outline is
    local cells, cols = {}, math.floor((maxX - minX) / step) + 1
    for ix = 0, cols - 1 do
        for iy = 0, math.floor((maxY - minY) / step) do
            local p = {x = minX + (ix + 0.5) * step, y = minY + (iy + 0.5) * step}
            if index:isInside(p) and index:closest(p, margin) == nil then
                local ok, isOnField = pcall(isField, p.x, p.y)
                if ok and not isOnField then
                    cells[ix * 100003 + iy] = {ix = ix, iy = iy, x = p.x, y = p.y}
                end
            end
        end
    end
    -- neighbouring cells are one island
    local seen = {}
    local keys = {}
    for key in pairs(cells) do table.insert(keys, key) end
    table.sort(keys)
    for _, key in ipairs(keys) do
        if not seen[key] then
            local group, stack = {}, {key}
            seen[key] = true
            while #stack > 0 do
                local c = cells[table.remove(stack)]
                table.insert(group, c)
                for _, d in ipairs({{1, 0}, {-1, 0}, {0, 1}, {0, -1}}) do
                    local k = (c.ix + d[1]) * 100003 + (c.iy + d[2])
                    if cells[k] and not seen[k] then
                        seen[k] = true
                        table.insert(stack, k)
                    end
                end
            end
            if #group >= GuidanceCourse.ISLAND_MIN_CELLS then
                local pts = {}
                for _, c in ipairs(group) do
                    for _, o in ipairs({{-1, -1}, {1, -1}, {1, 1}, {-1, 1}}) do
                        table.insert(pts, {x = c.x + o[1] * step / 2, y = c.y + o[2] * step / 2})
                    end
                end
                local island = {}
                for i, p in ipairs(Geo.convexHull(pts)) do island[i] = {x = p.x, z = p.y} end
                table.insert(islands, island)
            end
        end
    end
    GuidanceCourse.islandCache[fieldId] = islands
    if #islands > 0 then
        Guidance.info("field %d: %d island(s) found", fieldId, #islands)
    end
    return islands
end

--- Id of the field at a world position (a recorded one first), or nil
function GuidanceCourse.getFieldIdAt(x, z)
    local recorded = GuidanceLibrary.fieldAt(x, z)
    if recorded then
        return recorded.id
    end
    return GuidanceCourse.getMapFieldIdAt(x, z)
end

--- Id of the map's field of the farmland at a world position, or nil
function GuidanceCourse.getMapFieldIdAt(x, z)
    if g_farmlandManager == nil then
        return nil
    end
    local farmland = g_farmlandManager:getFarmlandAtWorldPosition(x, z)
    local field = farmland and farmland.getField and farmland:getField()
    return field and field:getId() or nil
end

--- The field to make a course on at x, z (for farmId):
--- - a field recorded by driving round it;
--- - else the field as it is on the ground (GuidanceFieldScan) when that is not the map's outline (field ground
---   painted on or away, a field painted where the map has none): kept as a field of its own, read again each time;
--- - else the map's field.
--- Returns id (and the field when it was read from the ground just now); or nil, error; or false, field when a new
--- or changed field read from the ground went to the server (the course can be made once it is back:
--- GuidanceCourse.isFieldBack)
function GuidanceCourse.fieldForCourse(x, z, farmId)
    local here = GuidanceLibrary.fieldAt(x, z)
    if here and here.baseField == nil then
        return here.id
    end
    local mapId = GuidanceCourse.getMapFieldIdAt(x, z)
    local scan
    if GuidanceFieldScan and GuidanceFieldScan.isAvailable() then
        local ok, result = pcall(GuidanceFieldScan.scan, x, z, mapId)
        scan = ok and result or nil
        if not ok then Guidance.info("field scan failed: %s", tostring(result)) end
    end
    if scan == nil then
        if here then return here.id end
        if mapId then return mapId end
        return nil, g_i18n:getText("guidance_err_notOnField")
    end
    local Scan = GuidanceFieldScan
    -- the ground is the map's field as it is
    local mapOutline = mapId and GuidanceCourse.getFieldOutline(mapId)
    local onMapField = mapOutline ~= nil and GuidanceCourse.overlaps(scan.outline, mapOutline)
    if here == nil and mapOutline and Scan.sameGround(scan.outline, mapOutline) then
        return mapId
    end
    -- read from the ground before: the same one again, or changed since
    local old = here
    if old == nil then
        for _, f in ipairs(GuidanceLibrary.fields) do
            if f.baseField ~= nil and f.farmId == farmId and GuidanceCourse.overlaps(scan.outline, f.outline) then
                old = f
                break
            end
        end
    end
    if old and Scan.sameGround(scan.outline, old.outline, 50) then
        return old.id
    end
    local name
    if old then
        name = old.name
    elseif onMapField then
        name = string.format(g_i18n:getText("guidance_scan_name"), mapId)
    else
        local n = 1
        for _, f in ipairs(GuidanceLibrary.fields) do
            if f.baseField == 0 and f.farmId == farmId then n = n + 1 end
        end
        name = string.format(g_i18n:getText("guidance_scan_nameNew"), n)
    end
    local field = {id = old and old.id or 0, name = name, farmId = farmId, outline = scan.outline,
                   baseField = onMapField and mapId or 0}
    Guidance.info("field read from the ground: %s, %.2f ha (map field %s), %d point(s)", name, scan.area / 10000,
        tostring(mapId), #scan.outline)
    GuidanceLibrary.addField(field)
    if g_server ~= nil then
        -- the server gave it its id at once
        return field.id, nil, field
    end
    return false, field
end

--- Is a field sent to the server (fieldForCourse) back, as it was sent? Returns its id
function GuidanceCourse.isFieldBack(sent)
    for _, f in ipairs(GuidanceLibrary.fields) do
        if f.baseField ~= nil and f.farmId == sent.farmId and #f.outline == #sent.outline
                and math.abs(f.outline[1].x - sent.outline[1].x) < 0.01
                and math.abs(f.outline[1].z - sent.outline[1].z) < 0.01 then
            return f.id
        end
    end
    return nil
end

--- Do two outlines (lists of {x, z}) overlap? (a corner of one inside the other)
function GuidanceCourse.overlaps(a, b)
    local polyA, polyB = {}, {}
    for i, p in ipairs(a) do polyA[i] = {x = p.x, y = p.z} end
    for i, p in ipairs(b) do polyB[i] = {x = p.x, y = p.z} end
    for _, p in ipairs(polyA) do
        if GuidanceGeo.pointInPolygon(p, polyB) then return true end
    end
    for _, p in ipairs(polyB) do
        if GuidanceGeo.pointInPolygon(p, polyA) then return true end
    end
    return false
end

--- Generates the course for a plan. Returns course or nil, error text
function GuidanceCourse.generate(plan)
    local outline = GuidanceCourse.getFieldOutline(plan.fieldId)
    if outline == nil or #outline < 3 then
        return nil, g_i18n:getText("guidance_err_noField")
    end
    local settings = plan:getGeneratorSettings()
    settings.islands = GuidanceCourse.findIslands(plan.fieldId, outline)
    -- the areas the player marked to work round: like islands
    local zones = plan:getSkipZones()
    if #zones > 0 then
        local all = {}
        for _, island in ipairs(settings.islands or {}) do all[#all + 1] = island end
        for _, zone in ipairs(zones) do all[#all + 1] = zone end
        settings.islands = all
    end
    local result, err = GuidanceCourseGenerator.generate(outline, settings)
    if result == nil then
        return nil, err
    end
    -- the editor's moved points
    GuidanceCourse.applyMoves(result.waypoints, plan:getMoves())
    return GuidanceCourse.new(result, plan, outline)
end

GuidanceCourse.MOVE_REACH = 8 -- m along the course a moved point takes its neighbours with it

--- Moves waypoints where the editor put them; the neighbours within MOVE_REACH along the course follow, less the
--- further away, so the course bends there instead of kinking
function GuidanceCourse.applyMoves(wps, moves)
    if #moves == 0 or #wps < 2 then return end
    -- distances along the course as made
    local d = {0}
    for i = 2, #wps do
        d[i] = d[i - 1] + math.sqrt((wps[i].x - wps[i - 1].x) ^ 2 + (wps[i].z - wps[i - 1].z) ^ 2)
    end
    local reach = GuidanceCourse.MOVE_REACH
    for _, m in ipairs(moves) do
        local w = wps[m.ix]
        if w then
            local dx, dz = m.x - w.x, m.z - w.z
            local i0 = m.ix
            for i = i0, 1, -1 do
                local f = 1 - (d[i0] - d[i]) / reach
                if f <= 0 then break end
                wps[i].x, wps[i].z = wps[i].x + dx * f, wps[i].z + dz * f
            end
            for i = i0 + 1, #wps do
                local f = 1 - (d[i] - d[i0]) / reach
                if f <= 0 then break end
                wps[i].x, wps[i].z = wps[i].x + dx * f, wps[i].z + dz * f
            end
            w.moved = true
        end
    end
end

function GuidanceCourse.new(result, plan, outline)
    local self = setmetatable({}, GuidanceCourse_mt)
    self.plan = plan
    self.waypoints = result.waypoints
    self.stats = result.stats
    self.outline = outline
    -- field, inside of the headlands, innermost headland, islands: for the way to the course (planApproach)
    self.area = result.area
    -- next-free-row team: the field's rows everybody takes from (the course itself has only the headland passes)
    self.teamRows = result.teamRows
    -- rows the player left out (for the editor)
    self.skippedLines = result.skippedLines or {}
    -- distance along the course to each waypoint
    local d = 0
    self.waypoints[1].d = 0
    for i = 2, #self.waypoints do
        local a, b = self.waypoints[i - 1], self.waypoints[i]
        d = d + math.sqrt((b.x - a.x) ^ 2 + (b.z - a.z) ^ 2)
        b.d = d
    end
    self.length = d
    -- turns (for the details): stretches of turn waypoints
    local turns, inTurn = 0, false
    for i = 2, #self.waypoints do
        local isTurn = self.waypoints[i].t == "T"
        if isTurn and not inTurn then turns = turns + 1 end
        inTurn = isTurn
    end
    self.stats.turns = turns
    return self
end

--- Seconds from the start to each waypoint at this work speed (km/h), see GuidanceCourseGenerator.timeProfile
function GuidanceCourse:getTimes(workSpeed)
    local key = math.floor(workSpeed + 0.5)
    self.timesBySpeed = self.timesBySpeed or {}
    if self.timesBySpeed[key] == nil then
        self.timesBySpeed[key] = GuidanceCourseGenerator.timeProfile(self.waypoints, key, self.plan.turnSpeed,
            self.plan.reverseSpeed)
    end
    return self.timesBySpeed[key]
end

function GuidanceCourse:getNumWaypoints()
    return #self.waypoints
end

function GuidanceCourse:getWaypoint(ix)
    return self.waypoints[ix]
end

--- The worked stretch nearest to a vehicle at x, z facing h (one facing about the other way counts as far
--- away): its end waypoint index, and the point on it to start at (nil: at the waypoint before it)
function GuidanceCourse:getNearest(x, z, h)
    local best, bestCost, bestPoint
    local wps = self.waypoints
    for i = 2, #wps do
        local a, b = wps[i - 1], wps[i]
        if b.work and not b.rev then
            local d, t = GuidanceGeo.distToSegment({x = x, y = z}, {x = a.x, y = a.z}, {x = b.x, y = b.z})
            local dh = math.abs(GuidanceGeo.normAngle(math.atan2(b.z - a.z, b.x - a.x) - h))
            local cost = d + (dh > math.pi / 2 and 200 or dh / (math.pi / 2) * 20)
            if bestCost == nil or cost < bestCost then
                local len = math.sqrt((b.x - a.x) ^ 2 + (b.z - a.z) ^ 2)
                bestCost, best = cost, i
                -- start where the vehicle is along it, unless that's right at its start or end
                if len > 10 and t * len > 5 and (1 - t) * len > 10 then
                    bestPoint = {x = a.x + (b.x - a.x) * t, z = a.z + (b.z - a.z) * t}
                else
                    bestPoint = nil
                    if t * len <= 5 then best = i - 1 end
                end
            end
        end
    end
    if best == nil then
        return 1
    end
    return math.max(1, best), bestPoint
end

--- Index where to continue after an interruption at ix: the start of the row or headland pass we were on
--- (not much is lost when working it again, and the vehicle gets a straight run into it), but not before
--- the point we were at if the row is long.
function GuidanceCourse:getResumeIx(ix)
    ix = math.max(1, math.min(ix or 1, #self.waypoints))
    local wp = self.waypoints[ix]
    if wp.t == "R" then
        -- back to this row's start
        for i = ix, 1, -1 do
            if self.waypoints[i].rs then
                if wp.d - self.waypoints[i].d < 150 then
                    return i
                end
                break
            end
        end
    elseif wp.t == "T" or wp.t == "C" then
        -- in a turn: continue at the next row
        for i = ix, #self.waypoints do
            if self.waypoints[i].rs then
                return i
            end
        end
    end
    -- a bit back along the pass, so the implement overlaps what was done
    local back = ix
    while back > 1 and wp.d - self.waypoints[back].d < 10 do
        back = back - 1
    end
    return back
end

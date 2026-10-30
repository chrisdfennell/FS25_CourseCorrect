-- Courseplay's saved courses (its own files in modSettings/FS25_Courseplay/Courses/<map>/...), read as data and
-- made into CourseCorrect saved courses: the field, the work width, the headland passes and their direction, which
-- comes first, the row direction. Courseplay keeps no turns in its files (it works them out as it drives), and
-- CourseCorrect makes its courses from such a plan, so the import carries the plan over, not the waypoints: the
-- rows come out at the same angle, our own turns between them.

GuidanceCourseplayImport = {}
local CPI = GuidanceCourseplayImport

CPI.MAX_WAYPOINTS = 100000
CPI.MAX_DEPTH = 3 -- folders below the map's (savegame type, field)

--- Courseplay's course folder for this map, or nil
function CPI.folder()
    if getUserProfileAppPath == nil then return nil end
    local info = g_currentMission and g_currentMission.missionInfo
    local mapId = info and info.mapId
    if mapId == nil then return nil end
    return getUserProfileAppPath() .. "modSettings/FS25_Courseplay/Courses/" .. mapId .. "/"
end

--- Its courses: list of {path, label ("Field 15 / Combine Harvest")}, sorted
function CPI.list()
    local root = CPI.folder()
    local out = {}
    if root == nil or getFiles == nil then return out end
    local function scan(dir, rel, depth)
        local entries = {}
        CPI.collect = entries
        getFiles(dir, "onFile", CPI)
        CPI.collect = nil
        for _, e in ipairs(entries) do
            local label = rel == "" and e.name or (rel .. " / " .. e.name)
            if e.isDirectory then
                if depth < CPI.MAX_DEPTH then scan(dir .. e.name .. "/", label, depth + 1) end
            else
                out[#out + 1] = {path = dir .. e.name, label = label, courseplay = true}
            end
        end
    end
    scan(root, "", 0)
    -- (the save type folder, "Singleplayer" and the like, says nothing to the player)
    for _, item in ipairs(out) do
        item.label = string.gsub(item.label, "^[^/]+ / ", "", 1)
    end
    table.sort(out, function(a, b) return a.label < b.label end)
    return out
end

function CPI:onFile(name, isDirectory)
    if CPI.collect then table.insert(CPI.collect, {name = name, isDirectory = isDirectory}) end
end

local function parsePosition(text)
    local v = {}
    for n in string.gmatch(text or "", "-?[%d%.]+") do v[#v + 1] = tonumber(n) end
    if #v >= 3 then return v[1], v[3] end
    return nil
end

--- Reads one: its name, a plan and (for a field the map doesn't have) an outline; nil and why when it can't
function CPI.read(path)
    if loadXMLFile == nil or not fileExists(path) then return nil end
    local xml = loadXMLFile("courseplayImport", path)
    if xml == nil or xml == 0 then return nil end
    local key = "Courses.Course(0)"
    local name = getXMLString(xml, key .. "#name")
    local width = getXMLFloat(xml, key .. "#workWidth")
    if name == nil or width == nil or width <= 0.5 then
        delete(xml)
        return nil
    end
    local numHeadlands = getXMLInt(xml, key .. "#numHeadlands") or 0
    -- the waypoints: right in the course, or (a course for several vehicles) in its first vehicle's set; imported as
    -- one course with the same layout (a team is set up on the Team tab)
    local wpKey = key
    if getXMLString(xml, key .. ".wp(0)#position") == nil
            and getXMLString(xml, key .. ".multiVehicleData.waypoints(0).wp(0)#position") ~= nil then
        wpKey = key .. ".multiVehicleData.waypoints(0)"
    end
    local clockwise = getXMLBool(xml, key .. "#headlandClockwise")
    -- the waypoints: which comes first, the rows' direction, the outermost headland pass, a point on the field
    local firstIsHeadland
    local sumC, sumS, rows = 0, 0, 0
    -- the outermost headland pass there is (a course for several vehicles: the first one's may start further in)
    local byPass, minPass = {}, nil
    local rowStart
    local sx, sz
    for i = 0, CPI.MAX_WAYPOINTS do
        local wk = string.format("%s.wp(%d)", wpKey, i)
        local pos = getXMLString(xml, wk .. "#position")
        if pos == nil then break end
        local x, z = parsePosition(pos)
        if x then
            local pass = getXMLInt(xml, wk .. "#headlandPassNumber")
            if firstIsHeadland == nil and (pass ~= nil or getXMLBool(xml, wk .. "#rowStart")) then
                firstIsHeadland = pass ~= nil
            end
            if pass and (getXMLString(xml, wk .. "#boundaryId") or "F") == "F" then
                byPass[pass] = byPass[pass] or {}
                table.insert(byPass[pass], {x = x, y = z})
                if minPass == nil or pass < minPass then minPass = pass end
            end
            if getXMLBool(xml, wk .. "#rowStart") then
                rowStart = {x = x, z = z}
            elseif getXMLBool(xml, wk .. "#rowEnd") and rowStart then
                local a = math.atan2(z - rowStart.z, x - rowStart.x)
                -- (directions, either way along: doubled angles averaged)
                sumC, sumS = sumC + math.cos(2 * a), sumS + math.sin(2 * a)
                rows = rows + 1
                sx, sz = (x + rowStart.x) / 2, (z + rowStart.z) / 2
                rowStart = nil
            end
            if sx == nil and i > 10 then sx, sz = x, z end
        end
    end
    delete(xml)
    local plan = GuidancePlan.new()
    plan.workWidth, plan.autoWidth = width, false
    plan.headlands = numHeadlands
    if clockwise ~= nil then plan.clockwise = clockwise end
    plan.headlandsFirst = firstIsHeadland ~= false
    if rows > 0 then
        plan.rowAngle = (math.floor(math.deg(math.atan2(sumS, sumC) / 2) * 10 + 0.5) / 10) % 180
    end
    -- the map's field where its rows are, else a field of its own: round its outermost headland pass
    local fieldId = sx and GuidanceCourse.getMapFieldIdAt(sx, sz) or nil
    local outline
    local pass1 = minPass and byPass[minPass] or {}
    if fieldId == nil and #pass1 >= 3 then
        -- out to the field's edge: half a width, and a width for each pass further in
        local out = width / 2 + (minPass - 1) * width
        -- (the pass comes back to where it started, its points close together on the bends: a clean ring first)
        local ring = GuidanceGeo.removeDuplicates(pass1, 0.5)
        if #ring > 3 and GuidanceGeo.dist(ring[1], ring[#ring]) < 1 then table.remove(ring) end
        ring = GuidanceGeo.ensureCCW(GuidanceGeo.simplify(GuidanceGeo.ensureCCW(ring), 0.2))
        local poly = #ring >= 3 and GuidanceGeo.offsetOutward(ring, out) or nil
        if poly == nil then
            -- a pass crossing itself somewhere: round its points
            poly = GuidanceGeo.offsetOutward(GuidanceGeo.ensureCCW(GuidanceGeo.convexHull(pass1)), out)
        end
        if poly and #poly >= 3 then
            outline = {}
            for i, p in ipairs(poly) do outline[i] = {x = p.x, z = p.y} end
        end
    end
    if fieldId == nil and outline == nil then return nil end
    plan.fieldId = fieldId or 0
    return name, plan, outline
end

-- Guidance: the courses of the farm's Guidance vehicles on the big map (the in-game menu's map page), done parts
-- dimmed. Client only.

GuidanceMap = {}
local Map = GuidanceMap
local Draw = GuidanceDraw

Map.TOLERANCE = 1.5 -- m, courses are simplified this much for the map
Map.LINE = 2 -- px

-- simplified courses, by course (forgotten with the course)
local cache = setmetatable({}, {__mode = "k"})

local function mapOpen()
    local menu = g_inGameMenu
    return menu ~= nil and menu.isOpen and menu.pageMapOverview ~= nil and menu.currentPage == menu.pageMapOverview
        and menu.baseIngameMap ~= nil and menu.baseIngameMap.layout ~= nil
end

--- Screen position of a world position on the open map, and whether it is in the visible part
local function toScreen(x, z)
    local map = g_inGameMenu.baseIngameMap
    local sx = (x + map.worldCenterOffsetX) / map.worldSizeX * 0.5 + 0.25
    local sz = (z + map.worldCenterOffsetZ) / map.worldSizeZ * 0.5 + 0.25
    local px, py = map.layout:getMapObjectPosition(sx, sz, 0, 0, 0, true)
    local frame = g_inGameMenu.pageMapOverview.ingameMap
    local minX, minY = frame.absoluteSizeOffset[1], frame.absoluteSizeOffset[2]
    local visible = px >= minX and px <= minX + frame.absSize[1] and py >= minY and py <= minY + frame.absSize[2]
    return px, py, visible
end

local function vehicles()
    local system = g_currentMission.vehicleSystem
    return (system and system.vehicles) or g_currentMission.vehicles or {}
end

--- The farm's vehicles that have a Guidance course
function Map.getFarmVehicles()
    local farmId = g_currentMission:getFarmId()
    local list = {}
    for _, v in pairs(vehicles()) do
        if v.getGuidanceCourse ~= nil and v:getOwnerFarmId() == farmId and not v.isDeleted
                and v.spec_guidance and not v.spec_guidance.isShopPreview then
            table.insert(list, v)
        end
    end
    table.sort(list, function(a, b) return Guidance.vehicleName(a) < Guidance.vehicleName(b) end)
    return list
end

local function drawCourse(vehicle, course)
    local runs = cache[course]
    if runs == nil then
        runs = Draw.makeWorldRuns(course, Map.TOLERANCE)
        cache[course] = runs
    end
    local progressIx = vehicle:getGuidanceProgress()
    local thickness = Map.LINE / g_screenHeight
    for _, run in ipairs(runs) do
        local c = Draw.COLORS[run.t] or Draw.COLORS.C
        local done = {c[1], c[2], c[3], 0.35}
        local todo = {c[1], c[2], c[3], 0.95}
        local px, py, pv = toScreen(run.pts[1].x, run.pts[1].y)
        for i = 2, #run.pts do
            local p = run.pts[i]
            local qx, qy, qv = toScreen(p.x, p.y)
            if pv and qv then
                Draw.line(px, py, qx, qy, thickness, p.ix <= progressIx and done or todo)
            end
            px, py, pv = qx, qy, qv
        end
    end
end

function Map.draw()
    if Map.disabled or not mapOpen() then
        return
    end
    local ok, err = pcall(function()
        for _, v in ipairs(Map.getFarmVehicles()) do
            local course = v:getGuidanceCourse()
            if course then
                drawCourse(v, course)
            end
        end
    end)
    if not ok then
        -- the map page works differently than we think: leave it alone
        Map.disabled = true
        Guidance.info("courses on the map turned off: %s", tostring(err))
    end
end

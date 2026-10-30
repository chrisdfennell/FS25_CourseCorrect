-- CourseCorrect: help when something goes wrong. The debug overlay draws, for every CourseCorrect helper near the
-- player, the way it is following (with the connections it planned as it went), the point it steers to and a few
-- lines of what it is doing and why it waits. The problem report writes a text file with the mod's version, the
-- vehicle, its settings and course, what the helper was doing and the mod's last log lines, to attach to a GitHub
-- issue. On a client of a dedicated server the helpers' thinking stays on the server: the overlay shows what is
-- sent (status, progress) there.

GuidanceDebug = {
    RANGE = 250, -- m from the camera: helpers drawn
    PATH_AHEAD = 120, -- m of the way ahead drawn
    LOG_LINES = 80, -- the mod's last log lines kept for a report
    -- the mod's own log lines (Guidance.info, Guidance.debug), the newest last
    log = {},
}
local Debug = GuidanceDebug

function Debug.remember(line)
    local log = Debug.log
    log[#log + 1] = string.format("%8.1f %s", (g_time or 0) / 1000, line)
    if #log > Debug.LOG_LINES then table.remove(log, 1) end
end

local function terrainY(x, z)
    if g_currentMission == nil or g_currentMission.terrainRootNode == nil then return 0 end
    return getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, x, 0, z) + 0.3
end

local function cameraPos()
    local cam = getCamera and getCamera()
    if cam and cam ~= 0 then
        local x, _, z = getWorldTranslation(cam)
        return x, z
    end
    return nil
end

--- What a helper is doing, as lines of text (server: its driver; client: what was sent)
function Debug.describe(vehicle)
    local lines = {Guidance.vehicleName(vehicle)}
    local spec = vehicle.spec_guidance
    local driver = spec and spec.driver
    local kind = vehicle.getGuidanceHelperKind and vehicle:getGuidanceHelperKind()
    if kind then
        lines[#lines + 1] = kind .. ": " .. tostring(vehicle:getGuidanceHelperPhase() or "?")
    elseif vehicle:getIsGuidanceActive() then
        local _, done = vehicle:getGuidanceProgress()
        lines[#lines + 1] = string.format("field work %d%%", math.floor(done * 100 + 0.5))
    end
    if driver then
        local f = driver.follower
        local state = driver.state
        if type(state) == "number" then
            for name, v in pairs(GuidanceFieldworkDriver) do
                if type(v) == "number" and v == state and name:sub(1, 6) == "STATE_" then state = name:sub(7) end
            end
        end
        local seg = f and select(1, f:getCurrentSegment()) or "-"
        lines[#lines + 1] = string.format("%s, %s, s %.0f/%.0f m, off line %.1f m", tostring(state), tostring(seg),
            f and f.s or 0, f and f.points[#f.points] and f.points[#f.points].d or 0, f and f.crossTrack or 0)
        local t = driver.debugTarget
        if t then lines[#lines + 1] = string.format("speed limit %.0f km/h%s", t[3] or 0, driver.lowered and ", lowered" or "") end
        if driver.blockedBy then
            lines[#lines + 1] = "waiting for " .. (driver.blockedBy.getName and Guidance.vehicleName(driver.blockedBy) or "a person")
        end
        if driver.combine then lines[#lines + 1] = "serving " .. Guidance.vehicleName(driver.combine) end
    end
    for _, info in ipairs(vehicle:getGuidanceInfoTexts()) do lines[#lines + 1] = info.text end
    return lines
end

--- The overlay: called every frame while it is on
function Debug.draw()
    if drawDebugLine == nil or g_currentMission == nil then return end
    local cx, cz = cameraPos()
    local vehicles = g_currentMission.vehicleSystem and g_currentMission.vehicleSystem.vehicles or {}
    for _, v in pairs(vehicles) do
        local spec = v.spec_guidance
        if spec and v.rootNode and (v:getIsGuidanceActive() or v == (g_localPlayer and g_localPlayer.getCurrentVehicle
                and g_localPlayer:getCurrentVehicle())) then
            local x, _, z = getWorldTranslation(v.rootNode)
            if cx == nil or (x - cx) ^ 2 + (z - cz) ^ 2 < Debug.RANGE ^ 2 then
                Guidance.try(Debug.drawVehicle, v, spec, x, z)
            end
        end
    end
end

function Debug.drawVehicle(v, spec, x, z)
    local driver = spec.driver
    local y = terrainY(x, z)
    -- the way it follows, ahead of it: green working, yellow on its way, red backing up
    local f = driver and driver.follower
    if f then
        local pts = f.points
        for i = math.max(2, f.ix), #pts do
            local a, b = pts[i - 1], pts[i]
            if (a.d or 0) - f.s > Debug.PATH_AHEAD then break end
            local r, g, bl = 1, 0.85, 0.1
            if b.work then r, g, bl = 0.2, 1, 0.3 end
            if b.rev then r, g, bl = 1, 0.25, 0.25 end
            drawDebugLine(a.x, terrainY(a.x, a.z) + 0.2, a.z, r, g, bl, b.x, terrainY(b.x, b.z) + 0.2, b.z, r, g, bl)
        end
    end
    -- where it steers to: a post
    local t = driver and driver.debugTarget
    if t then
        local ty = terrainY(t[1], t[2])
        drawDebugLine(t[1], ty, t[2], 0.3, 0.8, 1, t[1], ty + 3, t[2], 0.3, 0.8, 1)
        drawDebugLine(x, y + 1.5, z, 0.3, 0.8, 1, t[1], ty + 1.5, t[2], 0.3, 0.8, 1)
    end
    -- what it is doing
    if Utils and Utils.renderTextAtWorldPosition then
        local lines = Debug.describe(v)
        local size = getCorrectTextSize and getCorrectTextSize(0.012) or 0.012
        for i, line in ipairs(lines) do
            Utils.renderTextAtWorldPosition(x, y + 4.5 - i * 0.45, z, line, size, 0)
        end
    end
end

-----------------------------------------------------------------------------------------------------------------------
-- The problem report
-----------------------------------------------------------------------------------------------------------------------

function Debug.reportPath()
    if getUserProfileAppPath == nil then return nil end
    return getUserProfileAppPath() .. "modSettings/FS25_CourseCorrect/report.txt"
end

local function planLines(plan)
    local out = {}
    for _, f in ipairs(GuidancePlan.XML_FIELDS) do
        local v = plan[f[1]]
        if v ~= nil then out[#out + 1] = string.format("  %s = %s", f[1], tostring(v)) end
    end
    return out
end

--- The report's text for a vehicle (nil: none in reach)
function Debug.reportText(vehicle)
    local L = {}
    local function add(fmt, ...) L[#L + 1] = string.format(fmt, ...) end
    local mission = g_currentMission
    local info = mission and mission.missionInfo or {}
    add("CourseCorrect problem report")
    add("version %s, map %s, %s", Guidance.VERSION, tostring(info.mapTitle or info.mapId or "?"),
        g_server == nil and "client of a server" or (g_dedicatedServer and "dedicated server" or "host / single player"))
    local others = {}
    for _, name in ipairs({"FS25_AutoDrive", "FS25_Courseplay", "FS25_precisionFarming", "FS25_Guidance"}) do
        if g_modIsLoaded and g_modIsLoaded[name] then others[#others + 1] = name end
    end
    add("other mods that matter: %s", #others > 0 and table.concat(others, ", ") or "none")
    if vehicle then
        local spec = vehicle.spec_guidance
        add("")
        add("vehicle: %s", Guidance.vehicleName(vehicle))
        local children = {}
        for _, c in ipairs(vehicle.getChildVehicles and vehicle:getChildVehicles() or {}) do
            if c ~= vehicle then children[#children + 1] = Guidance.vehicleName(c) end
        end
        add("hitched: %s", #children > 0 and table.concat(children, ", ") or "nothing")
        local vi = GuidanceVehicleInfo and GuidanceVehicleInfo.get(vehicle)
        if vi then
            add("measured: width %.1f m, turning radius %.1f m, front %.1f, back %.1f, side %.1f, can reverse %s, tow %.1f m",
                vi.workWidth, vi.turnRadius, vi.frontOffset, vi.backOffset, vi.sideOffset, tostring(vi.canReverse), vi.towLength or 0)
        end
        add("")
        for _, line in ipairs(Debug.describe(vehicle)) do add("now: %s", line) end
        local course = vehicle:getGuidanceCourse()
        if course then
            local st = course.stats
            add("course: %d waypoints, %.0f m, %d headland(s), %d row(s), %d off-field turn(s), %d obstacle(s) not worked round",
                #course.waypoints, course.length or 0, st.headlands or 0, st.rows or 0, st.offField or 0, st.islandsIgnored or 0)
            local ix, done = vehicle:getGuidanceProgress()
            add("progress: waypoint %d, %d%%", ix or 0, math.floor((done or 0) * 100 + 0.5))
        else
            add("course: none")
        end
        local plan = vehicle:getGuidancePlan() or vehicle:getGuidanceSettings()
        if plan then
            add("")
            add("settings:")
            for _, line in ipairs(planLines(plan)) do L[#L + 1] = line end
        end
    end
    add("")
    add("last log lines of the mod:")
    for _, line in ipairs(Debug.log) do L[#L + 1] = "  " .. line end
    return table.concat(L, "\n")
end

--- Writes the report to the player's modSettings. Returns its path, or nil
function Debug.writeReport(vehicle)
    local path = Debug.reportPath()
    if path == nil or createFile == nil then return nil end
    createFolder(getUserProfileAppPath() .. "modSettings/")
    createFolder(getUserProfileAppPath() .. "modSettings/FS25_CourseCorrect/")
    local ok, file = Guidance.try(createFile, path, FileAccess and FileAccess.WRITE or 1)
    if not ok or file == nil or file == 0 then return nil end
    fileWrite(file, Debug.reportText(vehicle))
    delete(file)
    Guidance.info("problem report written to %s", path)
    return path
end

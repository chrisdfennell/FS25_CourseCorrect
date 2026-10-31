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
    -- (as high as the course lines, the player's line height)
    local h = GuidancePrefs and GuidancePrefs.lineHeight or 0.25
    return getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, x, 0, z) + h + 0.05
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
        -- standing: why
        if t and (t[3] or 0) == 0 and not driver.blockedBy then
            local why = driver.stopReason
            if why == nil and vehicle.spec_guidance and vehicle.spec_guidance.paused then why = "paused" end
            if why == nil and driver.makingRoom then why = "making room for another" end
            lines[#lines + 1] = "stopped: " .. (why or "no reason known (state " .. tostring(state) .. ")")
        end
        if driver.combine then lines[#lines + 1] = "serving " .. Guidance.vehicleName(driver.combine) end
        -- an unloader: where it is against its place under the pipe, and why it stands
        if driver.describe then
            local ok, text = Guidance.try(driver.describe, driver)
            if ok and text then lines[#lines + 1] = "unloader: " .. text end
        end
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
--- For a harvester, as AutoDrive sees it: its first target, call level, tank, pipe, whether AutoDrive counts it as
--- working, the unloader it sent; and every AutoDrive unloader: its first target (they pair only on the same one),
--- idle or busy. Empty for other vehicles or without AutoDrive.
function Debug.autoDriveLines(vehicle)
    local lines = {}
    local harvester = GuidanceFieldworkDriver and GuidanceFieldworkDriver.findHarvester(vehicle)
    local ad = AutoDrive or (FS25_AutoDrive and FS25_AutoDrive.AutoDrive)
    local manager = ADHarvestManager or (FS25_AutoDrive and FS25_AutoDrive.ADHarvestManager)
    if harvester == nil or ad == nil or manager == nil then return lines end
    Guidance.try(function()
        local function target(v)
            local m = v.ad and v.ad.stateModule and v.ad.stateModule:getFirstMarker()
            return m and tostring(m.name) or "none"
        end
        local function contains(list, v)
            for _, x in pairs(list or {}) do if x == v then return true end end
            return false
        end
        local fill, capacity = ad.getObjectFillLevels(harvester)
        local preCall = ad.getSetting("preCallLevel", harvester)
        local active = ad.getSetting("activeUnloading", harvester)
        local pipeOut = ad.isPipeOut(harvester)
        local state = contains(manager.harvesters, harvester) and "working (it looks for unloaders)"
            or contains(manager.idleHarvesters, harvester) and "idle (it doesn't look for unloaders)" or "not known to AutoDrive"
        lines[#lines + 1] = string.format("harvester first target %s, calls at %s, tank %s, pipe out %s, active unloading %s, %s",
            target(vehicle), preCall and string.format("%d%%", math.floor(preCall * 100 + 0.5)) or "?",
            (capacity or 0) > 0 and string.format("%d%%", math.floor(fill / capacity * 100 + 0.5)) or "?",
            tostring(pipeOut), tostring(active), state)
        local needs = manager.isHarvesterActive and manager.isHarvesterActive(harvester)
        local assigned = manager.getAssignedUnloader and manager:getAssignedUnloader(harvester)
        lines[#lines + 1] = string.format("wants an unloader on the move now: %s; unloader sent: %s", tostring(needs),
            assigned and Guidance.vehicleName(assigned) or "none")
        local count = 0
        for _, list in ipairs({{manager.idleUnloaders, "idle, waiting for a call"}, {manager.activeUnloaders, "busy"}}) do
            for _, u in pairs(list[1] or {}) do
                count = count + 1
                local same = target(u) == target(vehicle)
                lines[#lines + 1] = string.format("unloader %s: %s, first target %s%s", Guidance.vehicleName(u), list[2],
                    target(u), same and "" or " (not the harvester's: AutoDrive won't send it)")
            end
        end
        if count == 0 then
            lines[#lines + 1] = "no AutoDrive unloaders (none started in the unload-combine mode)"
        end
    end)
    return lines
end

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
        -- who drives it now: our helper, the game's own, AutoDrive (a report while something else drives it)
        local job = vehicle.getJob and vehicle:getJob()
        local ad = vehicle.ad and vehicle.ad.stateModule and vehicle.ad.stateModule.isActive and vehicle.ad.stateModule:isActive()
        local jobName = "no helper job"
        if job then
            -- the job's type (field work, go to, deliver...; ours by its name)
            local ok, typeName = Guidance.try(function()
                local m = g_currentMission.aiJobTypeManager
                local jobType = m:getJobTypeByIndex(job.jobTypeIndex or m:getJobTypeIndex(job))
                return jobType and (jobType.name or jobType.title)
            end)
            jobName = tostring(job.name or (ok and typeName) or "a helper job")
            if GuidanceVehicle and not GuidanceVehicle.getIsGuidanceActive(vehicle) then
                jobName = jobName .. " (not CourseCorrect's: the game's own helper or another mod's)"
            end
        end
        add("driven by: %s%s", jobName, ad and ", AutoDrive active" or "")
        for _, line in ipairs(Debug.describe(vehicle)) do add("now: %s", line) end
        -- a harvester and AutoDrive's unloaders: how AutoDrive sees it (why no truck comes)
        for _, line in ipairs(Debug.autoDriveLines(vehicle)) do add("autodrive: %s", line) end
        -- an unloader: where it can unload (why Unload at offers no station)
        local kinds = vehicle.getGuidanceHelperKinds and vehicle:getGuidanceHelperKinds() or {}
        local unloader = vehicle.getGuidanceHelperKind and vehicle:getGuidanceHelperKind() == "unload"
        for _, k in ipairs(kinds) do if k == "unload" then unloader = true end end
        if unloader and GuidanceTrips and GuidanceTrips.describeUnloadingStations then
            local ok, lines = Guidance.try(GuidanceTrips.describeUnloadingStations, vehicle:getOwnerFarmId())
            for _, line in ipairs(ok and lines or {}) do add("unloader: %s", line) end
            local s = vehicle:getGuidanceSettings()
            if s then
                add("unloader: Unload at mode %d, place %.0f %.0f, leave full at %d%%", s.unloadMode or 0, s.unloadX or 0,
                    s.unloadZ or 0, s.unloadFull or 97)
            end
        end
        local course = vehicle:getGuidanceCourse()
        if course then
            local st = course.stats
            add("course: %d waypoints, %.0f m, %d headland(s), %d row(s), %d off-field turn(s), %d obstacle(s) not worked round",
                #course.waypoints, course.length or 0, st.headlands or 0, st.rows or 0, st.offField or 0, st.islandsIgnored or 0)
            local ix, done = vehicle:getGuidanceProgress()
            add("progress: waypoint %d, %d%%", ix or 0, math.floor((done or 0) * 100 + 0.5))
            -- the field as the course was made for it (a field read from the ground is nowhere else): to make the
            -- same course again
            local outline = course.outline or {}
            add("field outline: %d point(s), x z", #outline)
            for i = 1, #outline, 4 do
                local parts = {}
                for k = i, math.min(i + 3, #outline) do
                    parts[#parts + 1] = string.format("%.2f %.2f", outline[k].x, outline[k].z)
                end
                add("  %s", table.concat(parts, "; "))
            end
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

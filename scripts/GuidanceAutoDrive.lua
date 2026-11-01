-- CourseCorrect: the combine unloader is AutoDrive's ("unload combine" mode); our panel only sets it up. Which combine
-- it serves: the truck and the combine get the same first target, the AutoDrive marker of the combine's field (that is
-- how AutoDrive pairs them, and where the truck waits); where it unloads: its second target; how it drives: AutoDrive's
-- own settings of the truck and the combine, written there and sent with AutoDrive's settings event. Nothing is kept
-- here: AutoDrive's menu and our panel always show the same, a change in either is a change in both.

GuidanceAutoDrive = {}
local AD = GuidanceAutoDrive

AD.COMBINE_MARKER_RANGE = 1000 -- m from the combine its field's AutoDrive marker may be

-- what the panel asks the server to do (GuidanceAutoDriveEvent)
AD.OP_SETTING = 1 -- an AutoDrive setting of a vehicle (the truck, or the combine it serves): name, value index
AD.OP_COMBINE = 2 -- the combine the truck serves (other)
AD.OP_UNLOAD_AT = 3 -- where it unloads: a marker id
AD.OP_START = 4
AD.OP_STOP = 5

-- the truck's settings and the combine's (AutoDrive reads these from the one or the other)
AD.TRUCK_SETTINGS = {"unloadFillLevel", "avoidFruit", "pipeOffset", "pipeZOffset", "followDistance"}
AD.COMBINE_SETTINGS = {"chaseSide", "callSecondUnloader"}

--- One of AutoDrive's globals (in its mod's environment, or shared), or nil
local function adGlobal(name)
    local ok, v = pcall(function() return _G[name] end)
    if ok and v ~= nil then return v end
    if FS25_AutoDrive ~= nil then return FS25_AutoDrive[name] end
    return nil
end

--- AutoDrive, or nil without it
function AD.get()
    return adGlobal("AutoDrive")
end

--- AutoDrive's "unload combine" mode number, or nil
function AD.unloadMode()
    local ad = AD.get()
    return ad and ad.MODE_UNLOAD
end

local function stateOf(vehicle)
    return vehicle and vehicle.ad and vehicle.ad.stateModule
end

--- Can the vehicle be AutoDrive's combine unloader? (AutoDrive there, a trailer or an auger wagon on it)
function AD.canUnload(vehicle)
    if AD.get() == nil or stateOf(vehicle) == nil then return false end
    for _, v in ipairs(vehicle.getChildVehicles and vehicle:getChildVehicles() or {}) do
        if v ~= vehicle and (v.spec_trailer or v.spec_pipe) and v.getFillUnits and #v:getFillUnits() > 0 then
            return true
        end
    end
    return false
end

--- Does AutoDrive drive the vehicle as a combine unloader now?
function AD.isUnloading(vehicle)
    local sm = stateOf(vehicle)
    return sm ~= nil and sm:isActive() and sm:getMode() == AD.unloadMode()
end

--- An AutoDrive setting: its values (list) and the index of the one the vehicle has; nil when there is no such setting
function AD.setting(name, vehicle)
    local ad = AD.get()
    local setting = ad and ad.settings and ad.settings[name]
    if setting == nil or setting.values == nil then return nil end
    local ok, ix = Guidance.try(ad.getSettingState, name, vehicle)
    return setting.values, (ok and ix) or setting.default or 1
end

--- The index of the value in a setting's list nearest to value
function AD.nearest(values, value)
    local best, bestD
    for i, v in ipairs(values or {}) do
        local d = math.abs((tonumber(v) or (v and 1 or 0)) - value)
        if bestD == nil or d < bestD then best, bestD = i, d end
    end
    return best
end

--- The vehicles of a combine that have AutoDrive's state: the one driving it and the harvester (a trailed one)
local function combineParts(combine)
    local parts = {}
    local harvester = GuidanceFieldworkDriver.findHarvester(combine)
    for _, v in ipairs(harvester and harvester ~= combine and {combine, harvester} or {combine}) do
        if stateOf(v) then parts[#parts + 1] = v end
    end
    return parts
end

--- The farm's combines (the vehicles driving them), each with the field it is on: list of {vehicle, number}, by name
function AD.combines(farmId)
    local list = {}
    local vehicles = g_currentMission and g_currentMission.vehicleSystem and g_currentMission.vehicleSystem.vehicles
    for _, v in pairs(vehicles or {}) do
        if not v.isDeleted and v.spec_guidance and (farmId == nil or v:getOwnerFarmId() == farmId)
                and (v.getRootVehicle == nil or v:getRootVehicle() == v)
                and GuidanceFieldworkDriver.findHarvester(v) and stateOf(v) then
            local _, number = GuidanceVehicle.fieldOfVehicle(v)
            list[#list + 1] = {vehicle = v, number = number}
        end
    end
    table.sort(list, function(a, b) return Guidance.vehicleName(a.vehicle) < Guidance.vehicleName(b.vehicle) end)
    return list
end

--- The combine the truck serves: the first with the truck's first target, or nil
function AD.combineOf(truck)
    local sm = stateOf(truck)
    local id = sm and sm:getFirstMarkerId()
    if id == nil or id == -1 then return nil end
    for _, c in ipairs(AD.combines(truck:getOwnerFarmId())) do
        local csm = stateOf(c.vehicle)
        if c.vehicle ~= truck and csm:getFirstMarkerId() == id then return c.vehicle end
    end
    return nil
end

--- The AutoDrive unloaders of a combine: trucks in unload combine mode, started, that wait at its first target (set
--- up for it) or that AutoDrive sent to it: list of {vehicle, busy (sent to it: on its way, unloading)}
function AD.unloadersOf(combine)
    local list = {}
    local mode = AD.unloadMode()
    local harvester = mode and GuidanceFieldworkDriver.findHarvester(combine)
    if harvester == nil then return list end
    local csm = stateOf(combine)
    local first = csm and csm:getFirstMarkerId()
    local vehicles = g_currentMission and g_currentMission.vehicleSystem and g_currentMission.vehicleSystem.vehicles
    for _, v in pairs(vehicles or {}) do
        local sm = stateOf(v)
        if v ~= combine and sm and sm:getMode() == mode and sm:isActive() then
            local m = v.ad.modes and v.ad.modes[mode]
            local sent = m ~= nil and m.combine ~= nil and (m.combine == harvester or m.combine == combine)
            local paired = first ~= nil and first ~= -1 and sm:getFirstMarkerId() == first
            -- (a client doesn't know where AutoDrive sent it: one on the move is busy too, a waiting one stands)
            local moving = v.getLastSpeed ~= nil and v:getLastSpeed() > 2
            if sent or paired then list[#list + 1] = {vehicle = v, busy = sent or moving} end
        end
    end
    return list
end

--- The name of a marker (by id), or nil
function AD.markerName(id)
    for _, m in ipairs(GuidanceVehicle.autoDriveMarkers() or {}) do
        if m.id == id then return m.name end
    end
    return nil
end

--- The AutoDrive marker of the field a combine is on (one at its edge named after it first), else the combine's own
--- first target: id and name, or nil
function AD.fieldMarker(combine)
    local outline, number = GuidanceVehicle.fieldOfVehicle(combine)
    if outline and combine.rootNode then
        local x, _, z = getWorldTranslation(combine.rootNode)
        local id, name = GuidanceVehicle.markerNear(GuidanceVehicle.autoDriveMarkers(), outline, number, {x = x, z = z},
            AD.COMBINE_MARKER_RANGE)
        if id then return id, name end
    end
    local sm = stateOf(combine)
    local id = sm and sm:getFirstMarkerId()
    if id and id ~= -1 then return id, AD.markerName(id) end
    return nil
end

-----------------------------------------------------------------------------------------------------------------------
-- Server: what the panel asked for
-----------------------------------------------------------------------------------------------------------------------

--- Sets an AutoDrive setting of a vehicle (by its index in the list) and sends it to everybody, as AutoDrive's menu does
function AD.setSetting(vehicle, name, index)
    local ad = AD.get()
    if ad == nil or ad.setSettingState == nil or vehicle == nil or vehicle.ad == nil then return false end
    Guidance.try(ad.setSettingState, name, index, vehicle)
    local event = adGlobal("AutoDriveUpdateSettingsEvent")
    if event and event.sendEvent and (g_server ~= nil or g_client ~= nil) then
        Guidance.try(event.sendEvent, vehicle)
    end
    return true
end

--- The truck serves this combine: both get the AutoDrive marker of the combine's field as their first target
function AD.pair(truck, combine)
    local id, name = AD.fieldMarker(combine)
    if id == nil then
        Guidance.info("%s: no AutoDrive marker by the field of %s", Guidance.vehicleName(truck), Guidance.vehicleName(combine))
        return false
    end
    stateOf(truck):setFirstMarker(id)
    for _, v in ipairs(combineParts(combine)) do stateOf(v):setFirstMarker(id) end
    Guidance.info("%s: unloads %s, waits at '%s'", Guidance.vehicleName(truck), Guidance.vehicleName(combine), tostring(name))
    return true
end

--- AutoDrive drives the truck as a combine unloader; (stop) or not any more
function AD.startStop(truck, start)
    local sm = stateOf(truck)
    local input = adGlobal("ADInputManager")
    if sm == nil or input == nil or input.input_start_stop == nil then return false end
    if start then
        if sm:isActive() then return true end
        sm:setMode(AD.unloadMode())
        if sm:getFirstMarker() == nil or sm:getSecondMarker() == nil then return false end
        Guidance.try(input.input_start_stop, input, truck, truck:getOwnerFarmId())
        return true
    end
    if sm:isActive() then Guidance.try(input.input_start_stop, input, truck, truck:getOwnerFarmId()) end
    return true
end

--- Server: one of the panel's asks (see the OP_ numbers)
function AD.apply(truck, op, other, name, value)
    local sm = stateOf(truck)
    if g_server == nil or sm == nil then return end
    if op == AD.OP_SETTING then
        AD.setSetting(other or truck, name, value)
    elseif op == AD.OP_COMBINE and other then
        AD.pair(truck, other)
    elseif op == AD.OP_UNLOAD_AT then
        sm:setSecondMarker(value)
    elseif op == AD.OP_START then
        AD.startStop(truck, true)
    elseif op == AD.OP_STOP then
        AD.startStop(truck, false)
    end
end

--- Asks the server (or does it, on the server)
function AD.ask(truck, op, other, name, value)
    if g_server ~= nil then
        AD.apply(truck, op, other, name or "", value or 0)
    else
        GuidanceAutoDriveEvent.sendEvent(truck, op, other, name or "", value or 0)
    end
end

AD.RESUME_DELAY = 10000 -- ms after loading before an unloader starts again (AutoDrive and the combines ready first)

--- Server, after loading: a truck AutoDrive drove as a combine unloader when the game was saved starts again, unless
--- its After loading says Wait. (AutoDrive does that itself only in single player, with its autostart switch on: on a
--- dedicated server the trucks stood after every restart.)
function AD.updateResume(vehicle, spec, dt)
    if spec.adResumeAfterLoad == nil then return end
    spec.adResumeAfterLoad = spec.adResumeAfterLoad + dt
    vehicle:raiseActive()
    if spec.adResumeAfterLoad < AD.RESUME_DELAY then return end
    spec.adResumeAfterLoad = nil
    local sm = stateOf(vehicle)
    if sm == nil or not sm.activeBeforeSave or sm:isActive() or sm:getMode() ~= AD.unloadMode()
            or (spec.settings and spec.settings.autoResume == false) then
        return
    end
    if sm:getFirstMarker() == nil or sm:getSecondMarker() == nil then return end
    Guidance.info("%s: AutoDrive's combine unloader when saved: started again", Guidance.vehicleName(vehicle))
    AD.startStop(vehicle, true)
end

--- Server, our combine starting on a field: its first target that field's marker, and the trucks set to it (the same
--- first target, unloading combines) along with it, so that they come to the new field. A first target nobody shares
--- is left as the player set it.
function AD.followCombine(combine)
    local sm = stateOf(combine)
    if sm == nil or AD.get() == nil then return end
    local id, name = AD.fieldMarker(combine)
    local old = sm:getFirstMarkerId()
    if id == nil or id == old then return end
    local trucks = {}
    local vehicles = g_currentMission and g_currentMission.vehicleSystem and g_currentMission.vehicleSystem.vehicles
    if old ~= -1 then
        for _, v in pairs(vehicles or {}) do
            local vsm = stateOf(v)
            if v ~= combine and vsm and vsm:getFirstMarkerId() == old then
                if vsm:getMode() == AD.unloadMode() then
                    trucks[#trucks + 1] = v
                elseif GuidanceFieldworkDriver.findHarvester(v) and v.getIsAIActive and v:getIsAIActive() then
                    -- (another combine still working there: the trucks stay for it)
                    return
                end
            end
        end
        if #trucks == 0 then return end
    end
    for _, v in ipairs(combineParts(combine)) do stateOf(v):setFirstMarker(id) end
    for _, v in ipairs(trucks) do stateOf(v):setFirstMarker(id) end
    Guidance.info("%s: on a new field, its AutoDrive unloaders (%d) wait at '%s' now", Guidance.vehicleName(combine),
        #trucks, tostring(name))
end

-----------------------------------------------------------------------------------------------------------------------
-- Fuel and repair trips: AutoDrive takes a helper of ours there and starts it again where it stopped (as it does
-- for Courseplay's helper, which we stand in for when Courseplay isn't there)
-----------------------------------------------------------------------------------------------------------------------

--- Can AutoDrive take the vehicle for fuel or a repair and bring it back?
function AD.canService(vehicle)
    return AD.get() ~= nil and stateOf(vehicle) ~= nil and vehicle.startAutoDrive ~= nil
        and Guidance.providesAutoDriveInterface ~= nil and Guidance.providesAutoDriveInterface() == true
end

--- Server, before such a trip: AutoDrive's own switch for it (autoRefuel / autoRepair) on for this vehicle, since our
--- Refuel at / Repair at asked for the trip
function AD.prepareService(vehicle, kind)
    local name = kind == "fuel" and "autoRefuel" or "autoRepair"
    local values, ix = AD.setting(name, vehicle)
    if values and values[ix] ~= true then
        for i, v in ipairs(values) do
            if v == true then AD.setSetting(vehicle, name, i) end
        end
    end
end

-----------------------------------------------------------------------------------------------------------------------
-- For the problem report
-----------------------------------------------------------------------------------------------------------------------

local function settingText(name, vehicle)
    local values, ix = AD.setting(name, vehicle)
    if values == nil then return name .. " ?" end
    return string.format("%s %s", name, tostring(values[ix]))
end

--- An unloader's AutoDrive setup, as lines of text (none when it isn't one)
function AD.describeUnloader(vehicle)
    local sm = stateOf(vehicle)
    if sm == nil or not (AD.canUnload(vehicle) or AD.isUnloading(vehicle)) then return {} end
    local lines = {}
    local first, second = sm:getFirstMarkerId(), sm:getSecondMarkerId()
    lines[#lines + 1] = string.format("AutoDrive mode %s%s, waits at '%s' (%s), unloads at '%s' (%s)", tostring(sm:getMode()),
        sm:isActive() and " (driving)" or "", tostring(AD.markerName(first)), tostring(first),
        tostring(AD.markerName(second)), tostring(second))
    local parts = {}
    for _, name in ipairs(AD.TRUCK_SETTINGS) do parts[#parts + 1] = settingText(name, vehicle) end
    lines[#lines + 1] = "truck: " .. table.concat(parts, ", ")
    local combine = AD.combineOf(vehicle)
    if combine then
        parts = {}
        for _, name in ipairs(AD.COMBINE_SETTINGS) do parts[#parts + 1] = settingText(name, combine) end
        parts[#parts + 1] = settingText("preCallLevel", combine)
        lines[#lines + 1] = string.format("serves %s: %s", Guidance.vehicleName(combine), table.concat(parts, ", "))
    else
        lines[#lines + 1] = "no combine of the farm has the same first target"
    end
    local mode = AD.unloadMode()
    local m = mode and vehicle.ad.modes and vehicle.ad.modes[mode]
    if m and m.combine then lines[#lines + 1] = "AutoDrive sent it to " .. Guidance.vehicleName(m.combine) end
    return lines
end

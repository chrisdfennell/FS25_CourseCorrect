-- Guidance: trips off the field on the game's roads (its own AI road driving): the stations a seeder / sprayer is
-- filled at, and filling at a station's load trigger.
-- A chosen station is kept by its place (the game's object ids don't survive a save); the nearest one is found
-- again from it.

GuidanceTrips = {}
local Trips = GuidanceTrips

Trips.FILL_TIMEOUT = 90000 -- ms at a load trigger without filling before giving up

--- The drive target of a station: x, z, dirX, dirZ (or nil)
function Trips.targetOf(station)
    if station == nil then return nil end
    if station.getAITargetPositionAndDirection then
        local ok, x, z, dx, dz = Guidance.try(station.getAITargetPositionAndDirection, station, FillType and FillType.UNKNOWN)
        if ok and x then return x, z, dx or 0, dz or 1 end
    end
    local trigger = station.unloadTriggers and station.unloadTriggers[1]
    if trigger and trigger.supportsAIUnloading and trigger.getAITargetPositionAndDirection then
        local ok, x, z, dx, dz = Guidance.try(trigger.getAITargetPositionAndDirection, trigger)
        if ok and x then return x, z, dx or 0, dz or 1 end
    end
    local node = (trigger and trigger.exactFillRootNode) or (station.loadTriggers and station.loadTriggers[1]
        and station.loadTriggers[1].triggerNode)
    if node then
        local x, _, z = getWorldTranslation(node)
        return x, z, 0, 1
    end
    return nil
end

--- A station's name for the player
function Trips.nameOf(station)
    local placeable = station and station.owningPlaceable
    if placeable and placeable.getName then
        local ok, name = Guidance.try(placeable.getName, placeable)
        if ok and name and name ~= "" then return name end
    end
    return station and station.getName and station:getName() or "?"
end

local function storage()
    return g_currentMission and g_currentMission.storageSystem
end

--- The loading stations the farm can fill fillType at (with some in stock)
function Trips.loadingStations(farmId, fillType)
    local list = {}
    local sys = storage()
    if sys == nil or sys.getLoadingStations == nil then return list end
    for _, st in pairs(sys:getLoadingStations()) do
        local ok = g_currentMission.accessHandler == nil or g_currentMission.accessHandler:canFarmAccess(farmId, st)
        local types = ok and st.getAISupportedFillTypes and st:getAISupportedFillTypes()
        if types and (fillType == nil or types[fillType]) and Trips.targetOf(st) then
            table.insert(list, st)
        end
    end
    table.sort(list, function(a, b) return Trips.nameOf(a) < Trips.nameOf(b) end)
    return list
end

--- The station of a list nearest to x, z (within 30 m), the one kept in a plan
function Trips.find(list, x, z)
    if x == nil or (x == 0 and z == 0) then return nil end
    local best, bestD
    for _, st in ipairs(list) do
        local sx, sz = Trips.targetOf(st)
        local d = (sx - x) ^ 2 + (sz - z) ^ 2
        if bestD == nil or d < bestD then best, bestD = st, d end
    end
    return bestD and bestD < 900 and best or nil
end

--- The next of a list after the one at x, z (the setting's arrows): its x, z; or 0, 0 for none
function Trips.cycle(list, x, z, step)
    local current = Trips.find(list, x, z)
    local ix = 0
    for i, st in ipairs(list) do if st == current then ix = i end end
    ix = ix + (step or 1)
    if ix < 1 or ix > #list then
        return 0, 0
    end
    local sx, sz = Trips.targetOf(list[ix])
    return sx, sz
end

-----------------------------------------------------------------------------------------------------------------------
-- Filling at a load trigger (the game has no task for this): the vehicle stands at the station, each fill unit
-- that takes fillTypes and has room is filled at the trigger that reaches it
-----------------------------------------------------------------------------------------------------------------------

GuidanceFillTask = {}
local Fill_mt = {__index = GuidanceFillTask}

function GuidanceFillTask.new(isServer, job)
    return setmetatable({isServer = isServer, job = job, isFinished = false, isRunning = false, markAsFinished = false},
        Fill_mt)
end

function GuidanceFillTask:setVehicle(vehicle) self.vehicle = vehicle end
function GuidanceFillTask:reset() self.isFinished = false end
function GuidanceFillTask:validate() return true, nil end
function GuidanceFillTask:getIsFinished() return self.isFinished end
function GuidanceFillTask:delete() end

function GuidanceFillTask:skip()
    if self.isRunning then self.isFinished = true else self.markAsFinished = true end
end

function GuidanceFillTask:start()
    self.isFinished = self.markAsFinished
    self.markAsFinished = false
    self.isRunning = true
    self.timer = 0
    self.loading = nil
end

function GuidanceFillTask:stop()
    self.isRunning = false
    if self.loading and self.loading.trigger then
        self.loading.trigger.autoStart = false
    end
    self.loading = nil
end

--- The fill units still to fill: list of {object, fillUnitIndex, fillType}
function GuidanceFillTask.wants(vehicle, fillTypes)
    local out = {}
    local list = vehicle.getChildVehicles and vehicle:getChildVehicles() or {vehicle}
    for _, v in ipairs(list) do
        if v.getFillUnits and v.getFillUnitFreeCapacity then
            for ix in ipairs(v:getFillUnits()) do
                if v:getFillUnitFreeCapacity(ix) > 0.1 then
                    for _, ft in ipairs(fillTypes) do
                        local takes = (v.getFillUnitSupportsFillType == nil or v:getFillUnitSupportsFillType(ix, ft))
                            and (v.getFillUnitAllowsFillType == nil or v:getFillUnitAllowsFillType(ix, ft))
                            and (v.getFillUnitSupportsToolType == nil or ToolType == nil
                                or v:getFillUnitSupportsToolType(ix, ToolType.TRIGGER))
                        if takes then
                            table.insert(out, {object = v, fillUnitIndex = ix, fillType = ft})
                            break
                        end
                    end
                end
            end
        end
    end
    return out
end

local function triggerReaches(trigger, object, ix)
    for _, f in pairs(trigger.fillableObjects or {}) do
        if f.object == object and (f.fillUnitIndex == nil or f.fillUnitIndex == ix) then return true end
    end
    return trigger.validFillableObject == object and (trigger.validFillableFillUnitIndex == nil
        or trigger.validFillableFillUnitIndex == ix)
end

function GuidanceFillTask:update(dt)
    if not self.isRunning or self.isFinished or not self.isServer then
        return
    end
    local job, vehicle = self.job, self.vehicle
    self.timer = self.timer + dt
    if self.loading then
        local l = self.loading
        if l.object:getFillUnitFreeCapacity(l.fillUnitIndex) <= 0.1 or not l.trigger.isLoading then
            l.trigger.autoStart = false
            self.loading = nil
            self.timer = 0
        end
        return
    end
    local wants = GuidanceFillTask.wants(vehicle, job.refillFillTypes or {})
    if #wants == 0 then
        self.isFinished = true
        return
    end
    local station = job.refillStation
    for _, w in ipairs(wants) do
        for _, trigger in ipairs(station and station.loadTriggers or {}) do
            if triggerReaches(trigger, w.object, w.fillUnitIndex) and trigger.onFillTypeSelection then
                trigger.autoStart = true
                trigger.selectedFillType = w.fillType
                local ok = Guidance.try(trigger.onFillTypeSelection, trigger, w.fillType)
                if ok and trigger.isLoading then
                    trigger.autoStart = false
                    self.loading = {trigger = trigger, object = w.object, fillUnitIndex = w.fillUnitIndex}
                    self.timer = 0
                    return
                end
                trigger.autoStart = false
            end
        end
    end
    if self.timer > Trips.FILL_TIMEOUT then
        -- nothing fills (the station is out, or the trailer isn't in reach): on with what there is
        Guidance.info("%s: could not fill at %s", Guidance.vehicleName(vehicle), Trips.nameOf(station))
        self.isFinished = true
    end
end

--- What a seeder / sprayer of the vehicle is filled with: list of fill types
function Trips.refillTypes(vehicle)
    local types, seen = {}, {}
    local function add(ft) if ft and not seen[ft] then seen[ft] = true; types[#types + 1] = ft end end
    for _, v in ipairs(vehicle.getChildVehicles and vehicle:getChildVehicles() or {vehicle}) do
        if v.spec_sowingMachine and FillType and FillType.SEEDS then add(FillType.SEEDS) end
        if v.getSprayerFillUnitIndex then
            local ok, ix = Guidance.try(v.getSprayerFillUnitIndex, v)
            if ok and ix and v.getFillUnitSupportedFillTypes then
                for ft, yes in pairs(v:getFillUnitSupportedFillTypes(ix) or {}) do
                    if yes then add(ft) end
                end
            end
        end
    end
    return types
end

--- The loading stations a seeder / sprayer of the vehicle can be filled at
function Trips.refillStations(vehicle)
    local list, seen = {}, {}
    for _, ft in ipairs(Trips.refillTypes(vehicle)) do
        for _, st in ipairs(Trips.loadingStations(vehicle:getOwnerFarmId(), ft)) do
            if not seen[st] then seen[st] = true; list[#list + 1] = st end
        end
    end
    table.sort(list, function(a, b) return Trips.nameOf(a) < Trips.nameOf(b) end)
    return list
end

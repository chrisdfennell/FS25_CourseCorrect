-- CourseCorrect: the AI jobs of the helpers that don't work a course (see Helpers.lua): the unloader (its work on the
-- field, then on the game's roads to the station and tipping there, then back), the bale collector, the silo
-- compacter. One task drives with our strategy; the unloader adds the game's own drive and discharge tasks.

GuidanceHelperTask = {}
local Task_mt = {__index = GuidanceHelperTask}

function GuidanceHelperTask.new(isServer, job)
    return setmetatable({isServer = isServer, job = job, isFinished = false, isRunning = false, markAsFinished = false},
        Task_mt)
end

function GuidanceHelperTask:setVehicle(vehicle) self.vehicle = vehicle end
function GuidanceHelperTask:reset() self.isFinished = false end
function GuidanceHelperTask:validate() return true, nil end
function GuidanceHelperTask:getIsFinished() return self.isFinished end
function GuidanceHelperTask:delete() end
function GuidanceHelperTask:update(dt) end

function GuidanceHelperTask:skip()
    if self.isRunning then self.isFinished = true else self.markAsFinished = true end
end

function GuidanceHelperTask:start()
    self.isFinished = self.markAsFinished
    self.markAsFinished = false
    self.isRunning = true
    local vehicle = self.vehicle
    -- driven by our own loop (GuidanceVehicle:onUpdate), not the game's field work helper: a trailer or a bale
    -- loader isn't a field work implement
    if self.isServer then
        self.driver = self.job:makeDriver(vehicle)
        vehicle.spec_guidance.driver = self.driver
        vehicle.spec_guidance.helperDriver = self.driver
        vehicle:raiseActive()
    end
end

function GuidanceHelperTask:stop(wasJobStopped)
    if not self.isRunning then return end
    self.isRunning = false
    self.markAsFinished = false
    if self.vehicle ~= nil and self.isServer then
        if self.driver then self.driver:delete() end
        self.vehicle.spec_guidance.helperDriver = nil
        -- stand still
        if WheelsUtil and WheelsUtil.updateWheelsPhysics then
            pcall(WheelsUtil.updateWheelsPhysics, self.vehicle, 0, 0, 0, true, true)
        end
        if self.vehicle.stopVehicle then self.vehicle:stopVehicle() end
    end
    if self.vehicle ~= nil and self.vehicle.spec_guidance ~= nil then
        self.vehicle.spec_guidance.driver = nil
        if self.isServer and self.vehicle.guidanceSetHelperPhase
                and not GuidanceVehicle.END_PHASES[self.vehicle:getGuidanceHelperPhase() or ""] then
            -- on the road: the game drives
            self.vehicle:guidanceSetHelperPhase(self.job.kind == "unload" and not wasJobStopped and "unloadTrip" or nil)
        end
    end
    self.driver = nil
end

-----------------------------------------------------------------------------------------------------------------------

GuidanceHelperJob = {}
local Job_mt = Class(GuidanceHelperJob, AIJob)

GuidanceHelperJob.KINDS = {
    unload = {name = "GUIDANCE_UNLOAD", driver = function() return GuidanceUnloadDriver end},
    bales = {name = "GUIDANCE_BALES", driver = function() return GuidanceBaleDriver end},
    silo = {name = "GUIDANCE_SILO", driver = function() return GuidanceSiloDriver end},
    shovel = {name = "GUIDANCE_SHOVEL", driver = function() return GuidanceShovelDriver end},
}

function GuidanceHelperJob.new(isServer, customMt, kind)
    local self = AIJob.new(isServer, customMt or Job_mt)
    self.kind = kind
    self.name = GuidanceHelperJob.KINDS[kind].name
    self.vehicleParameter = AIParameterVehicle.new()
    self:addNamedParameter("vehicle", self.vehicleParameter)
    local group = AIParameterGroup.new(g_i18n:getText("ai_parameterGroupTitleVehicle"))
    group:addParameter(self.vehicleParameter)
    table.insert(self.groupedParameters, group)
    -- where it unloads (its place; 0, 0: stops when full), how full it goes
    self.unloadX, self.unloadZ, self.fullLevel, self.unloadMode = 0, 0, GuidanceUnloadDriver.LEAVE_LEVEL, 0
    if kind == "unload" and AITaskDriveTo ~= nil then
        self.driveToFieldTask = AITaskDriveTo.new(isServer, self)
        self:addTask(self.driveToFieldTask)
    end
    self.task = GuidanceHelperTask.new(isServer, self)
    self:addTask(self.task)
    if kind == "unload" and AITaskDriveTo ~= nil and AITaskDischarge ~= nil then
        -- the game's deliver logic works with these names
        self.waitForFillingTask = self.task
        self.driveToUnloadingTask = AITaskDriveTo.new(isServer, self)
        self.dischargeTask = AITaskDischarge.new(isServer, self)
        self:addTask(self.driveToUnloadingTask)
        self:addTask(self.dischargeTask)
        self.dischargeNodeInfos = {}
    end
    return self
end

-- one job class per kind, so the game can make each by its type
GuidanceUnloadJob = {}
local Unload_mt = Class(GuidanceUnloadJob, GuidanceHelperJob)
GuidanceUnloadJob.name = GuidanceHelperJob.KINDS.unload.name
function GuidanceUnloadJob.new(isServer, customMt) return GuidanceHelperJob.new(isServer, customMt or Unload_mt, "unload") end

GuidanceBaleJob = {}
local Bale_mt = Class(GuidanceBaleJob, GuidanceHelperJob)
GuidanceBaleJob.name = GuidanceHelperJob.KINDS.bales.name
function GuidanceBaleJob.new(isServer, customMt) return GuidanceHelperJob.new(isServer, customMt or Bale_mt, "bales") end

GuidanceSiloJob = {}
local Silo_mt = Class(GuidanceSiloJob, GuidanceHelperJob)
GuidanceSiloJob.name = GuidanceHelperJob.KINDS.silo.name
function GuidanceSiloJob.new(isServer, customMt) return GuidanceHelperJob.new(isServer, customMt or Silo_mt, "silo") end

GuidanceShovelJob = {}
local Shovel_mt = Class(GuidanceShovelJob, GuidanceHelperJob)
GuidanceShovelJob.name = GuidanceHelperJob.KINDS.shovel.name
function GuidanceShovelJob.new(isServer, customMt) return GuidanceHelperJob.new(isServer, customMt or Shovel_mt, "shovel") end

function GuidanceHelperJob:makeDriver(vehicle)
    return GuidanceHelperJob.KINDS[self.kind].driver().new(vehicle, self)
end

function GuidanceHelperJob:getVehicle()
    return self.vehicleParameter:getVehicle()
end

function GuidanceHelperJob:applyCurrentState(vehicle, mission, farmId, isDirectStart)
    AIJob.applyCurrentState(self, vehicle, mission, farmId, isDirectStart)
    self.vehicleParameter:setVehicle(vehicle)
end

function GuidanceHelperJob:setValues()
    self:resetTasks()
    local vehicle = self.vehicleParameter:getVehicle()
    for _, task in ipairs(self.tasks) do
        if task.setVehicle then task:setVehicle(vehicle) end
    end
    -- back to the field after a trip: where it started
    if vehicle and self.driveToFieldTask and self.homeX == nil then
        local x, z, h = GuidanceHelperDriver.poseOf(vehicle)
        self.homeX, self.homeZ, self.homeDx, self.homeDz = x, z, math.cos(h), math.sin(h)
    end
    if self.driveToFieldTask and self.homeX then
        self.driveToFieldTask:setTargetPosition(self.homeX, self.homeZ)
        self.driveToFieldTask:setTargetDirection(self.homeDx, self.homeDz)
    end
end

function GuidanceHelperJob:validate(farmId)
    local vehicle = self.vehicleParameter:getVehicle()
    if vehicle == nil then
        return false, g_i18n:getText("ai_validationErrorNoVehicle")
    end
    local ok, why = GuidanceHelperJob.canDo(vehicle, self.kind)
    if not ok then return false, why end
    return true, nil
end

--- Can the vehicle do this kind of job? true, or false and why
function GuidanceHelperJob.canDo(vehicle, kind)
    if kind == "unload" then
        for _, v in ipairs(vehicle.getChildVehicles and vehicle:getChildVehicles() or {}) do
            if v ~= vehicle and (v.spec_trailer or v.spec_pipe) and v.getFillUnits and #v:getFillUnits() > 0 then
                return true
            end
        end
        return false, g_i18n:getText("guidance_helper_noTrailer")
    elseif kind == "bales" then
        if GuidanceBaleDriver.findTool(vehicle) then return true end
        return false, g_i18n:getText("guidance_helper_noBaleTool")
    elseif kind == "silo" then
        local x, z = GuidanceHelperDriver.poseOf(vehicle)
        if GuidanceSiloDriver.findSilo(x, z) then return true end
        return false, g_i18n:getText("guidance_helper_noSilo")
    elseif kind == "shovel" then
        if GuidanceShovelDriver.findTools(vehicle) then return true end
        return false, g_i18n:getText("guidance_helper_noShovel")
    end
    return false, "?"
end

function GuidanceHelperJob:getIsAvailableForVehicle(vehicle)
    return GuidanceHelperJob.canDo(vehicle, self.kind) == true
end

function GuidanceHelperJob:getTitle()
    local vehicle = self.vehicleParameter:getVehicle()
    return vehicle and vehicle:getName() or ""
end

function GuidanceHelperJob:getIsStartable(connection)
    return GuidanceJob.getIsStartable(self, connection)
end

function GuidanceHelperJob.getIsStartErrorText(state)
    return GuidanceJob.getIsStartErrorText(state)
end

function GuidanceHelperJob:getIsLooping()
    return self.kind == "unload"
end

--- unload: (to the field) -> working at the combines -> to the station -> tipping -> to the field ...
function GuidanceHelperJob:getNextTaskIndex(isSkipTask)
    local cur = self.currentTaskIndex
    local task = self.task.taskIndex
    if cur == 0 then
        return task
    end
    if self.kind ~= "unload" or self.driveToUnloadingTask == nil then
        return #self.tasks + 1
    end
    if self.driveToFieldTask and cur == self.driveToFieldTask.taskIndex then
        return task
    end
    if cur == task or cur == self.dischargeTask.taskIndex then
        -- the game's deliver logic: the next tipping point and where to drive for it
        local ok, ix = pcall(AIJobDeliver.getNextTaskIndex, self, isSkipTask)
        if cur == task then
            if ok and ix == self.driveToUnloadingTask.taskIndex and self.driveToUnloadingTask.x ~= nil then
                return ix
            end
            Guidance.info("%s: no way to the unloading station", Guidance.vehicleName(self:getVehicle()))
            return #self.tasks + 1
        end
        if ok and ix == self.driveToUnloadingTask.taskIndex and self.driveToUnloadingTask.x ~= nil then
            return ix
        end
        -- all tipped: back to the field
        return self.driveToFieldTask and self.driveToFieldTask.taskIndex or task
    end
    return cur + 1
end

function GuidanceHelperJob:startTask(task)
    if task == self.driveToUnloadingTask then
        for _, info in ipairs(self.dischargeNodeInfos or {}) do info.dirty = true end
    end
    AIJob.startTask(self, task)
end

function GuidanceHelperJob:canContinueWork()
    if self.kind == "unload" and self.driveToUnloadingTask and (self.currentTaskIndex == self.driveToUnloadingTask.taskIndex
            or self.currentTaskIndex == self.dischargeTask.taskIndex) and self.unloadingStationParameter then
        local ok, can, message = pcall(AIJobDeliver.canContinueWork, self)
        if ok and can == false then return false, message end
    end
    return true, nil
end

--- The unloader is full at the field edge: to the station it was given (true), or nothing to do that (false)
function GuidanceHelperJob:startDeliveryTrip()
    local vehicle = self:getVehicle()
    if self.driveToUnloadingTask == nil or vehicle == nil or (self.unloadX or 0) == 0 then
        return false
    end
    local infos = GuidanceTrips.dischargeNodeInfos(vehicle)
    local fillType
    for _, info in ipairs(infos) do
        local ft = info.vehicle:getFillUnitFillType(info.dischargeNode.fillUnitIndex)
        if ft and ft ~= (FillType and FillType.UNKNOWN) then fillType = ft break end
    end
    local station = GuidanceTrips.find(GuidanceTrips.unloadingStations(vehicle:getOwnerFarmId(), fillType),
        self.unloadX, self.unloadZ)
    if station == nil or #infos == 0 then
        Guidance.info("%s: no unloading station for that here", Guidance.vehicleName(vehicle))
        return false
    end
    self.unloadingStationParameter = GuidanceTrips.stationParameter(station)
    self.dischargeNodeInfos = infos
    self.supportedFillTypes = station:getAISupportedFillTypes()
    self.driveToUnloadingTask:setVehicle(vehicle)
    self.dischargeTask:setVehicle(vehicle)
    self.driveToUnloadingTask:setTargetOffset(-infos[#infos].offsetZ)
    Guidance.info("%s: full, to %s", Guidance.vehicleName(vehicle), GuidanceTrips.nameOf(station))
    self.task:skip()
    return true
end

function GuidanceHelperJob:start(farmId)
    GuidanceJob.start(self, farmId)
end

function GuidanceHelperJob:stop(aiMessage)
    local vehicle = self.vehicleParameter:getVehicle()
    if not self.isServer or vehicle == nil then
        AIJob.stop(self, aiMessage)
        return
    end
    if self.task and self.task.isRunning then
        self.task:stop(true)
    end
    if not GuidanceVehicle.END_PHASES[vehicle:getGuidanceHelperPhase() or ""] then vehicle:guidanceSetHelperPhase(nil) end
    vehicle:deleteAgent()
    vehicle:aiJobFinished()
    AIJob.stop(self, aiMessage)
end

function GuidanceHelperJob:writeStream(streamId, connection)
    streamWriteBool(streamId, self.isDirectStart)
    if streamWriteBool(streamId, self.jobId ~= nil) then
        streamWriteInt32(streamId, self.jobId)
    end
    for _, namedParameter in ipairs(self.namedParameters) do
        namedParameter.parameter:writeStream(streamId, connection)
    end
    streamWriteUInt8(streamId, self.currentTaskIndex)
    streamWriteFloat32(streamId, self.unloadX or 0)
    streamWriteFloat32(streamId, self.unloadZ or 0)
    streamWriteUInt8(streamId, math.floor((self.fullLevel or 0.97) * 100 + 0.5))
    streamWriteUInt8(streamId, self.unloadMode or 0)
end

function GuidanceHelperJob:readStream(streamId, connection)
    self.isDirectStart = streamReadBool(streamId)
    if streamReadBool(streamId) then
        self.jobId = streamReadInt32(streamId)
    end
    for _, namedParameter in ipairs(self.namedParameters) do
        namedParameter.parameter:readStream(streamId, connection)
    end
    self.currentTaskIndex = streamReadUInt8(streamId)
    self.unloadX = streamReadFloat32(streamId)
    self.unloadZ = streamReadFloat32(streamId)
    self.fullLevel = streamReadUInt8(streamId) / 100
    self.unloadMode = streamReadUInt8(streamId)
    self:setValues()
end

function GuidanceHelperJob:saveToXMLFile(xmlFile, key, usedModNames)
    AIJob.saveToXMLFile(self, xmlFile, key, usedModNames)
    return true
end

function GuidanceHelperJob:loadFromXMLFile(xmlFile, key)
    AIJob.loadFromXMLFile(self, xmlFile, key)
end

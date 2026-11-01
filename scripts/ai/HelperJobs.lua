-- CourseCorrect: the AI jobs of the helpers that don't work a course (see Helpers.lua): the bale collector, the silo
-- compacter, the shovel. One task drives with our strategy. (The combine unloader is AutoDrive's: see
-- GuidanceAutoDrive.lua.)

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
        -- (its engine, if it was switched off while waiting, is the player's again)
        self.vehicle.spec_guidance.engineOff, self.vehicle.spec_guidance.idleTime = false, 0
        -- stand still
        if WheelsUtil and WheelsUtil.updateWheelsPhysics then
            Guidance.try(WheelsUtil.updateWheelsPhysics, self.vehicle, 0, 0, 0, true, true)
        end
        if self.vehicle.stopVehicle then self.vehicle:stopVehicle() end
    end
    if self.vehicle ~= nil and self.vehicle.spec_guidance ~= nil then
        self.vehicle.spec_guidance.driver = nil
        if self.isServer and self.vehicle.guidanceSetHelperPhase
                and not GuidanceVehicle.END_PHASES[self.vehicle:getGuidanceHelperPhase() or ""] then
            self.vehicle:guidanceSetHelperPhase(nil)
        end
    end
    self.driver = nil
end

-----------------------------------------------------------------------------------------------------------------------

GuidanceHelperJob = {}
local Job_mt = Class(GuidanceHelperJob, AIJob)

GuidanceHelperJob.KINDS = {
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
    self.task = GuidanceHelperTask.new(isServer, self)
    self:addTask(self.task)
    return self
end

-- one job class per kind, so the game can make each by its type
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
    if kind == "bales" then
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

function GuidanceHelperJob:getNextTaskIndex(isSkipTask)
    if self.currentTaskIndex == 0 then
        return self.task.taskIndex
    end
    return #self.tasks + 1
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
    self:setValues()
end

function GuidanceHelperJob:saveToXMLFile(xmlFile, key, usedModNames)
    AIJob.saveToXMLFile(self, xmlFile, key, usedModNames)
    return true
end

function GuidanceHelperJob:loadFromXMLFile(xmlFile, key)
    AIJob.loadFromXMLFile(self, xmlFile, key)
end

-- Guidance: the AI job (a hired helper working the vehicle's course) and its single task.

GuidanceFieldworkTask = {}
local Task_mt = {__index = GuidanceFieldworkTask}

function GuidanceFieldworkTask.new(isServer, job)
    local self = setmetatable({}, Task_mt)
    self.isServer = isServer
    self.job = job
    self.isFinished = false
    self.isRunning = false
    self.markAsFinished = false
    return self
end

function GuidanceFieldworkTask:setVehicle(vehicle)
    self.vehicle = vehicle
end

function GuidanceFieldworkTask:reset()
    self.isFinished = false
    self.vehicle = nil
end

function GuidanceFieldworkTask:validate(ignoreUnsetParameters)
    return true, nil
end

function GuidanceFieldworkTask:getIsFinished()
    return self.isFinished
end

function GuidanceFieldworkTask:skip()
    if self.isRunning then
        self.isFinished = true
    else
        self.markAsFinished = true
    end
end

function GuidanceFieldworkTask:delete()
end

function GuidanceFieldworkTask:update(dt)
end

function GuidanceFieldworkTask:start()
    self.isFinished = self.markAsFinished
    self.markAsFinished = false
    self.isRunning = true
    local vehicle = self.vehicle
    local spec = vehicle.spec_aiFieldWorker
    spec.isActive = true
    if self.isServer then
        vehicle:updateAIFieldWorkerImplementData()
        vehicle:raiseAIEvent("onAIFieldWorkerStart", "onAIImplementStart")
        if vehicle:getAINeedsTrafficCollisionBox() and AIFieldWorker.TRAFFIC_COLLISION ~= nil
                and AIFieldWorker.TRAFFIC_COLLISION ~= 0 and spec.aiTrafficCollision == nil then
            spec.aiTrafficCollision = clone(AIFieldWorker.TRAFFIC_COLLISION, true, false, true)
        end
        if spec.driveStrategies ~= nil then
            for i = #spec.driveStrategies, 1, -1 do
                spec.driveStrategies[i]:delete()
            end
        end
        local course = vehicle:getGuidanceCourse()
        if course == nil then
            vehicle:stopCurrentAIJob(AIMessageGuidanceNoCourse.new())
            return
        end
        local startIx, startPoint = self.job.startIx, self.job.startPoint
        if not self.job.startIxSet then
            startIx, startPoint = vehicle:guidanceGetStart()
        end
        if startIx == nil or startIx < 1 then
            startIx = 1
        end
        vehicle.spec_guidance.paused = false
        -- back from a refill trip: on where it stopped
        if self.job.resumeAfterTrip then
            startIx, startPoint = course:getResumeIx(vehicle.spec_guidance.progressIx), nil
            self.job.resumeAfterTrip = false
        end
        self.driver = GuidanceFieldworkDriver.new(vehicle, course, startIx, startPoint)
        self.driver.task = self
        spec.driveStrategies = {self.driver}
        -- AutoDrive's unloaders ask the vehicle about it
        vehicle.spec_guidance.driver = self.driver
    else
        vehicle:raiseAIEvent("onAIFieldWorkerStart", "onAIImplementStart")
    end
end

function GuidanceFieldworkTask:stop(wasJobStopped)
    -- (stopped once: by the job, or by the game stopping the job's tasks)
    if not self.isRunning then
        return
    end
    self.isRunning = false
    self.markAsFinished = false
    if self.vehicle ~= nil and self.isServer then
        self.vehicle:stopFieldWorker()
    end
    if self.vehicle ~= nil and self.vehicle.spec_guidance ~= nil then
        local driver = self.vehicle.spec_guidance.driver
        if driver and self.isServer then
            driver:restoreLights()
            -- the work log: what this job did
            local st = driver.stats
            if st and st.seconds > 30 and GuidanceLibrary.addStat then
                local plan = self.vehicle.spec_guidance.plan
                GuidanceLibrary.addStat({fieldId = plan and plan.fieldId or 0, vehicle = Guidance.vehicleName(self.vehicle),
                                         farmId = self.vehicle:getOwnerFarmId(), area = st.area, seconds = st.seconds,
                                         fuel = st.fuel, day = GuidanceLibrary.today()})
            end
        end
        -- next free row: what it had taken but not done is free for the others
        local plan = self.vehicle.spec_guidance.plan
        if plan and GuidanceTeam then
            GuidanceTeam.release(plan.fieldId, self.vehicle)
        end
        self.vehicle.spec_guidance.driver = nil
        if self.vehicle.spec_guidance.paused then
            self.vehicle.spec_guidance.paused = false
            self.vehicle:raiseDirtyFlags(self.vehicle.spec_guidance.dirtyFlag)
        end
    end
    self.driver = nil
end

-----------------------------------------------------------------------------------------------------------------------

GuidanceJob = {}
local GuidanceJob_mt = Class(GuidanceJob, AIJob)
GuidanceJob.name = "GUIDANCE_FIELDWORK"

-- which vehicle event tells AutoDrive why we stopped (see AutoDrive's ExternalInterface)
GuidanceJob.STOP_EVENTS = {
    {AIMessageSuccessFinishedJob, "onCpFinished"},
    {AIMessageGuidanceIsFull, "onCpFull"},
    {AIMessageErrorOutOfFill, "onCpEmpty"},
    {AIMessageErrorOutOfFuel, "onCpFuelEmpty"},
    {AIMessageErrorVehicleBroken, "onCpBroken"},
}

function GuidanceJob.new(isServer, customMt)
    local self = AIJob.new(isServer, customMt or GuidanceJob_mt)
    self.name = GuidanceJob.name
    self.startIx = 1
    -- refill trips: the loading station's place (0, 0: none)
    self.refillX, self.refillZ = 0, 0
    -- false: nobody said where (the game started it): "start at" decides when it starts
    self.startIxSet = false
    self.vehicleParameter = AIParameterVehicle.new()
    self:addNamedParameter("vehicle", self.vehicleParameter)
    local group = AIParameterGroup.new(g_i18n:getText("ai_parameterGroupTitleVehicle"))
    group:addParameter(self.vehicleParameter)
    table.insert(self.groupedParameters, group)
    self.task = GuidanceFieldworkTask.new(isServer, self)
    self:addTask(self.task)
    -- a refill trip on the game's roads: there, filling, back (only when the course's plan names a station)
    if AITaskDriveTo ~= nil then
        self.driveToRefillTask = AITaskDriveTo.new(isServer, self)
        self.fillTask = GuidanceFillTask.new(isServer, self)
        self.driveBackTask = AITaskDriveTo.new(isServer, self)
        self:addTask(self.driveToRefillTask)
        self:addTask(self.fillTask)
        self:addTask(self.driveBackTask)
    end
    return self
end

--- The field work, then (when it went for a refill) the trip, then the field work again
function GuidanceJob:getIsLooping()
    return true
end

function GuidanceJob:getNextTaskIndex(isSkipTask)
    if self.currentTaskIndex == 0 then
        return self.task.taskIndex or 1
    end
    if self.currentTaskIndex == (self.task.taskIndex or 1) and not self.refillStation then
        -- the field work ended without a trip: done
        return #self.tasks + 1
    end
    if self.driveBackTask and self.currentTaskIndex == self.driveBackTask.taskIndex then
        self.refillStation = nil
        self.resumeAfterTrip = true
        return self.task.taskIndex or 1
    end
    return self.currentTaskIndex + 1
end

--- The field work ran empty: to the plan's refill station, if there is one with what it needs. Called by the
--- driver; true when the trip starts (the field work task ends).
function GuidanceJob:startRefillTrip(driver, fillTypes)
    local vehicle = self:getVehicle()
    if self.driveToRefillTask == nil or vehicle == nil or (self.refillX or 0) == 0 then
        return false
    end
    local station
    for _, ft in ipairs(fillTypes) do
        station = GuidanceTrips.find(GuidanceTrips.loadingStations(vehicle:getOwnerFarmId(), ft), self.refillX, self.refillZ)
        if station then break end
    end
    if station == nil then
        return false
    end
    local tx, tz, dx, dz = GuidanceTrips.targetOf(station)
    self.refillStation, self.refillFillTypes = station, fillTypes
    self.driveToRefillTask:setVehicle(vehicle)
    self.driveToRefillTask:setTargetPosition(tx, tz)
    self.driveToRefillTask:setTargetDirection(dx, dz)
    self.fillTask:setVehicle(vehicle)
    -- back to where it stopped, facing the same way
    local node = vehicle:getAIDirectionNode()
    local x, _, z = getWorldTranslation(node)
    local hx, _, hz = localDirectionToWorld(node, 0, 0, 1)
    self.driveBackTask:setVehicle(vehicle)
    self.driveBackTask:setTargetPosition(x, z)
    self.driveBackTask:setTargetDirection(hx, hz)
    Guidance.info("%s: empty, refilling at %s", Guidance.vehicleName(vehicle), GuidanceTrips.nameOf(station))
    vehicle:guidanceSetInfoText("NEEDS_FILLING", true)
    self.task:skip()
    return true
end

function GuidanceJob:getVehicle()
    return self.vehicleParameter:getVehicle()
end

--- Start at waypoint ix, or (startPoint {x, z}) at that point on the way to waypoint ix
function GuidanceJob:setStartIx(ix, startPoint)
    self.startIx = ix or 1
    self.startPoint = startPoint
    self.startIxSet = true
end

function GuidanceJob:applyCurrentState(vehicle, mission, farmId, isDirectStart)
    AIJob.applyCurrentState(self, vehicle, mission, farmId, isDirectStart)
    self.vehicleParameter:setVehicle(vehicle)
end

function GuidanceJob:setValues()
    self:resetTasks()
    self.task:setVehicle(self.vehicleParameter:getVehicle())
end

function GuidanceJob:validate(farmId)
    local vehicle = self.vehicleParameter:getVehicle()
    if vehicle == nil then
        return false, g_i18n:getText("ai_validationErrorNoVehicle")
    end
    if vehicle.getGuidanceCourse == nil or vehicle:getGuidanceCourse() == nil then
        return false, g_i18n:getText("guidance_msg_noCourse")
    end
    return true, nil
end

function GuidanceJob:getIsAvailableForVehicle(vehicle)
    return vehicle.getGuidanceCourse ~= nil and vehicle:getGuidanceCourse() ~= nil
end

function GuidanceJob:getTitle()
    local vehicle = self.vehicleParameter:getVehicle()
    return vehicle and vehicle:getName() or ""
end

function GuidanceJob:getIsStartable(connection)
    local vehicle = self.vehicleParameter:getVehicle()
    if vehicle == nil then
        return false, AIJobFieldWork.START_ERROR_VEHICLE_DELETED
    end
    if not g_currentMission:getHasPlayerPermission("hireAssistant", connection, vehicle:getOwnerFarmId()) then
        return false, AIJobFieldWork.START_ERROR_NO_PERMISSION
    end
    if vehicle:getIsInUse(connection) then
        return false, AIJobFieldWork.START_ERROR_VEHICLE_IN_USE
    end
    return true, AIJob.START_SUCCESS
end

function GuidanceJob.getIsStartErrorText(state)
    if state == AIJobFieldWork.START_ERROR_LIMIT_REACHED then
        return g_i18n:getText("ai_startStateLimitReached")
    elseif state == AIJobFieldWork.START_ERROR_VEHICLE_DELETED then
        return g_i18n:getText("ai_startStateVehicleDeleted")
    elseif state == AIJobFieldWork.START_ERROR_NO_PERMISSION then
        return g_i18n:getText("ai_startStateNoPermission")
    elseif state == AIJobFieldWork.START_ERROR_VEHICLE_IN_USE then
        return g_i18n:getText("ai_startStateVehicleInUse")
    end
    return g_i18n:getText("ai_startStateSuccess")
end

function GuidanceJob:start(farmId)
    if #g_helperManager.availableHelpers > 0 then
        self.helperIndex = g_helperManager:getRandomHelper().index
    else
        self.helperIndex = g_helperManager:getRandomIndex()
    end
    self.startedFarmId = farmId
    self.isRunning = true
    if self.isServer then
        self.currentTaskIndex = 0
        local vehicle = self.vehicleParameter:getVehicle()
        vehicle:guidanceClearInfoTexts()
        -- what the job was given is kept with the tractor (and its savegame) on the server too
        local spec = vehicle.spec_guidance
        if spec and spec.settings and self.refillX ~= nil then
            spec.settings.refillX, spec.settings.refillZ = self.refillX, self.refillZ
            if spec.plan then spec.plan.refillX, spec.plan.refillZ = self.refillX, self.refillZ end
        end
        if spec and spec.settings and self.unloadX ~= nil then
            spec.settings.unloadX, spec.settings.unloadZ = self.unloadX, self.unloadZ
            spec.settings.unloadFull = math.floor((self.fullLevel or 0.97) * 100 + 0.5)
        end
        vehicle:createAgent(self.helperIndex)
        vehicle:aiJobStarted(self, self.helperIndex, farmId)
    end
end

function GuidanceJob:stop(aiMessage)
    local vehicle = self.vehicleParameter:getVehicle()
    if not self.isServer or vehicle == nil then
        AIJob.stop(self, aiMessage)
        return
    end
    -- our task ends with the job: lights back, the work log entry, rows given back (whether the game stops it too)
    if self.task and self.task.isRunning then
        self.task:stop(true)
    end
    vehicle:deleteAgent()
    vehicle:aiJobFinished()
    AIJob.stop(self, aiMessage)
    -- the game sometimes leaves this set on clients
    if vehicle.spec_aiFieldWorker.isActive then
        vehicle.spec_aiFieldWorker.isActive = false
    end
    -- tell AutoDrive (and anyone else listening) why we stopped
    if aiMessage ~= nil and Guidance.providesAutoDriveInterface() then
        for _, entry in ipairs(GuidanceJob.STOP_EVENTS) do
            if aiMessage.isa and aiMessage:isa(entry[1]) then
                Guidance.debug("%s: stopped, raising %s", Guidance.vehicleName(vehicle), entry[2])
                SpecializationUtil.raiseEvent(vehicle, entry[2])
                break
            end
        end
    end
end

function GuidanceJob:writeStream(streamId, connection)
    streamWriteBool(streamId, self.isDirectStart)
    if streamWriteBool(streamId, self.jobId ~= nil) then
        streamWriteInt32(streamId, self.jobId)
    end
    for _, namedParameter in ipairs(self.namedParameters) do
        namedParameter.parameter:writeStream(streamId, connection)
    end
    streamWriteUInt8(streamId, self.currentTaskIndex)
    streamWriteInt32(streamId, self.startIx or 1)
    streamWriteFloat32(streamId, self.refillX or 0)
    streamWriteFloat32(streamId, self.refillZ or 0)
    streamWriteBool(streamId, self.startIxSet == true)
    if streamWriteBool(streamId, self.startPoint ~= nil) then
        streamWriteFloat32(streamId, self.startPoint.x)
        streamWriteFloat32(streamId, self.startPoint.z)
    end
end

function GuidanceJob:readStream(streamId, connection)
    self.isDirectStart = streamReadBool(streamId)
    if streamReadBool(streamId) then
        self.jobId = streamReadInt32(streamId)
    end
    for _, namedParameter in ipairs(self.namedParameters) do
        namedParameter.parameter:readStream(streamId, connection)
    end
    self.currentTaskIndex = streamReadUInt8(streamId)
    self.startIx = streamReadInt32(streamId)
    self.refillX = streamReadFloat32(streamId)
    self.refillZ = streamReadFloat32(streamId)
    self.startIxSet = streamReadBool(streamId)
    self.startPoint = nil
    if streamReadBool(streamId) then
        self.startPoint = {x = streamReadFloat32(streamId), z = streamReadFloat32(streamId)}
    end
    self:setValues()
end

function GuidanceJob:saveToXMLFile(xmlFile, key, usedModNames)
    AIJob.saveToXMLFile(self, xmlFile, key, usedModNames)
    return true
end

function GuidanceJob:loadFromXMLFile(xmlFile, key)
    AIJob.loadFromXMLFile(self, xmlFile, key)
end

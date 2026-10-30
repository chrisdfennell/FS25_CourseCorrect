-- Guidance: vehicle specialization. Holds the course plan of the vehicle, saves it, sends it to other players,
-- starts and stops the helper, and offers AutoDrive the interface it knows from Courseplay.

GuidanceVehicle = {}
GuidanceVehicle.MOD_NAME = g_currentModName
GuidanceVehicle.SPEC = "spec_" .. g_currentModName .. ".guidance"
GuidanceVehicle.SAVE_KEY = "vehicles.vehicle(?)." .. g_currentModName .. ".guidance"
-- where the mod kept it under its old name (Guidance, before 0.5): read once
GuidanceVehicle.OLD_SAVE_KEY = "vehicles.vehicle(?).FS25_Guidance.guidance"

-- status texts; the names are the ones AutoDrive's ticker knows from Courseplay
-- (sent as bits: only add at the end)
GuidanceVehicle.INFO_TEXTS = {"NEEDS_UNLOADING", "NEEDS_FILLING", "FUEL_IS_LOW", "FUEL_IS_EMPTY", "IS_STUCK", "FINISHED",
                              "NEXT_FIELD_WAITING", "GIVING_WAY"}

-- the next field of the queue: closer than this the helper drives there itself, else AutoDrive takes it
GuidanceVehicle.QUEUE_NEAR = 150
GuidanceVehicle.QUEUE_MARKER_RANGE = 250 -- m from the course start an AutoDrive marker may be

function GuidanceVehicle.prerequisitesPresent(specializations)
    return SpecializationUtil.hasSpecialization(AIFieldWorker, specializations)
end

function GuidanceVehicle.initSpecialization()
    local schema = Vehicle.xmlSchemaSavegame
    GuidancePlan.registerXMLPaths(schema, GuidanceVehicle.SAVE_KEY .. ".plan")
    GuidancePlan.registerXMLPaths(schema, GuidanceVehicle.SAVE_KEY .. ".settings")
    schema:register(XMLValueType.INT, GuidanceVehicle.SAVE_KEY .. "#progressIx", "Guidance: course waypoint to continue at")
    schema:register(XMLValueType.BOOL, GuidanceVehicle.SAVE_KEY .. "#active", "Guidance: the helper was working when saved")
    schema:register(XMLValueType.STRING, GuidanceVehicle.SAVE_KEY .. "#queue", "Guidance: saved courses to work next (ids)")
    if GuidanceVehicle.OLD_SAVE_KEY ~= GuidanceVehicle.SAVE_KEY then
        local old = GuidanceVehicle.OLD_SAVE_KEY
        GuidancePlan.registerXMLPaths(schema, old .. ".plan")
        GuidancePlan.registerXMLPaths(schema, old .. ".settings")
        schema:register(XMLValueType.INT, old .. "#progressIx", "Guidance (old name): course waypoint to continue at")
        schema:register(XMLValueType.BOOL, old .. "#active", "Guidance (old name): the helper was working when saved")
        schema:register(XMLValueType.STRING, old .. "#queue", "Guidance (old name): saved courses to work next")
    end
end

function GuidanceVehicle.registerEvents(vehicleType)
    if Guidance.providesAutoDriveInterface() then
        for _, name in ipairs({"onCpFinished", "onCpEmpty", "onCpFull", "onCpFuelEmpty", "onCpBroken"}) do
            SpecializationUtil.registerEvent(vehicleType, name)
        end
    end
end

function GuidanceVehicle.registerFunctions(vehicleType)
    local f = function(name, fn) SpecializationUtil.registerFunction(vehicleType, name, fn) end
    f("getGuidanceCourse", GuidanceVehicle.getGuidanceCourse)
    f("getGuidanceToolChange", GuidanceVehicle.getGuidanceToolChange)
    f("getGuidanceHelperKind", GuidanceVehicle.getGuidanceHelperKind)
    f("getGuidanceHelperKinds", GuidanceVehicle.getGuidanceHelperKinds)
    f("guidanceStartHelper", GuidanceVehicle.guidanceStartHelper)
    f("guidanceSetHelperPhase", GuidanceVehicle.guidanceSetHelperPhase)
    f("getGuidanceHelperPhase", GuidanceVehicle.getGuidanceHelperPhase)
    f("getGuidancePlan", GuidanceVehicle.getGuidancePlan)
    f("getGuidanceSettings", GuidanceVehicle.getGuidanceSettings)
    f("getGuidanceError", GuidanceVehicle.getGuidanceError)
    f("getGuidanceProgress", GuidanceVehicle.getGuidanceProgress)
    f("guidanceSetPlan", GuidanceVehicle.guidanceSetPlan)
    f("guidanceGenerate", GuidanceVehicle.guidanceGenerate)
    f("guidanceChangeSetting", GuidanceVehicle.guidanceChangeSetting)
    f("guidanceApplySettings", GuidanceVehicle.guidanceApplySettings)
    f("guidanceStart", GuidanceVehicle.guidanceStart)
    f("guidanceStop", GuidanceVehicle.guidanceStop)
    f("guidanceStartStop", GuidanceVehicle.guidanceStartStop)
    f("getIsGuidanceActive", GuidanceVehicle.getIsGuidanceActive)
    f("getIsHelperDriving", GuidanceVehicle.getIsHelperDriving)
    f("guidanceSetTeamProgress", GuidanceVehicle.guidanceSetTeamProgress)
    f("guidanceStopHelper", GuidanceVehicle.guidanceStopHelper)
    f("guidanceProgressChanged", GuidanceVehicle.guidanceProgressChanged)
    f("guidanceSetInfoText", GuidanceVehicle.guidanceSetInfoText)
    f("guidanceClearInfoTexts", GuidanceVehicle.guidanceClearInfoTexts)
    f("getGuidanceInfoTexts", GuidanceVehicle.getGuidanceInfoTexts)
    f("guidanceSetPaused", GuidanceVehicle.guidanceSetPaused)
    f("getIsGuidancePaused", GuidanceVehicle.getIsGuidancePaused)
    f("guidanceGetStart", GuidanceVehicle.guidanceGetStart)
    f("getGuidanceQueue", GuidanceVehicle.getGuidanceQueue)
    f("getGuidanceWorkSpeed", GuidanceVehicle.getGuidanceWorkSpeed)
    f("getGuidanceTimes", GuidanceVehicle.getGuidanceTimes)
    f("guidanceSetQueue", GuidanceVehicle.guidanceSetQueue)
    if Guidance.providesAutoDriveInterface() then
        -- what AutoDrive calls to hand a vehicle over to Courseplay and back
        f("cpStartStopDriver", GuidanceVehicle.cpStartStopDriver)
        f("startCpAtFirstWp", GuidanceVehicle.startCpAtFirstWp)
        f("startCpAtLastWp", GuidanceVehicle.startCpAtLastWp)
        f("getIsCpActive", GuidanceVehicle.getIsGuidanceActive)
        f("getCanStartCp", GuidanceVehicle.getCanStartCp)
        f("getCpActiveInfoTexts", GuidanceVehicle.getCpActiveInfoTexts)
        -- what AutoDrive's unloaders ask a harvester
        f("getIsCpHarvesterWaitingForUnload", GuidanceVehicle.getIsCpHarvesterWaitingForUnload)
        f("getIsCpHarvesterWaitingForUnloadInPocket", GuidanceVehicle.getIsCpHarvesterWaitingForUnloadInPocket)
        f("getIsCpHarvesterWaitingForUnloadAfterPulledBack", GuidanceVehicle.getIsCpHarvesterWaitingForUnloadInPocket)
        f("getIsCpHarvesterManeuvering", GuidanceVehicle.getIsCpHarvesterManeuvering)
        f("holdCpHarvesterTemporarily", GuidanceVehicle.holdCpHarvesterTemporarily)
    end
end

function GuidanceVehicle.registerEventListeners(vehicleType)
    for _, name in ipairs({"onLoad", "onPostLoad", "onDelete", "onReadStream", "onWriteStream", "onReadUpdateStream",
                           "onWriteUpdateStream", "onRegisterActionEvents", "onUpdate", "onUpdateTick", "onDraw"}) do
        SpecializationUtil.registerEventListener(vehicleType, name, GuidanceVehicle)
    end
end

local function getSpec(vehicle)
    return vehicle[GuidanceVehicle.SPEC]
end

function GuidanceVehicle:onLoad(savegame)
    local spec = getSpec(self)
    self.spec_guidance = spec
    -- the shop's preview vehicles get the specialization too, they must not do anything
    spec.isShopPreview = self.propertyState == VehiclePropertyState.SHOP_CONFIG
    spec.settings = GuidancePlan.new()
    spec.plan = nil
    spec.course = nil
    spec.error = nil
    spec.progressIx = 1
    spec.infoTexts = {}
    spec.actionEvents = {}
    spec.dirtyFlag = self:getNextDirtyFlag()
    -- saved courses (library ids) to work after this one, and where we are with going to the next
    spec.queue = {}
    spec.queueState = nil
end

function GuidanceVehicle:onPostLoad(savegame)
    local spec = getSpec(self)
    if spec.isShopPreview or savegame == nil or savegame.resetVehicles then
        return
    end
    local key = savegame.key .. "." .. GuidanceVehicle.MOD_NAME .. ".guidance"
    -- saved by the mod under its old name (Guidance): taken over once
    if not savegame.xmlFile:hasProperty(key) and savegame.xmlFile:hasProperty(savegame.key .. ".FS25_Guidance.guidance") then
        key = savegame.key .. ".FS25_Guidance.guidance"
    end
    local settings = GuidancePlan.loadFromXMLFile(savegame.xmlFile, key .. ".settings")
    if settings then
        -- saved before automatic headlands were 40 m: the old 30 m default becomes the new one (a course being
        -- worked keeps its own)
        if savegame.xmlFile:getValue(key .. ".settings#headlandRev") == nil and settings.minHeadlandWidth == 30 then
            settings.minHeadlandWidth = GuidancePlan.MIN_HEADLAND_DEFAULT
        end
        spec.settings = settings
    end
    local plan = GuidancePlan.loadFromXMLFile(savegame.xmlFile, key .. ".plan")
    if plan then
        self:guidanceSetPlan(plan, true)
        spec.progressIx = savegame.xmlFile:getValue(key .. "#progressIx", 1)
        -- working when saved: start again a little after loading (if the player wants that), where it was
        if self.isServer and savegame.xmlFile:getValue(key .. "#active", false) and plan.autoResume ~= false then
            spec.resumeAfterLoad = 0
            self:raiseActive()
        end
    end
    -- saved while a helper worked: the game sets its helper flag again, without a helper. Clear it soon after.
    if self.isServer and self.spec_aiFieldWorker and self.spec_aiFieldWorker.isActive then
        spec.staleHelperTime = 0
        self:raiseActive()
    end
    local queue = savegame.xmlFile:getValue(key .. "#queue")
    if queue then
        for id in string.gmatch(queue, "-?%d+") do table.insert(spec.queue, tonumber(id)) end
    end
end

function GuidanceVehicle:saveToXMLFile(xmlFile, key, usedModNames)
    local spec = getSpec(self)
    spec.settings:saveToXMLFile(xmlFile, key .. ".settings")
    if spec.plan then
        spec.plan:saveToXMLFile(xmlFile, key .. ".plan")
        xmlFile:setValue(key .. "#progressIx", spec.progressIx or 1)
        xmlFile:setValue(key .. "#active", self:getIsGuidanceActive())
    end
    if #spec.queue > 0 then
        xmlFile:setValue(key .. "#queue", table.concat(spec.queue, " "))
    end
end

function GuidanceVehicle:onDelete()
    if Guidance.hud then
        Guidance.hud:onVehicleDeleted(self)
    end
end

-----------------------------------------------------------------------------------------------------------------------
-- Course
-----------------------------------------------------------------------------------------------------------------------

function GuidanceVehicle:getGuidanceCourse()
    return getSpec(self).course
end

function GuidanceVehicle:getGuidancePlan()
    return getSpec(self).plan
end

--- The settings new courses are made with (also the ones the HUD shows)
function GuidanceVehicle:getGuidanceSettings()
    return getSpec(self).settings
end

--- Why the last course could not be made, or nil
function GuidanceVehicle:getGuidanceError()
    return getSpec(self).error
end

--- Waypoint index the helper is at, and the fraction of the course done
function GuidanceVehicle:getGuidanceProgress()
    local spec = getSpec(self)
    if spec.course == nil then
        return 1, 0
    end
    if (spec.teamTotal or 0) > 0 and spec.plan and spec.plan.teamMode == GuidancePlan.TEAM_NEXT_ROW then
        return spec.progressIx or 1, spec.teamDone / spec.teamTotal
    end
    local wp = spec.course:getWaypoint(spec.progressIx or 1)
    return spec.progressIx or 1, wp and spec.course.length > 0 and wp.d / spec.course.length or 0
end

--- Sets (or with nil clears) the course plan, makes the course, tells the other players
function GuidanceVehicle:guidanceSetPlan(plan, noEventSend)
    local spec = getSpec(self)
    spec.plan = plan
    spec.course = nil
    spec.error = nil
    spec.progressIx = 1
    if plan then
        spec.settings = plan:copy()
        local course, err = GuidanceCourse.generate(plan)
        spec.course = course
        spec.error = err
        if course == nil then
            Guidance.info("%s: no course for field %d: %s", Guidance.vehicleName(self), plan.fieldId, tostring(err))
        end
    end
    if not noEventSend then
        GuidanceCourseEvent.sendEvent(self, plan)
    end
end

--- Makes a course for the field the vehicle is on, with the vehicle's settings. Returns false, error text when
--- that is not possible.
-- what each member of a team keeps of its own (the rest, the layout, is the team's)
GuidanceVehicle.MEMBER_KEYS = {"keepLowered", "lowerLate", "raiseLate", "toolOffsetX", "callUnloaderAt", "startMode"}

function GuidanceVehicle:guidanceGenerate(team)
    local spec = getSpec(self)
    local x, _, z = getWorldTranslation(self.rootNode)
    if team then
        -- a member of a team (see GuidanceTeam.makeCourses): the team's layout, its own place in it
        local plan = team.base:copy()
        for _, k in ipairs(GuidanceVehicle.MEMBER_KEYS) do plan[k] = spec.settings[k] end
        plan.teamMode, plan.teamSize, plan.teamIndex = team.mode, team.size, team.index
        plan.autoWidth, plan.autoRadius = false, false
        -- its own pipe (lands: the worked ground on that side)
        plan.landsSide = spec.settings.landsSide or 0
        plan.landsPipe = GuidanceVehicle.pipeSide(self)
        plan.toolSig = GuidanceVehicle.toolSignature(self)
        plan.fieldId = team.fieldId
        plan.startX, plan.startZ = team.startX or x, team.startZ or z
        spec.settings.teamMode, spec.settings.teamSize, spec.settings.teamIndex = team.mode, team.size, team.index
        self:guidanceSetPlan(plan)
        if spec.course == nil then
            return false, spec.error
        end
        return true
    end
    -- the field: as it is on the ground (painted field ground) when that is not the map's outline
    local fieldId, err, scanned = GuidanceCourse.fieldForCourse(x, z, self:getOwnerFarmId())
    if fieldId == false then
        -- a field read from the ground went to the server: the course is made when it is back
        spec.waitField, spec.waitFieldTime = err, 0
        self:raiseActive()
        return true, nil, string.format(g_i18n:getText("guidance_scan_reading"), err.name)
    end
    if fieldId == nil then
        return false, err
    end
    local plan = spec.settings:copy()
    local info = GuidanceVehicleInfo.get(self)
    if plan.autoWidth then plan.workWidth = info.workWidth end
    if plan.autoRadius then plan.turnRadius = info.turnRadius end
    plan.runOut = info.runOut
    plan.allowReverse = info.canReverse
    plan.towLength = info.towLength
    -- the field's own settings win over the tractor's
    local fieldValues = GuidanceLibrary.fieldSettings[fieldId]
    if fieldValues then
        for name, value in pairs(fieldValues) do
            plan[name] = value
            spec.settings[name] = value
        end
    end
    -- an implement working to one side (a mower) goes round the field with that side to the edge, so the
    -- tractor stays on the field. Seen from above, driving clockwise the edge is on the left.
    local sideOffset = info.sideOffset - (plan.toolOffsetX or 0)
    if math.abs(sideOffset) > 1 then
        plan.clockwise = sideOffset > 0
        spec.settings.clockwise = plan.clockwise
    end
    -- the editor's rows left out and areas worked round belong to the field they were made on
    if spec.plan == nil or spec.plan.fieldId ~= fieldId then
        plan.skipRows, plan.skipZones = "", ""
        spec.settings.skipRows, spec.settings.skipZones = "", ""
    end
    plan.fieldId = fieldId
    plan.startX, plan.startZ = x, z
    plan.landsPipe = GuidanceVehicle.pipeSide(self)
    plan.toolSig = GuidanceVehicle.toolSignature(self)
    GuidanceVehicle.applyTramlines(self, plan)
    self:guidanceSetPlan(plan)
    if spec.course == nil then
        return false, spec.error
    end
    if scanned then
        return true, nil, string.format(g_i18n:getText("guidance_scan_done"), scanned.name,
            GuidanceFieldScan.areaOf(scanned.outline) / 10000)
    end
    return true
end

--- The implements attached now: their names, sorted ("" none)
function GuidanceVehicle.toolSignature(self)
    local names = {}
    for _, v in ipairs(self.getChildVehicles and self:getChildVehicles() or {}) do
        if v ~= self then names[#names + 1] = Guidance.vehicleName(v) end
    end
    table.sort(names)
    return table.concat(names, " + ")
end

--- The course was made with other implements than are attached now: what it was made with and what is there now,
--- else nil
function GuidanceVehicle:getGuidanceToolChange()
    local spec = getSpec(self)
    local plan = spec.plan
    if plan == nil or (plan.toolSig or "") == "" or spec.course == nil then
        return nil
    end
    local now = GuidanceVehicle.toolSignature(self)
    if now ~= plan.toolSig then
        return plan.toolSig, now
    end
    return nil
end

--- The side of a harvester's pipe (GuidancePlan.SIDE_LEFT / SIDE_RIGHT; left when it can't be told), 0 for other
--- vehicles
function GuidanceVehicle.pipeSide(self)
    local harvester = GuidanceFieldworkDriver and GuidanceFieldworkDriver.findHarvester(self)
    if harvester == nil then
        return GuidancePlan.SIDE_AUTO
    end
    local x
    if harvester.getCurrentDischargeNode then
        local ok, node = pcall(harvester.getCurrentDischargeNode, harvester)
        if ok and node and node.node then
            x = localToLocal(node.node, self.rootNode, 0, 0, 0)
        end
    end
    -- the vehicle's x points to its left
    if x and x < -0.3 then
        return GuidancePlan.SIDE_RIGHT
    end
    return GuidancePlan.SIDE_LEFT
end

--- A field read from the ground is back from the server: the course on it now (the panel shows how it went)
function GuidanceVehicle.updateWaitField(self, spec, dt)
    if spec.waitField == nil then
        return
    end
    spec.waitFieldTime = spec.waitFieldTime + dt
    if GuidanceCourse.isFieldBack(spec.waitField) then
        local sent = spec.waitField
        spec.waitField = nil
        local ok, err = self:guidanceGenerate()
        local hud = Guidance.hud
        if hud and hud.showMessage then
            if ok then
                hud:showMessage(string.format(g_i18n:getText("guidance_scan_done"), sent.name,
                    GuidanceFieldScan.areaOf(sent.outline) / 10000), false)
            else
                hud:showMessage(err or g_i18n:getText("guidance_err_generic"), true)
            end
        end
    elseif spec.waitFieldTime > 15000 then
        spec.waitField = nil
    else
        self:raiseActive()
    end
end

--- Changes several settings at once (name -> value), making the course again once
function GuidanceVehicle:guidanceApplySettings(values)
    local spec = getSpec(self)
    local remake = false
    for name, value in pairs(values) do
        spec.settings[name] = value
        if not GuidanceVehicle.START_SETTINGS[name] then remake = true end
    end
    if spec.plan and remake then
        local plan = spec.plan:copy()
        for name, value in pairs(values) do plan[name] = value end
        self:guidanceSetPlan(plan)
    end
end

-- settings only for starting the helper: changing them doesn't make the course again
GuidanceVehicle.START_SETTINGS = {startMode = true, refillX = true, refillZ = true, unloadX = true, unloadZ = true,
                                  unloadFull = true}

--- Changes a setting (from the HUD) and makes the course again if there is one
function GuidanceVehicle:guidanceChangeSetting(name, value)
    local spec = getSpec(self)
    if GuidanceVehicle.START_SETTINGS[name] then
        spec.settings[name] = value
        return
    end
    -- a setting of the field: remember it for the field (if the player wants that)
    if spec.plan and GuidanceLibrary.isFieldKey(name) and GuidancePrefs and GuidancePrefs.rememberFields then
        local values = GuidanceLibrary.fieldValuesOf(spec.plan)
        values[name] = value
        GuidanceLibrary.setFieldSettings(spec.plan.fieldId, values)
    end
    spec.settings[name] = value
    if name == "workWidth" then spec.settings.autoWidth = false end
    if name == "turnRadius" then spec.settings.autoRadius = false end
    if spec.plan then
        local plan = spec.plan:copy()
        plan[name] = value
        plan.autoWidth, plan.autoRadius = spec.settings.autoWidth, spec.settings.autoRadius
        if name == "autoWidth" and value then plan.workWidth = GuidanceVehicleInfo.get(self).workWidth end
        if name == "autoRadius" and value then plan.turnRadius = GuidanceVehicleInfo.get(self).turnRadius end
        self:guidanceSetPlan(plan)
    end
end

-----------------------------------------------------------------------------------------------------------------------
-- Helper
-----------------------------------------------------------------------------------------------------------------------

function GuidanceVehicle:getIsGuidanceActive()
    if not self:getIsAIActive() then
        return false
    end
    local job = self.getJob and self:getJob()
    return job ~= nil and (job.name == GuidanceJob.name or GuidanceVehicle.HELPER_JOBS[job.name] ~= nil)
end

-- our jobs without a course, by the game's job name: their kind
GuidanceVehicle.HELPER_JOBS = {GUIDANCE_UNLOAD = "unload", GUIDANCE_BALES = "bales", GUIDANCE_SILO = "silo"}

-- what a helper without a course is doing, for the panel (sent as a number: only add at the end)
GuidanceVehicle.HELPER_PHASES = {"unloadWait", "unloadDrive", "unloadFollow", "unloadLeave", "unloadTrip",
                                 "balesFind", "balesPick", "balesHome", "balesUnload", "siloDrive", "siloWait"}

--- (server) a helper without a course says what it is doing (nil: nothing)
function GuidanceVehicle:guidanceSetHelperPhase(name)
    local spec = getSpec(self)
    local ix = 0
    for i, n in ipairs(GuidanceVehicle.HELPER_PHASES) do
        if n == name then ix = i end
    end
    if (spec.helperPhase or 0) ~= ix then
        spec.helperPhase = ix
        self:raiseDirtyFlags(spec.dirtyFlag)
    end
end

--- What a helper without a course is doing: its name, or nil
function GuidanceVehicle:getGuidanceHelperPhase()
    local ix = getSpec(self).helperPhase or 0
    return GuidanceVehicle.HELPER_PHASES[ix]
end

--- The kind of helper without a course working the vehicle now ("unload", "bales", "silo"), or nil
function GuidanceVehicle:getGuidanceHelperKind()
    if not self:getIsAIActive() then return nil end
    local job = self.getJob and self:getJob()
    return job and GuidanceVehicle.HELPER_JOBS[job.name]
end

--- What helpers without a course the vehicle could be: list of kinds
function GuidanceVehicle:getGuidanceHelperKinds()
    local list = {}
    for _, kind in ipairs({"unload", "bales", "silo"}) do
        if GuidanceHelperJob.canDo(self, kind) == true then list[#list + 1] = kind end
    end
    return list
end

--- Hires a helper without a course (kind "unload", "bales", "silo"); values: unloadX, unloadZ, fullLevel.
--- Works on clients (asks the server).
function GuidanceVehicle:guidanceStartHelper(kind, values)
    if self:getIsHelperDriving() then
        return false
    end
    local mission = g_currentMission
    local job = mission.aiJobTypeManager:createJob(AIJobType[GuidanceHelperJob.KINDS[kind].name])
    if job == nil then
        return false
    end
    local farmId = self:getOwnerFarmId()
    job:applyCurrentState(self, mission, farmId, true)
    for k, v in pairs(values or {}) do job[k] = v end
    job:setValues()
    local ok, err = job:validate(farmId)
    if not ok then
        if err and g_client ~= nil and g_dedicatedServer == nil then
            mission:showBlinkingWarning(Guidance.TITLE .. ": " .. err, 4000)
        end
        return false, err
    end
    if g_server ~= nil then
        mission.aiSystem:startJob(job, farmId)
    else
        g_client:getServerConnection():sendEvent(AIJobStartRequestEvent.new(job, farmId))
    end
    return true
end

--- A helper (ours or another) really drives the vehicle. The game's own flag alone isn't enough: a savegame saved
--- while a helper worked loads with it set, but without a helper.
function GuidanceVehicle:getIsHelperDriving()
    if not self:getIsAIActive() then
        return false
    end
    return self.getJob == nil or self:getJob() ~= nil
end

--- Stops whatever helper drives the vehicle: ours, the game's own or another mod's (on a client the game asks the
--- server)
function GuidanceVehicle:guidanceStopHelper()
    if self:getIsHelperDriving() then
        self:stopCurrentAIJob(AIMessageSuccessStoppedByUser.new())
    end
end

GuidanceVehicle.STALE_HELPER_TIME = 3000 -- ms the game's helper flag may be set without a helper

--- Server: clears the game's helper flag when no helper is there (left over from the savegame)
local function clearStaleHelper(self, spec, dt)
    local worker = self.spec_aiFieldWorker
    if worker == nil or not worker.isActive or self.getJob == nil or self:getJob() ~= nil then
        spec.staleHelperTime = 0
        return
    end
    spec.staleHelperTime = (spec.staleHelperTime or 0) + dt
    if spec.staleHelperTime >= GuidanceVehicle.STALE_HELPER_TIME then
        worker.isActive = false
        spec.staleHelperTime = 0
        Guidance.info("%s: cleared a helper left over from the savegame", Guidance.vehicleName(self))
    end
end

GuidanceVehicle.RESUME_DELAY = 8000 -- ms after loading before a helper that was working starts again

--- Server: a helper that was working when the game was saved starts again where it was, once everything has
--- loaded (and the game's leftover helper flag is cleared). Not if another helper has the vehicle.
function GuidanceVehicle.updateResume(self, spec, dt)
    if spec.resumeAfterLoad == nil then
        return
    end
    spec.resumeAfterLoad = spec.resumeAfterLoad + dt
    self:raiseActive()
    if spec.resumeAfterLoad < GuidanceVehicle.RESUME_DELAY then
        return
    end
    spec.resumeAfterLoad = nil
    if spec.course and not self:getIsHelperDriving() then
        Guidance.info("%s: was working when saved, carries on", Guidance.vehicleName(self))
        self:guidanceStart(spec.course:getResumeIx(spec.progressIx))
    end
end

--- Tramlines: the rows where the field's sowing course has its passes (every k-th of them, k = our width over its
--- row spacing), its row direction. The sowing course: the newest saved one on this field narrower than ours, or
--- another tractor's course there. Sets plan.rowAngle, rowPhase, rowSpacing; without one, ordinary rows.
function GuidanceVehicle.applyTramlines(self, plan)
    plan.rowPhase, plan.rowSpacing = 0, 0
    getSpec(self).tramlineSource = nil
    if not plan.tramlines then
        return
    end
    local source, sourceName
    for _, e in ipairs(GuidanceLibrary.getForFarm(self:getOwnerFarmId())) do
        if e.plan.fieldId == plan.fieldId and e.plan.workWidth < plan.workWidth - 0.1 and not e.plan.tramlines
                and (source == nil or e.id > source.id) then
            source, sourceName = e, e.name
        end
    end
    local sourcePlan = source and source.plan
    if sourcePlan == nil then
        for _, v in ipairs(GuidanceMap.getFarmVehicles()) do
            local p = v ~= self and v:getGuidancePlan()
            if p and p.fieldId == plan.fieldId and p.workWidth < plan.workWidth - 0.1 and not p.tramlines then
                sourcePlan, sourceName = p, Guidance.vehicleName(v)
            end
        end
    end
    if sourcePlan == nil then
        return
    end
    local course = GuidanceCourse.generate(sourcePlan:copy())
    local lines = course and course.stats.rowLines
    if lines == nil or #lines < 2 then
        return
    end
    local step = (lines[#lines] - lines[1]) / (#lines - 1)
    local k = math.max(1, math.floor(plan.workWidth * (1 - (plan.overlap or 0)) / step + 0.5))
    -- the middle of the first k passes
    plan.rowAngle = course.stats.rowAngle
    plan.rowPhase = lines[1] + (k - 1) / 2 * step
    plan.rowSpacing = k * step
    getSpec(self).tramlineSource = string.format("%s (%d)", sourceName or "?", k)
end


--- Hires a helper to work the course from waypoint startIx (startPoint: from there on the way to it). Works on
--- clients (asks the server) and on the server (AutoDrive calls us there).
function GuidanceVehicle:guidanceStart(startIx, startPoint)
    local spec = getSpec(self)
    if spec.course == nil or self:getIsHelperDriving() then
        return false
    end
    local mission = g_currentMission
    local job = mission.aiJobTypeManager:createJob(AIJobType[GuidanceJob.name])
    if job == nil then
        return false
    end
    local farmId = self:getOwnerFarmId()
    job:applyCurrentState(self, mission, farmId, true)
    job:setStartIx(startIx or 1, startPoint)
    job.refillX, job.refillZ = spec.settings.refillX or 0, spec.settings.refillZ or 0
    job:setValues()
    local ok, err = job:validate(farmId)
    if not ok then
        if err and g_client ~= nil and g_dedicatedServer == nil then
            mission:showBlinkingWarning(Guidance.TITLE .. ": " .. err, 4000)
        end
        return false
    end
    if g_server ~= nil then
        mission.aiSystem:startJob(job, farmId)
    else
        g_client:getServerConnection():sendEvent(AIJobStartRequestEvent.new(job, farmId))
    end
    return true
end

function GuidanceVehicle:guidanceStop()
    if self:getIsGuidanceActive() then
        self:stopCurrentAIJob(AIMessageSuccessStoppedByUser.new())
    end
end

--- Where to start, by the "start at" setting: waypoint index and maybe a point on the way to it (starting in the
--- middle of a row)
function GuidanceVehicle:guidanceGetStart()
    local spec = getSpec(self)
    local course = spec.course
    local mode = spec.settings.startMode or GuidancePlan.START_CONTINUE
    if mode == GuidancePlan.START_FIRST then
        return 1
    elseif mode == GuidancePlan.START_NEAREST then
        local node = self.getAIDirectionNode and self:getAIDirectionNode() or self.rootNode
        local x, _, z = getWorldTranslation(node)
        local dx, _, dz = localDirectionToWorld(node, 0, 0, 1)
        return course:getNearest(x, z, math.atan2(dz, dx))
    end
    return course:getResumeIx(spec.progressIx)
end

--- Start (where the "start at" setting says) or stop
function GuidanceVehicle:guidanceStartStop()
    if self:getIsGuidanceActive() then
        self:guidanceStop()
    elseif not self:getIsHelperDriving() then
        local spec = getSpec(self)
        if spec.course then
            self:guidanceStart(self:guidanceGetStart())
        end
    end
end

--- Pause (stand still, the helper stays) or go on. On a client it asks the server.
function GuidanceVehicle:guidanceSetPaused(paused, noEventSend)
    local spec = getSpec(self)
    if g_server == nil then
        if not noEventSend then
            GuidancePauseEvent.sendEvent(self, paused)
        end
        return
    end
    paused = (paused and self:getIsGuidanceActive()) or false
    if spec.paused ~= paused then
        spec.paused = paused
        self:raiseDirtyFlags(spec.dirtyFlag)
    end
end

function GuidanceVehicle:getIsGuidancePaused()
    return getSpec(self).paused == true and self:getIsGuidanceActive()
end

-----------------------------------------------------------------------------------------------------------------------
-- Time: the course's time profile (turns, reversing, stopping to lower, curves; GuidanceCourseGenerator.timeProfile),
-- scaled by how fast this helper has actually been going against it (waiting to unload or refill, paused or
-- stuck doesn't count)
-----------------------------------------------------------------------------------------------------------------------

GuidanceVehicle.TIME_LEARN_MIN = 45 -- s of profile time before the measured pace counts
GuidanceVehicle.TIME_RATIO_MIN = 0.6
GuidanceVehicle.TIME_RATIO_MAX = 2.5
-- waiting for these isn't driving the course
GuidanceVehicle.WAITING_TEXTS = {"NEEDS_UNLOADING", "NEEDS_FILLING", "FUEL_IS_EMPTY", "IS_STUCK", "FINISHED",
                                 "NEXT_FIELD_WAITING", "GIVING_WAY"}

--- km/h the helper works at (the implements' limit)
function GuidanceVehicle:getGuidanceWorkSpeed()
    local speed = math.max(5, math.min(25, self:getSpeedLimit(true) or 12))
    local plan = getSpec(self).plan
    if plan and (plan.workSpeedMax or 0) > 0 then speed = math.min(speed, plan.workSpeedMax) end
    return speed
end

--- Seconds for the whole course and still to go (nil without a course)
function GuidanceVehicle:getGuidanceTimes()
    local spec = getSpec(self)
    local course = spec.course
    if course == nil then
        return nil
    end
    local team = course.stats.team
    if team and team.share == "nextRow" and team.wholeTime then
        -- next free row: the whole field shared out, what is left of it
        local total = team.wholeTime / math.max(1, team.size or 1) * (spec.timeRatio or 1)
        local _, done = self:getGuidanceProgress()
        return total, total * (1 - done)
    end
    local times = course:getTimes(self:getGuidanceWorkSpeed())
    local ratio = spec.timeRatio or 1
    local total = times[#times]
    local ix = math.max(1, math.min(#times, spec.progressIx or 1))
    local left = (total - times[ix]) * ratio
    -- counting down between waypoints (a row has one at each end)
    local sample = spec.timeSample
    if sample and sample.course == course and sample.ix == ix and ix < #times then
        left = left - math.min(sample.sinceIx, (times[ix + 1] - times[ix]) * ratio)
    end
    return total * ratio, math.max(0, left)
end

--- Learns the pace while the helper drives (every machine for itself: the progress is on all of them)
local function updatePace(self, spec, dt)
    local course = spec.course
    local driving = course ~= nil and self:getIsAIActive() and not spec.paused
    if driving then
        for _, name in ipairs(GuidanceVehicle.WAITING_TEXTS) do
            if spec.infoTexts[name] then driving = false end
        end
    end
    local sample = spec.timeSample
    if sample and sample.course ~= course then
        spec.timeSample, sample = nil, nil
    end
    if not driving then
        if sample then sample.paused = true end
        return
    end
    local times = course:getTimes(self:getGuidanceWorkSpeed())
    local ix = math.max(1, math.min(#times, spec.progressIx or 1))
    if sample == nil or ix < sample.ix or (sample.paused and ix ~= sample.ix) then
        -- (re)start measuring from here
        spec.timeSample = {course = course, ix = ix, startAt = times[ix], real = 0, sinceIx = 0}
        return
    end
    sample.paused = false
    sample.sinceIx = sample.sinceIx + dt / 1000
    if ix ~= sample.ix then
        -- passed waypoints: what that took against the profile
        sample.real = sample.real + sample.sinceIx
        sample.ix, sample.sinceIx = ix, 0
        local predicted = times[ix] - sample.startAt
        if predicted >= GuidanceVehicle.TIME_LEARN_MIN then
            spec.timeRatio = math.max(GuidanceVehicle.TIME_RATIO_MIN,
                math.min(GuidanceVehicle.TIME_RATIO_MAX, sample.real / predicted))
        end
    end
end

--- Next free row (server): the team's rows done of all, shown by every member
function GuidanceVehicle:guidanceSetTeamProgress(done, total)
    local spec = getSpec(self)
    if spec.teamDone ~= done or spec.teamTotal ~= total then
        spec.teamDone, spec.teamTotal = done, total
        self:raiseDirtyFlags(spec.dirtyFlag)
    end
end

function GuidanceVehicle:guidanceProgressChanged()
    self:raiseDirtyFlags(getSpec(self).dirtyFlag)
end

function GuidanceVehicle:guidanceSetInfoText(name, active)
    local spec = getSpec(self)
    active = active or nil
    if spec.infoTexts[name] ~= active then
        spec.infoTexts[name] = active
        self:raiseDirtyFlags(spec.dirtyFlag)
        -- the player hosting the game sees it here, the others when it arrives (readInfoBits)
        if active then
            Guidance.notify(self, name)
        end
    end
end

function GuidanceVehicle:guidanceClearInfoTexts()
    local spec = getSpec(self)
    if next(spec.infoTexts) ~= nil then
        spec.infoTexts = {}
        self:raiseDirtyFlags(spec.dirtyFlag)
    end
end

--- Active status texts: list of {name, text, id}
function GuidanceVehicle:getGuidanceInfoTexts()
    local spec = getSpec(self)
    local list = {}
    for i, name in ipairs(GuidanceVehicle.INFO_TEXTS) do
        if spec.infoTexts[name] then
            table.insert(list, {name = name, id = i, text = g_i18n:getText("guidance_info_" .. name)})
        end
    end
    return list
end

-----------------------------------------------------------------------------------------------------------------------
-- Queue: saved courses to work one after the other. When a course is done the next one is loaded; the helper drives
-- there itself if it is close, else AutoDrive takes the vehicle to its marker nearest to it first.
-----------------------------------------------------------------------------------------------------------------------

function GuidanceVehicle:getGuidanceQueue()
    return getSpec(self).queue
end

--- Sets the queue (library ids); on a client it asks the server, which tells everybody
function GuidanceVehicle:guidanceSetQueue(queue, noEventSend)
    local spec = getSpec(self)
    spec.queue = queue or {}
    if not noEventSend then
        GuidanceQueueEvent.sendEvent(self, spec.queue)
    end
end

local function autoDrive()
    local ad = AutoDrive
    if ad == nil and FS25_AutoDrive ~= nil then ad = FS25_AutoDrive.AutoDrive end
    return ad
end

--- The AutoDrive marker nearest to x, z (id, distance), or nil
local function nearestMarker(x, z)
    local ad = autoDrive()
    if ad == nil or ad.GetAvailableDestinations == nil then return nil end
    local ok, destinations = pcall(ad.GetAvailableDestinations, ad)
    if not ok or destinations == nil then return nil end
    local best, bestD
    for id, d in pairs(destinations) do
        local dist = math.sqrt((d.x - x) ^ 2 + (d.z - z) ^ 2)
        if bestD == nil or dist < bestD then best, bestD = id, dist end
    end
    return best, bestD
end

--- Server: after a course is done, on to the next one of the queue
function GuidanceVehicle.updateQueue(self)
    local spec = getSpec(self)
    if spec.queueState == "autodrive" then
        -- AutoDrive is taking us there: once it has stopped, start
        local active = self.ad and self.ad.stateModule and self.ad.stateModule:isActive()
        if active then
            spec.queueSeenDriving = true
        elseif spec.queueSeenDriving or (g_time or 0) > (spec.queueSince or 0) + 5000 then
            spec.queueState = nil
            self:guidanceStart(1)
        end
        return
    end
    if #spec.queue == 0 or self:getIsHelperDriving() or not spec.infoTexts.FINISHED then
        return
    end
    -- the course is done: load the next one
    local entry
    while #spec.queue > 0 and entry == nil do
        entry = GuidanceLibrary.getEntry(table.remove(spec.queue, 1))
    end
    GuidanceQueueEvent.sendEvent(self, spec.queue)
    if entry == nil then
        return
    end
    self:guidanceSetPlan(entry.plan:copy())
    self:guidanceSetInfoText("FINISHED", false)
    local course = spec.course
    if course == nil then
        return
    end
    local x, _, z = getWorldTranslation(self.rootNode)
    local first = course.waypoints[1]
    local distance = math.sqrt((first.x - x) ^ 2 + (first.z - z) ^ 2)
    if distance <= GuidanceVehicle.QUEUE_NEAR then
        self:guidanceStart(1)
        return
    end
    local marker, markerDistance = nearestMarker(first.x, first.z)
    local ad = autoDrive()
    if marker and markerDistance <= GuidanceVehicle.QUEUE_MARKER_RANGE and self.ad and self.ad.stateModule then
        local ok = pcall(function()
            self.ad.stateModule:setMode(ad.MODE_DRIVETO)
            ad:StartDriving(self, marker, marker)
        end)
        if ok then
            Guidance.info("%s: AutoDrive takes it to the next field", Guidance.vehicleName(self))
            spec.queueState, spec.queueSince, spec.queueSeenDriving = "autodrive", g_time or 0, false
            return
        end
    end
    -- no way to get there by itself: the player has to
    self:guidanceSetInfoText("NEXT_FIELD_WAITING", true)
end

-----------------------------------------------------------------------------------------------------------------------
-- AutoDrive (it talks to us as if we were Courseplay)
-----------------------------------------------------------------------------------------------------------------------

function GuidanceVehicle:cpStartStopDriver(isStartedByHud)
    self:guidanceStartStop()
end

function GuidanceVehicle:startCpAtFirstWp()
    return self:guidanceStart(1)
end

--- AutoDrive brings the vehicle back after unloading / refilling and continues where we stopped
function GuidanceVehicle:startCpAtLastWp()
    local spec = getSpec(self)
    if spec.course == nil then
        return false
    end
    return self:guidanceStart(spec.course:getResumeIx(spec.progressIx))
end

function GuidanceVehicle:getCanStartCp()
    return getSpec(self).course ~= nil and not self:getIsHelperDriving()
end

--- (only the statuses AutoDrive knows from Courseplay)
function GuidanceVehicle:getCpActiveInfoTexts()
    local list = {}
    for _, info in ipairs(self:getGuidanceInfoTexts()) do
        if info.name ~= "FINISHED" and info.name ~= "NEXT_FIELD_WAITING" and info.name ~= "GIVING_WAY" then
            table.insert(list, info)
        end
    end
    return list
end

local function activeDriver(vehicle)
    local spec = getSpec(vehicle)
    return GuidanceVehicle.getIsGuidanceActive(vehicle) and spec.driver or nil
end

function GuidanceVehicle:getIsCpHarvesterWaitingForUnload()
    local driver = activeDriver(self)
    return driver ~= nil and driver:isWaitingForUnload()
end

--- We never back out of the crop into a pocket for the unloader
function GuidanceVehicle:getIsCpHarvesterWaitingForUnloadInPocket()
    return false
end

function GuidanceVehicle:getIsCpHarvesterManeuvering()
    local driver = activeDriver(self)
    return driver ~= nil and driver:isManeuvering()
end

function GuidanceVehicle:holdCpHarvesterTemporarily(ms)
    local driver = activeDriver(self)
    if driver then
        driver:hold(ms)
    end
end

-----------------------------------------------------------------------------------------------------------------------
-- Multiplayer
-----------------------------------------------------------------------------------------------------------------------

local function writeInfoBits(spec, streamId)
    local bits = 0
    for i, name in ipairs(GuidanceVehicle.INFO_TEXTS) do
        if spec.infoTexts[name] then bits = bits + 2 ^ (i - 1) end
    end
    streamWriteUInt8(streamId, bits)
    streamWriteBool(streamId, spec.paused == true)
    -- what a helper without a course is doing (GuidanceVehicle.HELPER_PHASES, 0 nothing)
    streamWriteUInt8(streamId, spec.helperPhase or 0)
end

--- notify: tell the player about statuses that just came on (not when joining a game)
local function readInfoBits(vehicle, spec, streamId, notify)
    local bits = streamReadUInt8(streamId)
    local before = spec.infoTexts or {}
    spec.infoTexts = {}
    for i, name in ipairs(GuidanceVehicle.INFO_TEXTS) do
        if bitAND(bits, 2 ^ (i - 1)) ~= 0 then
            spec.infoTexts[name] = true
            if notify and not before[name] then
                Guidance.notify(vehicle, name)
            end
        end
    end
    spec.paused = streamReadBool(streamId)
    spec.helperPhase = streamReadUInt8(streamId)
end

function GuidanceVehicle:onWriteStream(streamId, connection)
    local spec = getSpec(self)
    spec.settings:writeStream(streamId)
    if streamWriteBool(streamId, spec.plan ~= nil) then
        spec.plan:writeStream(streamId)
    end
    streamWriteInt32(streamId, spec.progressIx or 1)
    writeInfoBits(spec, streamId)
    streamWriteUInt16(streamId, spec.teamDone or 0)
    streamWriteUInt16(streamId, spec.teamTotal or 0)
    streamWriteUInt8(streamId, math.min(255, #spec.queue))
    for i = 1, math.min(255, #spec.queue) do streamWriteInt32(streamId, spec.queue[i]) end
end

function GuidanceVehicle:onReadStream(streamId, connection)
    local spec = getSpec(self)
    spec.settings = GuidancePlan.readStream(streamId)
    if streamReadBool(streamId) then
        self:guidanceSetPlan(GuidancePlan.readStream(streamId), true)
    end
    spec.progressIx = streamReadInt32(streamId)
    readInfoBits(self, spec, streamId, false)
    spec.teamDone = streamReadUInt16(streamId)
    spec.teamTotal = streamReadUInt16(streamId)
    spec.queue = {}
    for _ = 1, streamReadUInt8(streamId) do table.insert(spec.queue, streamReadInt32(streamId)) end
end

function GuidanceVehicle:onWriteUpdateStream(streamId, connection, dirtyMask)
    if not connection:getIsServer() then
        local spec = getSpec(self)
        if streamWriteBool(streamId, bitAND(dirtyMask, spec.dirtyFlag) ~= 0) then
            streamWriteInt32(streamId, spec.progressIx or 1)
            writeInfoBits(spec, streamId)
            streamWriteUInt16(streamId, spec.teamDone or 0)
            streamWriteUInt16(streamId, spec.teamTotal or 0)
        end
    end
end

function GuidanceVehicle:onReadUpdateStream(streamId, timestamp, connection)
    if connection:getIsServer() then
        local spec = getSpec(self)
        if streamReadBool(streamId) then
            spec.progressIx = streamReadInt32(streamId)
            readInfoBits(self, spec, streamId, true)
            spec.teamDone = streamReadUInt16(streamId)
            spec.teamTotal = streamReadUInt16(streamId)
        end
    end
end

-----------------------------------------------------------------------------------------------------------------------
-- Input and drawing
-----------------------------------------------------------------------------------------------------------------------

function GuidanceVehicle:onRegisterActionEvents(isActiveForInput, isActiveForInputIgnoreSelection)
    if not self.isClient then
        return
    end
    local spec = getSpec(self)
    if spec.isShopPreview then
        return
    end
    self:clearActionEventsTable(spec.actionEvents)
    -- (the game's own flags say no while a helper drives this vehicle: then we couldn't stop it or open the panel)
    if self:getIsActiveForInput(true, true) then
        local _, id = self:addActionEvent(spec.actionEvents, InputAction.GUIDANCE_TOGGLE_HUD, self,
            GuidanceVehicle.actionToggleHud, false, true, false, true, nil)
        g_inputBinding:setActionEventTextPriority(id, GS_PRIO_NORMAL)
        _, id = self:addActionEvent(spec.actionEvents, InputAction.GUIDANCE_START_STOP, self,
            GuidanceVehicle.actionStartStop, false, true, false, true, nil)
        g_inputBinding:setActionEventTextPriority(id, GS_PRIO_HIGH)
        spec.startStopEventId = id
        -- a controller on the panel (no keys of their own: the player binds them in the game's controls)
        for _, entry in ipairs({{"GUIDANCE_UI_NEXT", GuidanceVehicle.actionUiNext},
                                {"GUIDANCE_UI_PREV", GuidanceVehicle.actionUiPrev},
                                {"GUIDANCE_UI_PRESS", GuidanceVehicle.actionUiPress}}) do
            if InputAction[entry[1]] then
                _, id = self:addActionEvent(spec.actionEvents, InputAction[entry[1]], self, entry[2], false, true, false,
                    true, nil)
                g_inputBinding:setActionEventTextVisibility(id, false)
            end
        end
        GuidanceVehicle.updateActionEvents(self)
    end
end

function GuidanceVehicle.actionToggleHud(self)
    if Guidance.hud then
        Guidance.hud:toggle(self)
    end
end

function GuidanceVehicle.actionUiNext(self)
    if Guidance.hud and Guidance.hud:isOpenFor(self) then Guidance.hud:moveFocus(1) end
end

function GuidanceVehicle.actionUiPrev(self)
    if Guidance.hud and Guidance.hud:isOpenFor(self) then Guidance.hud:moveFocus(-1) end
end

function GuidanceVehicle.actionUiPress(self)
    if Guidance.hud and Guidance.hud:isOpenFor(self) then Guidance.hud:pressFocus() end
end

function GuidanceVehicle.actionStartStop(self)
    self:guidanceStartStop()
end

function GuidanceVehicle.updateActionEvents(self)
    local spec = getSpec(self)
    if spec.startStopEventId then
        local text
        if self:getIsGuidanceActive() then
            text = g_i18n:getText("guidance_action_stop")
        else
            text = g_i18n:getText("guidance_action_start")
        end
        g_inputBinding:setActionEventText(spec.startStopEventId, text)
        g_inputBinding:setActionEventActive(spec.startStopEventId,
            spec.course ~= nil and (self:getIsGuidanceActive() or not self:getIsHelperDriving()))
    end
end

--- (server) a helper without a course drives here, every frame: its strategy gives the point to steer to, the
--- game's drive function goes there (no field work implements needed, unlike the game's field work helper)
function GuidanceVehicle:onUpdate(dt)
    local spec = getSpec(self)
    local driver = spec.helperDriver
    if driver == nil or not self.isServer then
        return
    end
    driver:update(dt)
    SpecializationUtil.raiseEvent(self, "onAIFieldWorkerActive")
    local ok, tx, tz, forwards, maxSpeed = pcall(driver.getDriveData, driver, dt)
    if not ok then
        Guidance.info("%s: helper stopped: %s", Guidance.vehicleName(self), tostring(tx))
        spec.helperDriver = nil
        self:stopCurrentAIJob(AIMessageErrorBlockedByObject.new())
        return
    end
    if spec.helperDriver == nil or tx == nil then
        return
    end
    maxSpeed = math.min(maxSpeed or 0, self:getCruiseControlMaxSpeed() or math.huge)
    local ty = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, tx, 0, tz)
    local node = self:getAISteeringNode()
    if not forwards and self.getAIReverserNode and self:getAIReverserNode() ~= nil then
        node = self:getAIReverserNode()
    end
    local lx, _, lz = worldToLocal(node, tx, ty, tz)
    AIVehicleUtil.driveToPoint(self, dt, 1, maxSpeed > 0, forwards ~= false, lx, lz, maxSpeed)
    self:raiseActive()
end

function GuidanceVehicle:onUpdateTick(dt, isActiveForInput, isActiveForInputIgnoreSelection, isSelected)
    if self.isClient and self.isActiveForInputIgnoreSelectionIgnoreAI then
        GuidanceVehicle.updateActionEvents(self)
    end
    updatePace(self, getSpec(self), dt)
    GuidanceVehicle.updateWaitField(self, getSpec(self), dt)
    if self.isServer then
        clearStaleHelper(self, getSpec(self), dt)
        GuidanceVehicle.updateResume(self, getSpec(self), dt)
        if getSpec(self).staleHelperTime > 0 then self:raiseActive() end
        GuidanceVehicle.updateQueue(self)
        -- keep ticking while something is queued
        if #getSpec(self).queue > 0 or getSpec(self).queueState then
            self:raiseActive()
        end
    end
end

--- Course in the world while the panel is open for this vehicle
function GuidanceVehicle:onDraw(isActiveForInput, isActiveForInputIgnoreSelection, isSelected)
    local spec = getSpec(self)
    if spec.course and Guidance.hud and Guidance.hud:isOpenFor(self) then
        GuidanceDraw.drawCourseInWorld(self, spec.course)
    end
end

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
                              "NEXT_FIELD_WAITING", "GIVING_WAY", "WAITING_RAIN", "NO_UNLOADER", "SERVICE_FUEL",
                              "SERVICE_REPAIR", "HANDED_OVER"}

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
    schema:register(XMLValueType.STRING, GuidanceVehicle.SAVE_KEY .. "#helper", "Guidance: the helper without a course working when saved (unload, bales, silo, shovel)")
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

function GuidanceVehicle.registerOverwrittenFunctions(vehicleType)
    -- (a helper that switched its engine off to save fuel: the game must not start it again by itself)
    if vehicleType.functions == nil or vehicleType.functions.getCanMotorRun ~= nil then
        SpecializationUtil.registerOverwrittenFunction(vehicleType, "getCanMotorRun", GuidanceVehicle.getCanMotorRun)
    end
end

function GuidanceVehicle:getCanMotorRun(superFunc, ...)
    local spec = self[GuidanceVehicle.SPEC]
    if spec and spec.engineOff and spec.helperDriver ~= nil then
        return false
    end
    return superFunc(self, ...)
end

GuidanceVehicle.ENGINE_OFF_AFTER = 10000 -- ms a helper stands with nothing to do before its engine goes off
-- the helpers' phases of waiting for the others: the engine may go off
GuidanceVehicle.IDLE_PHASES = {unloadWait = true, siloWait = true, balesWaitBaler = true}

--- (server) A helper without a course standing with nothing to do (an unloader waiting for a combine, a wrapper
--- for the baler...): the engine off after a while to save fuel, on again as soon as it has to move
function GuidanceVehicle.saveFuel(self, spec, dt, maxSpeed)
    if self.startMotor == nil or self.stopMotor == nil or self.getMotorState == nil or MotorState == nil then
        return
    end
    -- only where it waits for the others (not under a combine's pipe while the combine stands a moment)
    local waiting = GuidanceVehicle.IDLE_PHASES[self:getGuidanceHelperPhase() or ""]
    if not waiting or (maxSpeed or 0) > 0.1 or self:getLastSpeed() > 0.5 then
        spec.idleTime = 0
        if spec.engineOff then
            spec.engineOff = false
            Guidance.try(self.startMotor, self)
            Guidance.debug("%s: engine on again", Guidance.vehicleName(self))
        end
        return
    end
    spec.idleTime = (spec.idleTime or 0) + dt
    if not spec.engineOff and spec.idleTime > GuidanceVehicle.ENGINE_OFF_AFTER and self:getMotorState() ~= MotorState.OFF then
        spec.engineOff = true
        Guidance.try(self.stopMotor, self)
        Guidance.debug("%s: standing with nothing to do, engine off to save fuel", Guidance.vehicleName(self))
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
    f("guidanceFollowCourseOf", GuidanceVehicle.guidanceFollowCourseOf)
    f("guidanceFollowsCourseOf", GuidanceVehicle.guidanceFollowsCourseOf)
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
    f("guidanceSetStartSetting", GuidanceVehicle.guidanceSetStartSetting)
    f("getIsGuidancePaused", GuidanceVehicle.getIsGuidancePaused)
    f("guidanceGetStart", GuidanceVehicle.guidanceGetStart)
    f("getGuidanceQueue", GuidanceVehicle.getGuidanceQueue)
    f("getGuidanceWorkSpeed", GuidanceVehicle.getGuidanceWorkSpeed)
    f("getGuidanceTimes", GuidanceVehicle.getGuidanceTimes)
    f("guidanceSetQueue", GuidanceVehicle.guidanceSetQueue)
    f("guidanceGoTo", GuidanceVehicle.guidanceGoTo)
    f("guidanceCourseForField", GuidanceVehicle.guidanceCourseForField)
    f("guidanceAtCourseField", GuidanceVehicle.guidanceAtCourseField)
    f("guidanceTakeOver", GuidanceVehicle.guidanceTakeOver)
    f("guidanceCropTest", GuidanceVehicle.guidanceCropTest)
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
    -- a bale collector, silo compacter... working when saved: started again as that (not as the course it may also
    -- have)
    local helperKind = savegame.xmlFile:getValue(key .. "#helper")
    -- (saved before 1.0.5.2 "working", without which: the game's own last job tells, e.g. GUIDANCE_BALES)
    if helperKind == nil and GuidanceHelperJob and savegame.key and savegame.xmlFile:getValue(key .. "#active", false) then
        local ok, lastType = Guidance.try(savegame.xmlFile.getString, savegame.xmlFile,
            savegame.key .. ".aiJobVehicle.lastJob#type")
        for kind, d in pairs(GuidanceHelperJob.KINDS) do
            if ok and lastType == d.name then helperKind = kind end
        end
    end
    if self.isServer and helperKind and GuidanceHelperJob and GuidanceHelperJob.KINDS[helperKind]
            and spec.settings.autoResume ~= false then
        spec.resumeHelper = helperKind
        spec.resumeAfterLoad = 0
        self:raiseActive()
    end
    -- an AutoDrive combine unloader set up from our panel: started again too (see GuidanceAutoDrive.updateResume)
    if self.isServer and spec.settings.autoResume ~= false then
        spec.adResumeAfterLoad = 0
        self:raiseActive()
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
        -- (the course's helper only: an unloader working is saved as that, below)
        xmlFile:setValue(key .. "#active", self:getIsGuidanceActive() and self:getGuidanceHelperKind() == nil)
    end
    local helperKind = self:getGuidanceHelperKind()
    if helperKind then
        xmlFile:setValue(key .. "#helper", helperKind)
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
GuidanceVehicle.MEMBER_KEYS = {"keepLowered", "lowerLate", "raiseLate", "toolOffsetX", "callUnloaderAt", "startMode",
                               "startAfter"}

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
        plan.vineTool = GuidanceVines.hasRowTool(self)
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
    self:guidanceSetPlan(GuidanceVehicle.planForField(self, fieldId, x, z))
    if spec.course == nil then
        return false, spec.error
    end
    if scanned then
        return true, nil, string.format(g_i18n:getText("guidance_scan_done"), scanned.name,
            GuidanceFieldScan.areaOf(scanned.outline) / 10000)
    end
    return true
end

--- A course plan for this vehicle on a field (its id), with its own settings and implements (the field's own
--- settings win), starting near x, z
function GuidanceVehicle.planForField(self, fieldId, x, z)
    local spec = getSpec(self)
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
    -- a new course: no moved points
    plan.moves, spec.settings.moves = "", ""
    plan.landsPipe = GuidanceVehicle.pipeSide(self)
    plan.toolSig = GuidanceVehicle.toolSignature(self)
    plan.vineTool = GuidanceVines.hasRowTool(self)
    GuidanceVehicle.applyTramlines(self, plan)
    return plan
end

--- A course for this vehicle on a field from wherever it is (a contract's field, a field handed over to it): made,
--- starting at the field's edge nearest to it. True, or false and why
function GuidanceVehicle:guidanceCourseForField(fieldId)
    local outline = GuidanceCourse.getFieldOutline(fieldId)
    if outline == nil or #outline < 3 then
        return false, g_i18n:getText("guidance_err_generic")
    end
    local x, _, z = getWorldTranslation(self.rootNode)
    local best, bestD
    for _, p in ipairs(outline) do
        local d = (p.x - x) ^ 2 + (p.z - z) ^ 2
        if bestD == nil or d < bestD then best, bestD = p, d end
    end
    self:guidanceSetPlan(GuidanceVehicle.planForField(self, fieldId, best.x, best.z))
    local spec = getSpec(self)
    if spec.course == nil then
        return false, spec.error
    end
    return true
end

--- Server: this vehicle's course is done; the tractor it hands the field over to (its plan's Then) gets a course
--- for the field (its own one if it has one for it) and goes there: by itself when near, else AutoDrive takes it
--- there and it starts on arrival. Not when that one is busy or gone (said so in the log and the status).
function GuidanceVehicle.handOver(self)
    local spec = getSpec(self)
    local plan = spec.plan
    local nextVehicle = plan and GuidanceVehicle.vehicleByKey(plan.handOver)
    if nextVehicle == nil or nextVehicle == self or nextVehicle.spec_guidance == nil then
        if plan and (plan.handOver or "") ~= "" then
            Guidance.info("%s: done; the tractor to take over (%s) isn't there", Guidance.vehicleName(self), plan.handOver)
        end
        return false
    end
    if nextVehicle:getIsHelperDriving() then
        Guidance.info("%s: done; %s is busy, not handed over", Guidance.vehicleName(self), Guidance.vehicleName(nextVehicle))
        return false
    end
    local nextPlan = nextVehicle:getGuidancePlan()
    if nextPlan == nil or nextPlan.fieldId ~= plan.fieldId then
        local start = spec.course and spec.course.waypoints[1]
        local sx, sz = plan.startX, plan.startZ
        if start then sx, sz = start.x, start.z end
        nextVehicle:guidanceSetPlan(GuidanceVehicle.planForField(nextVehicle, plan.fieldId, sx, sz))
    end
    if getSpec(nextVehicle).course == nil then
        Guidance.info("%s: done; no course for %s on this field", Guidance.vehicleName(self), Guidance.vehicleName(nextVehicle))
        return false
    end
    Guidance.info("%s: done, the field goes to %s", Guidance.vehicleName(self), Guidance.vehicleName(nextVehicle))
    self:guidanceSetInfoText("HANDED_OVER", true)
    -- (from the start of its course: nothing of it is done yet)
    getSpec(nextVehicle).progressIx = 1
    nextVehicle:guidanceGoTo(0)
    return true
end

--- The grass chain: a baler / loader wagon follows the rake's course, its passes are where the windrows lie
local function hasSpec(self, test)
    for _, v in ipairs(self.getChildVehicles and self:getChildVehicles() or {}) do
        if test(v) then return true end
    end
    return false
end

--- Picks up from windrows (baler, loader / forage wagon, pickup header)
function GuidanceVehicle.hasPickup(self)
    return hasSpec(self, function(v) return v.spec_baler ~= nil or v.spec_forageWagon ~= nil or v.spec_pickup ~= nil end)
end

--- Makes windrows (rake, merger)
function GuidanceVehicle.hasRake(self)
    return hasSpec(self, function(v) return v.spec_windrower ~= nil end)
end

--- The rake whose windrows lie on the field we're on: one of the farm's with a rake and a course there; or nil
function GuidanceVehicle.windrowSource(self)
    local x, _, z = getWorldTranslation(self.rootNode)
    local farmVehicles = GuidanceMap and GuidanceMap.getFarmVehicles and GuidanceMap.getFarmVehicles() or {}
    for _, v in ipairs(farmVehicles) do
        local plan = v ~= self and v.getGuidancePlan and v:getGuidancePlan()
        local course = plan and v:getGuidanceCourse()
        if course and GuidanceVehicle.hasRake(v) then
            local outline = GuidanceCourse.getFieldOutline(plan.fieldId)
            if outline and #outline >= 3 then
                local poly = {}
                for i, p in ipairs(outline) do poly[i] = {x = p.x, y = p.z} end
                if GuidanceGeo.pointInPolygon({x = x, y = z}, poly) then return v end
            end
        end
    end
    return nil
end

-- what makes the passes where they are (the rest stays ours: speeds, timing, turning)
GuidanceVehicle.WINDROW_KEYS = {"fieldId", "workWidth", "overlap", "clockwise", "headlandsFirst", "squareCorners",
                                "roundedPasses", "minHeadlandWidth", "rowShape", "rowsPerLand", "workPart", "rowFrom",
                                "rowTo", "skipRows", "skipZones", "headlandRev"}

--- Is our course the other's passes already (made by guidanceFollowCourseOf)?
function GuidanceVehicle:guidanceFollowsCourseOf(other)
    local plan, op, oc = self:getGuidancePlan(), other:getGuidancePlan(), other:getGuidanceCourse()
    if plan == nil or op == nil or oc == nil or self:getGuidanceCourse() == nil then return false end
    return plan.fieldId == op.fieldId and math.abs(plan.workWidth - op.workWidth) < 0.01
        and plan.headlands == GuidanceVehicle.headlandsOf(oc) and math.abs((plan.rowAngle or -1) - oc.stats.rowAngle) < 0.01
end

function GuidanceVehicle.headlandsOf(course)
    return course.stats.team and course.stats.team.wholeHeadlands or course.stats.headlands
end

--- A course on the other's passes (a baler on the rake's windrows): its layout, the headland passes, row angle and
--- pattern its course got (so its own turning doesn't change them), the whole field (not a team member's share);
--- our own turning, speeds and timing. Returns ok, error text
function GuidanceVehicle:guidanceFollowCourseOf(other)
    local op, oc = other:getGuidancePlan(), other:getGuidanceCourse()
    if op == nil or oc == nil then
        return false, g_i18n:getText("guidance_err_generic")
    end
    local spec = getSpec(self)
    local plan = spec.settings:copy()
    for _, k in ipairs(GuidanceVehicle.WINDROW_KEYS) do plan[k] = op[k] end
    plan.headlands = GuidanceVehicle.headlandsOf(oc)
    plan.rowAngle = oc.stats.rowAngle
    for ix, name in pairs(GuidancePlan.PATTERNS) do
        if name == oc.stats.pattern then plan.pattern = ix end
    end
    plan.autoWidth = false
    plan.teamMode, plan.teamSize, plan.teamIndex = GuidancePlan.TEAM_ALONE, 1, 1
    local info = GuidanceVehicleInfo.get(self)
    if plan.autoRadius then plan.turnRadius = info.turnRadius end
    plan.runOut = info.runOut
    plan.allowReverse = info.canReverse
    plan.towLength = info.towLength
    local x, _, z = getWorldTranslation(self.rootNode)
    plan.startX, plan.startZ = x, z
    -- (the other's moved points are numbered along its course: they don't fit ours)
    plan.moves = ""
    plan.landsPipe = GuidanceVehicle.pipeSide(self)
    plan.toolSig = GuidanceVehicle.toolSignature(self)
    self:guidanceSetPlan(plan)
    if spec.course == nil then
        return false, spec.error
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
        local ok, node = Guidance.try(harvester.getCurrentDischargeNode, harvester)
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
        if GuidanceVehicle.START_SETTINGS[name] then
            -- (to the server too, even when the course stays)
            self:guidanceSetStartSetting(name, value)
        else
            spec.settings[name] = value
            remake = true
        end
    end
    -- a change of the course (other than the moves themselves) drops the editor's moved points
    if remake and values.moves == nil and (spec.settings.moves or "") ~= "" then
        values.moves = ""
        spec.settings.moves = ""
    end
    if spec.plan and remake then
        local plan = spec.plan:copy()
        for name, value in pairs(values) do plan[name] = value end
        self:guidanceSetPlan(plan)
    end
end

-- settings the working helper takes as they are changed (they don't change the course): while it works they are
-- changed like the start settings, the course stays
GuidanceVehicle.LIVE_SETTINGS = {callUnloaderAt = true, workSpeedMax = true, turnSpeed = true, reverseSpeed = true,
                                 lowerLate = true, raiseLate = true, rainWait = true, keepRunning = true,
                                 refuelAt = true, repairAt = true, handOver = true}

-- settings only for starting the helper: changing them doesn't make the course again
GuidanceVehicle.START_SETTINGS = {startMode = true, startAfter = true, refillX = true, refillZ = true, rainWait = true, refillEdge = true,
                                  adMarker = true, refuelAt = true, repairAt = true, handOver = true, autoResume = true}

--- A setting only for starting: kept in the settings and the course's plan (the course stays as it is, and where it
--- got to), sent to the server and the other players
function GuidanceVehicle:guidanceSetStartSetting(name, value, noEventSend)
    local spec = getSpec(self)
    spec.settings[name] = value
    if spec.plan then spec.plan[name] = value end
    -- (the server: a new call level goes to AutoDrive too)
    if name == "callUnloaderAt" and g_server ~= nil and spec.driver and spec.driver.harvester
            and GuidanceFieldworkDriver and self:getIsGuidanceActive() then
        GuidanceFieldworkDriver.setCallUnloaderLevel(self, spec.driver.harvester, value)
    end
    if not noEventSend then
        GuidanceSettingEvent.sendEvent(self, name, value)
    end
end

--- Changes a setting (from the HUD) and makes the course again if there is one
function GuidanceVehicle:guidanceChangeSetting(name, value)
    local spec = getSpec(self)
    if GuidanceVehicle.START_SETTINGS[name] or (GuidanceVehicle.LIVE_SETTINGS[name] and self:getIsGuidanceActive()) then
        self:guidanceSetStartSetting(name, value)
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
    -- (the course changes: the editor's moved points go)
    spec.settings.moves = ""
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
GuidanceVehicle.HELPER_JOBS = {GUIDANCE_BALES = "bales", GUIDANCE_SILO = "silo", GUIDANCE_SHOVEL = "shovel"}

-- what a helper without a course is doing, for the panel (sent as a number: only add at the end)
GuidanceVehicle.HELPER_PHASES = {"unloadWait", "unloadDrive", "unloadFollow", "unloadLeave", "unloadTrip",
                                 "balesFind", "balesPick", "balesHome", "balesUnload", "siloDrive", "siloWait",
                                 "balesCantWrap", "unloadToTruck", "unloadOverload", "unloadToHeap", "unloadHeap",
                                 "shovelLoad", "shovelToTrailer", "shovelTip", "shovelBack", "shovelEmpty",
                                 "shovelNoTrailer", "shovelNoHeap", "balesWaitBaler", "unloadClear", "unloadReturn"}
-- why a helper stopped by itself: still shown after the job
GuidanceVehicle.END_PHASES = {balesCantWrap = true, shovelEmpty = true, shovelNoTrailer = true, shovelNoHeap = true}

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

--- The kind of helper without a course working the vehicle now ("bales", "silo", "shovel"), or nil
function GuidanceVehicle:getGuidanceHelperKind()
    if not self:getIsAIActive() then return nil end
    local job = self.getJob and self:getJob()
    return job and GuidanceVehicle.HELPER_JOBS[job.name]
end

--- What helpers without a course the vehicle could be: list of kinds ("unload": AutoDrive's combine unloader, set
--- up from our panel)
function GuidanceVehicle:getGuidanceHelperKinds()
    local list = {}
    if GuidanceAutoDrive.canUnload(self) then list[#list + 1] = "unload" end
    for _, kind in ipairs({"bales", "silo", "shovel"}) do
        if GuidanceHelperJob.canDo(self, kind) == true then list[#list + 1] = kind end
    end
    return list
end

--- Hires a helper without a course (kind "bales", "silo", "shovel"). Works on clients (asks the server).
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
    local kind = spec.resumeHelper
    spec.resumeHelper = nil
    if kind then
        if not self:getIsHelperDriving() then
            Guidance.info("%s: was working when saved (%s), carries on", Guidance.vehicleName(self), kind)
            self:guidanceStartHelper(kind)
        end
        return
    end
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

--- The start setting that counts now: Start at, except Start at First on a course that has got going (somewhere past
--- its first waypoint): then its Then (continue, nearest, or first again). A new course starts at its first again.
function GuidanceVehicle.startModeNow(spec)
    local mode = spec.settings.startMode or GuidancePlan.START_CONTINUE
    if mode == GuidancePlan.START_FIRST and (spec.progressIx or 1) > 1 then
        mode = spec.settings.startAfter or GuidancePlan.START_FIRST
    end
    return mode
end

--- Where to start, by the "start at" setting: waypoint index and maybe a point on the way to it (starting in the
--- middle of a row)
function GuidanceVehicle:guidanceGetStart()
    local spec = getSpec(self)
    local course = spec.course
    local mode = GuidanceVehicle.startModeNow(spec)
    if mode == GuidancePlan.START_FIRST then
        return 1
    elseif mode == GuidancePlan.START_NEAREST then
        local node = self.getAIDirectionNode and self:getAIDirectionNode() or self.rootNode
        local x, _, z = getWorldTranslation(node)
        local dx, _, dz = localDirectionToWorld(node, 0, 0, 1)
        local test, probe = self:guidanceCropTest(course)
        local ix, point, skipped = course:getNearest(x, z, math.atan2(dz, dx), test)
        if skipped then
            Guidance.info("%s: start at nearest: the passes nearest to it are harvested already, it starts on the "
                .. "nearest one with crop (waypoint %d)", Guidance.vehicleName(self), ix)
        end
        -- (crop left behind it on that stretch, a little way back: from there, not where it stands; only standing on
        -- that stretch, lined up, and able to back straight up it)
        local backIx, backPoint = ix, point
        local a, b = course.waypoints[ix - 1], course.waypoints[ix]
        if a and b and spec.plan and spec.plan.allowReverse then
            local lateral = GuidanceGeo.distToSegment({x = x, y = z}, {x = a.x, y = a.z}, {x = b.x, y = b.z})
            local turn = math.abs(GuidanceGeo.normAngle(math.atan2(b.z - a.z, b.x - a.x) - math.atan2(dz, dx)))
            if lateral < GuidanceVehicle.ON_STRETCH and turn < math.rad(30) then
                backIx, backPoint = course:uncutBehind(probe, ix, point, GuidanceVehicle.CROP_ENOUGH)
            end
        end
        if backIx ~= ix or backPoint ~= point then
            Guidance.info("%s: start at nearest: crop standing behind it on that pass, it starts back there (waypoint %d)",
                Guidance.vehicleName(self), backIx)
        end
        return backIx, backPoint
    end
    return course:getResumeIx(spec.progressIx)
end

GuidanceVehicle.CROP_AHEAD = 40 -- m of the course on from a start looked at for crop
GuidanceVehicle.ON_STRETCH = 3 -- m from a stretch's line the vehicle counts as on it (Nearest: crop behind it there)
GuidanceVehicle.CROP_ENOUGH = 4 -- m of crop in them: work left there

--- A harvester: a test whether a start on its course (waypoint ix, maybe a point on the way to it) has crop standing
--- ahead, so Start at: Nearest leaves out the passes already harvested; and the probe it asks. nil for anything else,
--- or when the game can't tell where the crop is.
function GuidanceVehicle:guidanceCropTest(course)
    if GuidanceFieldworkDriver == nil or GuidanceFieldworkDriver.findHarvester(self) == nil
            or GuidanceFruitProbe == nil then
        return nil
    end
    local ok, probe = Guidance.try(GuidanceFruitProbe.new, course.outline or {})
    if not ok or probe == nil or #probe.fruitIndexes == 0 then
        return nil
    end
    return function(ix, point)
        local okCrop, crop = Guidance.try(course.cropAhead, course, probe, ix, point, GuidanceVehicle.CROP_AHEAD)
        return not okCrop or crop >= GuidanceVehicle.CROP_ENOUGH
    end, probe
end

--- Server: the game's own field work helper is being hired for this vehicle (the hire key starts the job the
--- savegame remembers, the game's helper menu, AutoDrive with its helper set to the game's). With a course for the
--- field it is at and Game's helper: CourseCorrect, CourseCorrect works the course instead (where the start setting
--- says). True when it did; false: the game's helper goes ahead.
function GuidanceVehicle:guidanceTakeOver()
    local spec = getSpec(self)
    if spec.course == nil or spec.settings.takeOver == false or self:getIsHelperDriving()
            or not self:guidanceAtCourseField() then
        return false
    end
    if not self:guidanceStart(self:guidanceGetStart()) then
        return false
    end
    Guidance.info("%s: the game's own helper was hired, CourseCorrect works its course instead",
        Guidance.vehicleName(self))
    return true
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
                                 "NEXT_FIELD_WAITING", "GIVING_WAY", "WAITING_RAIN", "NO_UNLOADER", "SERVICE_FUEL",
                                 "SERVICE_REPAIR", "HANDED_OVER"}

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

--- AutoDrive's markers: list of {id, name, x, z}, or nil without AutoDrive
function GuidanceVehicle.autoDriveMarkers()
    local ad = autoDrive()
    if ad == nil or ad.GetAvailableDestinations == nil then return nil end
    local ok, destinations = Guidance.try(ad.GetAvailableDestinations, ad)
    if not ok or destinations == nil then return nil end
    local list = {}
    for id, d in pairs(destinations) do
        list[#list + 1] = {id = id, name = d.name or tostring(id), x = d.x, z = d.z}
    end
    table.sort(list, function(a, b) return a.name < b.name end)
    return list
end

GuidanceVehicle.MARKER_AT_FIELD = 15 -- m from the field's edge a marker is the field's own (its WAIT point, gateway)

--- The number of the map field a plan's field is (a field read from the ground: the map field it lies on), or nil
local function mapFieldNumber(plan)
    local id = plan.fieldId or 0
    if id > 0 then return id end
    local recorded = id < 0 and GuidanceLibrary and GuidanceLibrary.getField(id)
    if recorded and (recorded.baseField or 0) > 0 then return recorded.baseField end
    return nil
end

--- The AutoDrive marker that takes a vehicle to the course: the one its plan names, else, within QUEUE_MARKER_RANGE
--- of its start: one at the field's edge named after the field ("Field 42b WAIT"), one at the field's edge, any one;
--- the nearest to the start of the first kind there is (not a silo or shop beside the field when the field has a
--- marker of its own). Its id and name, or nil
function GuidanceVehicle.markerFor(plan, course)
    local markers = GuidanceVehicle.autoDriveMarkers()
    if markers == nil or course == nil or course.waypoints[1] == nil then return nil end
    if (plan.adMarker or "") ~= "" then
        for _, m in ipairs(markers) do
            if m.name == plan.adMarker then return m.id, m.name end
        end
        Guidance.info("AutoDrive marker '%s' not found, taking the nearest", plan.adMarker)
    end
    return GuidanceVehicle.markerNear(markers, course.outline, mapFieldNumber(plan), course.waypoints[1],
        GuidanceVehicle.QUEUE_MARKER_RANGE)
end

--- Of AutoDrive's markers within range m of ref {x, z}: one at the edge of the field (outline: list of {x, z}) named
--- after it (number), else one at its edge, else any; the nearest to ref of the first kind there is. Id and name, or nil
function GuidanceVehicle.markerNear(markers, outline, number, ref, range)
    local first = ref
    local poly
    if outline and #outline >= 3 then
        poly = {}
        for i, p in ipairs(outline) do poly[i] = {x = p.x, y = p.z} end
    end
    local pattern = number and ("%f[%d]" .. number .. "%f[%D]")
    local best, bestCost
    for _, m in ipairs(markers or {}) do
        local d = math.sqrt((m.x - first.x) ^ 2 + (m.z - first.z) ^ 2)
        if d <= range then
            local cost = d + 2000
            local p = {x = m.x, y = m.z}
            if poly and (GuidanceGeo.pointInPolygon(p, poly)
                    or GuidanceGeo.distToPolygon(p, poly) <= GuidanceVehicle.MARKER_AT_FIELD) then
                cost = d + 1000
                if pattern and tostring(m.name):find(pattern) then cost = d end
            end
            if bestCost == nil or cost < bestCost then best, bestCost = m, cost end
        end
    end
    if best then return best.id, best.name end
    return nil
end

--- A vehicle's key that survives a save (the game's unique id), for picking it in a setting
function GuidanceVehicle.vehicleKey(v)
    return v and (v.uniqueId or Guidance.vehicleName(v)) or ""
end

--- The vehicle with that key, or nil
function GuidanceVehicle.vehicleByKey(key)
    if key == nil or key == "" then return nil end
    local vehicles = g_currentMission and g_currentMission.vehicleSystem and g_currentMission.vehicleSystem.vehicles
    for _, v in pairs(vehicles or {}) do
        if not v.isDeleted and GuidanceVehicle.vehicleKey(v) == key then return v end
    end
    return nil
end

--- The field a vehicle works on: its outline (list of {x, z}) and its map field number (or nil); from its course,
--- else where it stands. nil when it isn't on a field
function GuidanceVehicle.fieldOfVehicle(v)
    local course = v.getGuidanceCourse and v:getGuidanceCourse()
    if course and course.outline and #course.outline >= 3 then
        local plan = v.getGuidancePlan and v:getGuidancePlan()
        return course.outline, plan and mapFieldNumber(plan)
    end
    if v.rootNode == nil or GuidanceCourse.getFieldIdAt == nil then return nil end
    local x, _, z = getWorldTranslation(v.rootNode)
    local id = GuidanceCourse.getFieldIdAt(x, z)
    local outline = id and GuidanceCourse.getFieldOutline(id)
    if outline == nil or #outline < 3 then return nil end
    local number = id > 0 and id or nil
    if id < 0 then
        local recorded = GuidanceLibrary.getField(id)
        if recorded and (recorded.baseField or 0) > 0 then number = recorded.baseField end
    end
    return outline, number
end

--- Is a vehicle at a field (on it or within FIELD_NEAR m)?
function GuidanceVehicle.isAtField(v, outline)
    local poly = {}
    for i, p in ipairs(outline) do poly[i] = {x = p.x, y = p.z} end
    local x, _, z = getWorldTranslation(v.rootNode)
    return GuidanceGeo.pointInPolygon({x = x, y = z}, poly)
        or GuidanceGeo.distToPolygon({x = x, y = z}, poly) <= GuidanceVehicle.FIELD_NEAR
end

GuidanceVehicle.FOLD_TIMEOUT = 30000 -- ms the implements may take to fold before AutoDrive sets off anyway

--- Server: the implements ready for the road before AutoDrive takes the vehicle: switched off, raised, folded (the
--- game's fold, as its own helper and AutoDrive do it)
function GuidanceVehicle.foldForRoad(self)
    for _, v in ipairs(self.getChildVehicles and self:getChildVehicles() or {}) do
        if v ~= self then
            if v.getIsTurnedOn and v.setIsTurnedOn and v:getIsTurnedOn() then Guidance.try(v.setIsTurnedOn, v, false) end
            local attacher = v.getAttacherVehicle and v:getAttacherVehicle()
            if attacher and attacher.getAttacherJointIndexFromObject and attacher.setJointMoveDown then
                local ix = attacher:getAttacherJointIndexFromObject(v)
                if ix then Guidance.try(attacher.setJointMoveDown, attacher, ix, false, false) end
            end
            local spec = v.spec_foldable
            if spec and spec.hasFoldingParts and v.setFoldState then
                local fold = -(spec.turnOnFoldDirection or 1)
                if spec.foldMoveDirection ~= fold and (v.getIsFoldAllowed == nil or v:getIsFoldAllowed(fold, false)) then
                    Guidance.try(v.setFoldState, v, fold, false)
                end
            end
        end
    end
end

--- Are the implements folded (those that may fold)?
function GuidanceVehicle.isFoldedForRoad(self)
    for _, v in ipairs(self.getChildVehicles and self:getChildVehicles() or {}) do
        local spec = v ~= self and v.spec_foldable
        if spec and spec.hasFoldingParts and spec.foldAnimTime then
            local fold = -(spec.turnOnFoldDirection or 1)
            local foldedAt = fold > 0 and 1 or 0
            local mayFold = v.getIsFoldAllowed == nil or v:getIsFoldAllowed(fold, false)
            if mayFold and math.abs(spec.foldAnimTime - foldedAt) > 0.01 then return false end
        end
    end
    return true
end

--- Server: AutoDrive is to take the vehicle to its course's marker. First the implements are folded for the road;
--- then (updateQueue) AutoDrive sets off with its helper ("CP") button switched on: on arrival AutoDrive presses it
--- and starts us (as it would Courseplay). True when that is under way.
function GuidanceVehicle.autoDriveTo(self)
    local spec = getSpec(self)
    local ad = autoDrive()
    local sm = self.ad and self.ad.stateModule
    if ad == nil or sm == nil or spec.course == nil then return false end
    local marker, name = GuidanceVehicle.markerFor(spec.plan, spec.course)
    if marker == nil then return false end
    return GuidanceVehicle.autoDriveToMarker(self, marker, name)
end

--- Server: AutoDrive is to take the vehicle to a marker (see autoDriveTo)
function GuidanceVehicle.autoDriveToMarker(self, marker, name)
    local spec = getSpec(self)
    if autoDrive() == nil or self.ad == nil or self.ad.stateModule == nil then return false end
    GuidanceVehicle.foldForRoad(self)
    spec.adMarkerId, spec.adMarkerName = marker, name
    spec.queueState, spec.queueSince = "folding", g_time or 0
    return true
end

--- Server: the implements folded (or it took too long): AutoDrive sets off, its helper button on
function GuidanceVehicle.autoDriveSetOff(self)
    local spec = getSpec(self)
    local ad = autoDrive()
    local sm = self.ad and self.ad.stateModule
    if ad == nil or sm == nil then
        spec.queueState = nil
        self:guidanceSetInfoText("NEXT_FIELD_WAITING", true)
        return
    end
    local before = sm.getStartHelper and sm:getStartHelper()
    local marker = spec.adMarkerId
    local ok = Guidance.try(function()
        sm:setMode(ad.MODE_DRIVETO)
        -- (only where AutoDrive's "CP" is us: with Courseplay installed it would start Courseplay)
        if Guidance.providesAutoDriveInterface() and sm.setStartHelper then
            local states = ADStateModule or (FS25_AutoDrive and FS25_AutoDrive.ADStateModule)
            if sm.setUsedHelper then sm:setUsedHelper(states and states.HELPER_CP or nil) end
            sm:setStartHelper(true)
        end
        ad:StartDriving(self, marker, marker)
    end)
    if not ok then
        spec.queueState = nil
        self:guidanceSetInfoText("NEXT_FIELD_WAITING", true)
        return
    end
    Guidance.info("%s: AutoDrive takes it to '%s'; it starts us there", Guidance.vehicleName(self),
        tostring(spec.adMarkerName))
    spec.queueState, spec.queueSince, spec.queueSeenDriving = "autodrive", g_time or 0, false
    spec.adHelperBefore = before == true
    -- (AutoDrive starts us with "continue": from the course's start setting then)
    spec.goStart = true
end

GuidanceVehicle.FIELD_NEAR = 40 -- m off its field a vehicle is still "at" it (the field edge, a gateway)

--- Is the vehicle at its course's field (on it, or within FIELD_NEAR m)? And how far from it it is (m)
function GuidanceVehicle:guidanceAtCourseField()
    local course = getSpec(self).course
    local outline = course and course.outline
    if outline == nil or #outline < 3 then return true, 0 end
    local poly = {}
    for i, p in ipairs(outline) do poly[i] = {x = p.x, y = p.z} end
    local x, _, z = getWorldTranslation(self.rootNode)
    if GuidanceGeo.pointInPolygon({x = x, y = z}, poly) then return true, 0 end
    local d = GuidanceGeo.distToPolygon({x = x, y = z}, poly)
    return d <= GuidanceVehicle.FIELD_NEAR, d
end

--- The vehicle sent to a saved course (entryId; 0: the course it has): loaded, and there by itself when close, else
--- the implements folded and AutoDrive takes it to the course's marker and starts us on arrival. On a client it asks
--- the server.
function GuidanceVehicle:guidanceGoTo(entryId, noEventSend)
    if g_server == nil then
        if not noEventSend then GuidanceGoEvent.sendEvent(self, entryId) end
        return
    end
    local spec = getSpec(self)
    if entryId ~= 0 then
        local entry = GuidanceLibrary.getEntry(entryId)
        if entry == nil then return end
        if self:getIsGuidanceActive() then self:guidanceStop() end
        self:guidanceSetPlan(entry.plan:copy())
    end
    self:guidanceSetInfoText("FINISHED", false)
    self:guidanceSetInfoText("NEXT_FIELD_WAITING", false)
    if spec.course == nil then return end
    local x, _, z = getWorldTranslation(self.rootNode)
    local first = spec.course.waypoints[1]
    if math.sqrt((first.x - x) ^ 2 + (first.z - z) ^ 2) <= GuidanceVehicle.QUEUE_NEAR then
        self:guidanceStart(self:guidanceGetStart())
    elseif not GuidanceVehicle.autoDriveTo(self) then
        self:guidanceSetInfoText("NEXT_FIELD_WAITING", true)
    end
end

--- Server: after a course is done, on to the next one of the queue
function GuidanceVehicle.updateQueue(self)
    local spec = getSpec(self)
    if spec.queueState == "folding" then
        -- the implements folding for the road: AutoDrive sets off once they are
        if GuidanceVehicle.isFoldedForRoad(self) or (g_time or 0) > (spec.queueSince or 0) + GuidanceVehicle.FOLD_TIMEOUT then
            GuidanceVehicle.autoDriveSetOff(self)
        end
        return
    end
    if spec.queueState == "autodrive" then
        -- AutoDrive is taking us there: once it has stopped, it has started us (its helper button); if it didn't
        -- (stopped short of the marker, Courseplay installed), we start ourselves. Its button back as it was.
        local active = self.ad and self.ad.stateModule and self.ad.stateModule:isActive()
        if active then
            spec.queueSeenDriving = true
        elseif spec.queueSeenDriving or (g_time or 0) > (spec.queueSince or 0) + 5000 then
            spec.queueState = nil
            if not self:getIsHelperDriving() then
                self:guidanceStart(self:guidanceGetStart())
            end
            spec.goStart = nil
            local sm = self.ad and self.ad.stateModule
            if sm and sm.setStartHelper and not spec.adHelperBefore then
                Guidance.try(sm.setStartHelper, sm, false)
            end
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
    -- AutoDrive to the course's marker, starting us there
    if GuidanceVehicle.autoDriveTo(self) then
        return
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
    -- AutoDrive brought it to a new course (Go, the queue): where the start setting says
    if spec.goStart then
        spec.goStart = nil
        return self:guidanceStart(self:guidanceGetStart())
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
    if driver and driver.holdForAutoDrive then
        driver:holdForAutoDrive(ms)
    elseif driver and driver.hold then
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
    streamWriteUInt16(streamId, bits)
    streamWriteBool(streamId, spec.paused == true)
    -- what a helper without a course is doing (GuidanceVehicle.HELPER_PHASES, 0 nothing)
    streamWriteUInt8(streamId, spec.helperPhase or 0)
end

--- notify: tell the player about statuses that just came on (not when joining a game)
local function readInfoBits(vehicle, spec, streamId, notify)
    local bits = streamReadUInt16(streamId)
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
    local ok, tx, tz, forwards, maxSpeed = Guidance.try(driver.getDriveData, driver, dt)
    if not ok then
        Guidance.info("%s: helper stopped: %s", Guidance.vehicleName(self), tostring(tx))
        spec.helperDriver = nil
        self:stopCurrentAIJob(AIMessageErrorBlockedByObject.new())
        return
    end
    if spec.helperDriver == nil or tx == nil then
        return
    end
    driver.debugTarget = {tx, tz, maxSpeed}
    GuidanceVehicle.saveFuel(self, spec, dt, maxSpeed)
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
        GuidanceAutoDrive.updateResume(self, getSpec(self), dt)
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

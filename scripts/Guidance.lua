-- CourseCorrect (FS25_CourseCorrect; called Guidance before 0.5, the code's names still are): field work helper for
-- Farming Simulator 25.
-- Bootstrap: adds the vehicle specialization, registers the AI job and messages, forwards draw and mouse events
-- to the HUD.

Guidance = {
    MOD_NAME = g_currentModName,
    MOD_DIR = g_currentModDirectory,
    SPEC_NAME = g_currentModName .. ".guidance",
    VERSION = "1.0.8.7",
    -- the name players see
    TITLE = "CourseCorrect",
    -- the mod's name before 0.5: its data is read once, and it must not be loaded as well
    OLD_MOD_NAME = "FS25_Guidance",
}

-- errors in calls that may fail (other mods' functions, the game's for an odd implement, a frame of our own): written
-- to the log (each one once, at most ERRORS of them), and the caller carries on
Guidance.ERRORS = 50
Guidance.errorsSeen, Guidance.errorCount = {}, 0

function Guidance.onError(err)
    local text = tostring(err)
    if not Guidance.errorsSeen[text] and Guidance.errorCount < Guidance.ERRORS then
        Guidance.errorsSeen[text] = true
        Guidance.errorCount = Guidance.errorCount + 1
        print("CourseCorrect: error (carried on): " .. text)
        if GuidanceDebug then GuidanceDebug.remember("error: " .. text) end
    end
    return err
end

--- Calls fn(...); an error in it is logged (see onError) instead of stopping us. Returns true and fn's results, or
--- false and the error
function Guidance.try(fn, ...)
    local n, args = select("#", ...), {...}
    return xpcall(function() return fn(unpack(args, 1, n)) end, Guidance.onError)
end

function Guidance.info(fmt, ...)
    local line = string.format(fmt, ...)
    print("CourseCorrect: " .. line)
    if GuidanceDebug then GuidanceDebug.remember(line) end
end

function Guidance.debug(fmt, ...)
    -- (kept for a problem report even when not printed)
    local ok, line = Guidance.try(string.format, fmt, ...)
    if not ok then return end
    if GuidanceDebug then GuidanceDebug.remember(line) end
    if Guidance.debugEnabled then
        print("CourseCorrect [dbg]: " .. line)
    end
end

--- The old Guidance mod is loaded too: then this one stays out of the way (both would add the same helper to every
--- vehicle)
function Guidance.oldModLoaded()
    return Guidance.MOD_NAME ~= Guidance.OLD_MOD_NAME and g_modIsLoaded[Guidance.OLD_MOD_NAME] == true
end

function Guidance.vehicleName(vehicle)
    return vehicle and vehicle.getName and vehicle:getName() or "?"
end

-- how a status shows as a notification: the game's notification types by status name
Guidance.NOTIFY = {
    FINISHED = "INGAME_NOTIFICATION_OK",
    IS_STUCK = "INGAME_NOTIFICATION_CRITICAL",
    FUEL_IS_EMPTY = "INGAME_NOTIFICATION_CRITICAL",
    NEEDS_UNLOADING = "INGAME_NOTIFICATION_INFO",
    NEEDS_FILLING = "INGAME_NOTIFICATION_INFO",
    FUEL_IS_LOW = "INGAME_NOTIFICATION_INFO",
    NEXT_FIELD_WAITING = "INGAME_NOTIFICATION_INFO",
    WAITING_RAIN = "INGAME_NOTIFICATION_INFO",
    NO_UNLOADER = "INGAME_NOTIFICATION_CRITICAL",
    SERVICE_FUEL = "INGAME_NOTIFICATION_INFO",
    SERVICE_REPAIR = "INGAME_NOTIFICATION_INFO",
    HANDED_OVER = "INGAME_NOTIFICATION_OK",
}

--- Tells the player (if it is their farm's vehicle) that a helper got a status: finished, full, stuck...
function Guidance.notify(vehicle, name)
    local mission = g_currentMission
    if mission == nil or mission.addIngameNotification == nil or g_client == nil then
        return
    end
    if GuidancePrefs and GuidancePrefs.notifications == false then
        return
    end
    -- and a sound (if the player wants that): the game's error sound for trouble, its notification sound else
    if GuidancePrefs == nil or GuidancePrefs.soundAlerts ~= false then
        Guidance.try(function()
            local samples = GuiSoundPlayer and GuiSoundPlayer.SOUND_SAMPLES
            if samples and g_gui and g_gui.soundPlayer then
                local critical = Guidance.NOTIFY[name] == "INGAME_NOTIFICATION_CRITICAL"
                local sample = critical and (samples.ERROR or samples.FAIL) or (samples.NOTIFICATION or samples.CLICK)
                if sample then g_gui.soundPlayer:playSample(sample) end
            end
        end)
    end
    if vehicle.getOwnerFarmId == nil or vehicle:getOwnerFarmId() ~= mission:getFarmId() then
        return
    end
    local typeName = Guidance.NOTIFY[name]
    if typeName == nil then
        return
    end
    local notificationType = FSBaseMission[typeName] or FSBaseMission.INGAME_NOTIFICATION_INFO
    mission:addIngameNotification(notificationType, string.format("%s: %s", Guidance.vehicleName(vehicle),
        g_i18n:getText("guidance_info_" .. name)))
end

--- Courseplay registers the same AutoDrive interface (cpStartStopDriver, onCpFull...), only one may provide it
function Guidance.providesAutoDriveInterface()
    return not g_modIsLoaded["FS25_Courseplay"]
end

-- every vehicle that can have the game's field work helper gets Guidance
local function addSpecialization(typeManager)
    if typeManager.typeName ~= "vehicle" or not g_modIsLoaded[Guidance.MOD_NAME] then
        return
    end
    if Guidance.oldModLoaded() then
        print("CourseCorrect: FS25_Guidance.zip (its old name) is loaded too: CourseCorrect is off. Remove FS25_Guidance.zip.")
        return
    end
    for typeName, typeEntry in pairs(typeManager.types) do
        if SpecializationUtil.hasSpecialization(AIFieldWorker, typeEntry.specializations)
                and SpecializationUtil.hasSpecialization(Drivable, typeEntry.specializations) then
            typeManager:addSpecialization(typeName, Guidance.SPEC_NAME)
        end
    end
end
TypeManager.finalizeTypes = Utils.prependedFunction(TypeManager.finalizeTypes, addSpecialization)

-----------------------------------------------------------------------------------------------------------------------
-- AI messages
-----------------------------------------------------------------------------------------------------------------------

-- The game has no message for a full implement, AutoDrive needs to know it to unload
AIMessageGuidanceIsFull = {}
local AIMessageGuidanceIsFull_mt = Class(AIMessageGuidanceIsFull, AIMessage)
AIMessageGuidanceIsFull.name = "GUIDANCE_IS_FULL"
function AIMessageGuidanceIsFull.new(customMt)
    return AIMessage.new(customMt or AIMessageGuidanceIsFull_mt)
end
function AIMessageGuidanceIsFull:getI18NText()
    return g_i18n:getText("guidance_msg_isFull")
end

AIMessageGuidanceNoCourse = {}
local AIMessageGuidanceNoCourse_mt = Class(AIMessageGuidanceNoCourse, AIMessage)
AIMessageGuidanceNoCourse.name = "GUIDANCE_NO_COURSE"
function AIMessageGuidanceNoCourse.new(customMt)
    return AIMessage.new(customMt or AIMessageGuidanceNoCourse_mt)
end
function AIMessageGuidanceNoCourse:getI18NText()
    return g_i18n:getText("guidance_msg_noCourse")
end

-- in multiplayer the game looks messages and jobs up by class, which fails for mod classes: fall back to the name
AIMessageManager.getMessageIndex = Utils.overwrittenFunction(AIMessageManager.getMessageIndex,
    function(manager, superFunc, message, ...)
        local ix = superFunc(manager, message, ...)
        if ix == nil and message ~= nil and message.name ~= nil and manager.nameToIndex ~= nil then
            ix = manager.nameToIndex[message.name]
        end
        return ix
    end)

AIJobTypeManager.getJobTypeIndex = Utils.overwrittenFunction(AIJobTypeManager.getJobTypeIndex,
    function(manager, superFunc, job, ...)
        local ix = superFunc(manager, job, ...)
        if ix == nil and job ~= nil and job.name ~= nil and manager.nameToIndex ~= nil then
            ix = manager.nameToIndex[job.name]
        end
        return ix
    end)

--- The vehicle the game's own field work helper (its job type FIELDWORK, not another mod's helper built on it) is
--- being started for, or nil
function Guidance.gameFieldWorkVehicle(job)
    if Guidance.disabled or job == nil or job.vehicleParameter == nil or job.vehicleParameter.getVehicle == nil then
        return nil
    end
    local ok, typeName = Guidance.try(function()
        local m = g_currentMission.aiJobTypeManager
        local jobType = m:getJobTypeByIndex(m:getJobTypeIndex(job))
        return jobType and jobType.name
    end)
    if not ok or typeName ~= "FIELDWORK" then
        return nil
    end
    return job.vehicleParameter:getVehicle()
end

-- the game's own field work helper hired for a vehicle with a CourseCorrect course at its field (the hire key starts
-- the job the savegame remembers; AutoDrive set to the game's helper): CourseCorrect works the course instead
AISystem.startJob = Utils.overwrittenFunction(AISystem.startJob, function(system, superFunc, job, farmId, ...)
    local vehicle = Guidance.gameFieldWorkVehicle(job)
    if vehicle ~= nil and vehicle.guidanceTakeOver ~= nil then
        local ok, took = Guidance.try(function() return vehicle:guidanceTakeOver() end)
        if ok and took then
            return
        end
    end
    return superFunc(system, job, farmId, ...)
end)

-----------------------------------------------------------------------------------------------------------------------
-- Mod event listener
-----------------------------------------------------------------------------------------------------------------------

function Guidance:loadMap()
    local mission = g_currentMission
    if Guidance.oldModLoaded() then
        Guidance.disabled = true
        if g_client ~= nil and mission.addIngameNotification then
            mission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_CRITICAL,
                g_i18n:getText("guidance_oldModLoaded"))
        end
        return
    end
    mission.aiMessageManager:registerMessage(AIMessageGuidanceIsFull.name, AIMessageGuidanceIsFull)
    mission.aiMessageManager:registerMessage(AIMessageGuidanceNoCourse.name, AIMessageGuidanceNoCourse)
    mission.aiJobTypeManager:registerJobType(GuidanceJob.name, g_i18n:getText("guidance_jobTitle"), GuidanceJob)
    -- the helpers without a course: unloader, bale collector, silo compacter
    mission.aiJobTypeManager:registerJobType(GuidanceBaleJob.name, g_i18n:getText("guidance_helper_bales"), GuidanceBaleJob)
    mission.aiJobTypeManager:registerJobType(GuidanceSiloJob.name, g_i18n:getText("guidance_helper_silo"), GuidanceSiloJob)
    mission.aiJobTypeManager:registerJobType(GuidanceShovelJob.name, g_i18n:getText("guidance_helper_shovel"), GuidanceShovelJob)
    if g_client ~= nil then
        GuidancePrefs.load()
        self.hud = GuidanceHud.new()
    end
    if g_server ~= nil then
        GuidanceLibrary.load()
    end
    addConsoleCommand("ccDebug", "CourseCorrect: toggle debug output", "consoleToggleDebug", self)
    addConsoleCommand("ccOverlay", "CourseCorrect: toggle the debug overlay", "consoleToggleOverlay", self)
    Guidance.info("%s loaded, AutoDrive interface %s", Guidance.VERSION,
        Guidance.providesAutoDriveInterface() and "on" or "off (Courseplay is installed)")
end

function Guidance:deleteMap()
    if self.hud then
        self.hud:delete()
        self.hud = nil
    end
    removeConsoleCommand("ccDebug")
    removeConsoleCommand("ccOverlay")
end

function Guidance:consoleToggleDebug()
    Guidance.debugEnabled = not Guidance.debugEnabled
    return "CourseCorrect debug " .. (Guidance.debugEnabled and "on" or "off")
end

function Guidance:consoleToggleOverlay()
    GuidancePrefs.set("debugOverlay", not GuidancePrefs.debugOverlay)
    return "CourseCorrect debug overlay " .. (GuidancePrefs.debugOverlay and "on" or "off")
end

function Guidance:draw()
    if GuidancePrefs and GuidancePrefs.debugOverlay and GuidanceDebug and not g_gui:getIsGuiVisible() then
        local ok, err = Guidance.try(GuidanceDebug.draw)
        if not ok and not self.overlayFailed then
            self.overlayFailed = true
            Guidance.info("overlay: %s", tostring(err))
        end
    end
    if self.hud and not g_gui:getIsGuiVisible() and not g_noHudModeEnabled then
        -- the alerts (a broken one must not take the panel with it)
        local ok, err = Guidance.try(self.hud.drawAlerts, self.hud)
        if not ok and not self.alertsFailed then
            self.alertsFailed = true
            Guidance.info("alerts: %s", tostring(err))
        end
        self.hud:draw()
    end
end

function Guidance:mouseEvent(posX, posY, isDown, isUp, button)
    if self.hud and not g_gui:getIsGuiVisible() then
        self.hud:mouseEvent(posX, posY, isDown, isUp, button)
    end
end

function Guidance:update(dt)
    if Guidance.disabled then
        return
    end
    -- a player who joined asks the server for the saved courses, once
    if g_server == nil and g_client ~= nil and not self.libraryRequested then
        self.libraryRequested = true
        GuidanceLibraryEvent.toServer(GuidanceLibraryEvent.REQUEST, nil)
    end
    if self.hud then
        self.hud:update(dt)
    end
end

-- the saved courses are saved with the savegame (on the server)
if ItemSystem ~= nil and ItemSystem.save ~= nil then
    ItemSystem.save = Utils.prependedFunction(ItemSystem.save, function()
        -- (not when switched off: an empty file would hide the old name's one)
        if g_server ~= nil and GuidanceLibrary ~= nil and not Guidance.disabled then
            GuidanceLibrary.save()
        end
    end)
end

-- the courses on the big map: drawn with the mission, like the map page
if BaseMission ~= nil and BaseMission.draw ~= nil then
    BaseMission.draw = Utils.appendedFunction(BaseMission.draw, function()
        if g_client ~= nil and GuidanceMap ~= nil then
            GuidanceMap.draw()
        end
    end)
end

addModEventListener(Guidance)

-- Stand-ins for the parts of the FS25 engine and game API Guidance uses, just enough to load the mod and drive a
-- course outside the game. Behaviour is simplified; the real game may differ.

g_currentModName = "FS25_CourseCorrect"
g_currentModDirectory = ""
g_modIsLoaded = {FS25_CourseCorrect = true}
g_server = {broadcastEvent = function() end}
g_client = nil
g_dedicatedServer = nil
g_screenWidth, g_screenHeight, g_screenAspectRatio = 1920, 1080, 16 / 9

LOG = {}
function log(fmt, ...) table.insert(LOG, string.format(fmt, ...)) end
print = function(s) table.insert(LOG, tostring(s)) end

function Class(members, baseClass)
    members = members or {}
    local mt = {__index = members}
    if baseClass then setmetatable(members, {__index = baseClass}) end
    members.superClass = function() return baseClass end
    members.isa = function(self, other)
        local c = members
        while c do
            if c == other then return true end
            local m = getmetatable(c)
            c = m and m.__index or nil
        end
        return false
    end
    return mt
end
function InitEventClass() end

Utils = {
    overwrittenFunction = function(old, new) return function(self, ...) return new(self, old, ...) end end,
    prependedFunction = function(old, new) return function(...) new(...); return old(...) end end,
    appendedFunction = function(old, new) return function(...) old(...); return new(...) end end,
}

Event = {}
function Event.new(mt) return setmetatable({}, mt) end

AIMessage = {}
local AIMessage_mt = Class(AIMessage)
function AIMessage.new(mt) return setmetatable({}, mt or AIMessage_mt) end
local function message(name)
    local c = {}
    local mt = Class(c, AIMessage)
    c.name = name
    c.new = function() return setmetatable({}, mt) end
    _G[name] = c
end
for _, n in ipairs({"AIMessageSuccessFinishedJob", "AIMessageSuccessStoppedByUser", "AIMessageErrorOutOfFill",
                    "AIMessageErrorOutOfFuel", "AIMessageErrorVehicleBroken", "AIMessageErrorBlockedByObject"}) do
    message(n)
end

AIMessageManager = {getMessageIndex = function() return 1 end}
AIJobTypeManager = {getJobTypeIndex = function() return 1 end}
TypeManager = {finalizeTypes = function() end}
function addModEventListener(l) MOD_LISTENER = l end
function addConsoleCommand() end
function removeConsoleCommand() end

AIJob = {START_SUCCESS = 0}
local AIJob_mt = Class(AIJob)
function AIJob.new(isServer, mt)
    local self = setmetatable({}, mt or AIJob_mt)
    self.isServer = isServer
    self.namedParameters, self.groupedParameters, self.tasks = {}, {}, {}
    self.currentTaskIndex = 0
    return self
end
function AIJob:addNamedParameter(name, p) table.insert(self.namedParameters, {name = name, parameter = p}) end
function AIJob:addTask(t) table.insert(self.tasks, t); t.taskIndex = #self.tasks end
function AIJob:resetTasks() for _, t in ipairs(self.tasks) do t:reset() end end
function AIJob:applyCurrentState(vehicle, mission, farmId, isDirectStart) self.isDirectStart = isDirectStart end
function AIJob:stop(msg)
    -- as the game: the job's running task stops with it
    for _, t in ipairs(self.tasks or {}) do
        if t.isRunning and t.stop then t:stop(true) end
    end
    self.isRunning = false
end
function AIJob:saveToXMLFile() end
function AIJob:loadFromXMLFile() end
AIJobFieldWork = {START_ERROR_VEHICLE_DELETED = 1, START_ERROR_NO_PERMISSION = 2, START_ERROR_VEHICLE_IN_USE = 3,
                  START_ERROR_LIMIT_REACHED = 4}

AIParameterVehicle = {}
function AIParameterVehicle.new()
    return {setVehicle = function(self, v) self.vehicle = v end, getVehicle = function(self) return self.vehicle end}
end
AIParameterGroup = {}
function AIParameterGroup.new() return {addParameter = function() end} end

g_i18n = {getText = function(_, key) return key end}
g_helperManager = {availableHelpers = {1}, getRandomHelper = function() return {index = 1} end}

XMLValueType = {INT = "INT", FLOAT = "FLOAT", BOOL = "BOOL", STRING = "STRING"}
Vehicle = {xmlSchemaSavegame = {register = function() end}}
VehicleStateChange = {AI_START_LINE = 1, AI_END_LINE = 2}
AttacherJoints = {JOINTTYPE_IMPLEMENT = 1, JOINTTYPE_CUTTER = 2, JOINTTYPE_CUTTERHARVESTER = 3, JOINTTYPE_TRAILER = 4}
VehiclePropertyState = {SHOP_CONFIG = 99}
AIFieldWorker = {TRAFFIC_COLLISION = 0}
Drivable = {}
RenderText = {ALIGN_LEFT = 0, ALIGN_CENTER = 1, ALIGN_RIGHT = 2}
InputAction = {GUIDANCE_TOGGLE_HUD = 1, GUIDANCE_START_STOP = 2}

SpecializationUtil = {}
function SpecializationUtil.hasSpecialization() return true end
function SpecializationUtil.registerEvent(vt, name) vt.events[name] = true end
function SpecializationUtil.registerFunction(vt, name, fn) vt.functions[name] = fn end
function SpecializationUtil.registerEventListener(vt, name, spec) vt.listeners[name] = spec[name] end
function SpecializationUtil.raiseEvent(vehicle, name, ...)
    table.insert(vehicle.raisedEvents, name)
end

-- streams: a plain list
function streamWriteBool(s, v) table.insert(s, v and true or false) return v end
local function w(s, v) table.insert(s, v) end
streamWriteInt32, streamWriteFloat32, streamWriteInt8, streamWriteUInt8, streamWriteString, streamWriteUInt16 = w, w, w, w, w, w
local function r(s) s.pos = (s.pos or 0) + 1 return s[s.pos] end
streamReadBool, streamReadInt32, streamReadFloat32, streamReadInt8, streamReadUInt8, streamReadString, streamReadUInt16 = r, r, r, r, r, r, r
function bitAND(a, b)
    local result, bit = 0, 1
    while a > 0 and b > 0 do
        if a % 2 == 1 and b % 2 == 1 then result = result + bit end
        a, b, bit = math.floor(a / 2), math.floor(b / 2), bit * 2
    end
    return result
end

-- world: nodes are tables {x, z, heading}
function getWorldTranslation(node) return node.x, 0, node.z end
function localDirectionToWorld(node, x, y, z)
    -- only (0, 0, 1) is used: the node's forward direction
    return math.cos(node.h), 0, math.sin(node.h)
end
function localToLocal(node, ref, x, y, z)
    -- markers are stored with their offset along the vehicle
    return node.lx or 0, 0, node.lz or 0
end
function getTerrainHeightAtWorldPos() return 0 end

-- fields, filled by the test
FIELDS = {}
g_fieldManager = {getFields = function() return FIELDS end}
g_farmlandManager = {
    getFarmlandAtWorldPosition = function(_, x, z)
        return {getField = function() return FIELDS[1] end}
    end,
}
function makeField(id, flat)
    local field = {
        getId = function() return id end,
        getDensityMapPolygon = function()
            return {getVerticesList = function() return flat end}
        end,
    }
    table.insert(FIELDS, field)
    return field
end

g_currentMission = {
    missionInfo = {helperBuySeeds = true, helperBuyFertilizer = true, helperBuyFuel = true},
    aiMessageManager = {registerMessage = function() end},
    aiJobTypeManager = {
        registerJobType = function(self, name, title, class) AIJobType = {[name] = 1}; self.class = class end,
        createJob = function(self, typeIx) return self.class.new(true) end,
    },
    aiSystem = {startJob = function(_, job, farmId) STARTED_JOB = job end},
    showBlinkingWarning = function(_, text) log("WARNING %s", text) end,
    terrainRootNode = 0,
    getFarmId = function() return 1 end,
    addIngameNotification = function(_, kind, text) table.insert(NOTES, text) end,
}
NOTES = {}
FSBaseMission = {INGAME_NOTIFICATION_OK = 1, INGAME_NOTIFICATION_INFO = 2, INGAME_NOTIFICATION_CRITICAL = 3}

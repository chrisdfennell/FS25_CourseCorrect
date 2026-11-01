-- Guidance: the player's own defaults (on this PC, modSettings/FS25_CourseCorrect.xml, with where the panel is). A
-- vehicle that never had Guidance settings starts with these; some only live here (notifications, remembering
-- settings per field).

GuidancePrefs = {
    -- the panel's place (left, top; screen 0..1), nil: the default place
    panelX = nil, panelTop = nil,
    -- defaults for courses
    minHeadlandWidth = 40,
    -- 2: saved with automatic headlands at least 40 m (before: 30 m)
    headlandRev = 2,
    autoResume = true,
    workSpeedMax = 0,
    turnSpeed = 10,
    reverseSpeed = 5,
    lights = 1,
    soundAlerts = true,
    -- the alerts on the screen: shown, where (left, top; nil the default place)
    alertsOnScreen = true,
    alertsX = nil, alertsTop = nil,
    lowerLate = 0,
    raiseLate = 0,
    roundedPasses = 1,
    keepLowered = false,
    keepRunning = false,
    takeOver = true,
    startMode = 1,
    startAfter = 3,
    clockwise = true,
    headlandsFirst = true,
    pattern = 3,
    -- the player's own
    rememberFields = true,
    -- the panel's size (1 = normal)
    panelScale = 1,
    notifications = true,
    -- the debug overlay (the helpers' ways and thinking drawn in the world)
    debugOverlay = false,
    -- how high above the ground the course lines are drawn in the world (m; up to see them over tall crops)
    lineHeight = 0.25,
    -- Precision Farming in the planner's amounts: true = when it is installed (automatic), false = never
    precisionFarming = true,
}
local Prefs = GuidancePrefs

-- name, kind: what is saved
Prefs.FIELDS = {
    {"panelX", "FLOAT"}, {"panelTop", "FLOAT"}, {"minHeadlandWidth", "FLOAT"}, {"headlandRev", "INT"}, {"debugOverlay", "BOOL"}, {"precisionFarming", "BOOL"}, {"roundedPasses", "INT"},
    {"keepLowered", "BOOL"}, {"startMode", "INT"}, {"startAfter", "INT"}, {"clockwise", "BOOL"}, {"headlandsFirst", "BOOL"},
    {"pattern", "INT"}, {"rememberFields", "BOOL"}, {"notifications", "BOOL"}, {"lowerLate", "FLOAT"},
    {"panelScale", "FLOAT"}, {"autoResume", "BOOL"}, {"workSpeedMax", "FLOAT"}, {"turnSpeed", "FLOAT"},
    {"reverseSpeed", "FLOAT"}, {"lights", "INT"}, {"soundAlerts", "BOOL"}, {"alertsOnScreen", "BOOL"},
    {"alertsX", "FLOAT"}, {"alertsTop", "FLOAT"},
    {"raiseLate", "FLOAT"}, {"lineHeight", "FLOAT"}, {"keepRunning", "BOOL"}, {"takeOver", "BOOL"},
}

-- the heights the course lines can be drawn at (m above the ground): on it, 1 m, 2.5 m (8 ft, over maize), 4 m
Prefs.LINE_HEIGHTS = {0.25, 1, 2.5, 4}

-- the ones that are course settings, given to a vehicle that has none yet
Prefs.PLAN_DEFAULTS = {"minHeadlandWidth", "roundedPasses", "keepLowered", "keepRunning", "takeOver", "lowerLate", "raiseLate", "autoResume",
                       "workSpeedMax", "turnSpeed", "reverseSpeed", "lights",
                       "startMode", "startAfter",
                       "clockwise", "headlandsFirst",
                       "pattern"}

local function path()
    if getUserProfileAppPath == nil then
        return nil
    end
    return getUserProfileAppPath() .. "modSettings/FS25_CourseCorrect.xml"
end

function Prefs.load()
    local p = path()
    -- not saved under the new name yet: the old name's (Guidance)
    if p ~= nil and not fileExists(p) and fileExists(getUserProfileAppPath() .. "modSettings/FS25_Guidance.xml") then
        p = getUserProfileAppPath() .. "modSettings/FS25_Guidance.xml"
    end
    if p == nil or not fileExists(p) then
        return
    end
    local xml = loadXMLFile("guidancePrefs", p)
    if xml == nil or xml == 0 then
        return
    end
    for _, f in ipairs(Prefs.FIELDS) do
        local key = "guidance.prefs#" .. f[1]
        local v
        if f[2] == "FLOAT" then v = getXMLFloat(xml, key)
        elseif f[2] == "INT" then v = getXMLInt(xml, key)
        else v = getXMLBool(xml, key) end
        if v ~= nil then Prefs[f[1]] = v end
    end
    -- saved before automatic headlands were 40 m: the old 30 m default becomes the new one
    if getXMLInt(xml, "guidance.prefs#headlandRev") == nil and Prefs.minHeadlandWidth == 30 then
        Prefs.minHeadlandWidth = 40
    end
    Prefs.headlandRev = 2
    -- (earlier versions kept the panel's place here)
    Prefs.panelX = Prefs.panelX or getXMLFloat(xml, "guidance.panel#x")
    Prefs.panelTop = Prefs.panelTop or getXMLFloat(xml, "guidance.panel#top")
    delete(xml)
end

function Prefs.save()
    local p = path()
    if p == nil then
        return
    end
    createFolder(getUserProfileAppPath() .. "modSettings/")
    local xml = createXMLFile("guidancePrefs", p, "guidance")
    if xml == nil or xml == 0 then
        return
    end
    for _, f in ipairs(Prefs.FIELDS) do
        local v = Prefs[f[1]]
        local key = "guidance.prefs#" .. f[1]
        if v ~= nil then
            if f[2] == "FLOAT" then setXMLFloat(xml, key, v)
            elseif f[2] == "INT" then setXMLInt(xml, key, v)
            else setXMLBool(xml, key, v) end
        end
    end
    saveXMLFile(xml)
    delete(xml)
end

function Prefs.set(name, value)
    Prefs[name] = value
    Prefs.save()
end

--- Gives settings that were never changed the player's defaults
function Prefs.applyTo(settings)
    for _, name in ipairs(Prefs.PLAN_DEFAULTS) do
        settings[name] = Prefs[name]
    end
end

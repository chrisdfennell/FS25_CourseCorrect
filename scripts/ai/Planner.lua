-- Guidance: what working a course will take: seed, fertiliser / lime / spray, fuel, against what is in the tanks.
-- From the game's own rates (seed per square metre of the crop, the sprayer's rate, the engine's usage at full load);
-- with Precision Farming on the server the way it works the field: its seed rate (by soil, or the one set), its
-- fertiliser and lime by what each spot of the course still needs (or the amount set), from its own maps.

GuidancePlanner = {}
local Planner = GuidancePlanner

Planner.LOAD_WORKING = 0.7 -- share of full load while working
Planner.LOAD_DRIVING = 0.35
Planner.SAMPLE_STEP = 25 -- m of work between Precision Farming samples
Planner.MAX_SAMPLES = 400
Planner.CACHE_TIME = 2000 -- ms

local function vehicles(vehicle)
    return vehicle.getChildVehicles and vehicle:getChildVehicles() or {vehicle}
end

local function level(object, ix)
    if ix == nil or object.getFillUnitFillLevel == nil then return nil end
    return object:getFillUnitFillLevel(ix) or 0
end

local function fillTypeTitle(fillType)
    local desc = g_fillTypeManager and g_fillTypeManager:getFillTypeByIndex(fillType)
    return desc and desc.title or nil, desc and desc.name or ""
end

-----------------------------------------------------------------------------------------------------------------------
-- Precision Farming
-----------------------------------------------------------------------------------------------------------------------

local PF = {}
Planner.PF = PF

function PF.isLoaded()
    return g_modIsLoaded ~= nil and g_modIsLoaded["FS25_precisionFarming"] == true
end

--- Used for the amounts: installed, and the player hasn't switched it off (My defaults)
function PF.isOn()
    return PF.isLoaded() and not (GuidancePrefs ~= nil and GuidancePrefs.precisionFarming == false)
end

--- Precision Farming's own object (its maps), or nil
function PF.instance()
    local ok, inst = Guidance.try(function()
        if type(g_precisionFarming) == "table" then return g_precisionFarming end
        if type(FS25_precisionFarming) == "table" and type(FS25_precisionFarming.g_precisionFarming) == "table" then
            return FS25_precisionFarming.g_precisionFarming
        end
        return nil
    end)
    return ok and inst or nil
end

--- Its seed rates from its settings file: by fruit name {usages = {low, medium, high} (per m²), yields = {soil index
--- -> {3 yields}}}
function PF.seedRates()
    if PF.seedRateCache ~= nil then
        return PF.seedRateCache or nil
    end
    PF.seedRateCache = false
    local dir = g_modNameToDirectory and g_modNameToDirectory["FS25_precisionFarming"]
    local file = dir and (dir .. "PrecisionFarming.xml")
    if file == nil or not fileExists(file) then
        return nil
    end
    local xml = loadXMLFile("guidancePF", file)
    if xml == nil or xml == 0 then
        return nil
    end
    local rates = {}
    local i = 0
    while true do
        local key = string.format("precisionFarming.seedRateMap.fruitTypes.fruitType(%d)", i)
        if not hasXMLProperty(xml, key) then break end
        local name = getXMLString(xml, key .. "#name")
        local usages = {}
        for n in string.gmatch(getXMLString(xml, key .. ".seedRates#usages") or "", "[%d%.]+") do
            usages[#usages + 1] = tonumber(n)
        end
        local yields = {}
        local j = 0
        while true do
            local skey = string.format("%s.soilTypes.soilType(%d)", key, j)
            if not hasXMLProperty(xml, skey) then break end
            local list = {}
            for n in string.gmatch(getXMLString(xml, skey .. "#yields") or "", "[%d%.]+") do list[#list + 1] = tonumber(n) end
            yields[getXMLInt(xml, skey .. "#index") or (j + 1)] = list
            j = j + 1
        end
        if name and #usages > 0 then
            rates[string.upper(name)] = {usages = usages, yields = yields}
        end
        i = i + 1
    end
    delete(xml)
    PF.seedRateCache = rates
    return rates
end

--- The seed rate (1 low, 2 medium, 3 high) Precision Farming's automatic mode takes on a soil: the best yield, the
--- lower rate when two are as good
local function bestRate(entry, soil)
    local yields = soil and entry.yields[soil]
    if yields == nil then return 2 end
    local best = 1
    for r = 2, #yields do
        if yields[r] > yields[best] + 1e-6 then best = r end
    end
    return best
end

--- The seed rate set on a sowing machine (1..3), or nil when it chooses itself
local function manualSeedRate(v)
    local spec = v["spec_FS25_precisionFarming.extendedSowingMachine"]
    if spec == nil or spec.seedRateAutoMode ~= false then
        return nil
    end
    for _, k in ipairs({"manualSeedRate", "seedRateManual", "seedRate", "currentSeedRate"}) do
        local r = spec[k]
        if type(r) == "number" and r >= 1 and r <= 3 then return math.floor(r) end
    end
    return nil
end

--- Points to sample the course's remaining work at: list of {x, z}
local function samplePoints(course, remaining)
    local pts = {}
    local wps = course.waypoints
    local fromD = (1 - remaining) * (course.length or 0)
    local nextD = fromD
    local step = math.max(Planner.SAMPLE_STEP, (course.stats.workLength or 0) * remaining / Planner.MAX_SAMPLES)
    for _, w in ipairs(wps) do
        if (w.d or 0) >= nextD and (w.t == "R" or w.t == "H") then
            pts[#pts + 1] = {x = w.x, z = w.z}
            nextD = (w.d or 0) + step
        end
    end
    return pts
end

--- Seed per m² with Precision Farming (fruit name), or nil
local function pfSeedPerSqm(v, fruitName, course, remaining)
    local rates = PF.seedRates()
    local entry = rates and fruitName and rates[string.upper(fruitName)]
    if entry == nil then
        return nil
    end
    local manual = manualSeedRate(v)
    if manual then
        return entry.usages[manual] or entry.usages[2]
    end
    -- automatic: the best rate for the soil at each spot
    local inst = PF.instance()
    local soilMap = inst and inst.soilMap
    if soilMap == nil or soilMap.getTypeIndexAtWorldPos == nil then
        return entry.usages[2] or entry.usages[1]
    end
    local sum, n = 0, 0
    for _, p in ipairs(samplePoints(course, remaining)) do
        local soil = soilMap:getTypeIndexAtWorldPos(p.x, p.z)
        sum = sum + (entry.usages[bestRate(entry, soil)] or entry.usages[2])
        n = n + 1
    end
    return n > 0 and sum / n or entry.usages[2]
end

--- Litres per hectare a Precision Farming sprayer / spreader / seeder's fertiliser part puts out over the course's
--- remaining work: by what each spot still needs (automatic) or the amount set. Returns l/ha, or nil.
local function pfLitersPerHa(v, fillType, fruitIndex, course, remaining)
    local ext = v["spec_FS25_precisionFarming.extendedSprayer"]
    if ext == nil then
        return nil
    end
    local hasLime, hasFertilizer = false, false
    if type(FS25_precisionFarming) == "table" and FS25_precisionFarming.ExtendedSprayer
            and FS25_precisionFarming.ExtendedSprayer.getCurrentSprayerMode then
        hasLime, hasFertilizer = FS25_precisionFarming.ExtendedSprayer.getCurrentSprayerMode(v)
    end
    if hasLime and ext.pHMap then
        local map = ext.pHMap
        if not ext.sprayAmountAutoMode then
            return map:getLimeUsageByStateChange(ext.sprayAmountManual)
        end
        local soilMap = ext.soilMap
        if soilMap == nil or map.getLevelAtWorldPos == nil or map.getOptimalPHValueForSoilTypeIndex == nil then
            return ext.lastLitersPerHectar
        end
        local sum, n = 0, 0
        for _, p in ipairs(samplePoints(course, remaining)) do
            local soil = soilMap:getTypeIndexAtWorldPos(p.x, p.z)
            local states = math.max(0, (map:getOptimalPHValueForSoilTypeIndex(soil) or 0) - (map:getLevelAtWorldPos(p.x, p.z) or 0))
            sum = sum + (states > 0 and map:getLimeUsageByStateChange(states) or 0)
            n = n + 1
        end
        return n > 0 and sum / n or nil
    end
    if hasFertilizer and ext.nitrogenMap then
        local map = ext.nitrogenMap
        if not ext.sprayAmountAutoMode then
            return map:getFertilizerUsageByStateChange(ext.sprayAmountManual, fillType)
        end
        local soilMap = ext.soilMap
        if soilMap == nil or fruitIndex == nil or fruitIndex == 0 or map.getLevelAtWorldPos == nil
                or map.getNitrogenTargetLevel == nil then
            -- no crop to fertilise for yet: what it put out last (0 before it started)
            local last = ext.lastLitersPerHectar
            return last and last > 0 and last or nil
        end
        local sum, n = 0, 0
        for _, p in ipairs(samplePoints(course, remaining)) do
            local soil = soilMap:getTypeIndexAtWorldPos(p.x, p.z)
            local states = math.max(0, (map:getNitrogenTargetLevel(fruitIndex, soil) or 0) - (map:getLevelAtWorldPos(p.x, p.z) or 0))
            sum = sum + (states > 0 and map:getFertilizerUsageByStateChange(states, fillType) or 0)
            n = n + 1
        end
        return n > 0 and sum / n or nil
    end
    return nil
end

--- The crop on the course's field (for what the fertiliser is for), or nil
local function fieldFruit(course)
    local fieldId = course.plan.fieldId or 0
    local field = fieldId > 0 and GuidanceCourse.getField(fieldId)
    if not field then return nil end
    local state = field.getFieldState and field:getFieldState() or field.fieldState
    local ix = type(state) == "table" and (state.fruitTypeIndex or state.currentFruitTypeIndex) or nil
    if ix == nil or ix == 0 or (FruitType and ix == FruitType.UNKNOWN) then return nil end
    return ix
end

-----------------------------------------------------------------------------------------------------------------------

--- What the course needs: list of {kind ("seed", "spray", "fuel"), label (the fill type's name, or nil), needed,
--- have, bought (the helper buys it), pf (by Precision Farming)}. 'remaining' (0..1): the part of the course still
--- to do. Worked out again at most every 2 s.
function Planner.get(vehicle, course, seconds, remaining)
    remaining = remaining or 1
    local cache = Planner.cache and Planner.cache[vehicle]
    local now = g_time or 0
    if cache and cache.course == course and math.abs(cache.remaining - remaining) < 0.005
            and now - cache.time < Planner.CACHE_TIME then
        return cache.list
    end
    local list = Planner.compute(vehicle, course, seconds, remaining)
    Planner.cache = Planner.cache or setmetatable({}, {__mode = "k"})
    Planner.cache[vehicle] = {course = course, remaining = remaining, time = now, list = list}
    return list
end

function Planner.compute(vehicle, course, seconds, remaining)
    local list = {}
    local missionInfo = g_currentMission and g_currentMission.missionInfo or {}
    local st = course.stats
    local pfOn = PF.isOn()
    -- worked area: the worked stretches times the work width
    local area = st.workLength * course.plan.workWidth * remaining
    local workLength = st.workLength * remaining
    for _, v in pairs(vehicles(vehicle)) do
        -- seed
        local sowing = v.spec_sowingMachine
        local seedFruit
        if sowing and sowing.fillUnitIndex then
            local ok, needed, pf = Guidance.try(function()
                local fruitIndex = sowing.seeds and sowing.seeds[sowing.currentSeed]
                local fruit = fruitIndex and g_fruitTypeManager:getFruitTypeByIndex(fruitIndex)
                seedFruit = fruitIndex
                local perSqm = pfOn and fruit and pfSeedPerSqm(v, fruit.name, course, remaining)
                if perSqm then
                    return area * perSqm, true
                end
                return fruit and fruit.seedUsagePerSqm and area * fruit.seedUsagePerSqm or nil, false
            end)
            if ok and needed then
                table.insert(list, {kind = "seed", needed = needed, have = level(v, sowing.fillUnitIndex) or 0,
                                    bought = missionInfo.helperBuySeeds, pf = pf})
            end
        end
        -- fertiliser, lime, spray, manure (a sowing machine's fertiliser too)
        local sprayer = v.spec_sprayer
        if sprayer and v.getSprayerFillUnitIndex then
            local ok, needed, have, fillType, pf = Guidance.try(function()
                local ix = v:getSprayerFillUnitIndex()
                if ix == nil or (sowing and ix == sowing.fillUnitIndex) then return nil end
                local fillType = v:getFillUnitFillType(ix)
                if fillType == nil or (FillType and fillType == FillType.UNKNOWN) then
                    -- empty: what it takes
                    local types = v.getFillUnitSupportedFillTypes and v:getFillUnitSupportedFillTypes(ix)
                    for ft, yes in pairs(types or {}) do
                        if yes then fillType = ft; break end
                    end
                end
                if pfOn then
                    local ok2, lph = Guidance.try(pfLitersPerHa, v, fillType, seedFruit or fieldFruit(course), course, remaining)
                    if ok2 and lph then
                        return lph * area / 10000, level(v, ix), fillType, true
                    end
                end
                local scales = sprayer.usageScale or {}
                local scale = (scales.fillTypeScales and scales.fillTypeScales[fillType]) or scales.default or 1
                local width = scales.workingWidth or course.plan.workWidth
                local sprayType = g_sprayTypeManager and g_sprayTypeManager:getSprayTypeByFillTypeIndex(fillType)
                local litersPerSecond = sprayType and sprayType.litersPerSecond or 1
                -- the game's rate is per second at the speed limit: per metre it doesn't depend on the speed
                return scale * litersPerSecond * width * 3.6 * workLength, level(v, ix), fillType, false
            end)
            if ok and needed then
                local title, name = fillTypeTitle(fillType)
                local fertilizer = name:find("FERTILIZER") or name:find("MANURE") or name == "DIGESTATE"
                table.insert(list, {kind = fertilizer and "fertilizer" or "spray", label = title, needed = needed,
                                    have = have or 0, bought = missionInfo.helperBuyFertilizer, pf = pf})
            end
        end
        -- fuel
        local motor = v.spec_motorized
        if motor and motor.consumers then
            for _, consumer in pairs(motor.consumers) do
                if consumer.usage and consumer.fillUnitIndex and consumer.fillType ~= (FillType and FillType.DEF) then
                    local workHours = st.workLength / math.max(1, course.length) * seconds * remaining / 3600
                    local driveHours = seconds * remaining / 3600 - workHours
                    local needed = consumer.usage * (workHours * Planner.LOAD_WORKING + driveHours * Planner.LOAD_DRIVING)
                    table.insert(list, {kind = "fuel", needed = needed, have = level(v, consumer.fillUnitIndex) or 0,
                                        bought = missionInfo.helperBuyFuel})
                    break
                end
            end
        end
    end
    return list
end

--- Everything that runs out before the end: list of {item, at (part of the course, 0..1)}, the first first
function Planner.shortages(list, remaining)
    local out = {}
    for _, item in ipairs(list) do
        if not item.bought and item.needed > 0 and item.have < item.needed then
            local fraction = (1 - (remaining or 1)) + (remaining or 1) * item.have / item.needed
            out[#out + 1] = {item = item, at = fraction}
        end
    end
    table.sort(out, function(a, b) return a.at < b.at end)
    return out
end

--- The first thing that runs out: item and at what part of the course (0..1), or nil
function Planner.firstShortage(list, remaining)
    local first = Planner.shortages(list, remaining)[1]
    if first then
        return first.item, first.at
    end
    return nil, nil
end

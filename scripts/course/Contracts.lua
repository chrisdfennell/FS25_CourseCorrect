-- CourseCorrect: the farm's contracts (the game's missions) on fields, so the panel can make a tractor's course for
-- one and send it there in one go. The game's own mission data (BetterContracts and the like use the same).

GuidanceContracts = {}
local Contracts = GuidanceContracts

--- What a contract is called ("Harvest wheat", "Sow canola"...)
function Contracts.titleOf(mission)
    local ok, title = Guidance.try(function()
        if mission.getTitle then return mission:getTitle() end
        return mission.type and (mission.type.title or mission.type.name)
    end)
    return (ok and title) or "?"
end

--- The field a contract is on (the game's field id, as our map fields), or nil
function Contracts.fieldIdOf(mission)
    local field = mission and mission.field
    local ok, id = Guidance.try(function() return field and field.getId and field:getId() end)
    return ok and id or nil
end

--- The running contracts of a farm on fields: list of {mission, fieldId, title, area (ha), done (0..1)}, by field
function Contracts.running(farmId)
    local manager = g_missionManager
    if manager == nil or manager.getMissionsByFarmId == nil then return {} end
    local ok, missions = Guidance.try(manager.getMissionsByFarmId, manager, farmId)
    local list = {}
    for _, m in pairs(ok and missions or {}) do
        local running = MissionStatus == nil or m.status == MissionStatus.RUNNING
        local fieldId = running and Contracts.fieldIdOf(m)
        if fieldId then
            local okArea, area = Guidance.try(function() return m.field.getAreaHa and m.field:getAreaHa() end)
            list[#list + 1] = {mission = m, fieldId = fieldId, title = Contracts.titleOf(m),
                               area = okArea and area or nil, done = m.fieldPercentageDone}
        end
    end
    table.sort(list, function(a, b) return a.fieldId < b.fieldId end)
    return list
end

--- The farm's running contract on a field, or nil
function Contracts.onField(farmId, fieldId)
    for _, c in ipairs(Contracts.running(farmId)) do
        if c.fieldId == fieldId then return c end
    end
    return nil
end

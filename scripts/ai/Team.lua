-- Guidance: helpers working one field together (see GuidancePlan.TEAM_*). For "next free row": which rows of a field
-- are taken and which are done, so no two helpers take the same row; a helper finishing a row takes the free one
-- nearest to it. Kept on the server (the helpers drive there), saved with the savegame (GuidanceLibrary).

GuidanceTeam = {
    -- by field id: {done = {[row] = true}, taken = {[row] = vehicle}, signature = text (which rows these are)}
    fields = {},
}
local Team = GuidanceTeam

--- A field's rows as a short text: when the course is made again with other rows, what was done doesn't count
function Team.signature(rows)
    local first, last = rows[1], rows[#rows]
    if first == nil then return "" end
    return string.format("%d:%.0f,%.0f:%.0f,%.0f", #rows, first.a.x, first.a.z, last.b.x, last.b.z)
end

function Team.getField(fieldId, rows)
    local sig = Team.signature(rows or {})
    local f = Team.fields[fieldId]
    if f == nil or (rows and f.signature ~= sig) then
        f = {done = {}, taken = {}, signature = sig}
        Team.fields[fieldId] = f
    end
    return f
end

--- Where a row lies across the field (m, along the normal of its direction): rows next to each other are a work
--- width apart here (their numbers are the driving order, not their place)
local function across(r, dirX, dirZ)
    local mx, mz = (r.a.x + r.b.x) / 2, (r.a.z + r.b.z) / 2
    return -mx * dirZ + mz * dirX
end

--- How many rows there are and how many are done
function Team.count(fieldId, rows)
    local f = Team.getField(fieldId, rows)
    local done = 0
    for _, r in ipairs(rows) do
        if f.done[r.row] then done = done + 1 end
    end
    return done, #rows
end

--- A helper at x, z (facing hx, hz along the row it just finished, at 'lastAcross' across the field; nil: none yet)
--- takes its next row: the free one nearest to it, preferring one far enough over to turn into without backing up
--- (minGap m across). Returns the row and whether to drive it from b to a, or nil when none are left.
function Team.takeRow(fieldId, rows, vehicle, x, z, lastAcross, minGap, mayRestart)
    local f = Team.getField(fieldId, rows)
    if #rows == 0 then return nil end
    -- everything done: a helper started on the finished field (mayRestart) starts it over; one that worked this
    -- round with the others just finishes (on a small field the others may be done with every row while it is
    -- still on its headland passes)
    local done = Team.count(fieldId, rows)
    if done == #rows and next(f.taken) == nil then
        if not mayRestart then return nil end
        f.done = {}
    end
    local first = rows[1]
    local dx, dz = first.b.x - first.a.x, first.b.z - first.a.z
    local len = math.max(math.sqrt(dx * dx + dz * dz), 1e-6)
    dx, dz = dx / len, dz / len
    local best, bestCost, bestReversed
    for _, r in ipairs(rows) do
        if not f.done[r.row] and f.taken[r.row] == nil then
            local da = math.sqrt((r.a.x - x) ^ 2 + (r.a.z - z) ^ 2)
            local db = math.sqrt((r.b.x - x) ^ 2 + (r.b.z - z) ^ 2)
            local reversed = db < da
            local cost = math.min(da, db)
            if lastAcross and minGap and math.abs(across(r, dx, dz) - lastAcross) < minGap - 0.1 then
                -- too close to turn into in one go: only if nothing else is left
                cost = cost + 10000
            end
            if bestCost == nil or cost < bestCost - 0.01 or (math.abs(cost - bestCost) <= 0.01 and r.row < best.row) then
                best, bestCost, bestReversed = r, cost, reversed
            end
        end
    end
    if best then
        f.taken[best.row] = vehicle
        return best, bestReversed, across(best, dx, dz)
    end
    return nil
end

function Team.markDone(fieldId, rows, row)
    local f = Team.getField(fieldId, rows)
    f.done[row] = true
    f.taken[row] = nil
end

--- A helper stops: the rows it had taken but not finished are free again
function Team.release(fieldId, vehicle)
    local f = Team.fields[fieldId]
    if f == nil then return end
    for row, v in pairs(f.taken) do
        if v == vehicle then f.taken[row] = nil end
    end
end

--- Forget what was done on a field (a new team course)
function Team.reset(fieldId)
    Team.fields[fieldId] = nil
end

-----------------------------------------------------------------------------------------------------------------------
-- Making a team's courses (the player's machine): one layout for all, each its own place
-----------------------------------------------------------------------------------------------------------------------

-- the settings that make the field's layout: the first member's, for everybody
Team.LAYOUT_KEYS = {"workWidth", "turnRadius", "runOut", "headlands", "rowAngle", "clockwise", "headlandsFirst",
                    "pattern", "overlap", "allowReverse", "squareCorners", "roundedPasses", "towLength",
                    "minHeadlandWidth"}

--- The members of the team on a field (vehicles of the farm whose course is a team course there), in their order
function Team.membersOn(fieldId)
    local list = {}
    for _, v in ipairs(GuidanceMap.getFarmVehicles()) do
        local plan = v:getGuidancePlan()
        if plan and plan.fieldId == fieldId and (plan.teamMode or 0) ~= GuidancePlan.TEAM_ALONE then
            table.insert(list, v)
        end
    end
    table.sort(list, function(a, b) return a:getGuidancePlan().teamIndex < b:getGuidancePlan().teamIndex end)
    return list
end

--- The team's layout: the first member's settings, its implement's width, the widest turn and longest run-out of
--- all (so every member can drive every turn), the field's own settings
function Team.layout(members, fieldId)
    local leader = members[1]
    local base = leader:getGuidanceSettings():copy()
    local info = GuidanceVehicleInfo.get(leader)
    if base.autoWidth then base.workWidth = info.workWidth end
    if base.autoRadius then base.turnRadius = info.turnRadius end
    base.runOut, base.allowReverse, base.towLength = info.runOut, info.canReverse, info.towLength or 0
    for i = 2, #members do
        local s = members[i]:getGuidanceSettings()
        local mi = GuidanceVehicleInfo.get(members[i])
        base.turnRadius = math.max(base.turnRadius, s.autoRadius and mi.turnRadius or s.turnRadius)
        base.runOut = math.max(base.runOut, mi.runOut or 0)
        base.towLength = math.max(base.towLength, mi.towLength or 0)
        base.allowReverse = base.allowReverse and mi.canReverse
    end
    for name, value in pairs(GuidanceLibrary.fieldSettings[fieldId] or {}) do
        base[name] = value
    end
    base.fieldId = fieldId
    return base
end

--- Work widths of the members that differ from the team's (they would leave gaps or overlap): list of vehicles
function Team.widthMismatches(members, width)
    local list = {}
    for i = 2, #members do
        local s = members[i]:getGuidanceSettings()
        local w = s.autoWidth and GuidanceVehicleInfo.get(members[i]).workWidth or s.workWidth
        if math.abs(w - width) > 0.25 then table.insert(list, members[i]) end
    end
    return list
end

--- Strips: each member gets the strip nearest to it (members sorted across the rows)
local function nearestOrder(members, outline, base)
    local angle = base.rowAngle
    if angle == nil or angle < 0 then
        local ok, course = pcall(GuidanceCourseGenerator.generate, outline, base:getGeneratorSettings())
        angle = ok and course and course.stats.rowAngle or 0
    end
    local a = math.rad(angle)
    local list = {}
    for _, v in ipairs(members) do
        local x, _, z = getWorldTranslation(v.rootNode)
        table.insert(list, {v = v, y = -x * math.sin(a) + z * math.cos(a)})
    end
    table.sort(list, function(p, q) return p.y < q.y end)
    local out = {}
    for i, e in ipairs(list) do out[i] = e.v end
    return out
end

--- Makes the courses of a team on a field (members: vehicles, the first one's settings are the layout). Returns
--- true, or false and an error text.
function Team.makeCourses(members, fieldId, mode)
    if #members == 0 then
        return false, "no tractors"
    end
    local base = Team.layout(members, fieldId)
    local order = members
    if (mode == GuidancePlan.TEAM_STRIPS or mode == GuidancePlan.TEAM_LANDS) and #members > 1 then
        local outline = GuidanceCourse.getFieldOutline(fieldId)
        if outline then
            base.teamMode = GuidancePlan.TEAM_ALONE
            order = nearestOrder(members, outline, base)
        end
    end
    local x, _, z = getWorldTranslation(members[1].rootNode)
    for i, v in ipairs(order) do
        local team = #members > 1 and {base = base, mode = mode, size = #members, index = i, fieldId = fieldId,
                                       startX = x, startZ = z}
            or {base = base, mode = GuidancePlan.TEAM_ALONE, size = 2, index = 1, fieldId = fieldId}
        local ok, err = v:guidanceGenerate(team)
        if not ok then
            return false, string.format("%s: %s", Guidance.vehicleName(v), tostring(err))
        end
    end
    return true
end

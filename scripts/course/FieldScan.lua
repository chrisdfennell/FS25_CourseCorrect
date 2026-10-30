-- Guidance: the field as it is on the ground. Fields made bigger, smaller or new with the landscaping tools (painted
-- field ground) are not in the map's field outline; the scan finds the field ground joined to a point on a grid,
-- then follows its edge, each edge point placed exactly on the change from field to no field.

GuidanceFieldScan = {
    STEP = 2, -- m between samples
    MAX_CELLS = 500000, -- 200 ha: bigger is given up
    SEARCH = 24, -- m: a start point off the field ground looks this far round for it
    REFINE = 5, -- halvings placing an edge point (2 m / 32)
    SIMPLIFY = 0.35, -- m
    MIN_HOLE = 20, -- m²: smaller spots inside are left alone
}
local Scan = GuidanceFieldScan

--- Field ground at x, z (the game's field ground map; painted field ground counts)
function Scan.isField(x, z)
    local y = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, x, 1, z)
    local isOnField = FSDensityMapUtil.getFieldDataAtWorldPosition(x, y, z)
    return isOnField == true
end

--- Can the game tell field ground here?
function Scan.isAvailable()
    return Scan.isFieldAt ~= nil or (FSDensityMapUtil ~= nil and FSDensityMapUtil.getFieldDataAtWorldPosition ~= nil
        and g_currentMission ~= nil and g_currentMission.terrainRootNode ~= nil)
end

--- Field ground that belongs to the map's other fields is not ours (fields touching each other stay apart):
--- returns a function x, z -> true when the point is inside another map field's outline
function Scan.otherFieldTest(ownFieldId)
    local indexes = {}
    return function(x, z)
        if g_farmlandManager == nil then
            return false
        end
        local farmland = g_farmlandManager:getFarmlandAtWorldPosition(x, z)
        local field = farmland and farmland.getField and farmland:getField()
        local id = field and field.getId and field:getId()
        if id == nil or id == ownFieldId then
            return false
        end
        local index = indexes[id]
        if index == nil then
            local outline = GuidanceCourse.getFieldOutline(id)
            index = false
            if outline and #outline >= 3 then
                local poly = {}
                for i, p in ipairs(outline) do poly[i] = {x = p.x, y = p.z} end
                index = GuidanceGeo.outlineIndex(GuidanceGeo.ensureCCW(poly), 10)
            end
            indexes[id] = index
        end
        return index and index:isInside({x = x, y = z}) or false
    end
end

local function key(i, j)
    return (i + 32768) * 65536 + (j + 32768)
end

--- Scans the field ground joined to x, z. ownFieldId: the map field there (its ground may be scanned, not the other
--- fields'). Returns {outline = list of {x, z} (counterclockwise), area (m²), holes = list of polygons {x, z}}, or
--- nil, reason ("none": no field ground near, "big": too big)
function Scan.scan(x, z, ownFieldId)
    local isField = Scan.isFieldAt or Scan.isField
    local other = Scan.otherFieldTest(ownFieldId)
    local function ok(px, pz)
        return isField(px, pz) and not other(px, pz)
    end
    local step = Scan.STEP
    -- the start: here, or the nearest field ground round about
    local x0, z0
    if ok(x, z) then
        x0, z0 = x, z
    else
        for r = step, Scan.SEARCH, step do
            local n = math.max(8, math.floor(2 * math.pi * r / step))
            for k = 0, n - 1 do
                local a = 2 * math.pi * k / n
                local px, pz = x + r * math.cos(a), z + r * math.sin(a)
                if ok(px, pz) then
                    x0, z0 = px, pz
                    break
                end
            end
            if x0 then break end
        end
    end
    if x0 == nil then
        return nil, "none"
    end
    -- every cell of field ground joined to the start (side by side, not only corner to corner)
    local inside = {}
    local queue, head, tail = {{0, 0}}, 1, 1
    inside[key(0, 0)] = true
    local count = 1
    while head <= tail do
        local c = queue[head]
        queue[head] = nil
        head = head + 1
        for _, d in ipairs({{1, 0}, {-1, 0}, {0, 1}, {0, -1}}) do
            local i, j = c[1] + d[1], c[2] + d[2]
            local k = key(i, j)
            if inside[k] == nil then
                local isIn = ok(x0 + i * step, z0 + j * step)
                inside[k] = isIn
                if isIn then
                    count = count + 1
                    if count > Scan.MAX_CELLS then
                        return nil, "big"
                    end
                    tail = tail + 1
                    queue[tail] = {i, j}
                end
            end
        end
    end
    -- the edges between a cell of ours and one that is not, each with ours on its left: from corner to corner
    -- (corner a, b is the bottom left corner of cell a, b)
    local out = {}
    local edges = {}
    local function addEdge(ax, ay, bx, by, ci, cj, ni, nj)
        local e = {a = key(ax, ay), b = key(bx, by), ci = ci, cj = cj, ni = ni, nj = nj, dx = bx - ax, dy = by - ay}
        local list = out[e.a]
        if list == nil then
            list = {}
            out[e.a] = list
        end
        list[#list + 1] = e
        edges[#edges + 1] = e
    end
    for k, isIn in pairs(inside) do
        if isIn then
            local i, j = math.floor(k / 65536) - 32768, k % 65536 - 32768
            if inside[key(i + 1, j)] ~= true then addEdge(i + 1, j, i + 1, j + 1, i, j, i + 1, j) end
            if inside[key(i, j + 1)] ~= true then addEdge(i + 1, j + 1, i, j + 1, i, j, i, j + 1) end
            if inside[key(i - 1, j)] ~= true then addEdge(i, j + 1, i, j, i, j, i - 1, j) end
            if inside[key(i, j - 1)] ~= true then addEdge(i, j, i + 1, j, i, j, i, j - 1) end
        end
    end
    -- the exact change from field to no field between our cell's middle and the other one's
    local function edgePoint(e)
        local ax, az = x0 + e.ci * step, z0 + e.cj * step
        local bx, bz = x0 + e.ni * step, z0 + e.nj * step
        local lo, hi = 0, 1
        for _ = 1, Scan.REFINE do
            local mid = (lo + hi) / 2
            if ok(ax + (bx - ax) * mid, az + (bz - az) * mid) then lo = mid else hi = mid end
        end
        local t = (lo + hi) / 2
        return {x = ax + (bx - ax) * t, y = az + (bz - az) * t}
    end
    -- follow the edges round into closed loops; where two meet at a corner, the sharpest left turn (cells touching
    -- only at a corner are not joined)
    local used = {}
    local loops = {}
    for _, first in ipairs(edges) do
        if not used[first] then
            local loop = {}
            local e = first
            while e and not used[e] do
                used[e] = true
                loop[#loop + 1] = edgePoint(e)
                local nextList = out[e.b]
                local best, bestTurn = nil, nil
                for _, n in ipairs(nextList or {}) do
                    if not used[n] or n == first then
                        -- left turn 1, straight 0, right turn -1
                        local turn = e.dx * n.dy - e.dy * n.dx
                        if best == nil or turn > bestTurn then best, bestTurn = n, turn end
                    end
                end
                e = best
            end
            if #loop >= 3 then loops[#loops + 1] = loop end
        end
    end
    -- the biggest loop is the edge of the field, the others are holes in it
    local outer, outerArea = nil, 0
    for _, loop in ipairs(loops) do
        local a = GuidanceGeo.signedArea(loop)
        if a > outerArea then outer, outerArea = loop, a end
    end
    if outer == nil then
        return nil, "none"
    end
    local poly = GuidanceGeo.removeDuplicates(GuidanceGeo.simplify(outer, Scan.SIMPLIFY), 0.3)
    local result = {outline = {}, area = math.abs(GuidanceGeo.signedArea(poly)), holes = {}}
    for i, p in ipairs(poly) do result.outline[i] = {x = p.x, z = p.y} end
    for _, loop in ipairs(loops) do
        if loop ~= outer and math.abs(GuidanceGeo.signedArea(loop)) >= Scan.MIN_HOLE then
            local hole = {}
            for i, p in ipairs(GuidanceGeo.convexHull(loop)) do hole[i] = {x = p.x, z = p.y} end
            result.holes[#result.holes + 1] = hole
        end
    end
    return result
end

--- Area (m²) of an outline list of {x, z}
function Scan.areaOf(outline)
    local poly = {}
    for i, p in ipairs(outline) do poly[i] = {x = p.x, y = p.z} end
    return math.abs(GuidanceGeo.signedArea(poly))
end

--- Do two outlines cover the same ground (within tolerance m², at least 1 %)? Compared by area and by sampling
--- each one's points against the other.
function Scan.sameGround(a, b, tolerance)
    local areaA, areaB = Scan.areaOf(a), Scan.areaOf(b)
    local tol = math.max(tolerance or 400, 0.01 * math.max(areaA, areaB))
    if math.abs(areaA - areaB) > tol then
        return false
    end
    local polyA, polyB = {}, {}
    for i, p in ipairs(a) do polyA[i] = {x = p.x, y = p.z} end
    for i, p in ipairs(b) do polyB[i] = {x = p.x, y = p.z} end
    local ia = GuidanceGeo.outlineIndex(GuidanceGeo.ensureCCW(polyA), 10)
    local ib = GuidanceGeo.outlineIndex(GuidanceGeo.ensureCCW(polyB), 10)
    -- every corner of one lies on (within 3 m of) the other's edge
    for _, pair in ipairs({{polyA, ib}, {polyB, ia}}) do
        for _, p in ipairs(pair[1]) do
            if pair[2]:closest(p, 3) == nil then
                return false
            end
        end
    end
    return true
end

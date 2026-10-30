-- Guidance: finds a way across a field that keeps out of standing crop (and off islands, and on the field), for
-- driving to the course and for connections that would cross crop. A search on a grid of cells, standing crop
-- costs a lot, the strip where the implement would hang over the edge costs extra; the route found is straightened
-- where that doesn't cost more, then made drivable (turning radius) with Dubins pieces and rounded corners.
--
-- The crop comes from a probe: probe:hasFruit(x, z, size) -> true if there is standing crop in that square.

GuidancePathfinder = {}
local PF = GuidancePathfinder
local Geo, Dubins = GuidanceGeo, GuidanceDubins

PF.MAX_CELLS = 80000 -- the cells get bigger on big fields
PF.MIN_CELL = 3 -- m
PF.FRUIT_COST = 30 -- per metre through crop, compared to 1 on clear ground
PF.EDGE_COST = 4 -- the implement would hang over the field edge
PF.OUTSIDE_COST = 6 -- off the field, only near the start (the vehicle may come from the road)
PF.OUTSIDE_NEAR_START = 40 -- m

local SQRT2 = math.sqrt(2)

--- A binary heap of {f, id}
local function heapPush(heap, f, id)
    local n = #heap + 1
    heap[n] = {f, id}
    while n > 1 do
        local parent = math.floor(n / 2)
        if heap[parent][1] <= heap[n][1] then break end
        heap[parent], heap[n] = heap[n], heap[parent]
        n = parent
    end
end

local function heapPop(heap)
    local top = heap[1]
    local last = table.remove(heap)
    if #heap > 0 then
        heap[1] = last
        local n, size = 1, #heap
        while true do
            local l, r, smallest = 2 * n, 2 * n + 1, n
            if l <= size and heap[l][1] < heap[smallest][1] then smallest = l end
            if r <= size and heap[r][1] < heap[smallest][1] then smallest = r end
            if smallest == n then break end
            heap[smallest], heap[n] = heap[n], heap[smallest]
            n = smallest
        end
    end
    return top
end

--- area: {field, fieldIndex, islands} of a course (see GuidanceCourseGenerator); settings: workWidth, turnRadius;
--- from, to: poses {x, y, h}. Returns points {x, y} from 'from' to 'to', or nil if there is no way.
function PF.find(area, settings, from, to, probe)
    if area == nil or area.field == nil then
        return nil
    end
    local fieldIndex = area.fieldIndex or Geo.outlineIndex(area.field, 10)
    area.fieldIndex = fieldIndex
    local minX, minY, maxX, maxY = Geo.bounds(area.field)
    minX = math.min(minX, from.x, to.x) - PF.OUTSIDE_NEAR_START
    minY = math.min(minY, from.y, to.y) - PF.OUTSIDE_NEAR_START
    maxX = math.max(maxX, from.x, to.x) + PF.OUTSIDE_NEAR_START
    maxY = math.max(maxY, from.y, to.y) + PF.OUTSIDE_NEAR_START
    local cell = math.max(PF.MIN_CELL, math.sqrt((maxX - minX) * (maxY - minY) / PF.MAX_CELLS))
    local nx, ny = math.ceil((maxX - minX) / cell), math.ceil((maxY - minY) / cell)
    local half = (settings.workWidth or 6) / 2

    local function center(ix, iy)
        return {x = minX + (ix + 0.5) * cell, y = minY + (iy + 0.5) * cell}
    end
    local function cellOf(p)
        return math.max(0, math.min(nx - 1, math.floor((p.x - minX) / cell))),
               math.max(0, math.min(ny - 1, math.floor((p.y - minY) / cell)))
    end

    -- what it costs to drive a metre through a cell (nil: not at all), worked out when first needed
    local costs = {}
    local function costAt(p)
        for _, island in ipairs(area.islands or {}) do
            if island.padIndex:isInside(p) then
                return nil
            end
        end
        local cost = 1
        if not fieldIndex:isInside(p) then
            if Geo.dist(p, from) > PF.OUTSIDE_NEAR_START then
                return nil
            end
            cost = PF.OUTSIDE_COST
        elseif fieldIndex:closest(p, half) ~= nil then
            cost = PF.EDGE_COST
        end
        -- the middle of the cell: a harvested strip narrower than a cell still shows as one
        if probe and probe:hasFruit(p.x, p.y, cell / 2) then
            cost = cost + PF.FRUIT_COST
        end
        return cost
    end
    local function cellCost(ix, iy)
        local id = iy * nx + ix + 1
        local c = costs[id]
        if c == nil then
            c = costAt(center(ix, iy)) or false
            costs[id] = c
        end
        return c or nil
    end

    -- search to a point a few turning radii before the target, on its line: the last bit is then straight in, the
    -- bend before it a rounded corner (a Dubins loop right at the target would swing through the crop there)
    local r = settings.turnRadius or 6
    local goal = {x = to.x - math.cos(to.h) * 3 * r, y = to.y - math.sin(to.h) * 3 * r}
    local lined = costAt(goal) ~= nil
    if not lined then goal = {x = to.x, y = to.y} end
    local sx, sy = cellOf(from)
    local gx, gy = cellOf(goal)
    local startId, goalId = sy * nx + sx + 1, gy * nx + gx + 1
    -- where the vehicle is and where it goes are always allowed
    costs[startId] = math.max(1, costAt(from) or PF.OUTSIDE_COST)
    costs[goalId] = math.max(1, costAt(goal) or 1)

    local g, cameFrom, closed = {[startId] = 0}, {}, {}
    local heap = {}
    local function h(ix, iy)
        local dx, dy = math.abs(ix - gx), math.abs(iy - gy)
        return (math.max(dx, dy) + (SQRT2 - 1) * math.min(dx, dy)) * cell
    end
    heapPush(heap, h(sx, sy), startId)
    local found = false
    local expanded = 0
    while #heap > 0 do
        local id = heapPop(heap)[2]
        if not closed[id] then
            closed[id] = true
            expanded = expanded + 1
            if id == goalId then
                found = true
                break
            end
            local ix, iy = (id - 1) % nx, math.floor((id - 1) / nx)
            local here = cellCost(ix, iy) or PF.OUTSIDE_COST
            for dx = -1, 1 do
                for dy = -1, 1 do
                    if dx ~= 0 or dy ~= 0 then
                        local jx, jy = ix + dx, iy + dy
                        if jx >= 0 and jx < nx and jy >= 0 and jy < ny then
                            local nid = jy * nx + jx + 1
                            local c = not closed[nid] and cellCost(jx, jy)
                            if c then
                                local step = (dx ~= 0 and dy ~= 0) and SQRT2 * cell or cell
                                local ng = g[id] + step * (c + here) / 2
                                if g[nid] == nil or ng < g[nid] then
                                    g[nid] = ng
                                    cameFrom[nid] = id
                                    heapPush(heap, ng + h(jx, jy), nid)
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    if not found then
        Guidance.debug("pathfinder: no way found (%d cells looked at)", expanded)
        return nil
    end

    -- the cells from start to goal
    local cells = {}
    local id = goalId
    while id do
        local ix, iy = (id - 1) % nx, math.floor((id - 1) / nx)
        table.insert(cells, 1, {ix = ix, iy = iy, cost = cellCost(ix, iy) or PF.OUTSIDE_COST})
        id = cameFrom[id]
    end

    -- straighten: from each point on, the furthest later point a straight line gets to for no more than the grid
    -- route costs between the two (cost: metres times what each metre costs)
    local function lineCost(a, b)
        local d = Geo.dist(a, b)
        local steps = math.max(1, math.ceil(d / (cell / 2)))
        local total = 0
        for k = 1, steps do
            local p = {x = a.x + (b.x - a.x) * (k - 0.5) / steps, y = a.y + (b.y - a.y) * (k - 0.5) / steps}
            local ix, iy = cellOf(p)
            local c = cellCost(ix, iy)
            if c == nil then return math.huge end
            total = total + c * d / steps
        end
        return total
    end
    local function pointOf(k)
        if k == 1 then return {x = from.x, y = from.y} end
        if k == #cells then return {x = goal.x, y = goal.y} end
        return center(cells[k].ix, cells[k].iy)
    end
    local route = {{x = from.x, y = from.y}}
    local i = 1
    while i < #cells do
        local a = pointOf(i)
        local best, gridCost = i + 1, 0
        for j = i + 1, #cells do
            local p, q = pointOf(j - 1), pointOf(j)
            gridCost = gridCost + Geo.dist(p, q) * (cells[j - 1].cost + cells[j].cost) / 2
            if j > i + 1 and lineCost(a, pointOf(j)) <= gridCost + 1e-6 then
                best = j
            end
        end
        i = best
        table.insert(route, pointOf(i))
    end
    if Geo.dist(route[#route], to) > 0.1 then
        table.insert(route, {x = to.x, y = to.y})
    end
    return PF.makeDrivable(route, from, to, r, lined)
end

--- A route (points from 'from' to 'to') made drivable: Dubins from the vehicle onto it, corners rounded with the
--- turning radius, Dubins into the target pose (unless 'lined': the route's last bit already is on its line)
function PF.makeDrivable(route, from, to, r, lined)
    local pts = {}
    -- coming in along the target's line from its far side: the route passes the target, then turns back to it on
    -- the spot. That can't be rounded: a Dubins turn into the target instead.
    if lined and #route >= 3 then
        local n = #route
        local hIn = Geo.heading(route[n - 2], route[n - 1])
        local turn = math.abs((to.h - hIn + math.pi) % (2 * math.pi) - math.pi)
        if turn > math.rad(100) then
            lined = false
        end
    end
    if #route <= 2 then
        local path = Dubins.shortest(from, to, r)
        return path and Dubins.sample(from, path, r, 1.5) or {{x = to.x, y = to.y}}
    end
    -- onto the route at its second point, facing along it
    local join = {x = route[2].x, y = route[2].y, h = Geo.heading(route[2], route[3])}
    local first = Dubins.shortest(from, join, r)
    if first then
        for _, p in ipairs(Dubins.sample(from, first, r, 1.5)) do table.insert(pts, p) end
    end
    -- the middle, rounded
    local middle = {}
    for k = 2, lined and #route or #route - 1 do table.insert(middle, route[k]) end
    if lined and #middle >= 2 then
        -- rounded, and no tighter than the turning radius where the pieces were too short for that
        local rounded = Geo.limitCurvature(Geo.roundCorners(middle, r, false, math.rad(5), 1.5), r, false)
        for k = 2, #rounded do table.insert(pts, rounded[k]) end
        return pts
    end
    local leave
    if #middle >= 2 then
        local rounded = Geo.limitCurvature(Geo.roundCorners(middle, r, false, math.rad(5), 1.5), r, false)
        for k = 2, #rounded do table.insert(pts, rounded[k]) end
        local n = #middle
        leave = {x = middle[n].x, y = middle[n].y, h = Geo.heading(middle[n - 1], middle[n])}
    else
        leave = join
    end
    -- into the target
    local last = Dubins.shortest(leave, to, r)
    if last then
        for _, p in ipairs(Dubins.sample(leave, last, r, 1.5)) do table.insert(pts, p) end
    else
        table.insert(pts, {x = to.x, y = to.y})
    end
    return pts
end

--- How many metres of the path (points {x, y}, starting at 'from') go through crop
function PF.fruitLength(probe, from, pts, step)
    if probe == nil then return 0 end
    step = step or 2
    local length, prev = 0, from
    for _, p in ipairs(pts) do
        local d = Geo.dist(prev, p)
        local n = math.max(1, math.ceil(d / step))
        for k = 1, n do
            local q = {x = prev.x + (p.x - prev.x) * k / n, y = prev.y + (p.y - prev.y) * k / n}
            if probe:hasFruit(q.x, q.y, step) then
                length = length + d / n
            end
        end
        prev = p
    end
    return length
end

-----------------------------------------------------------------------------------------------------------------------
-- Crop on a field, from the game's fruit density maps
-----------------------------------------------------------------------------------------------------------------------

GuidanceFruitProbe = {}
local Probe = GuidanceFruitProbe
local Probe_mt = {__index = Probe}

--- Finds which crops grow on the field (a few big queries), so later checks only ask about those. Grass and
--- meadow don't count, driving over them does no harm. Returns nil if the game can't tell.
function Probe.new(outline)
    if FSDensityMapUtil == nil or FSDensityMapUtil.getFruitArea == nil or g_fruitTypeManager == nil then
        return nil
    end
    local self = setmetatable({fruitIndexes = {}}, Probe_mt)
    local ignore = {}
    if FruitType then
        for _, name in ipairs({"GRASS", "MEADOW"}) do
            if FruitType[name] then ignore[FruitType[name]] = true end
        end
    end
    local minX, minY, maxX, maxY = math.huge, math.huge, -math.huge, -math.huge
    for _, p in ipairs(outline) do
        local y = p.y or p.z
        minX, maxX = math.min(minX, p.x), math.max(maxX, p.x)
        minY, maxY = math.min(minY, y), math.max(maxY, y)
    end
    local parts = 4
    local w, hgt = (maxX - minX) / parts, (maxY - minY) / parts
    for _, fruitType in ipairs(g_fruitTypeManager.fruitTypes or {}) do
        if not ignore[fruitType.index] then
            local present = false
            for i = 0, parts - 1 do
                for j = 0, parts - 1 do
                    if not present then
                        local x0, z0 = minX + i * w, minY + j * hgt
                        local ok, value = pcall(FSDensityMapUtil.getFruitArea, fruitType.index, x0, z0, x0 + w, z0,
                            x0, z0 + hgt, true, true)
                        present = ok and value ~= nil and value > 0
                    end
                end
            end
            if present then
                table.insert(self.fruitIndexes, fruitType.index)
            end
        end
    end
    Guidance.debug("fruit probe: %d crop(s) on the field", #self.fruitIndexes)
    return self
end

function Probe:hasFruit(x, z, size)
    if #self.fruitIndexes == 0 then
        return false
    end
    local s = (size or 3) / 2
    for _, index in ipairs(self.fruitIndexes) do
        local ok, value = pcall(FSDensityMapUtil.getFruitArea, index, x - s, z - s, x + s, z - s, x - s, z + s, true, true)
        if ok and value ~= nil and value > 0 then
            return true
        end
    end
    return false
end

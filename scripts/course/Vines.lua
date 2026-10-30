-- Vineyards and orchards (the game builds both on its vine system, "vineOrchard": grapes, olives...): their rows read
-- from the map, made into the
-- lines a course drives. The game's helper can't work them; we drive on the rows (grape harvester, pre-pruner) or
-- between them (sprayer, mulcher).

GuidanceVines = {}
local Vines = GuidanceVines

Vines.MARGIN = 15 -- m round the rows: room to turn at their ends, the vineyard's outline
Vines.EXTEND = 2 -- m the course runs on past the vines' ends (the tool clear of them before it turns)
Vines.NEAR = 60 -- m from a vineyard's rows the vehicle may stand to make its course
Vines.ANGLE = math.rad(3) -- rows this far apart in direction belong to different vineyards

--- Every vine segment on the map: list of {x1, z1, x2, z2, width, h (heading, 0..pi)}
function Vines.segments()
    local sys = g_currentMission and g_currentMission.vineSystem
    if sys == nil or type(sys.nodes) ~= "table" then
        return {}
    end
    local seen, out = {}, {}
    for _, placeable in pairs(sys.nodes) do
        local spec = type(placeable) == "table" and placeable.spec_vine
        if spec and not seen[placeable] and type(spec.vineSegments) == "table" then
            seen[placeable] = true
            -- what grows there (GRAPE, OLIVE...)
            local fruit = spec.fruitType and spec.fruitType.name
            for k, v in pairs(spec.vineSegments) do
                -- (the segments are the keys, or the values)
                local seg = (type(k) == "table" and k.x1 ~= nil) and k or v
                if type(seg) == "table" and seg.x1 and seg.z1 and seg.x2 and seg.z2 then
                    local h = math.atan2(seg.z2 - seg.z1, seg.x2 - seg.x1) % math.pi
                    out[#out + 1] = {x1 = seg.x1, z1 = seg.z1, x2 = seg.x2, z2 = seg.z2, width = spec.width or 2.5, h = h,
                                     fruit = fruit}
                end
            end
        end
    end
    return out
end

local function angleDiff(a, b)
    local d = math.abs(a - b) % math.pi
    return math.min(d, math.pi - d)
end

local function pointSegDist(px, pz, s)
    local dx, dz = s.x2 - s.x1, s.z2 - s.z1
    local l2 = dx * dx + dz * dz
    local t = l2 > 0 and math.max(0, math.min(1, ((px - s.x1) * dx + (pz - s.z1) * dz) / l2)) or 0
    local qx, qz = s.x1 + dx * t, s.z1 + dz * t
    return math.sqrt((px - qx) ^ 2 + (pz - qz) ^ 2)
end

local function segDist(a, b)
    return math.min(pointSegDist(a.x1, a.z1, b), pointSegDist(a.x2, a.z2, b), pointSegDist(b.x1, b.z1, a),
        pointSegDist(b.x2, b.z2, a))
end

--- The segments of one vineyard: those with the same direction that reach each other (rows a few metres apart,
--- pieces of a row end to end), starting from segment 'first'
local function vineyardOf(segs, first)
    local list, taken, queue = {}, {[first] = true}, {first}
    local head = 1
    while queue[head] do
        local s = queue[head]
        head = head + 1
        list[#list + 1] = s
        local reach = 2 * s.width + 5
        for _, o in ipairs(segs) do
            if not taken[o] and angleDiff(o.h, s.h) < Vines.ANGLE and segDist(o, s) < reach then
                taken[o] = true
                queue[#queue + 1] = o
            end
        end
    end
    return list
end

--- The rows of a vineyard's segments: pieces in line joined, from the first vine to the last. Returns
--- {rows = list of {a, b ({x, y}), lat}, spacing, angle, outline (list of {x, z}), area}, sorted across
function Vines.rowsOf(segs)
    if #segs == 0 then return nil end
    -- the direction: the longest segment's
    local longest, best = nil, -1
    for _, s in ipairs(segs) do
        local l = (s.x2 - s.x1) ^ 2 + (s.z2 - s.z1) ^ 2
        if l > best then longest, best = s, l end
    end
    local h = math.atan2(longest.z2 - longest.z1, longest.x2 - longest.x1)
    local dx, dz = math.cos(h), math.sin(h)
    local nx, nz = -dz, dx
    local width = longest.width
    local items = {}
    for _, s in ipairs(segs) do
        local lat = ((s.x1 + s.x2) / 2) * nx + ((s.z1 + s.z2) / 2) * nz
        local a1, a2 = s.x1 * dx + s.z1 * dz, s.x2 * dx + s.z2 * dz
        items[#items + 1] = {lat = lat, from = math.min(a1, a2), to = math.max(a1, a2)}
    end
    table.sort(items, function(p, q) return p.lat < q.lat end)
    -- pieces of one row: about the same place across
    local groups = {}
    for _, it in ipairs(items) do
        local g = groups[#groups]
        if g and math.abs(it.lat - g.lat) < width * 0.4 then
            g.lat = (g.lat * g.n + it.lat) / (g.n + 1)
            g.n = g.n + 1
            g.from, g.to = math.min(g.from, it.from), math.max(g.to, it.to)
        else
            groups[#groups + 1] = {lat = it.lat, n = 1, from = it.from, to = it.to}
        end
    end
    local rows = {}
    local minA, maxA, minL, maxL = math.huge, -math.huge, math.huge, -math.huge
    for _, g in ipairs(groups) do
        local function at(along) return {x = dx * along + nx * g.lat, y = dz * along + nz * g.lat} end
        rows[#rows + 1] = {a = at(g.from), b = at(g.to), lat = g.lat}
        minA, maxA = math.min(minA, g.from), math.max(maxA, g.to)
        minL, maxL = math.min(minL, g.lat), math.max(maxL, g.lat)
    end
    local spacing = width
    if #rows > 1 then spacing = (maxL - minL) / (#rows - 1) end
    -- the outline: round the rows, MARGIN out
    local m = Vines.MARGIN
    local function corner(along, lat) return {x = dx * along + nx * lat, z = dz * along + nz * lat} end
    local outline = {corner(minA - m, minL - m), corner(maxA + m, minL - m), corner(maxA + m, maxL + m),
                     corner(minA - m, maxL + m)}
    return {rows = rows, spacing = spacing, angle = h, outline = outline,
            area = (maxA - minA + 2 * m) * (maxL - minL + 2 * m), fruit = longest.fruit}
end

--- The vineyard at (x, z): its rows (Vines.rowsOf) when there are vines within NEAR m; else nil
function Vines.at(x, z)
    local segs = Vines.segments()
    local nearest, bestD
    for _, s in ipairs(segs) do
        local d = pointSegDist(x, z, s)
        if d < Vines.NEAR and (bestD == nil or d < bestD) then nearest, bestD = s, d end
    end
    if nearest == nil then return nil end
    return Vines.rowsOf(vineyardOf(segs, nearest))
end

--- The vineyard inside an outline (list of {x, z}), or nil: for the course of a field made for one
function Vines.inOutline(outline)
    local poly = {}
    for i, p in ipairs(outline) do poly[i] = {x = p.x, y = p.z} end
    local inside = {}
    for _, s in ipairs(Vines.segments()) do
        if GuidanceGeo.pointInPolygon({x = (s.x1 + s.x2) / 2, y = (s.z1 + s.z2) / 2}, poly) then
            inside[#inside + 1] = s
        end
    end
    if #inside == 0 then return nil end
    -- the biggest vineyard in it
    local best
    local left = {}
    for _, s in ipairs(inside) do left[s] = true end
    for _, s in ipairs(inside) do
        if left[s] then
            local list = vineyardOf(inside, s)
            for _, o in ipairs(list) do left[o] = nil end
            if best == nil or #list > #best then best = list end
        end
    end
    return Vines.rowsOf(best)
end

--- Has the vehicle a tool that works on the rows (grape harvester, pre-pruner)?
function Vines.hasRowTool(vehicle)
    for _, v in ipairs(vehicle.getChildVehicles and vehicle:getChildVehicles() or {vehicle}) do
        if v.spec_vineCutter ~= nil or v.spec_vinePrepruner ~= nil then return true end
    end
    return false
end

--- The lines the course drives: on every row, or between them (a sprayer: every gap its width covers both sides
--- of, the outermost rows always reached). List of {a, b, lat}
function Vines.lines(vineyard, onRows, workWidth)
    local rows = vineyard.rows
    if onRows or #rows < 2 then
        return rows
    end
    local gaps = {}
    for i = 1, #rows - 1 do
        local r, q = rows[i], rows[i + 1]
        local lat = (r.lat + q.lat) / 2
        local h = vineyard.angle
        local dx, dz, nx, nz = math.cos(h), math.sin(h), -math.sin(h), math.cos(h)
        local function along(p) return p.x * dx + p.y * dz end
        local from = math.min(along(r.a), along(q.a))
        local to = math.max(along(r.b), along(q.b))
        gaps[i] = {a = {x = dx * from + nx * lat, y = dz * from + nz * lat},
                   b = {x = dx * to + nx * lat, y = dz * to + nz * lat}, lat = lat}
    end
    -- gap g sprays rows g and g + 1; a wider tool reaches k rows each side
    local k = math.max(1, math.floor((workWidth or 0) / math.max(0.5, vineyard.spacing) + 0.25))
    local out = {}
    local g = math.min(#gaps, math.max(1, math.ceil(k / 2)))
    local last
    while g <= #gaps do
        out[#out + 1] = gaps[g]
        last = g
        g = g + k
    end
    -- the last row reached too
    if last and last + 1 < #rows and last < #gaps then out[#out + 1] = gaps[#gaps] end
    return out
end

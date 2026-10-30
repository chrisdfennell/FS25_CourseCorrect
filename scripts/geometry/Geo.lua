-- Guidance: 2D geometry on the ground plane.
-- Points are tables {x = worldX, y = worldZ}. Polygons are arrays of points, not closed (last ~= first).
-- Headings are math angles, atan2(dy, dx).

GuidanceGeo = {}
local Geo = GuidanceGeo

Geo.EPS = 1e-9

function Geo.p(x, y)
    return {x = x, y = y}
end

function Geo.dist(a, b)
    local dx, dy = b.x - a.x, b.y - a.y
    return math.sqrt(dx * dx + dy * dy)
end

function Geo.heading(a, b)
    return math.atan2(b.y - a.y, b.x - a.x)
end

--- Angle normalized to (-pi, pi]
function Geo.normAngle(a)
    while a > math.pi do a = a - 2 * math.pi end
    while a <= -math.pi do a = a + 2 * math.pi end
    return a
end

function Geo.cross(ax, ay, bx, by)
    return ax * by - ay * bx
end

--- Positive for counter clockwise polygons
function Geo.signedArea(poly)
    local a, n = 0, #poly
    for i = 1, n do
        local p, q = poly[i], poly[i % n + 1]
        a = a + p.x * q.y - q.x * p.y
    end
    return a / 2
end

function Geo.copy(poly)
    local out = {}
    for i, p in ipairs(poly) do
        out[i] = {x = p.x, y = p.y}
    end
    return out
end

function Geo.reverse(poly)
    local out, n = {}, #poly
    for i = 1, n do
        out[i] = poly[n - i + 1]
    end
    return out
end

function Geo.ensureCCW(poly)
    if Geo.signedArea(poly) < 0 then
        return Geo.reverse(poly)
    end
    return poly
end

--- Drops consecutive points closer than minDist and a closing point equal to the first
function Geo.removeDuplicates(poly, minDist)
    minDist = minDist or 0.05
    local out = {}
    for _, p in ipairs(poly) do
        if #out == 0 or Geo.dist(out[#out], p) > minDist then
            table.insert(out, p)
        end
    end
    while #out > 2 and Geo.dist(out[1], out[#out]) <= minDist do
        table.remove(out)
    end
    return out
end

local function distToSegment(p, a, b)
    local dx, dy = b.x - a.x, b.y - a.y
    local len2 = dx * dx + dy * dy
    if len2 < Geo.EPS then
        return Geo.dist(p, a), 0
    end
    local t = math.max(0, math.min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
    local cx, cy = a.x + t * dx, a.y + t * dy
    local ex, ey = p.x - cx, p.y - cy
    return math.sqrt(ex * ex + ey * ey), t
end
Geo.distToSegment = distToSegment

--- Smallest distance from p to the outline of a closed polygon
function Geo.distToPolygon(p, poly)
    local best, n = math.huge, #poly
    for i = 1, n do
        local d = distToSegment(p, poly[i], poly[i % n + 1])
        if d < best then best = d end
    end
    return best
end

local function douglasPeucker(pts, first, last, tolerance, keep)
    local maxD, index = 0, nil
    for i = first + 1, last - 1 do
        local d = distToSegment(pts[i], pts[first], pts[last])
        if d > maxD then
            maxD, index = d, i
        end
    end
    if index and maxD > tolerance then
        keep[index] = true
        douglasPeucker(pts, first, index, tolerance, keep)
        douglasPeucker(pts, index, last, tolerance, keep)
    end
end

--- Simplifies a closed polygon, keeping the outline within tolerance
function Geo.simplify(poly, tolerance)
    local n = #poly
    if n < 4 then return poly end
    -- split at the point farthest from the first, so both halves are open polylines
    local far, farD = 1, 0
    for i = 2, n do
        local d = Geo.dist(poly[1], poly[i])
        if d > farD then far, farD = i, d end
    end
    local pts = Geo.copy(poly)
    table.insert(pts, {x = poly[1].x, y = poly[1].y})
    local keep = {[1] = true, [far] = true, [n + 1] = true}
    douglasPeucker(pts, 1, far, tolerance, keep)
    douglasPeucker(pts, far, n + 1, tolerance, keep)
    local out = {}
    for i = 1, n do
        if keep[i] then table.insert(out, pts[i]) end
    end
    return out
end

function Geo.pointInPolygon(p, poly)
    local inside, n = false, #poly
    local j = n
    for i = 1, n do
        local a, b = poly[i], poly[j]
        if (a.y > p.y) ~= (b.y > p.y) then
            local x = a.x + (p.y - a.y) * (b.x - a.x) / (b.y - a.y)
            if p.x < x then inside = not inside end
        end
        j = i
    end
    return inside
end

--- Intersection of segments ab and cd, returns t on ab, u on cd (both in [0,1]) or nil
function Geo.segmentIntersection(a, b, c, d)
    local rx, ry = b.x - a.x, b.y - a.y
    local sx, sy = d.x - c.x, d.y - c.y
    local den = Geo.cross(rx, ry, sx, sy)
    if math.abs(den) < Geo.EPS then return nil end
    local qx, qy = c.x - a.x, c.y - a.y
    local t = Geo.cross(qx, qy, sx, sy) / den
    local u = Geo.cross(qx, qy, rx, ry) / den
    if t >= 0 and t <= 1 and u >= 0 and u <= 1 then
        return t, u
    end
    return nil
end

function Geo.rotate(poly, angle)
    local c, s = math.cos(angle), math.sin(angle)
    local out = {}
    for i, p in ipairs(poly) do
        out[i] = {x = p.x * c - p.y * s, y = p.x * s + p.y * c}
    end
    return out
end

function Geo.bounds(poly)
    local minX, minY, maxX, maxY = math.huge, math.huge, -math.huge, -math.huge
    for _, p in ipairs(poly) do
        minX, maxX = math.min(minX, p.x), math.max(maxX, p.x)
        minY, maxY = math.min(minY, p.y), math.max(maxY, p.y)
    end
    return minX, minY, maxX, maxY
end

function Geo.length(line, closed)
    local len = 0
    for i = 2, #line do
        len = len + Geo.dist(line[i - 1], line[i])
    end
    if closed and #line > 1 then
        len = len + Geo.dist(line[#line], line[1])
    end
    return len
end

-----------------------------------------------------------------------------------------------------------------------
-- Offsetting
-----------------------------------------------------------------------------------------------------------------------

--- Moves every edge of a CCW polygon inward by d and joins neighbours at their intersection.
--- The result may intersect itself where edges vanished, see Geo.offsetInward
local function rawOffset(poly, d)
    local n, out = #poly, {}
    for i = 1, n do
        local prev, cur, nxt = poly[(i - 2) % n + 1], poly[i], poly[i % n + 1]
        local ax, ay = cur.x - prev.x, cur.y - prev.y
        local bx, by = nxt.x - cur.x, nxt.y - cur.y
        local la, lb = math.sqrt(ax * ax + ay * ay), math.sqrt(bx * bx + by * by)
        ax, ay, bx, by = ax / la, ay / la, bx / lb, by / lb
        -- left normals point inside a CCW polygon
        local nax, nay, nbx, nby = -ay, ax, -by, bx
        local den = Geo.cross(ax, ay, bx, by)
        if math.abs(den) < 1e-6 then
            out[i] = {x = cur.x + nax * d, y = cur.y + nay * d}
        else
            -- intersect line (cur + na*d) + s*a with (cur + nb*d) + t*b
            local px, py = cur.x + nax * d, cur.y + nay * d
            local qx, qy = cur.x + nbx * d, cur.y + nby * d
            local s = Geo.cross(qx - px, qy - py, bx, by) / den
            local mx, my = px + s * ax, py + s * ay
            -- very sharp spikes push the miter far away, clamp it, the cleanup removes what is left
            local mlx, mly = mx - cur.x, my - cur.y
            local ml = math.sqrt(mlx * mlx + mly * mly)
            local maxMiter = 8 * math.abs(d)
            if ml > maxMiter then
                mx, my = cur.x + mlx / ml * maxMiter, cur.y + mly / ml * maxMiter
            end
            out[i] = {x = mx, y = my}
        end
    end
    return out
end

--- Splits a self intersecting closed polygon into simple loops
function Geo.splitLoops(poly)
    local n = #poly
    -- collect intersections per edge
    local cuts = {}
    for i = 1, n do cuts[i] = {} end
    local nodeId = 0
    for i = 1, n do
        local a, b = poly[i], poly[i % n + 1]
        for j = i + 2, n do
            if not (i == 1 and j == n) then
                local c, d = poly[j], poly[j % n + 1]
                local t, u = Geo.segmentIntersection(a, b, c, d)
                if t and t > 1e-9 and t < 1 - 1e-9 and u > 1e-9 and u < 1 - 1e-9 then
                    nodeId = nodeId + 1
                    local x, y = a.x + t * (b.x - a.x), a.y + t * (b.y - a.y)
                    table.insert(cuts[i], {t = t, x = x, y = y, id = nodeId})
                    table.insert(cuts[j], {t = u, x = x, y = y, id = nodeId})
                end
            end
        end
    end
    if nodeId == 0 then
        return {poly}
    end
    local seq = {}
    for i = 1, n do
        table.insert(seq, {x = poly[i].x, y = poly[i].y})
        table.sort(cuts[i], function(p, q) return p.t < q.t end)
        for _, c in ipairs(cuts[i]) do
            table.insert(seq, {x = c.x, y = c.y, id = c.id})
        end
    end
    -- walk the sequence, every time we get back to a node we have seen, the points in between are a loop
    local loops, stack, onStack = {}, {}, {}
    for _, p in ipairs(seq) do
        if p.id and onStack[p.id] then
            local start = onStack[p.id]
            local loop = {}
            for k = start, #stack do
                table.insert(loop, stack[k])
            end
            for k = #stack, start + 1, -1 do
                if stack[k].id then onStack[stack[k].id] = nil end
                stack[k] = nil
            end
            table.insert(loops, loop)
        else
            table.insert(stack, p)
            if p.id then onStack[p.id] = #stack end
        end
    end
    if #stack > 2 then
        table.insert(loops, stack)
    end
    return loops
end

--- Offsets a CCW polygon inward by d. Returns a list of CCW polygons, largest first (a field can
--- fall apart into several pieces where it narrows), possibly empty.
function Geo.offsetInward(poly, d)
    local raw = Geo.removeDuplicates(rawOffset(poly, d), 0.01)
    if #raw < 3 then return {} end
    local minArea = math.max(1, d * d * 0.05)
    local result = {}
    local function isValidEdge(a, b)
        local mid = {x = (a.x + b.x) / 2, y = (a.y + b.y) / 2}
        return Geo.distToPolygon(mid, poly) >= d * 0.9 and Geo.pointInPolygon(mid, poly)
    end
    local function collect(loops, depth)
        for _, loop in ipairs(loops) do
            loop = Geo.removeDuplicates(loop, 0.01)
            local area = #loop >= 3 and Geo.signedArea(loop) or 0
            -- clockwise loops are the inside out leftovers of collapsed edges
            if area > minArea then
                local valid = true
                for i = 1, #loop do
                    if not isValidEdge(loop[i], loop[i % #loop + 1]) then
                        valid = false
                        break
                    end
                end
                if valid then
                    table.insert(result, {poly = loop, area = area})
                elseif depth < 3 then
                    -- remains of spikes that collapsed without crossing anything: drop the points too
                    -- close to the outline and try again
                    local pruned = {}
                    for _, p in ipairs(loop) do
                        if Geo.distToPolygon(p, poly) >= d * 0.95 then
                            table.insert(pruned, p)
                        end
                    end
                    if #pruned >= 3 and #pruned < #loop then
                        collect(Geo.splitLoops(pruned), depth + 1)
                    end
                end
            end
        end
    end
    collect(Geo.splitLoops(raw), 0)
    table.sort(result, function(a, b) return a.area > b.area end)
    local out = {}
    for i, r in ipairs(result) do out[i] = r.poly end
    return out
end

--- Removes spikes from a closed polygon: points where it turns back on itself (more than maxTurn), again and
--- again until none are left (a thin spike goes away point by point from its tip)
--- (spikes pointing out, like a narrow tail of the field, of any size; spikes pointing in only small ones, the
--- leftovers of offsetting: at most maxHeight from the line between the neighbours. A wedge cut into the field is
--- a big inward spike and stays.)
function Geo.removeSpikes(poly, maxTurn, maxHeight)
    maxTurn = maxTurn or math.rad(150)
    maxHeight = maxHeight or 10
    local pts = Geo.copy(poly)
    local changed = true
    while changed and #pts > 3 do
        changed = false
        local n = #pts
        for i = n, 1, -1 do
            if #pts <= 3 then break end
            n = #pts
            local prev, cur, nxt = pts[(i - 2) % n + 1], pts[i], pts[i % n + 1]
            local turn = Geo.normAngle(Geo.heading(cur, nxt) - Geo.heading(prev, cur))
            -- (CCW: a left turn is a corner bulging out)
            if math.abs(turn) > maxTurn and (turn > 0 or distToSegment(cur, prev, nxt) <= maxHeight) then
                table.remove(pts, i)
                changed = true
            end
        end
    end
    return pts
end

--- Offsets a CCW polygon outward by d (sharp corners). Returns the outer loop, or nil.
function Geo.offsetOutward(poly, d)
    local raw = Geo.removeDuplicates(rawOffset(poly, -d), 0.01)
    if #raw < 3 then return nil end
    local best, bestArea
    for _, loop in ipairs(Geo.splitLoops(raw)) do
        local area = #loop >= 3 and Geo.signedArea(loop) or 0
        if area > 0 and (bestArea == nil or area > bestArea) then
            best, bestArea = loop, area
        end
    end
    return best
end

--- The polygon without the parts narrower than 2 * r (shrunk by r and grown back): what a vehicle that can't
--- turn tighter than r can drive around. Where it falls apart, the biggest piece.
function Geo.openPolygon(poly, r)
    local shrunk = Geo.offsetInward(poly, r)[1]
    if shrunk == nil then
        return poly
    end
    return Geo.offsetOutward(shrunk, r) or poly
end

-----------------------------------------------------------------------------------------------------------------------
-- Smoothing
-----------------------------------------------------------------------------------------------------------------------

--- Infinite lines a + s * (b - a) and c + t * (d - c): intersection point or nil if parallel
function Geo.lineIntersection(a, b, c, d)
    local rx, ry = b.x - a.x, b.y - a.y
    local sx, sy = d.x - c.x, d.y - c.y
    local den = Geo.cross(rx, ry, sx, sy)
    if math.abs(den) < 1e-9 then return nil end
    local t = Geo.cross(c.x - a.x, c.y - a.y, sx, sy) / den
    return {x = a.x + t * rx, y = a.y + t * ry}
end

--- Merges edges shorter than minLength of a closed polygon into a single corner where the neighbouring edges
--- meet (or their middle, if the neighbours don't meet close by). A tip cut off by a short edge then becomes one
--- corner, which can be rounded with the full radius instead of two corners with half the room each.
function Geo.mergeShortEdges(poly, minLength)
    local pts = Geo.copy(poly)
    while #pts > 3 do
        local n = #pts
        local shortest, shortestLen = nil, minLength
        for i = 1, n do
            local len = Geo.dist(pts[i], pts[i % n + 1])
            if len < shortestLen then
                shortest, shortestLen = i, len
            end
        end
        if shortest == nil then break end
        local i, j = shortest, shortest % n + 1
        local a, b = pts[i], pts[j]
        local prev, nxt = pts[(i - 2) % n + 1], pts[j % n + 1]
        local p = Geo.lineIntersection(prev, a, b, nxt)
        if p == nil or Geo.dist(p, a) > 3 * minLength or Geo.dist(p, b) > 3 * minLength then
            p = {x = (a.x + b.x) / 2, y = (a.y + b.y) / 2}
        end
        pts[i] = p
        table.remove(pts, j)
    end
    return pts
end

--- Replaces the corners of a closed polygon (or open polyline) by arcs of the given radius (smaller where the
--- edges are too short). Returns a new point list with arcs sampled every maxStep meters.
--- keepAway (optional, see limitCurvature): a corner turning right (towards the outline, for a counter clockwise
--- ring inside it) is only rounded if the arc keeps away from the outline; otherwise it stays sharp.
function Geo.roundCorners(line, radius, closed, minAngle, maxStep, keepAway)
    minAngle = minAngle or math.rad(5)
    maxStep = maxStep or 1.5
    local n = #line
    if n < 3 or radius <= 0 then return Geo.copy(line) end
    local out = {}
    local function edgeLen(i, j) return Geo.dist(line[i], line[j]) end
    for i = 1, n do
        local isEnd = not closed and (i == 1 or i == n)
        if isEnd then
            table.insert(out, {x = line[i].x, y = line[i].y})
        else
            local ip, inx = (i - 2) % n + 1, i % n + 1
            local prev, cur, nxt = line[ip], line[i], line[inx]
            local h1, h2 = Geo.heading(prev, cur), Geo.heading(cur, nxt)
            local turn = Geo.normAngle(h2 - h1)
            if math.abs(turn) < minAngle then
                table.insert(out, {x = cur.x, y = cur.y})
            else
                local arc = {}
                local tanHalf = math.tan(math.abs(turn) / 2)
                -- an edge is shared by two corners, so each may use half of it
                local maxT = math.min(edgeLen(ip, i), edgeLen(i, inx)) / 2
                local r = math.min(radius, maxT / tanHalf)
                local t = r * tanHalf
                local sx, sy = cur.x - math.cos(h1) * t, cur.y - math.sin(h1) * t
                local side = turn > 0 and 1 or -1
                local cx, cy = sx - math.sin(h1) * r * side, sy + math.cos(h1) * r * side
                local a0 = math.atan2(sy - cy, sx - cx)
                local steps = math.max(2, math.ceil(math.abs(turn) * r / maxStep))
                for k = 0, steps do
                    local a = a0 + turn * k / steps
                    table.insert(arc, {x = cx + math.cos(a) * r, y = cy + math.sin(a) * r})
                end
                local allowed = true
                if keepAway and turn < 0 then
                    for _, p in ipairs(arc) do
                        if not Geo.isClearOf(p, keepAway, 0.3) then
                            allowed = false
                            break
                        end
                    end
                end
                if allowed then
                    for _, p in ipairs(arc) do table.insert(out, p) end
                else
                    table.insert(out, {x = cur.x, y = cur.y})
                end
            end
        end
    end
    return out
end

--- Is p inside the outline, at least keepAway.dist (less tolerance) from it and out of its circles?
function Geo.isClearOf(p, keepAway, tolerance)
    if keepAway.index:closest(p, keepAway.dist - tolerance) ~= nil or not keepAway.index:isInside(p) then
        return false
    end
    for _, c in ipairs(keepAway.circles or {}) do
        if (p.x - c.x) ^ 2 + (p.y - c.y) ^ 2 < (c.r - tolerance) ^ 2 then
            return false
        end
    end
    return true
end

--- Densifies a polyline so no segment is longer than maxStep
function Geo.densify(line, maxStep)
    local out = {}
    for i = 1, #line - 1 do
        local a, b = line[i], line[i + 1]
        local d = Geo.dist(a, b)
        local steps = math.max(1, math.ceil(d / maxStep))
        for k = 0, steps - 1 do
            local f = k / steps
            table.insert(out, {x = a.x + (b.x - a.x) * f, y = a.y + (b.y - a.y) * f})
        end
    end
    if #line > 0 then
        table.insert(out, {x = line[#line].x, y = line[#line].y})
    end
    return out
end

--- Cuts 'margin' meters off both ends of a polyline, nil if nothing (or only a single point) is left
function Geo.trimPolyline(line, margin)
    local total = Geo.length(line)
    if total <= 2 * margin + 1 then
        return nil
    end
    local out, d = {}, 0
    for i = 1, #line - 1 do
        local a, b = line[i], line[i + 1]
        local len = Geo.dist(a, b)
        local from, to = math.max(margin - d, 0), math.min(total - margin - d, len)
        if to > from and len > 0 then
            if #out == 0 then
                table.insert(out, {x = a.x + (b.x - a.x) * from / len, y = a.y + (b.y - a.y) * from / len})
            end
            table.insert(out, {x = a.x + (b.x - a.x) * to / len, y = a.y + (b.y - a.y) * to / len})
        end
        d = d + len
    end
    if #out < 2 then return nil end
    return out
end

--- Smooths a closed ring (or open polyline) until no part of it turns tighter than minRadius, by pulling the
--- points of tight places towards their neighbours. Tight places are left where the corner rounding couldn't
--- use the full radius (short edges, narrow tips): the vehicle could not follow those.
--- Points on straight stretches are dropped again afterwards.
--- Closest point on the outline of a closed polygon to p, and the distance
function Geo.closestPointOnPolygon(p, poly)
    local best, bestD = nil, math.huge
    local n = #poly
    for i = 1, n do
        local a, b = poly[i], poly[i % n + 1]
        local d, t = distToSegment(p, a, b)
        if d < bestD then
            bestD = d
            best = {x = a.x + (b.x - a.x) * t, y = a.y + (b.y - a.y) * t}
        end
    end
    return best, bestD
end

--- A closed polygon with its edges sorted into a grid, for fast "closest point on the outline" queries
local OutlineIndex = {}
OutlineIndex.__index = OutlineIndex

function Geo.outlineIndex(poly, cellSize)
    local self = setmetatable({poly = poly, cell = cellSize or 10, cells = {}}, OutlineIndex)
    local n = #poly
    for i = 1, n do
        local a, b = poly[i], poly[i % n + 1]
        local x1, x2 = math.floor(math.min(a.x, b.x) / self.cell), math.floor(math.max(a.x, b.x) / self.cell)
        local y1, y2 = math.floor(math.min(a.y, b.y) / self.cell), math.floor(math.max(a.y, b.y) / self.cell)
        for cx = x1, x2 do
            for cy = y1, y2 do
                local key = cx * 100003 + cy
                local list = self.cells[key]
                if list == nil then list = {} self.cells[key] = list end
                table.insert(list, i)
            end
        end
    end
    return self
end

--- Closest point on the outline within maxDist of p, its distance, the edge (from poly[i]) and the fraction along
--- it; nil if there is none that close
function OutlineIndex:closest(p, maxDist)
    local c = self.cell
    local r = math.ceil(maxDist / c)
    local px, py = math.floor(p.x / c), math.floor(p.y / c)
    local n = #self.poly
    local best, bestD, bestI, bestT, seen = nil, maxDist, nil, nil, {}
    -- a wide search (a point far off the outline) would visit more cells than there are edges: go through the
    -- edges themselves instead (the same answer)
    if (2 * r + 1) * (2 * r + 1) > 4 * n then
        for i = 1, n do
            local a, b = self.poly[i], self.poly[i % n + 1]
            local d, t = distToSegment(p, a, b)
            if d < bestD then
                bestD, bestI, bestT = d, i, t
                best = {x = a.x + (b.x - a.x) * t, y = a.y + (b.y - a.y) * t}
            end
        end
        return best, best and bestD or nil, bestI, bestT
    end
    for cx = px - r, px + r do
        for cy = py - r, py + r do
            local list = self.cells[cx * 100003 + cy]
            if list then
                for _, i in ipairs(list) do
                    if not seen[i] then
                        seen[i] = true
                        local a, b = self.poly[i], self.poly[i % n + 1]
                        local d, t = distToSegment(p, a, b)
                        if d < bestD then
                            bestD, bestI, bestT = d, i, t
                            best = {x = a.x + (b.x - a.x) * t, y = a.y + (b.y - a.y) * t}
                        end
                    end
                end
            end
        end
    end
    return best, best and bestD or nil, bestI, bestT
end

--- Is p inside the (CCW) polygon? Cells the outline doesn't cross are all in or all out (remembered); near the
--- outline the side of the closest edge tells.
function OutlineIndex:isInside(p)
    local c = self.cell
    local cx, cy = math.floor(p.x / c), math.floor(p.y / c)
    local key = cx * 100003 + cy
    if self.cells[key] == nil then
        self.insideCache = self.insideCache or {}
        local cached = self.insideCache[key]
        if cached == nil then
            cached = Geo.pointInPolygon({x = (cx + 0.5) * c, y = (cy + 0.5) * c}, self.poly)
            self.insideCache[key] = cached
        end
        return cached
    end
    local q, d, i, t = self:closest(p, 1.5 * c)
    local n = #self.poly
    if q and t > 1e-6 and t < 1 - 1e-6 then
        local a, b = self.poly[i], self.poly[i % n + 1]
        return Geo.cross(b.x - a.x, b.y - a.y, p.x - a.x, p.y - a.y) > 0
    end
    if q and d > 1e-6 then
        -- closest to a corner: the two edges meeting there tell. At a corner bulging out (CCW: turning left) p is
        -- inside if it is left of both, at one bending in if it is left of either
        local v = t <= 1e-6 and i or i % n + 1
        local u, w = self.poly[(v - 2) % n + 1], self.poly[v % n + 1]
        local cv = self.poly[v]
        local leftIn = Geo.cross(cv.x - u.x, cv.y - u.y, p.x - u.x, p.y - u.y) > 0
        local leftOut = Geo.cross(w.x - cv.x, w.y - cv.y, p.x - cv.x, p.y - cv.y) > 0
        if Geo.cross(cv.x - u.x, cv.y - u.y, w.x - cv.x, w.y - cv.y) >= 0 then
            return leftIn and leftOut
        end
        return leftIn or leftOut
    end
    return Geo.pointInPolygon(p, self.poly)
end

--- Moves p (in place) so it is inside the polygon and at least dist from its outline. Returns true if it moved.
--- index: Geo.outlineIndex of the polygon
function Geo.keepInside(p, index, dist)
    local q, d = index:closest(p, dist + 2)
    local inside = index:isInside(p)
    if q == nil then
        if inside then
            -- nothing close: far enough
            return false
        end
        -- far outside: back in from the closest edge, however far
        q, d = index:closest(p, 100000)
        if q == nil then return false end
    end
    if inside and d >= dist - 0.05 then
        return false
    end
    local dx, dy = p.x - q.x, p.y - q.y
    local len = math.sqrt(dx * dx + dy * dy)
    if len < 1e-6 then
        return false
    end
    local move = inside and (dist - d) or -(dist + d)
    p.x, p.y = p.x + dx / len * move, p.y + dy / len * move
    return true
end

--- Pushes p (in place) out of the circles {x, y, r} it is in. Returns true if it moved.
local function keepOutOfCircles(p, circles)
    local moved = false
    for _, c in ipairs(circles or {}) do
        local dx, dy = p.x - c.x, p.y - c.y
        local d = math.sqrt(dx * dx + dy * dy)
        if d < c.r - 0.05 and d > 1e-6 then
            p.x, p.y = c.x + dx / d * c.r, c.y + dy / d * c.r
            moved = true
        end
    end
    return moved
end

--- keepAway (optional): {index = Geo.outlineIndex, dist, circles = list of {x, y, r} (optional)}, every point
--- stays inside the polygon, at least dist from its outline and out of the circles (where a tight bend and the
--- outline conflict, the outline wins: the bend is pushed inside instead of cut across)
function Geo.limitCurvature(line, minRadius, closed, maxIterations, keepAway)
    maxIterations = maxIterations or 400
    local pts = Geo.copy(line)
    if closed then table.insert(pts, {x = pts[1].x, y = pts[1].y}) end
    pts = Geo.densify(pts, 1.5)
    if closed then table.remove(pts) end
    local n = #pts
    if n < 3 then return pts end
    local first, last = 1, n
    if not closed then first, last = 2, n - 1 end
    local limit = minRadius * 0.97
    -- only points next to one that moved can have become tight: work through a list of those
    local active = {}
    for i = first, last do
        if keepAway then
            keepOutOfCircles(pts[i], keepAway.circles)
            Geo.keepInside(pts[i], keepAway.index, keepAway.dist)
        end
        table.insert(active, i)
    end
    local function wrap(i)
        if closed then return (i - 1) % n + 1 end
        return (i >= first and i <= last) and i or nil
    end
    for _ = 1, maxIterations do
        if #active == 0 then break end
        local nextSet = {}
        for _, i in ipairs(active) do
            local a, b, c = pts[(i - 2) % n + 1], pts[i], pts[i % n + 1]
            local dh = math.abs(Geo.normAngle(Geo.heading(b, c) - Geo.heading(a, b)))
            local len = (Geo.dist(a, b) + Geo.dist(b, c)) / 2
            if dh > 1e-3 and len / dh < limit then
                b.x = b.x + 0.5 * ((a.x + c.x) / 2 - b.x)
                b.y = b.y + 0.5 * ((a.y + c.y) / 2 - b.y)
                if keepAway then
                    keepOutOfCircles(b, keepAway.circles)
                    Geo.keepInside(b, keepAway.index, keepAway.dist)
                end
                for k = i - 1, i + 1 do
                    local j = wrap(k)
                    if j then nextSet[j] = true end
                end
            end
        end
        -- in index order, so every machine gets the same result
        active = {}
        for i in pairs(nextSet) do table.insert(active, i) end
        table.sort(active)
    end
    -- drop the points of straight stretches again. Only points that are really on a straight line: removing
    -- points of a curve would concentrate its turning on fewer points and make it tight again.
    local out = {}
    for i = 1, n do
        local isEnd = not closed and (i == 1 or i == n)
        local b, c = pts[i], pts[i % n + 1]
        if isEnd or #out == 0 then
            table.insert(out, b)
        else
            local dh = math.abs(Geo.normAngle(Geo.heading(b, c) - Geo.heading(out[#out], b)))
            if dh > math.rad(0.1) then
                table.insert(out, b)
            end
        end
    end
    return Geo.removeDuplicates(out, 0.1)
end

--- Convex hull of a point list (CCW), Andrew's monotone chain
function Geo.convexHull(points)
    local pts = {}
    for i, p in ipairs(points) do pts[i] = {x = p.x, y = p.y} end
    table.sort(pts, function(a, b) return a.x < b.x or (a.x == b.x and a.y < b.y) end)
    if #pts < 3 then return pts end
    local function turn(o, a, b) return Geo.cross(a.x - o.x, a.y - o.y, b.x - o.x, b.y - o.y) end
    local lower, upper = {}, {}
    for _, p in ipairs(pts) do
        while #lower >= 2 and turn(lower[#lower - 1], lower[#lower], p) <= 0 do table.remove(lower) end
        table.insert(lower, p)
    end
    for i = #pts, 1, -1 do
        local p = pts[i]
        while #upper >= 2 and turn(upper[#upper - 1], upper[#upper], p) <= 0 do table.remove(upper) end
        table.insert(upper, p)
    end
    table.remove(lower)
    table.remove(upper)
    for _, p in ipairs(upper) do table.insert(lower, p) end
    return lower
end

--- Centroid (mean of the vertices)
function Geo.center(poly)
    local x, y = 0, 0
    for _, p in ipairs(poly) do x, y = x + p.x, y + p.y end
    return {x = x / #poly, y = y / #poly}
end

--- A closed CCW ring at distance d around a convex CCW polygon, with no curve tighter than minRadius: the corners
--- are arcs. Where d is less than minRadius the polygon is shrunk first, so the arcs can have the full radius
--- (the ring then keeps a little more distance); a small polygon becomes a circle.
function Geo.ringAroundConvex(hull, d, minRadius, maxStep)
    maxStep = maxStep or 1.5
    local core, r = hull, d
    if #hull < 3 then
        -- a point or a line: a circle around it
        local c = Geo.center(hull)
        local extent = 0
        for _, p in ipairs(hull) do extent = math.max(extent, Geo.dist(c, p)) end
        core, r = {c}, math.max(d + extent, minRadius)
    elseif d < minRadius then
        r = minRadius
        core = Geo.offsetInward(hull, minRadius - d)[1]
    end
    if core == nil or #core < 3 then
        core = {Geo.center(hull)}
    end
    local out, n = {}, #core
    if n == 1 then
        local steps = math.max(12, math.ceil(2 * math.pi * r / maxStep))
        for k = 0, steps - 1 do
            local a = 2 * math.pi * k / steps
            table.insert(out, {x = core[1].x + math.cos(a) * r, y = core[1].y + math.sin(a) * r})
        end
        return out
    end
    for i = 1, n do
        local prev, cur, nxt = core[(i - 2) % n + 1], core[i], core[i % n + 1]
        -- outward normals of a CCW polygon are the right normals
        local h1, h2 = Geo.heading(prev, cur), Geo.heading(cur, nxt)
        local a1, a2 = h1 - math.pi / 2, h2 - math.pi / 2
        local sweep = Geo.normAngle(a2 - a1)
        if sweep < 0 then sweep = 0 end
        local steps = math.max(1, math.ceil(sweep * r / maxStep))
        for k = 0, steps do
            local a = a1 + sweep * k / steps
            table.insert(out, {x = cur.x + math.cos(a) * r, y = cur.y + math.sin(a) * r})
        end
    end
    return Geo.removeDuplicates(out, 0.1)
end

--- Index of the polygon vertex closest to p
function Geo.closestVertex(poly, p)
    local best, bestD = 1, math.huge
    for i, q in ipairs(poly) do
        local d = Geo.dist(p, q)
        if d < bestD then best, bestD = i, d end
    end
    return best, bestD
end

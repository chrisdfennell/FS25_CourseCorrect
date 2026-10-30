-- Guidance: field course generator.
--
-- A field course is the path of the vehicle's guidance point (the AI direction node): headland passes around the
-- field (and around islands in it), then straight rows across the inside, linked by turns. Straight pieces are
-- stored with their end points only, so even big fields give small courses (cheap to save and to send to clients).
--
-- Waypoint fields: x, z (world), t = type ("H" headland, "R" row, "T" turn, "C" connection),
-- work = implement lowered while driving to this point, rev = reversing to this point,
-- rs / re = start / end of a worked row or pass, pass = headland pass number (1 = outermost), row = row number,
-- island = island number of an island headland pass.

GuidanceCourseGenerator = {}
local CG = GuidanceCourseGenerator
local Geo, Dubins = GuidanceGeo, GuidanceDubins

CG.PATTERN_AUTO = "auto"
CG.PATTERN_ADJACENT = "adjacent"
CG.PATTERN_RACETRACK = "racetrack"
CG.PATTERN_LANDS = "lands" -- in lands of a few rows, each worked from its middle out (plowing)
CG.PATTERN_SPIRAL = "spiral" -- headland passes all the way in, no rows

CG.defaults = {
    workWidth = 6,
    headlands = -1, -- -1 = enough for the turns
    clockwise = true,
    headlandsFirst = true,
    rowAngle = nil, -- degrees, nil = automatic
    turnRadius = 6,
    runOut = 3, -- how far the guidance point is ahead of the end of the work area
    pattern = CG.PATTERN_AUTO,
    overlap = 0, -- fraction of the work width shared by neighbouring passes
    startX = nil, startZ = nil, -- vehicle position, the course starts close to it
    allowReverse = false, -- the vehicle can back up (nothing towed): three-point turns, square corners
    squareCorners = true, -- with allowReverse: work headland corners out square instead of rounding them
    islands = nil, -- list of polygons (lists of {x, z}) inside the field that are not field
    workSpeed = 12, -- km/h, only for comparing patterns
    minHeadlandWidth = 40, -- m, automatic headlands are at least this wide
    roundedPasses = 1, -- the innermost this many headland passes have round corners, the others sharp ones
    towLength = 0, -- m from the guidance point back to the middle of a towed implement (0: nothing towed)
}

CG.TURN_SPEED = 10 -- km/h, for the time estimate
CG.REVERSE_SPEED = 5
CG.DIRECTION_CHANGE_TIME = 4 -- s lost every time the vehicle stops and changes direction
CG.LOWER_TIME = 3 -- s standing while the implements go down at the start of a worked stretch
CG.ACCELERATION = 0.8 -- m/s², speeding up
CG.DECELERATION = 0.6 -- m/s², slowing down (as the driver does before a change of direction)
CG.LATERAL_ACCEL = 1.2 -- m/s², limits the speed in curves (as the driver)
CG.CURVE_MIN_SPEED = 4 -- km/h
CG.LOWER_APPROACH_SPEED = 8 -- km/h, the driver arrives at a worked stretch no faster
CG.VEHICLE_FRONT = 5 -- m the vehicle reaches ahead of its guidance point (near the rear axle)
CG.VEHICLE_HALF_WIDTH = 1.5 -- m, half the tractor's width (its front corners must stay on the field too)
CG.MAX_HEADLANDS = 15

-- corners of headland passes that are worked out square (with allowReverse), turn angle range
CG.SQUARE_CORNER_MIN = math.rad(50)
CG.SQUARE_CORNER_MAX = math.rad(125)

local function withDefaults(s)
    local out = {}
    for k, v in pairs(CG.defaults) do out[k] = v end
    for k, v in pairs(s or {}) do out[k] = v end
    return out
end

local function spacingOf(s)
    return s.workWidth * (1 - s.overlap)
end

--- How far a turn to the next row reaches beyond the end of the row
function CG.turnDepth(s, pattern)
    local spacing = spacingOf(s)
    if pattern == CG.PATTERN_RACETRACK or spacing >= 2 * s.turnRadius then
        -- wide U-turns: one turning radius
        return s.turnRadius
    end
    local from = {x = 0, y = 0, h = math.pi / 2}
    local to = {x = spacing, y = 0, h = -math.pi / 2}
    local path = Dubins.shortest(from, to, s.turnRadius)
    local depth = 0
    for _, p in ipairs(Dubins.sample(from, path, s.turnRadius, 0.5)) do
        depth = math.max(depth, p.y)
    end
    return depth
end

--- Tightest corner a towed implement follows well: the tractor drives round it with its own turning radius, the
--- implement, towLength behind, on a smaller circle (sqrt(R² - L²)); much tighter than 0.6 L it can't get round
--- in time
function CG.towedCornerRadius(s)
    local r, l = s.turnRadius, s.towLength or 0
    return math.max(1, 0.6 * l, math.sqrt(math.max(0, r * r - l * l)))
end

--- Number of headland passes: at least minHeadlandWidth wide, and enough to turn inside the field. At the far
--- end of a turn the implement lies across the way the row went, so half of its width reaches further towards
--- the field edge than the vehicle: the headland must hold the run out, the turn and that (or the front of the
--- vehicle at the end of the run out).
function CG.autoHeadlands(s, pattern)
    local spacing = spacingOf(s)
    local depth = s.runOut + math.max(CG.turnDepth(s, pattern) + s.workWidth / 2, CG.VEHICLE_FRONT)
    depth = math.max(depth, s.minHeadlandWidth or CG.defaults.minHeadlandWidth)
    return math.max(1, math.min(CG.MAX_HEADLANDS, math.ceil(depth / spacing - 1e-6)))
end

-----------------------------------------------------------------------------------------------------------------------
-- Rows
-----------------------------------------------------------------------------------------------------------------------

--- Crossings of the horizontal line y with the polygons (the field and its holes), sorted, as pairs {x1, x2}
local function sweepLine(polys, y)
    local xs = {}
    for _, poly in ipairs(polys) do
        local n = #poly
        for i = 1, n do
            local a, b = poly[i], poly[i % n + 1]
            if (a.y <= y and b.y > y) or (b.y <= y and a.y > y) then
                table.insert(xs, a.x + (y - a.y) * (b.x - a.x) / (b.y - a.y))
            end
        end
    end
    table.sort(xs)
    local segs = {}
    for i = 1, #xs - 1, 2 do
        table.insert(segs, {x1 = xs[i], x2 = xs[i + 1]})
    end
    return segs
end

--- Rows of polygons already rotated so rows run along x (polys[1] the outline, then other parts of the inside and
--- holes: a line's crossings pair up inside / outside). Returns lines of segments: lines[k] = {y, segs}
local function sweep(polys, spacing, minLength, phase)
    local minY, maxY = math.huge, -math.huge
    for _, poly in ipairs(polys) do
        local _, y0, _, y1 = Geo.bounds(poly)
        minY, maxY = math.min(minY, y0), math.max(maxY, y1)
    end
    local height = maxY - minY
    local n = math.max(1, math.ceil(height / spacing - 1e-6))
    local lines = {}
    if phase then
        -- tramlines: rows exactly at phase + k spacing (where another course's rows are), as many as fit
        local k0 = math.ceil((minY + spacing * 0.4 - phase) / spacing)
        local k1 = math.floor((maxY - spacing * 0.4 - phase) / spacing)
        for k = k0, k1 do
            local y = phase + k * spacing
            local segs = {}
            for _, s in ipairs(sweepLine(polys, y)) do
                if s.x2 - s.x1 >= minLength then table.insert(segs, s) end
            end
            table.insert(lines, {y = y, segs = segs})
        end
        return lines
    end
    -- spread evenly, first and last row half a width from the edge: the bit more than a whole number of rows
    -- is shared out as overlap, instead of squeezing a last row in next to the one before it (two rows that close
    -- need a deep turn, a wide implement would swing off the field)
    local step = n > 1 and (height - spacing) / (n - 1) or 0
    for k = 1, n do
        local y
        if n == 1 then
            y = (minY + maxY) / 2
        else
            y = minY + spacing / 2 + step * (k - 1)
        end
        local segs = {}
        for _, s in ipairs(sweepLine(polys, y)) do
            if s.x2 - s.x1 >= minLength then table.insert(segs, s) end
        end
        table.insert(lines, {y = y, segs = segs})
    end
    return lines
end

--- Groups the row segments into blocks: runs of rows that can be worked back and forth without crossing an
--- unworked part of the field.
--- How thick a polygon is: twice its area over its perimeter (a strip w wide: about w)
function CG.thickness(poly)
    local per = 0
    for i = 1, #poly do
        local a, b = poly[i], poly[i % #poly + 1]
        per = per + math.sqrt((b.x - a.x) ^ 2 + (b.y - a.y) ^ 2)
    end
    return per > 0 and 2 * math.abs(Geo.signedArea(poly)) / per or 0
end

local function splitBlocks(lines, minBlockLength)
    local blocks, open = {}, {}
    for _, line in ipairs(lines) do
        -- every open block continues with the segment overlapping its last row the most, as long as they share
        -- at least half of the shorter one. A notch in the outline then only splits off the small piece.
        local pairsByOverlap = {}
        for si, s in ipairs(line.segs) do
            for bi, b in ipairs(open) do
                local last = b.rows[#b.rows]
                local overlap = math.min(s.x2, last.x2) - math.max(s.x1, last.x1)
                local shorter = math.min(s.x2 - s.x1, last.x2 - last.x1)
                if overlap > 0.5 * shorter then
                    table.insert(pairsByOverlap, {si = si, bi = bi, overlap = overlap})
                end
            end
        end
        table.sort(pairsByOverlap, function(a, b) return a.overlap > b.overlap end)
        local segBlock, blockTaken = {}, {}
        for _, p in ipairs(pairsByOverlap) do
            if segBlock[p.si] == nil and not blockTaken[p.bi] then
                segBlock[p.si], blockTaken[p.bi] = p.bi, true
            end
        end
        local nextOpen = {}
        for si, s in ipairs(line.segs) do
            local row = {x1 = s.x1, x2 = s.x2, y = line.y}
            local b = segBlock[si] and open[segBlock[si]]
            if b then
                table.insert(b.rows, row)
            else
                b = {rows = {row}}
                table.insert(blocks, b)
            end
            table.insert(nextOpen, b)
        end
        open = nextOpen
    end
    -- tiny blocks cost more time to get to than they are worth, the headland covers most of them anyway
    local result, skipped = {}, 0
    for _, b in ipairs(blocks) do
        local len = 0
        for _, r in ipairs(b.rows) do len = len + r.x2 - r.x1 end
        if len >= (minBlockLength or 0) then
            table.insert(result, b)
        else
            skipped = skipped + len
        end
    end
    return result, skipped
end

--- A team member's strip of the rows: of all rows across the field (by their place across it), the k-th of n
--- equal runs. Blocks keep their rows in that strip, empty ones go.
function CG.stripBlocks(blocks, n, k)
    local ys = {}
    for _, blk in ipairs(blocks) do
        for _, row in ipairs(blk.rows) do ys[#ys + 1] = row.y end
    end
    table.sort(ys)
    local lines = {}
    for _, y in ipairs(ys) do
        if #lines == 0 or y - lines[#lines] > 0.01 then lines[#lines + 1] = y end
    end
    local first, last = math.floor((k - 1) * #lines / n) + 1, math.floor(k * #lines / n)
    if first > last then
        return {}
    end
    local lo, hi = lines[first] - 0.005, lines[last] + 0.005
    local result = {}
    for _, blk in ipairs(blocks) do
        local rows = {}
        for _, row in ipairs(blk.rows) do
            if row.y >= lo and row.y <= hi then rows[#rows + 1] = row end
        end
        if #rows > 0 then
            result[#result + 1] = {rows = rows}
        end
    end
    return result
end

--- Rows rowFrom..rowTo (counted across the field, 1 the first; 0: from the first / to the last). Returns the
--- blocks with those rows and how many rows there are in all.
function CG.rowRange(blocks, rowFrom, rowTo)
    local ys = {}
    for _, blk in ipairs(blocks) do
        for _, row in ipairs(blk.rows) do ys[#ys + 1] = row.y end
    end
    table.sort(ys)
    local lines = {}
    for _, y in ipairs(ys) do
        if #lines == 0 or y - lines[#lines] > 0.01 then lines[#lines + 1] = y end
    end
    local first = math.max(1, rowFrom or 0)
    local last = (rowTo or 0) > 0 and math.min(#lines, rowTo) or #lines
    if first > last then
        return {}, #lines
    end
    local lo, hi = lines[first] - 0.005, lines[last] + 0.005
    local result = {}
    for _, blk in ipairs(blocks) do
        local rows = {}
        for _, row in ipairs(blk.rows) do
            if row.y >= lo and row.y <= hi then rows[#rows + 1] = row end
        end
        if #rows > 0 then result[#result + 1] = {rows = rows} end
    end
    return result, #lines
end

--- The place (1, 2, ...) of a row at y among the rows' places across the field
local function rankOf(lines, y)
    for i, v in ipairs(lines) do
        if math.abs(v - y) <= 0.01 then return i end
    end
    return 0
end

--- The longest stretch of the outline (CCW) without a sharp corner: list of points, or the whole outline
--- (a round field) from its first point halfway round
function CG.edgeChain(poly, maxTurn)
    local n = #poly
    local sharp = {}
    local any = false
    for i = 1, n do
        local a, b, c = poly[(i - 2) % n + 1], poly[i], poly[i % n + 1]
        if math.abs(Geo.normAngle(Geo.heading(b, c) - Geo.heading(a, b))) > maxTurn then
            sharp[i] = true
            any = true
        end
    end
    local best, bestLen = nil, -1
    if not any then
        local chain, total, len = {}, 0, 0
        for i = 1, n do total = total + Geo.dist(poly[i], poly[i % n + 1]) end
        for i = 1, n + 1 do
            local p = poly[(i - 1) % n + 1]
            chain[#chain + 1] = p
            if i > 1 then len = len + Geo.dist(chain[#chain - 1], p) end
            if len > total / 2 then break end
        end
        return chain
    end
    for start = 1, n do
        if sharp[start] then
            local chain, len, i = {poly[start]}, 0, start
            repeat
                local j = i % n + 1
                len = len + Geo.dist(poly[i], poly[j])
                chain[#chain + 1] = poly[j]
                i = j
            until sharp[i] or i == start
            if len > bestLen then best, bestLen = chain, len end
        end
    end
    return best
end

--- A polyline moved d to its left (the inside of a CCW outline), corners mitred (but never more than twice d)
local function offsetLine(line, d)
    local out, n = {}, #line
    for i = 1, n do
        local a = line[math.max(1, i - 1)]
        local b = line[i]
        local c = line[math.min(n, i + 1)]
        local h1 = i > 1 and Geo.heading(a, b) or Geo.heading(b, c)
        local h2 = i < n and Geo.heading(b, c) or h1
        local nx1, ny1 = -math.sin(h1), math.cos(h1)
        local nx2, ny2 = -math.sin(h2), math.cos(h2)
        local nx, ny = nx1 + nx2, ny1 + ny2
        local len = math.sqrt(nx * nx + ny * ny)
        if len < 1e-6 then nx, ny, len = nx1, ny1, 1 end
        nx, ny = nx / len, ny / len
        local cosHalf = math.max(0.5, nx * nx1 + ny * ny1)
        out[i] = {x = b.x + nx * d / cosHalf, y = b.y + ny * d / cosHalf}
    end
    return out
end

--- Rows along the field's longest gently bent edge (curved rows): copies of that edge a work width apart, inside
--- the headland passes, off the islands. Blocks as splitBlocks makes them, the rows with their points (pts) and
--- y = their place across the field.
function CG.curvedBlocks(poly, inner, islands, s, spacing, headlandWidth)
    local edge = CG.edgeChain(poly, math.rad(35))
    local innerIndex = Geo.outlineIndex(inner, 10)
    local function usable(p)
        if not innerIndex:isInside(p) then return false end
        for _, island in ipairs(islands) do
            if island.zoneIndex:isInside(p) then return false end
        end
        return true
    end
    local x0, y0, x1, y1 = Geo.bounds(poly)
    local reach = math.sqrt((x1 - x0) ^ 2 + (y1 - y0) ^ 2)
    local rows = {}
    local empty = 0
    for k = 1, math.ceil(reach / spacing) + 2 do
        local line = offsetLine(edge, headlandWidth + (k - 0.5) * spacing)
        -- on past both ends, so the field's whole width is crossed, then smooth enough to drive at work speed
        local a, b2 = line[1], line[2]
        local h0 = Geo.heading(b2, a)
        table.insert(line, 1, {x = a.x + math.cos(h0) * reach, y = a.y + math.sin(h0) * reach})
        local m = #line
        local h1 = Geo.heading(line[m - 1], line[m])
        table.insert(line, {x = line[m].x + math.cos(h1) * reach, y = line[m].y + math.sin(h1) * reach})
        line = Geo.limitCurvature(Geo.removeSpikes(line), math.max(s.turnRadius, 2 * spacing), false)
        local dense = Geo.densify(line, 2)
        local run = nil
        local found = false
        local function close()
            if run and #run >= 2 then
                local len = 0
                for j = 2, #run do len = len + Geo.dist(run[j - 1], run[j]) end
                if len >= 2 * spacing then
                    table.insert(rows, {y = k, pts = Geo.simplify(run, 0.2), x1 = 0, x2 = len})
                    found = true
                end
            end
            run = nil
        end
        for _, p in ipairs(dense) do
            if usable(p) then
                run = run or {}
                run[#run + 1] = {x = p.x, y = p.y}
            else
                close()
            end
        end
        close()
        if found then empty = 0 else empty = empty + 1 end
        if empty >= 3 and k > 3 then break end
    end
    if #rows == 0 then return {} end
    return {{rows = rows}}
end

--- A team member works pass / island i (of a team of n, member k): dealt out in turn
local function isMine(i, s)
    local n = s.teamSize or 1
    return n <= 1 or (i - 1) % n == (s.teamIndex or 1) - 1
end

function CG.minBlockLength(spacing)
    return math.max(50, 10 * spacing)
end

local function rotateAll(polys, angle)
    local out = {}
    for i, p in ipairs(polys) do out[i] = Geo.rotate(p, angle) end
    return out
end

--- Cost of working the polygons with rows in this direction, in turns
local function rowCost(polys, angle, spacing, turnLength)
    local lines = sweep(rotateAll(polys, -angle), spacing, 2 * spacing)
    local blocks = splitBlocks(lines, CG.minBlockLength(spacing))
    local rows, offsetTravel = 0, 0
    for _, b in ipairs(blocks) do
        rows = rows + #b.rows
        -- where the field's end runs at a shallow angle to the rows, neighbouring rows end far apart and every
        -- turn gets longer by that
        for k = 2, #b.rows do
            local p, q = b.rows[k - 1], b.rows[k]
            offsetTravel = offsetTravel + (math.abs(p.x1 - q.x1) + math.abs(p.x2 - q.x2)) / 2
        end
    end
    -- moving to another block costs about as much as several turns
    return rows + 8 * #blocks + offsetTravel / turnLength
end

--- Row direction with the fewest turns (and blocks); prefers directions along the field's edges
function CG.findBestAngle(polys, spacing, turnLength)
    local poly = polys[1]
    local candidates = {}
    for i = 1, #poly do
        local a, b = poly[i], poly[i % #poly + 1]
        if Geo.dist(a, b) > 3 * spacing then
            table.insert(candidates, {angle = Geo.heading(a, b) % math.pi, edge = true})
        end
    end
    for deg = 0, 175, 5 do
        table.insert(candidates, {angle = math.rad(deg), edge = false})
    end
    local best, bestScore
    for _, c in ipairs(candidates) do
        -- edge directions get a small bonus: rows parallel to a straight edge look and work best
        local score = rowCost(polys, c.angle, spacing, turnLength) - (c.edge and 0.5 or 0)
        if bestScore == nil or score < bestScore then
            best, bestScore = c.angle, score
        end
    end
    return best or 0
end

--- Order of the rows of a block: list of {index, forward}. racetrack = work row i, then row i + half, back
--- to i + 1... so all turns are wide U-turns. lands: upFirst, the second row of the first land is the next one up
--- (else down); the other lands keep the worked ground on the same side of the vehicle.
local function rowOrder(n, pattern, firstForward, perLand, upFirst)
    local order = {}
    if pattern == CG.PATTERN_LANDS and n >= 2 then
        -- land by land; in a land its middle row first, then one each side in turn: the vehicle goes round the
        -- middle, every turn wider than the one before, the worked ground always on the same side
        local k = math.max(2, perLand or 6)
        local fwd = firstForward
        if upFirst == nil then upFirst = true end
        for first = 1, n, k do
            local last = math.min(n, first + k - 1)
            -- starting the other way than the first land: the other side first, so the worked ground stays on the
            -- same side of the vehicle
            local up = upFirst == (fwd == firstForward)
            -- the side taken first gets the extra row (they alternate to the end)
            local mid = up and math.floor((first + last) / 2) or math.ceil((first + last) / 2)
            local seq = {mid}
            for d = 1, k do
                local a, b = mid + d, mid - d
                if not up then a, b = b, a end
                if a >= first and a <= last then seq[#seq + 1] = a end
                if b >= first and b <= last then seq[#seq + 1] = b end
            end
            for _, i in ipairs(seq) do
                table.insert(order, {index = i, forward = fwd})
                fwd = not fwd
            end
        end
    elseif pattern == CG.PATTERN_RACETRACK and n >= 4 then
        local m = math.ceil(n / 2)
        local fwd = firstForward
        for i = 1, m do
            table.insert(order, {index = i, forward = fwd})
            fwd = not fwd
            if i + m <= n then
                table.insert(order, {index = i + m, forward = fwd})
                fwd = not fwd
            end
        end
    else
        local fwd = firstForward
        for i = 1, n do
            table.insert(order, {index = i, forward = fwd})
            fwd = not fwd
        end
    end
    return order
end

--- Lands: on which side of the vehicle (1 left, 2 right) the worked ground is while it drives the second row of
--- a block's order (the first row worked). The world's z points south: seen from above, a point is on the left
--- when the cross product of the way and the point is below 0.
function CG.workedSide(blk, order, reversed, rowEnds)
    local function rowOf(step)
        return blk.rows[reversed and (#blk.rows - step.index + 1) or step.index]
    end
    local a1, b1 = rowEnds(rowOf(order[1]), order[1].forward)
    local a2, b2 = rowEnds(rowOf(order[2]), order[2].forward)
    local mx, my = (a1.x + b1.x) / 2 - a2.x, (a1.y + b1.y) / 2 - a2.y
    local dx, dy = b2.x - a2.x, b2.y - a2.y
    return dx * my - dy * mx < 0 and 1 or 2
end

-----------------------------------------------------------------------------------------------------------------------
-- Headland passes
-----------------------------------------------------------------------------------------------------------------------

--- Corners of a closed CCW polygon that can be worked out square: convex, not too sharp, with long enough edges
--- on both sides for the manoeuvre. Returns a set of vertex indices.
--- How far the vehicle can drive on beyond corner c (heading h1, turning by 'turn' there) to work the corner out
--- square, without its front or the ends of its implement getting off the field, up to what it would want.
--- Returns that distance (-1 if c is no place for it) and the distance it would want.
local function squareCornerRoom(c, h1, turn, s, fieldIndex)
    local spacing = spacingOf(s)
    local fx, fy = math.cos(h1), math.sin(h1)
    local lat = math.max(0, s.workWidth / 2 - 0.5)
    local function fits(d)
        local px, py = c.x + fx * d, c.y + fy * d
        local nose = CG.VEHICLE_HALF_WIDTH
        local probes = {
            {x = px + fx * CG.VEHICLE_FRONT - fy * nose, y = py + fy * CG.VEHICLE_FRONT + fx * nose},
            {x = px + fx * CG.VEHICLE_FRONT + fy * nose, y = py + fy * CG.VEHICLE_FRONT - fx * nose},
            {x = px - fy * lat, y = py + fx * lat},
            {x = px + fy * lat, y = py - fx * lat},
        }
        for _, p in ipairs(probes) do
            if not fieldIndex:isInside(p) then return false end
        end
        return true
    end
    local wanted = math.min(spacing / 2 * math.tan(math.abs(turn) / 2), spacing) + s.runOut
    local room = -1
    if fits(0) then
        room = 0
        while room + 0.5 <= wanted and fits(room + 0.5) do room = room + 0.5 end
    end
    return room, wanted
end

local function findSquareCorners(poly, s, fieldIndex)
    local corners, n = {}, #poly
    for i = 1, n do
        local prev, cur, nxt = poly[(i - 2) % n + 1], poly[i], poly[i % n + 1]
        local turn = Geo.normAngle(Geo.heading(cur, nxt) - Geo.heading(prev, cur))
        if turn >= CG.SQUARE_CORNER_MIN and turn <= CG.SQUARE_CORNER_MAX then
            local a = s.turnRadius * math.tan(turn / 2)
            -- room for the manoeuvre in both driving directions (the pass may be driven either way round)
            if math.min(Geo.dist(prev, cur), Geo.dist(cur, nxt)) >= 2 * a + 2
                    and squareCornerRoom(cur, Geo.heading(prev, cur), turn, s, fieldIndex) >= s.runOut + 0.5
                    and squareCornerRoom(cur, Geo.heading(nxt, cur), turn, s, fieldIndex) >= s.runOut + 0.5 then
                corners[i] = true
            end
        end
    end
    return corners
end

--- Smooths a headland pass polygon so the vehicle can drive it. The corners in 'square' stay sharp and are marked
--- (corner = true), the manoeuvre is made there when the pass is worked. keepAway: {poly, dist}, the pass must
--- stay that far inside the field outline (bends are pushed inside, never cut towards the edge)
local function smoothRing(poly, s, square, keepAway, radius)
    local r = radius or s.turnRadius
    local first
    for i = 1, #poly do
        if square and square[i] then first = i break end
    end
    if first == nil then
        local ring = Geo.roundCorners(poly, r, true, math.rad(8), 1.5, keepAway)
        ring = Geo.limitCurvature(ring, r, true, nil, keepAway)
        return Geo.removeDuplicates(ring, 0.1)
    end
    -- open pieces from one square corner to the next, each smoothed on its own
    local n, ring = #poly, {}
    local i = first
    repeat
        local piece = {poly[i]}
        local j = i % n + 1
        while not square[j] do
            table.insert(piece, poly[j])
            j = j % n + 1
        end
        table.insert(piece, poly[j])
        piece = Geo.roundCorners(piece, r, false, math.rad(8), 1.5, keepAway)
        piece = Geo.limitCurvature(piece, r, false, nil, keepAway)
        piece = Geo.removeDuplicates(piece, 0.1)
        local corner = {x = poly[i].x, y = poly[i].y, corner = true}
        table.insert(ring, corner)
        for k = 2, #piece - 1 do
            table.insert(ring, piece[k])
        end
        i = j
    until i == first
    return ring
end

-----------------------------------------------------------------------------------------------------------------------
-- Course assembly
-----------------------------------------------------------------------------------------------------------------------

local Builder = {}
Builder.__index = Builder

--- area: {field = outline, inner = inside of the headlands (or nil), innerRing = innermost headland pass (of the
--- main part), outerRing = the outermost pass (round the whole field: every part), islands = list of {hull, pad,
--- zone, rings}}
local function newBuilder(s, area)
    local b = setmetatable({s = s, wps = {}}, Builder)
    -- outline indexes for fast checks, kept in the area for later use (planApproach)
    if area.field and area.fieldIndex == nil then area.fieldIndex = Geo.outlineIndex(area.field, 10) end
    if area.inner and area.innerIndex == nil then area.innerIndex = Geo.outlineIndex(area.inner, 10) end
    for k, v in pairs(area) do b[k] = v end
    return b
end

function Builder:add(x, y, t, work, extra)
    local last = self.wps[#self.wps]
    if last and math.abs(last.x - x) < 0.05 and math.abs(last.z - y) < 0.05 then
        -- same point again (a connection ends where a pass starts): keep one, with the flags of both. The type,
        -- work and direction of a waypoint describe the way to it, that stays the one of the first.
        if extra then
            for k, v in pairs(extra) do
                if k ~= "rev" then last[k] = v end
            end
        end
        return last
    end
    local wp = {x = x, z = y, t = t, work = work}
    if extra then
        for k, v in pairs(extra) do wp[k] = v end
    end
    table.insert(self.wps, wp)
    return wp
end

--- Pose at the end of the course: position and the heading the vehicle faces (not the way it moves)
function Builder:lastPose()
    local n = #self.wps
    local a, b = self.wps[n - 1], self.wps[n]
    local h = math.atan2(b.z - a.z, b.x - a.x)
    if b.rev then h = h + math.pi end
    return {x = b.x, y = b.z, h = h}
end

function Builder:hasPoints()
    return #self.wps >= 2
end

--- Points of a Dubins path from pose 'from' to pose 'to'
function Builder:dubinsBetween(from, to)
    if Geo.dist({x = from.x, y = from.y}, to) < 0.1 then
        return {}
    end
    local path = Dubins.shortest(from, to, self.s.turnRadius)
    if path == nil then
        return {{x = to.x, y = to.y}}
    end
    return Dubins.sample(from, path, self.s.turnRadius, 1.5)
end

--- Points of a Dubins path from the current end of the course to pose 'to'
function Builder:dubinsTo(to)
    return self:dubinsBetween(self:lastPose(), to)
end

--- Drives from the current end of the course to pose 'to' with a Dubins path, implement raised
function Builder:connect(to, t)
    if not self:hasPoints() then
        return
    end
    for _, p in ipairs(self:dubinsTo(to)) do
        self:add(p.x, p.y, t or "C", false)
    end
end

--- Is the path (from the end of the course through pts) somewhere it must not be? Every 2 m the vehicle is put on
--- the path, facing the way it drives there, with its implement: the corners of the work area and the front of
--- the vehicle must be on the field and off islands. Returns the reason of the first problem: "island" (and
--- which), "outside" (off the field), "inner" (cuts into the middle of the field), or nil; how many points have a
--- problem, and how many of them are off the field or on an island.
function Builder:checkPath(pts, allowOutside)
    local tolerance = self.s.workWidth
    local from = self:lastPose()
    local prev = {x = from.x, y = from.y}
    local firstProblem, firstIsland, count, danger, outside = nil, nil, 0, 0, 0
    for _, p in ipairs(pts) do
        local dx, dy = p.x - prev.x, p.y - prev.y
        local len = math.sqrt(dx * dx + dy * dy)
        if len > 1e-3 then
            local h = math.atan2(dy, dx)
            if p.rev then h = h + math.pi end
            local steps = math.max(1, math.ceil(len / 2))
            for k = 1, steps do
                local q = {x = prev.x + dx * k / steps, y = prev.y + dy * k / steps}
                local problem, hit = self:checkPoint(q, h, allowOutside, tolerance)
                if problem then
                    count = count + 1
                    if problem ~= "inner" then danger = danger + 1 end
                    if problem == "outside" then outside = outside + 1 end
                    if firstProblem == nil then firstProblem, firstIsland = problem, hit end
                end
            end
        end
        prev = p
    end
    return firstProblem, firstIsland, count, danger, outside
end

--- Corners of the work area (half a work width to the sides, from the guidance point back to the end of the
--- implement) and the front corners of the vehicle, at p facing h. A mounted implement is rigid: in a bend its back
--- swings out. A towed one follows the path behind the hitch (cutting inside), where the path was checked
--- already, so only the hitch end counts.
function Builder:footprint(p, h)
    local s = self.s
    local half = s.workWidth / 2
    local back = s.allowReverse and math.max(0, s.runOut - 0.5) or 0
    local fx, fy = math.cos(h), math.sin(h)
    local lx, ly = -fy, fx
    return {
        {x = p.x + lx * half, y = p.y + ly * half},
        {x = p.x - lx * half, y = p.y - ly * half},
        {x = p.x - fx * back + lx * half, y = p.y - fy * back + ly * half},
        {x = p.x - fx * back - lx * half, y = p.y - fy * back - ly * half},
        {x = p.x + fx * CG.VEHICLE_FRONT + lx * CG.VEHICLE_HALF_WIDTH, y = p.y + fy * CG.VEHICLE_FRONT + ly * CG.VEHICLE_HALF_WIDTH},
        {x = p.x + fx * CG.VEHICLE_FRONT - lx * CG.VEHICLE_HALF_WIDTH, y = p.y + fy * CG.VEHICLE_FRONT - ly * CG.VEHICLE_HALF_WIDTH},
    }
end

function Builder:checkPoint(p, h, allowOutside, tolerance)
    local corners = self:footprint(p, h)
    for _, island in ipairs(self.islands or {}) do
        for _, c in ipairs(corners) do
            if island.padIndex:isInside(c) then
                return "island", island
            end
        end
    end
    if not allowOutside then
        for _, c in ipairs(corners) do
            if not self.fieldIndex:isInside(c) and self.fieldIndex:closest(c, 0.3) == nil then
                return "outside"
            end
        end
    end
    if self.innerIndex and self.innerIndex:isInside(p) and self.innerIndex:closest(p, tolerance) == nil then
        -- inside the rows, unless in the headland of an island
        local inIslandHeadland = false
        for _, island in ipairs(self.islands or {}) do
            if island.zoneIndex:isInside(p) or island.zoneIndex:closest(p, tolerance) then
                inIslandHeadland = true
                break
            end
        end
        if not inIslandHeadland then
            return "inner"
        end
    end
    return nil
end

--- Drives to pose 'to' (a turn to the next row, the move to another block or headland pass). Tries the direct
--- way first; where that would cut into the middle of the field (odd shaped ends, racetrack on a slanted edge),
--- take the implement off the field (a narrow headland, a notch in the outline) or hit an island: a three-point
--- turn (if the vehicle can back up), then along the innermost headland or around the island. Takes the first
--- that has no problem, or the one with the fewest.
function Builder:route(to, t, allowOutside)
    local from = self:lastPose()
    local direct = self:dubinsTo(to)
    if #direct == 0 or self.field == nil then
        self:addPoints(direct, t)
        return true
    end
    local best, bestCount, bestDanger, bestOutside
    local function try(pts)
        if pts == nil or (best and bestCount == 0) then return nil end
        local problem, island, count, danger, outside = self:checkPath(pts, allowOutside)
        -- off the field or on an island is worse than over unworked land
        if best == nil or danger < bestDanger or (danger == bestDanger and count < bestCount) then
            best, bestCount, bestDanger, bestOutside = pts, count, danger, outside
        end
        return problem, island
    end
    local problem, island = try(direct)
    if problem and self.s.allowReverse then
        try(CG.threePointTurn(from, to, self.s.turnRadius))
    end
    if problem == "island" then
        try(self:ringPath(island.rings[1], from, to))
    end
    if problem then
        try(self:ringPath(self.innerRing, from, to))
    end
    -- from one part of the field to another (the inside split at a notch): round by the outermost pass, which goes
    -- round all of them
    if problem and self.outerRing and self.outerRing ~= self.innerRing and (best == nil or bestCount > 0) then
        try(self:ringPath(self.outerRing, from, to))
    end
    -- still off the field (between parts of a field split at a notch): a way on the field found on a grid
    if bestOutside > 0 and not allowOutside and GuidancePathfinder and self.field then
        local ok, pts = pcall(GuidancePathfinder.find, {field = self.field, fieldIndex = self.fieldIndex},
            {workWidth = self.s.workWidth, turnRadius = self.s.turnRadius}, from, to, nil)
        if ok and pts and #pts > 0 then
            local list = {}
            for _, p in ipairs(pts) do list[#list + 1] = {x = p.x, y = p.y} end
            try(list)
        end
    end
    if bestOutside > 0 and not allowOutside then
        -- remembered: automatic headlands get another pass then
        self.offField = (self.offField or 0) + 1
        self.offFieldSpots = self.offFieldSpots or {}
        table.insert(self.offFieldSpots, {x = from.x, y = from.y, toX = to.x, toY = to.y, t = t})
    end
    self:addPoints(best, t)
    -- nothing in the way and only forward: an implement may stay down here
    local clean = bestCount == 0
    for _, p in ipairs(best) do
        if p.rev then clean = false end
    end
    return clean
end

--- Adds points {x, y, rev} as type t, implement raised
function Builder:addPoints(pts, t)
    for _, p in ipairs(pts) do
        self:add(p.x, p.y, t, false, p.rev and {rev = true} or nil)
    end
end

--- A three-point turn from pose 'from' to pose 'to' (about the opposite heading, to the side): forward quarter
--- circle, straight back (or on, when the rows are far enough apart), forward quarter circle, straight on to
--- 'to'. Needs only one turning radius beyond the end of the row, whatever the row spacing. Returns the points,
--- or nil if 'to' isn't a place for this.
function CG.threePointTurn(from, to, r, maxStep)
    maxStep = maxStep or 1.5
    if math.abs(Geo.normAngle(to.h - from.h - math.pi)) > math.rad(10) then
        return nil
    end
    local fx, fy = math.cos(from.h), math.sin(from.h)
    local lx, ly = -fy, fx
    local dx, dy = to.x - from.x, to.y - from.y
    local lat, lon = dx * lx + dy * ly, dx * fx + dy * fy
    local side = lat >= 0 and 1 or -1
    local width = math.abs(lat)
    if width < 0.5 then
        return nil
    end
    -- a = along the row, b = across, towards the next row
    local function at(a, b)
        return {x = from.x + fx * a + lx * side * b, y = from.y + fy * a + ly * side * b}
    end
    local pts = {}
    local m = math.max(0, lon)
    if m > 0.1 then
        table.insert(pts, at(m, 0))
    end
    local steps = math.max(3, math.ceil(math.pi / 2 * r / maxStep))
    for k = 1, steps do
        local th = -math.pi / 2 + math.pi / 2 * k / steps
        table.insert(pts, at(m + r * math.cos(th), r + r * math.sin(th)))
    end
    local b2 = width - r
    if math.abs(b2 - r) > 0.2 then
        local p = at(m + r, b2)
        p.rev = b2 < r
        table.insert(pts, p)
    end
    for k = 1, steps do
        local th = math.pi / 2 * k / steps
        table.insert(pts, at(m + r * math.cos(th), b2 + r * math.sin(th)))
    end
    if m - lon > 0.1 then
        table.insert(pts, {x = to.x, y = to.y})
    end
    return pts
end

--- The manoeuvre at a square corner of a headland pass, from 'prev' through the corner c towards 'nxt': work on
--- past the corner until the whole corner is covered, back up, turn into the next edge, back up to where its work
--- starts. The waypoints after this continue the pass.
function Builder:addSquareCorner(prev, c, nxt, pass, extra)
    local s = self.s
    local r, spacing = s.turnRadius, spacingOf(s)
    local h1, h2 = Geo.heading(prev, c), Geo.heading(c, nxt)
    local turn = Geo.normAngle(h2 - h1)
    local side = turn > 0 and 1 or -1
    local tanHalf = math.tan(math.abs(turn) / 2)
    local f1x, f1y, f2x, f2y = math.cos(h1), math.sin(h1), math.cos(h2), math.sin(h2)
    local a = r * tanHalf
    local q = math.max(0, math.min(spacing / 2, a - 1))
    local flags = {pass = pass}
    for k, v in pairs(extra or {}) do flags[k] = v end
    -- work on until the end of the pass covers the corner, but the vehicle never drives off the field: neither
    -- its front nor the ends of the implement (findSquareCorners only picks corners with room for it). If there
    -- is no room after all, round the corner.
    local room, wanted = squareCornerRoom(c, h1, turn, s, self.fieldIndex)
    if room < s.runOut + 0.5 then
        -- the arc replaces the straight bit right before the corner (a waypoint there would put the front of the
        -- vehicle over the edge)
        local t = r * tanHalf
        while #self.wps > 1 do
            local w = self.wps[#self.wps]
            local ahead = (c.x - w.x) * f1x + (c.y - w.z) * f1y
            if w.t == "H" and not w.rs and ahead > -0.05 and ahead < t + 0.05 then
                table.remove(self.wps)
            else
                break
            end
        end
        -- arms long enough for the full radius (the edges next to a square corner are, see findSquareCorners)
        local arm = a + 1
        local arc = Geo.roundCorners({{x = c.x - f1x * arm, y = c.y - f1y * arm}, c,
                                      {x = c.x + f2x * arm, y = c.y + f2y * arm}}, r, false, math.rad(1), 1.5)
        for k = 2, #arc - 1 do
            self:add(arc[k].x, arc[k].y, "H", true, flags)
        end
        return
    end
    local runEnd = math.min(wanted, room)
    local e = runEnd - s.runOut
    self:add(c.x + f1x * e, c.y + f1y * e, "H", true, flags)
    self:add(c.x + f1x * runEnd, c.y + f1y * runEnd, "C", false)
    -- back up to where a turn of radius r gets onto the next edge
    local rx, ry = c.x - f1x * a, c.y - f1y * a
    self:add(rx, ry, "C", false, {rev = true})
    local cx, cy = rx - f1y * r * side, ry + f1x * r * side
    local a0 = math.atan2(ry - cy, rx - cx)
    local steps = math.max(3, math.ceil(math.abs(turn) * r / 1.5))
    for k = 1, steps do
        local ang = a0 + turn * k / steps
        self:add(cx + math.cos(ang) * r, cy + math.sin(ang) * r, "C", false)
    end
    -- back up to where the work on the next edge starts
    self:add(c.x + f2x * q, c.y + f2y * q, "C", false, {rev = true})
end

--- A closed headland pass, starting and ending at ring[1]
function Builder:addRing(ring, pass, extra)
    local n = #ring
    for i = 1, n + 1 do
        local p = ring[(i - 1) % n + 1]
        local flags = {pass = pass, rs = i == 1 or nil, re = i == n + 1 or nil}
        for k, v in pairs(extra or {}) do flags[k] = v end
        if p.corner and i > 1 and i <= n then
            self:addSquareCorner(ring[i - 1], p, ring[i % n + 1], pass, extra)
        else
            self:add(p.x, p.y, "H", true, flags)
        end
    end
end

local function rotateRing(ring, startIx)
    local out = {}
    for i = 0, #ring - 1 do
        table.insert(out, ring[(startIx - 1 + i) % #ring + 1])
    end
    return out
end

--- Closest point to p on a closed ring: edge index (from ring[i] to ring[i + 1]) and fraction along it
local function projectOnRing(ring, p)
    local bestI, bestT, bestD = 1, 0, math.huge
    for i = 1, #ring do
        local d, t = Geo.distToSegment(p, ring[i], ring[i % #ring + 1])
        if d < bestD then bestI, bestT, bestD = i, t, d end
    end
    return bestI, bestT
end

--- Copy of the ring with a point inserted on edge i at fraction t, and the index of that point
local function splitRing(ring, i, t)
    local a, b = ring[i], ring[i % #ring + 1]
    local out = {}
    for k = 1, i do out[k] = ring[k] end
    local ix = i
    if t > 1e-6 and t < 1 - 1e-6 then
        ix = i + 1
        table.insert(out, {x = a.x + (b.x - a.x) * t, y = a.y + (b.y - a.y) * t})
    elseif t >= 1 - 1e-6 then
        ix = i % #ring + 1
    end
    for k = i + 1, #ring do table.insert(out, ring[k]) end
    return out, ix
end

--- The ring, starting 'ahead' meters (in driving direction) after the point closest to p
local function ringStartingNear(ring, p, ahead)
    local i, t = projectOnRing(ring, p)
    -- walk along the ring from the projected point
    local remaining = ahead
    local a, b = ring[i], ring[i % #ring + 1]
    local len = Geo.dist(a, b)
    local along = len * t
    for _ = 1, #ring + 1 do
        if along + remaining <= len or len == 0 then
            local f = len > 0 and (along + remaining) / len or 0
            local split, ix = splitRing(ring, i, f)
            return rotateRing(split, ix)
        end
        remaining = remaining - (len - along)
        along = 0
        i = i % #ring + 1
        a, b = ring[i], ring[i % #ring + 1]
        len = Geo.dist(a, b)
    end
    return ring
end

--- The ring started on a straight stretch: on the first edge (in driving direction, from ring[1] on) at least
--- 'need' long, 'lead' meters into it; on the longest edge if none is that long.
local function startOnStraight(ring, need, lead)
    local n = #ring
    local pick, pickLen
    for i = 1, n do
        local len = Geo.dist(ring[i], ring[i % n + 1])
        if len >= need then
            pick, pickLen = i, len
            break
        end
        if pickLen == nil or len > pickLen + 1e-6 then
            pick, pickLen = i, len
        end
    end
    if pick == nil or pickLen < 1 then
        return ring
    end
    local split, ix = splitRing(ring, pick, math.min(lead, pickLen / 2) / pickLen)
    return rotateRing(split, ix)
end

--- Points along a closed ring from the point closest to p to the point closest to q, in driving direction of the
--- ring or against it
local function ringBetween(ring, p, q, forward)
    local r = forward and ring or Geo.reverse(ring)
    local i, t = projectOnRing(r, p)
    local split, ix = splitRing(r, i, t)
    split = rotateRing(split, ix)
    local j, u = projectOnRing(split, q)
    local out = {}
    for k = 1, j do out[k] = split[k] end
    local a, b = split[j], split[j % #split + 1]
    table.insert(out, {x = a.x + (b.x - a.x) * u, y = a.y + (b.y - a.y) * u})
    return out
end

--- The way from pose 'from' to pose 'to' along a closed ring (the shorter way round), as points, or nil if the
--- two are too close together on the ring
function Builder:ringPath(ring, from, to)
    if ring == nil or #ring < 3 then
        return nil
    end
    -- join the ring a turning circle after the closest point, leave it a turning circle before, so the Dubins
    -- pieces at both ends can be smooth
    local margin = 2 * self.s.turnRadius
    local fwdPath = Geo.trimPolyline(ringBetween(ring, from, to, true), margin)
    local bwdPath = Geo.trimPolyline(ringBetween(ring, from, to, false), margin)
    local path
    if fwdPath and (bwdPath == nil or Geo.length(fwdPath) <= Geo.length(bwdPath)) then
        path = fwdPath
    else
        path = bwdPath
    end
    if path == nil then
        return nil
    end
    local pts = self:dubinsBetween(from, {x = path[1].x, y = path[1].y, h = Geo.heading(path[1], path[2])})
    for i = 2, #path do
        table.insert(pts, {x = path[i].x, y = path[i].y})
    end
    local n = #path
    for _, p in ipairs(self:dubinsBetween({x = path[n].x, y = path[n].y, h = Geo.heading(path[n - 1], path[n])}, to)) do
        table.insert(pts, p)
    end
    return pts
end

-----------------------------------------------------------------------------------------------------------------------
-- Main
-----------------------------------------------------------------------------------------------------------------------

--- Seconds to drive the waypoints (for comparing patterns)
--- Seconds to drive from one speed to another over d metres, no faster than vMax (m/s), speeding up with a and
--- slowing down with b
local function stretchTime(d, v0, v1, vMax, a, b)
    if d <= 0 then return 0 end
    local accelD = math.max(0, (vMax * vMax - v0 * v0) / (2 * a))
    local decelD = math.max(0, (vMax * vMax - v1 * v1) / (2 * b))
    if accelD + decelD <= d then
        return (vMax - v0) / a + (vMax - v1) / b + (d - accelD - decelD) / vMax
    end
    -- never gets to vMax: up to a peak and down again
    local peak = math.sqrt(math.max(v0 * v0, v1 * v1, (2 * a * b * d + b * v0 * v0 + a * v1 * v1) / (a + b)))
    return math.max(0, peak - v0) / a + math.max(0, peak - v1) / b
end

--- How long driving the course takes, as the driver does it: work speed on worked stretches, turn speed and
--- slower in curves, stopping where the direction changes and where the implements go down (not where they stay
--- down through a turn), speeding up and slowing down in between. Returns the seconds from the start to each
--- waypoint (the last one is the whole course).
function CG.timeProfile(wps, workSpeed, turnSpeed, reverseSpeed)
    turnSpeed, reverseSpeed = turnSpeed or CG.TURN_SPEED, reverseSpeed or CG.REVERSE_SPEED
    local n = #wps
    local times = {0}
    if n < 2 then return times end
    local lengths, limits = {}, {}
    for i = 2, n do
        local a, b = wps[i - 1], wps[i]
        lengths[i] = math.sqrt((b.x - a.x) ^ 2 + (b.z - a.z) ^ 2)
        local speed = b.rev and reverseSpeed or (b.work and workSpeed or turnSpeed)
        limits[i] = speed / 3.6
    end
    -- speed at each waypoint: 0 at the ends, where the direction changes and where the implements go down,
    -- limited by the curve there
    local nodes, waits = {}, {}
    for i = 1, n do
        local v = math.huge
        local wait = 0
        if i == 1 or i == n then
            v = 0
        else
            local a, b, c = wps[i - 1], wps[i], wps[i + 1]
            if (b.rev or false) ~= (c.rev or false) then
                v, wait = 0, CG.DIRECTION_CHANGE_TIME
            else
                local h1 = math.atan2(b.z - a.z, b.x - a.x)
                local h2 = math.atan2(c.z - b.z, c.x - b.x)
                local turn = math.abs(Geo.normAngle(h2 - h1))
                if turn > 0.01 then
                    local radius = math.min(lengths[i], lengths[i + 1]) / turn
                    v = math.max(CG.CURVE_MIN_SPEED / 3.6, math.sqrt(CG.LATERAL_ACCEL * radius))
                end
            end
            -- a worked stretch starts here with the implements up: stop and lower them
            if c.work and not b.work and not c.rev and not b.keep then
                v, wait = 0, wait + CG.LOWER_TIME
            elseif c.work and not b.work then
                v = math.min(v, CG.LOWER_APPROACH_SPEED / 3.6)
            end
            v = math.min(v, limits[i], limits[i + 1])
        end
        nodes[i], waits[i] = v, wait
    end
    -- what can be reached speeding up from the waypoint before, and slowing down for the one after
    for i = 2, n do
        nodes[i] = math.min(nodes[i], math.sqrt(nodes[i - 1] ^ 2 + 2 * CG.ACCELERATION * lengths[i]))
    end
    for i = n - 1, 1, -1 do
        nodes[i] = math.min(nodes[i], math.sqrt(nodes[i + 1] ^ 2 + 2 * CG.DECELERATION * lengths[i + 1]))
    end
    local time = waits[1]
    for i = 2, n do
        time = time + stretchTime(lengths[i], nodes[i - 1], nodes[i], limits[i], CG.ACCELERATION, CG.DECELERATION)
        times[i] = time
        time = time + waits[i]
    end
    return times
end

function CG.estimateTime(wps, s)
    local times = CG.timeProfile(wps, s.workSpeed, s.turnSpeed, s.reverseSpeed)
    return times[#times]
end

--- Islands that fit into the inside of the headlands, with their headland passes: list of
--- {hull, pad (the island and a little room), zone (island and its headland), rings (outermost first)}
local function prepareIslands(islandPolys, inner, nPasses, s)
    local spacing = spacingOf(s)
    local result, ignored = {}, 0
    for _, poly in ipairs(islandPolys or {}) do
        local pts = {}
        for i, p in ipairs(poly) do pts[i] = {x = p.x, y = p.y or p.z} end
        local hull = Geo.convexHull(pts)
        if #hull >= 1 then
            -- as many passes round it as turning needs (fewer would leave no room to turn at the rows' ends: the
            -- turns would go over it)
            local passes = nPasses
            local zone = Geo.ringAroundConvex(hull, passes * spacing, s.turnRadius)
            local fits = inner ~= nil
            for _, p in ipairs(zone) do
                if not fits then break end
                fits = Geo.pointInPolygon(p, inner)
            end
            if fits then
                local pad = Geo.ringAroundConvex(hull, 1, 0.5)
                local island = {hull = hull, zone = zone, pad = pad, rings = {},
                                zoneIndex = Geo.outlineIndex(zone, 10), padIndex = Geo.outlineIndex(pad, 10)}
                for i = passes, 1, -1 do
                    local ring = Geo.ringAroundConvex(hull, (i - 0.5) * spacing, s.turnRadius)
                    -- around an island the other way round than around the field: the side of the vehicle
                    -- facing the island is the one facing the field edge on the outer passes
                    if s.clockwise then ring = Geo.reverse(ring) end
                    table.insert(island.rings, ring)
                end
                table.insert(result, island)
            else
                ignored = ignored + 1
            end
        end
    end
    return result, ignored
end

local function generateCourse(boundary, s)
    local spacing = spacingOf(s)
    local poly = {}
    for i, p in ipairs(boundary) do
        poly[i] = {x = p.x, y = p.y or p.z}
    end
    poly = Geo.removeDuplicates(poly, 0.1)
    if #poly < 3 then
        return nil, "field outline has too few points"
    end
    -- the real outline, the headland passes keep their distance from it
    local outlineIndex = Geo.outlineIndex(Geo.ensureCCW(Geo.copy(poly)), 10)
    -- points where the outline turns sharply into the field (the tip of a notch), small jags left out
    local sharpInwardPoints = {}
    do
        local coarse = Geo.ensureCCW(Geo.simplify(Geo.ensureCCW(Geo.copy(poly)), 2))
        local n = #coarse
        for i = 1, n do
            local prev, cur, nxt = coarse[(i - 2) % n + 1], coarse[i], coarse[i % n + 1]
            if Geo.normAngle(Geo.heading(cur, nxt) - Geo.heading(prev, cur)) < -math.rad(60) then
                table.insert(sharpInwardPoints, cur)
            end
        end
    end
    poly = Geo.ensureCCW(Geo.simplify(poly, 0.25))
    local start = {x = s.startX or poly[1].x, y = s.startZ or poly[1].y}
    local pattern = s.pattern

    -- headland passes, outermost first, each a closed ring in driving direction. rings are fully rounded (for
    -- routing along them), workRings may have square corners
    local nHeadlands = s.headlands
    if nHeadlands < 0 then nHeadlands = CG.autoHeadlands(s, pattern) end
    local spiral = pattern == CG.PATTERN_SPIRAL
    if spiral then nHeadlands = 500 end
    local rings, workRings = {}, {}
    -- headland levels made (a level may have several rings: where the field's inside splits into parts, e.g. at a
    -- deep notch, each part big enough to turn in gets its passes), and the innermost ring of the main part
    local levels, mainInnerRing, otherRings = 0, nil, {}
    for i = 1, nHeadlands do
        -- small steps in the outline come out of a big offset as folds: iron them out, more the further in the
        -- pass is (the pass still keeps its distance from the real outline, see keepAway)
        local base = i == 1 and poly or Geo.ensureCCW(Geo.simplify(poly, math.min(1.5, (i - 0.5) * spacing * 0.25)))
        local pieces = Geo.offsetInward(base, (i - 0.5) * spacing)
        if #pieces == 0 then break end
        -- spiral: until there is no room left to turn in
        if spiral and math.abs(Geo.signedArea(pieces[1])) < (2 * s.turnRadius + spacing) ^ 2 then break end
        -- the main part first, then the other parts thick enough to turn in (narrow tails stay with the outer passes)
        local parts = {pieces[1]}
        if not spiral then
            for k = 2, #pieces do
                if CG.thickness(pieces[k]) >= math.max(2 * s.turnRadius, 2 * spacing) then parts[#parts + 1] = pieces[k] end
            end
        end
        for partIx, part in ipairs(parts) do
        -- no going into tails of the field too narrow to turn in
        local sharp = Geo.mergeShortEdges(Geo.openPolygon(Geo.removeSpikes(part), s.turnRadius), s.turnRadius)
        -- the implement reaches half a work width to the side: the outermost pass works up to the edge, not over.
        -- Around sharp inward points of the outline it can't turn that close, it keeps a turning radius away there.
        local dist = (i - 0.5) * spacing
        local circles = {}
        for _, v in ipairs(sharpInwardPoints) do
            if s.turnRadius + 0.5 > dist then
                table.insert(circles, {x = v.x, y = v.y, r = s.turnRadius + 0.5})
            end
        end
        local keepAway = {index = outlineIndex, dist = dist, circles = circles}
        local ring = smoothRing(sharp, s, nil, keepAway)
        local workRing = ring
        -- the inner passes have round corners (a smooth way into the rows), the outer ones sharp corners: worked
        -- out square with a short reverse, or with a towed implement, a tight corner for the implement while the
        -- tractor swings wide (it can pivot behind the tractor, see the driver)
        local rounded = s.roundedPasses < 0 or i > nHeadlands - s.roundedPasses
        if s.towLength > 0 then
            -- towed: the pass is where the implement goes, the tractor drives towLength ahead of it (see the
            -- driver). Past a corner it gets that far ahead of the implement towards the edge: near the edge the
            -- corner must be round enough for the tractor to stay on the field
            local needed = s.towLength - ((i - 0.5) * spacing - CG.VEHICLE_FRONT)
            -- sharp: the tightest bend the implement can follow (the tractor swings wide); round: a smooth bend
            -- the tractor drives without that, clearly rounder than the sharp ones
            local sharpRadius = CG.towedCornerRadius(s)
            local base = rounded and math.max(s.turnRadius, s.towLength, sharpRadius + 2) or sharpRadius
            workRing = smoothRing(sharp, s, nil, keepAway, math.max(base, needed))
        elseif not rounded and s.allowReverse then
            local square = findSquareCorners(sharp, s, outlineIndex)
            if next(square) then
                workRing = smoothRing(sharp, s, square, keepAway)
            end
        end
        -- world z points south, so a polygon counter clockwise in x/z (Geo's sense) is clockwise on the map
        if not s.clockwise then
            ring, workRing = Geo.reverse(ring), Geo.reverse(workRing)
        end
        if #ring < 3 or #workRing < 3 then
            -- (a sliver: nothing to drive)
        elseif partIx == 1 then
            table.insert(rings, ring)
            table.insert(workRings, workRing)
            mainInnerRing = ring
            levels = i
        else
            -- the other parts' passes come after the main part's, each part outside in
            table.insert(otherRings, {ring = ring, workRing = workRing})
        end
        end
    end
    for _, r in ipairs(otherRings) do
        table.insert(rings, r.ring)
        table.insert(workRings, r.workRing)
    end

    -- inside of the headlands
    local inner = poly
    local innerParts = {}
    if levels > 0 then
        local pieces = Geo.offsetInward(poly, levels * spacing)
        inner = pieces[1]
        for k = 2, #pieces do
            if CG.thickness(pieces[k]) >= 2 * spacing then
                innerParts[#innerParts + 1] = Geo.ensureCCW(Geo.simplify(pieces[k], math.min(spacing / 3, 1.5)))
            end
        end
    end

    local islands, islandsIgnored = {}, 0
    local blocks, angle, skippedLength = {}, 0, 0
    local allRows
    local lineYs, skippedRows = {}, {}
    if inner ~= nil and Geo.signedArea(inner) > spacing * spacing then
        -- small notches in the outline would split the rows into many short pieces, smooth them out: rows may
        -- then end a little inside the headland or short of it
        inner = Geo.ensureCCW(Geo.simplify(inner, math.min(spacing / 3, 1.5)))
        -- around islands only as many passes as turning needs (the 30 m minimum is for the field edge)
        local turnOnly = withDefaults(s)
        turnOnly.minHeadlandWidth = 0
        local islandPasses = math.max(1, math.min(math.max(1, levels), CG.autoHeadlands(turnOnly, pattern)))
        islands, islandsIgnored = prepareIslands(s.islands, inner, islandPasses, s)
        local polys = {inner}
        -- the other parts of the inside get rows too
        for _, part in ipairs(innerParts) do table.insert(polys, part) end
        for _, island in ipairs(islands) do table.insert(polys, island.zone) end
        angle = s.rowAngle and math.rad(s.rowAngle) or CG.findBestAngle(polys, spacing, math.pi * s.turnRadius + 2 * s.runOut)
        if s.rowShape == "edge" and s.teamShare ~= "nextRow" then
            -- rows along the field's longest gently bent edge
            blocks = CG.curvedBlocks(poly, inner, islands, s, spacing, levels * spacing)
            skippedLength = 0
        else
            -- slivers shorter than two work widths are left to the headland
            local rowSpacing = (s.rowSpacing or 0) > 0 and s.rowSpacing or spacing
            local phase = (s.rowSpacing or 0) > 0 and s.rowPhase or nil
            blocks, skippedLength = splitBlocks(sweep(rotateAll(polys, -angle), rowSpacing, 2 * spacing, phase),
                CG.minBlockLength(spacing))
        end
        if spiral then blocks = {} end
        -- every row's place across the field (rows next to each other: 1, 2, 3...), for picking and skipping them
        lineYs = {}
        for _, blk in ipairs(blocks) do
            for _, row in ipairs(blk.rows) do lineYs[#lineYs + 1] = row.y end
        end
        table.sort(lineYs)
        local unique = {}
        for _, y in ipairs(lineYs) do
            if #unique == 0 or y - unique[#unique] > 0.01 then unique[#unique + 1] = y end
        end
        lineYs = unique
        -- rows the player wants skipped
        if s.skipRows and next(s.skipRows) then
            for bi = #blocks, 1, -1 do
                local kept = {}
                for _, row in ipairs(blocks[bi].rows) do
                    local rank = rankOf(lineYs, row.y)
                    if s.skipRows[rank] then
                        table.insert(skippedRows, {rank = rank, row = row})
                    else
                        table.insert(kept, row)
                    end
                end
                if #kept > 0 then blocks[bi].rows = kept else table.remove(blocks, bi) end
            end
        end
        -- only some of the rows (the player's choice), or none (headlands only)
        if s.workPart == "headlands" then
            allRows = select(2, CG.rowRange(blocks, 0, 0))
            blocks = {}
        elseif (s.rowFrom or 0) > 0 or (s.rowTo or 0) > 0 then
            blocks, allRows = CG.rowRange(blocks, s.rowFrom, s.rowTo)
        end
        -- a team member: only its strip of the rows; with next-free-row none (the driver takes them as it goes)
        if (s.teamSize or 1) > 1 then
            if s.teamShare == "nextRow" then
                blocks = {}
            else
                blocks = CG.stripBlocks(blocks, s.teamSize, s.teamIndex or 1)
            end
        end
    else
        islandsIgnored = #(s.islands or {})
    end

    local b = newBuilder(s, {field = poly, inner = levels > 0 and inner or nil, innerRing = mainInnerRing,
                             outerRing = rings[1],
                             islands = islands})
    local cosA, sinA = math.cos(angle), math.sin(angle)
    local function toWorld(x, y)
        return x * cosA - y * sinA, x * sinA + y * cosA
    end
    -- world end points of a row driven in the given direction
    local function rowEnds(row, forward)
        if row.pts then
            local first, last = row.pts[1], row.pts[#row.pts]
            if forward then return first, last end
            return last, first
        end
        local ax, ay = toWorld(row.x1, row.y)
        local bx, by = toWorld(row.x2, row.y)
        if forward then
            return {x = ax, y = ay}, {x = bx, y = by}
        end
        return {x = bx, y = by}, {x = ax, y = ay}
    end

    -- the pass added last (a closed ring, ends where it started): the way on along it, for carrying on past a
    -- corner before moving to the next pass
    local lastRing
    local function alongLastRing(dist)
        local pts, acc = {}, 0
        local n = #lastRing
        for i = 1, n do
            local a, c = lastRing[i], lastRing[i % n + 1]
            local len = Geo.dist(a, c)
            if acc + len >= dist then
                local t = (dist - acc) / math.max(len, 1e-6)
                pts[#pts + 1] = {x = a.x + (c.x - a.x) * t, y = a.y + (c.y - a.y) * t}
                return pts, Geo.heading(a, c)
            end
            pts[#pts + 1] = {x = c.x, y = c.y}
            acc = acc + len
        end
        return pts, nil
    end

    --- don't start a pass at or just after a square corner, the manoeuvre needs the edges on both sides: start in
    --- the middle of the edge after it
    local function offCorner(ring)
        local n = #ring
        if ring[1].corner then
            return ringStartingNear(ring, ring[1], Geo.dist(ring[1], ring[2]) / 2)
        elseif ring[n].corner then
            return ringStartingNear(ring, ring[n], (Geo.dist(ring[n], ring[1]) + Geo.dist(ring[1], ring[2])) / 2)
        end
        return ring
    end

    local function addRingList(list, near)
        for _, entry in ipairs(list) do
            -- passes start (and end) on a long straight edge: the move from one to the next is then a gentle
            -- S-curve along it, never around a corner (a wide implement would swing off the field there)
            local base = math.max(2 * s.turnRadius, 3 * spacing)
            local lead = 2 * s.turnRadius + 1
            local need = lead + base + 2 * s.turnRadius + 10
            local ring
            if not b:hasPoints() then
                ring = startOnStraight(ringStartingNear(entry.ring, near, 0), need, lead)
            else
                -- start a bit further along, so the move to this pass is a gentle S-curve; if that doesn't keep
                -- the implement on the field, later still
                local pose = b:lastPose()
                -- first on the same straight (a shorter S-curve), then further along, then from the next long
                -- straight on: the first move that keeps the implement on the field
                local here = {x = pose.x, y = pose.y}
                local candidates = {}
                for _, ahead in ipairs({base, 2 * s.turnRadius + spacing, base + 10, base + 25, base + 50, base + 100}) do
                    table.insert(candidates, offCorner(ringStartingNear(entry.ring, here, ahead)))
                end
                table.insert(candidates, offCorner(startOnStraight(ringStartingNear(entry.ring, here, base), need, 0)))
                local clean = false
                for _, candidate in ipairs(candidates) do
                    local startPose = {x = candidate[1].x, y = candidate[1].y, h = Geo.heading(candidate[1], candidate[2])}
                    if ring == nil then ring = candidate end
                    if b:checkPath(b:dubinsTo(startPose)) == nil then
                        ring = candidate
                        clean = true
                        break
                    end
                end
                -- none keeps the implement on the field (the pass ended running into a sharp corner): carry on along
                -- the pass just done, implement up, round the corner, and move over from there
                if not clean and lastRing then
                    for _, extra in ipairs({15, 30, 50, 80}) do
                        local carry, h = alongLastRing(extra)
                        if h == nil then break end
                        local endPose = {x = carry[#carry].x, y = carry[#carry].y, h = h}
                        local found
                        for _, ahead in ipairs({base, base + 10, base + 25, base + 50}) do
                            local candidate = offCorner(ringStartingNear(entry.ring, endPose, ahead))
                            local startPose = {x = candidate[1].x, y = candidate[1].y, h = Geo.heading(candidate[1], candidate[2])}
                            local path = {}
                            for _, q in ipairs(carry) do path[#path + 1] = q end
                            for _, q in ipairs(b:dubinsBetween(endPose, startPose)) do path[#path + 1] = q end
                            if b:checkPath(path) == nil then
                                found = candidate
                                break
                            end
                        end
                        if found then
                            b:addPoints(carry, "C")
                            ring = found
                            break
                        end
                    end
                end
            end
            ring = offCorner(ring)
            if b:hasPoints() then
                b:route({x = ring[1].x, y = ring[1].y, h = Geo.heading(ring[1], ring[2])}, "C")
            end
            b:addRing(ring, entry.pass, entry.island and {island = entry.island} or nil)
            lastRing = ring
        end
    end

    --- the island passes, nearest island first
    local function islandRingList()
        local list, left = {}, {}
        for i, island in ipairs(islands) do left[i] = {island = island, number = i} end
        local here = start
        if b:hasPoints() then
            local pose = b:lastPose()
            here = {x = pose.x, y = pose.y}
        end
        -- a team member: only its islands; rows only: none
        for i = #left, 1, -1 do
            if not isMine(left[i].number, s) or s.workPart == "rows" then table.remove(left, i) end
        end
        while #left > 0 do
            local bestK, bestD
            for k, entry in ipairs(left) do
                local _, d = Geo.closestVertex(entry.island.rings[1], here)
                if bestD == nil or d < bestD then bestK, bestD = k, d end
            end
            local entry = table.remove(left, bestK)
            for i, ring in ipairs(entry.island.rings) do
                table.insert(list, {ring = ring, pass = #entry.island.rings - i + 1, island = entry.number})
            end
            here = entry.island.rings[#entry.island.rings][1]
        end
        return list
    end

    local function outerRingList(order)
        local list = {}
        for _, i in ipairs(order) do table.insert(list, {ring = workRings[i], pass = i}) end
        return list
    end

    local outerOrder = {}
    for i = 1, #rings do
        if isMine(i, s) and s.workPart ~= "rows" then table.insert(outerOrder, i) end
    end
    if s.headlandsFirst then
        addRingList(outerRingList(outerOrder), start)
        addRingList(islandRingList(), start)
    end

    -- rows, block by block, always the nearest block next
    local rowNumber, blockNumber = 0, 0
    local remaining = {}
    for i, blk in ipairs(blocks) do remaining[i] = blk end
    local runIn = math.max(s.runOut, 2)
    while #remaining > 0 do
        local here = start
        if b:hasPoints() then
            local pose = b:lastPose()
            here = {x = pose.x, y = pose.y}
        end
        -- pick block and how to enter it (first or last row, either direction)
        local best
        -- lands with a worked side (a harvester's pipe): only the ways in that keep the worked ground on it
        local side = pattern == CG.PATTERN_LANDS and (s.landsSide or 0) or 0
        for bi, blk in ipairs(remaining) do
            for _, reversed in ipairs({false, true}) do
                for _, firstForward in ipairs({true, false}) do
                    for _, upFirst in ipairs(side ~= 0 and {true, false} or {true}) do
                        local order = rowOrder(#blk.rows, pattern, firstForward, s.rowsPerLand, upFirst)
                        local first = order[1]
                        local rowIx = reversed and (#blk.rows - first.index + 1) or first.index
                        local p1 = rowEnds(blk.rows[rowIx], first.forward)
                        local d = Geo.dist(here, p1)
                        if side ~= 0 and #order >= 2 and CG.workedSide(blk, order, reversed, rowEnds) ~= side then
                            d = math.huge
                        end
                        if best == nil or d < best.d then
                            best = {d = d, bi = bi, reversed = reversed, order = order}
                        end
                    end
                end
            end
        end
        local blk = table.remove(remaining, best.bi)
        blockNumber = blockNumber + 1
        for _, step in ipairs(best.order) do
            local row = blk.rows[best.reversed and (#blk.rows - step.index + 1) or step.index]
            local p1, p2 = rowEnds(row, step.forward)
            local h = Geo.heading(p1, p2)
            -- a curved row: in along its first stretch
            local inner2
            if row.pts then
                inner2 = step.forward and row.pts[2] or row.pts[#row.pts - 1]
                h = Geo.heading(p1, inner2)
            end
            local approach = {x = p1.x - math.cos(h) * runIn, y = p1.y - math.sin(h) * runIn, h = h}
            if b:hasPoints() then
                local isFirstOfBlock = step == best.order[1]
                if isFirstOfBlock then
                    if b.wps[#b.wps].t == "R" then
                        -- from the previous block: clear the row, then along the headland
                        local pose = b:lastPose()
                        b:add(pose.x + math.cos(pose.h) * s.runOut, pose.y + math.sin(pose.h) * s.runOut, "C", false)
                    end
                    b:route(approach, "C")
                    b:add(approach.x, approach.y, b.wps[#b.wps].t, false)
                else
                    local pose = b:lastPose()
                    local turnStart = #b.wps + 1
                    b:add(pose.x + math.cos(pose.h) * s.runOut, pose.y + math.sin(pose.h) * s.runOut, "T", false)
                    -- a three-point turn is slower than a bulb turn, route() takes it only where that doesn't
                    -- fit (fewer headlands than it needs, a narrow end of the field)
                    local clean = b:route(approach, "T")
                    b:add(approach.x, approach.y, b.wps[#b.wps].t, false)
                    -- a turn on the field, over worked land, forward only: the implement may stay down on it
                    -- (switched off), if the player wants that
                    if clean then
                        for k = turnStart, #b.wps do b.wps[k].keep = true end
                    end
                end
            else
                b:add(approach.x, approach.y, "C", false)
            end
            rowNumber = rowNumber + 1
            local line = rankOf(lineYs, row.y)
            b:add(p1.x, p1.y, "R", false, {rs = true, row = rowNumber, block = blockNumber, line = line})
            if row.pts then
                local n = #row.pts
                for j = 2, n - 1 do
                    local q = row.pts[step.forward and j or (n - j + 1)]
                    b:add(q.x, q.y, "R", true, {row = rowNumber, block = blockNumber, line = line})
                end
            end
            b:add(p2.x, p2.y, "R", true, {re = true, row = rowNumber, block = blockNumber, line = line})
        end
    end

    if not s.headlandsFirst then
        if b:hasPoints() and b.wps[#b.wps].t == "R" then
            local pose = b:lastPose()
            b:add(pose.x + math.cos(pose.h) * s.runOut, pose.y + math.sin(pose.h) * s.runOut, "C", false)
        end
        addRingList(islandRingList(), start)
        local order = {}
        for i = #rings, 1, -1 do
            if isMine(i, s) and s.workPart ~= "rows" then table.insert(order, i) end
        end
        addRingList(outerRingList(order), start)
    end

    if #b.wps < 2 and s.teamShare == "nextRow" then
        -- no headland pass for this one: it starts right with the rows, from where it is
        b.wps = {{x = start.x, z = start.y, t = "C", work = false}, {x = start.x + 1, z = start.y, t = "C", work = false}}
    end
    if #b.wps < 2 then
        if s.workPart ~= "whole" or (s.rowFrom or 0) > 0 or (s.rowTo or 0) > 0 then
            return nil, "nothing to work: no rows or headland passes in this part of the field"
        end
        if (s.teamSize or 1) > 1 then
            return nil, "nothing left on this field for this tractor of the team"
        end
        return nil, "field too small for this work width"
    end
    -- the work area is behind the vehicle: at the end drive on until it is out of the last row or pass, or its
    -- last metres stay undone
    if b.wps[#b.wps].work then
        local pose = b:lastPose()
        b:add(pose.x + math.cos(pose.h) * s.runOut, pose.y + math.sin(pose.h) * s.runOut, "C", false)
    end

    -- statistics
    local total, worked, reversing = 0, 0, 0
    for i = 2, #b.wps do
        local d = math.sqrt((b.wps[i].x - b.wps[i - 1].x) ^ 2 + (b.wps[i].z - b.wps[i - 1].z) ^ 2)
        total = total + d
        if b.wps[i].work then worked = worked + d end
        if b.wps[i].rev then reversing = reversing + d end
    end
    return {
        waypoints = b.wps,
        settings = s,
        stats = {
            headlands = levels,
            rows = rowNumber,
            blocks = #blocks,
            rowAngle = math.deg(angle) % 180,
            pattern = pattern,
            length = total,
            workLength = worked,
            reverseLength = reversing,
            area = Geo.signedArea(poly),
            skippedArea = skippedLength * spacing,
            islands = #islands,
            islandsIgnored = islandsIgnored,
            time = CG.estimateTime(b.wps, s),
            -- all the field's rows (counted across it), when only some are worked
            allRows = allRows,
            -- where the rows are across the field (in the turned frame) and which way: for tramlines
            rowLines = lineYs,
            -- turns and connections that could not be kept on the field (too few headland passes)
            offField = b.offField or 0,
            offFieldSpots = b.offFieldSpots,
        },
        boundary = poly,
        -- rows the player skipped: {line, a, b} (world), so the editor can show them and take them back
        skippedLines = (function()
            local out = {}
            for _, e in ipairs(skippedRows) do
                local a, c = rowEnds(e.row, true)
                out[#out + 1] = {line = e.rank, a = {x = a.x, z = a.y}, b = {x = c.x, z = c.y}}
            end
            return out
        end)(),
        -- for planning the way to the course later (see CG.planApproach)
        area = {field = poly, inner = levels > 0 and inner or nil, innerRing = mainInnerRing, outerRing = rings[1],
                islands = islands},
    }
end

--- With automatic headlands (s.headlands < 0): as many passes as autoHeadlands says, and one more each time a turn
--- still could not be kept on the field (an odd field end, an implement wider than it turns).
function CG.generateWithHeadlands(boundary, s)
    if s.headlands >= 0 or s.pattern == CG.PATTERN_SPIRAL then
        return generateCourse(boundary, s)
    end
    local n = CG.autoHeadlands(s, s.pattern)
    local course, firstErr
    for k = 0, 3 do
        local s2 = withDefaults(s)
        s2.headlands = math.min(n + k, CG.MAX_HEADLANDS)
        local c, err = generateCourse(boundary, s2)
        if c == nil then
            -- more passes left no room for rows: keep what we had
            firstErr = firstErr or err
            break
        end
        -- more passes only count if they keep more turns on the field, and never if an obstacle (an island, an
        -- area the player marked) is then too close to them to be worked round: driving over it is worse
        local ignored, best = c.stats.islandsIgnored or 0, course and (course.stats.islandsIgnored or 0)
        if course == nil or ignored < best or (ignored == best and c.stats.offField < course.stats.offField) then
            course = c
        end
        if c.stats.offField == 0 or s2.headlands >= CG.MAX_HEADLANDS then break end
    end
    if course == nil then
        return nil, firstErr
    end
    course.stats.headlandsAuto = true
    return course, nil
end

--- The rows of a course: list of {row, a = {x, z}, b = {x, z}} (start and end as the course drives it)
function CG.rowsOf(wps)
    local rows = {}
    for i = 2, #wps do
        local a, b = wps[i - 1], wps[i]
        if b.re and b.t == "R" and a.rs then
            rows[#rows + 1] = {row = b.row or #rows + 1, a = {x = a.x, z = a.z}, b = {x = b.x, z = b.z}}
        end
    end
    return rows
end

--- Generates a course for the field outline (list of {x, z} or {x, y} world points).
--- Returns course {waypoints, stats, settings, boundary, area} or nil, error text
function CG.generate(boundary, settings)
    local s = withDefaults(settings)
    if s.workWidth <= 0.5 then
        return nil, "work width too small"
    end
    if (s.teamSize or 1) > 1 then
        -- a team member's strip: the whole field first, so every member has the same headland passes and rows
        -- (headland count, row direction, pattern) and the strips fit together
        local whole = withDefaults(s)
        whole.teamSize, whole.teamIndex = 1, 1
        -- the same for every member: made once
        local keys = {}
        for k, v in pairs(whole) do
            if type(v) ~= "table" then keys[#keys + 1] = k .. "=" .. tostring(v) end
        end
        table.sort(keys)
        local cacheKey = table.concat(keys, ";")
        local full, err
        if CG.wholeCache and CG.wholeCache.boundary == boundary and CG.wholeCache.key == cacheKey then
            full = CG.wholeCache.course
        else
            full, err = CG.generate(boundary, whole)
            CG.wholeCache = full and {boundary = boundary, key = cacheKey, course = full} or nil
        end
        if full == nil then
            return nil, err
        end
        local member = withDefaults(s)
        member.headlands = full.stats.headlands
        member.rowAngle = full.stats.rowAngle
        member.pattern = full.stats.pattern
        local course, err2 = generateCourse(boundary, member)
        if course then
            course.stats.team = {size = s.teamSize, index = s.teamIndex, wholeTime = full.stats.time,
                                 wholeRows = full.stats.rows, wholeHeadlands = full.stats.headlands,
                                 share = s.teamShare}
            course.stats.headlandsAuto = s.headlands < 0
            if s.teamShare == "nextRow" then
                -- the rows everybody takes from: as the whole course has them (start, end, its number)
                course.teamRows = CG.rowsOf(full.waypoints)
                course.stats.rows = #course.teamRows
            end
        end
        return course, err2
    end
    if s.pattern ~= CG.PATTERN_AUTO then
        return CG.generateWithHeadlands(boundary, s)
    end
    -- automatic: the pattern that gets the field done sooner, staying on the field comes first
    local best, firstErr
    for _, pattern in ipairs({CG.PATTERN_ADJACENT, CG.PATTERN_RACETRACK}) do
        local s2 = withDefaults(s)
        s2.pattern = pattern
        local course, err = CG.generateWithHeadlands(boundary, s2)
        firstErr = firstErr or err
        if course and (best == nil or course.stats.offField < best.stats.offField
                or (course.stats.offField == best.stats.offField and course.stats.time < best.stats.time - 1)) then
            best = course
        end
    end
    if best == nil then
        return nil, firstErr
    end
    best.stats.patternAuto = true
    return best, nil
end

--- A course along given lines (a vineyard's rows): no headland passes. boundary: the area to turn in (list of {x, z});
--- lines: list of {a, b ({x, y}), lat (place across)}; each driven once, either way, extend m on past its ends. Next
--- comes the nearest line start, preferably one far enough to the side to turn into without backing up (as many
--- lines as that takes skipped, and filled in on the way back). Returns course (as CG.generate) or nil, error text
function CG.generateFromLines(boundary, settings, lines, extend)
    local s = withDefaults(settings)
    if #lines == 0 then
        return nil, "no rows"
    end
    local poly = {}
    for i, p in ipairs(boundary) do poly[i] = {x = p.x, y = p.z or p.y} end
    poly = Geo.ensureCCW(poly)
    local b = newBuilder(s, {field = poly})
    extend = extend or 0
    local wide = 2 * s.turnRadius
    local done = {}
    local cur = {x = s.startX or lines[1].a.x, y = s.startZ or lines[1].a.y}
    local lastLat
    local rowNumber = 0
    local ranks = {}
    do
        local order = {}
        for i = 1, #lines do order[i] = i end
        table.sort(order, function(p, q) return lines[p].lat < lines[q].lat end)
        for rank, i in ipairs(order) do ranks[i] = rank end
    end
    for _ = 1, #lines do
        local best, bestD, bestFlip
        for i, l in ipairs(lines) do
            if not done[i] then
                for _, flip in ipairs({false, true}) do
                    local p = flip and l.b or l.a
                    local d = Geo.dist(cur, p)
                    -- (too close beside the last one to turn into round)
                    if lastLat and math.abs(l.lat - lastLat) < wide - 0.01 then d = d + 1000 end
                    if bestD == nil or d < bestD then best, bestD, bestFlip = i, d, flip end
                end
            end
        end
        done[best] = true
        local l = lines[best]
        local p1, p2 = bestFlip and l.b or l.a, bestFlip and l.a or l.b
        local h = math.atan2(p2.y - p1.y, p2.x - p1.x)
        local cx, cy = math.cos(h), math.sin(h)
        p1 = {x = p1.x - cx * extend, y = p1.y - cy * extend}
        p2 = {x = p2.x + cx * extend, y = p2.y + cy * extend}
        if b:hasPoints() then
            local pose = b:lastPose()
            b:add(pose.x + math.cos(pose.h) * s.runOut, pose.y + math.sin(pose.h) * s.runOut, "T", false)
            b:route({x = p1.x, y = p1.y, h = h}, "T")
            b:add(p1.x, p1.y, b.wps[#b.wps].t, false)
        else
            b:add(p1.x - cx * 5, p1.y - cy * 5, "C", false)
        end
        rowNumber = rowNumber + 1
        local extra = {row = rowNumber, block = 1, line = ranks[best]}
        b:add(p1.x, p1.y, "R", false, {rs = true, row = rowNumber, block = 1, line = ranks[best]})
        -- points along it (every 10 m), for the progress and the drawing
        local len = Geo.dist(p1, p2)
        local n = math.floor(len / 10)
        for k = 1, n - 1 do
            b:add(p1.x + cx * len * k / n, p1.y + cy * len * k / n, "R", true, extra)
        end
        b:add(p2.x, p2.y, "R", true, {re = true, row = rowNumber, block = 1, line = ranks[best]})
        cur, lastLat = p2, l.lat
    end
    local pose = b:lastPose()
    b:add(pose.x + math.cos(pose.h) * s.runOut, pose.y + math.sin(pose.h) * s.runOut, "C", false)
    local total, worked, reversing = 0, 0, 0
    for i = 2, #b.wps do
        local d = Geo.dist({x = b.wps[i - 1].x, y = b.wps[i - 1].z}, {x = b.wps[i].x, y = b.wps[i].z})
        total = total + d
        if b.wps[i].work then worked = worked + d end
        if b.wps[i].rev then reversing = reversing + d end
    end
    return {
        waypoints = b.wps,
        settings = s,
        stats = {headlands = 0, rows = rowNumber, blocks = 1, rowAngle = math.deg(math.atan2(lines[1].b.y - lines[1].a.y,
                 lines[1].b.x - lines[1].a.x)) % 180, pattern = "vines", length = total, workLength = worked,
                 reverseLength = reversing, area = Geo.signedArea(poly), skippedArea = 0, islands = 0, islandsIgnored = 0,
                 time = CG.estimateTime(b.wps, s), allRows = rowNumber, offField = b.offField or 0,
                 offFieldSpots = b.offFieldSpots},
        boundary = poly,
        skippedLines = {},
        area = {field = poly},
    }
end

--- The way from pose 'from' to pose 'to' (into the course) for a course's area: direct, or along the headland when
--- the direct way would cut through the middle of the field or an island. Returns points {x, y}.
function CG.planApproach(area, settings, from, to)
    local s = withDefaults(settings)
    local b = newBuilder(s, area or {})
    -- the builder plans from the end of its course: a point behind the start pose gives it the heading
    b:add(from.x - math.cos(from.h), from.y - math.sin(from.h), "C", false)
    b:add(from.x, from.y, "C", false)
    if area and area.field then
        b:route(to, "C", true)
    else
        b:connect(to, "C")
    end
    local pts = {}
    for i = 3, #b.wps do
        table.insert(pts, {x = b.wps[i].x, y = b.wps[i].z})
    end
    return pts
end

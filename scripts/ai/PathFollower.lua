-- Guidance: follows a path (pure pursuit). The path is a list of points {x, z, work, t, rev}; straight pieces may
-- be long. Progress is measured as distance along the path, so the follower never jumps to a neighbouring row, and
-- implements can be raised and lowered at exact distances.
--
-- rev on a point: the way to it is driven in reverse. Where the direction changes (a cusp) the vehicle must stop
-- on the point, so the follower never looks past a cusp until the driver says it got there (passCusp).

GuidancePathFollower = {}
local PF = GuidancePathFollower
local PF_mt = {__index = PF}

function PF.new(points)
    local self = setmetatable({}, PF_mt)
    self.points = points
    self.ix = 1 -- current segment: points[ix] -> points[ix + 1]
    self.s = 0 -- distance along the path of the projected vehicle position
    self.crossTrack = 0
    self:measure()
    return self
end

--- Distances along the path, direction changes, worked stretches
function PF:measure()
    local points = self.points
    local d = 0
    points[1].d = 0
    for i = 2, #points do
        local a, b = points[i - 1], points[i]
        d = d + math.sqrt((b.x - a.x) ^ 2 + (b.z - a.z) ^ 2)
        b.d = d
    end
    self.length = d
    -- direction changes
    for i = 2, #points - 1 do
        points[i].cusp = (points[i].rev or false) ~= (points[i + 1].rev or false) or nil
    end
    -- stretches where the implements must be lowered, {from, to} in path distance
    self.workIntervals = {}
    local open
    for i = 2, #points do
        if points[i].work then
            if open == nil then
                open = {from = points[i - 1].d, to = points[i].d}
                table.insert(self.workIntervals, open)
            else
                open.to = points[i].d
            end
        else
            open = nil
        end
    end
end

--- Replaces the points between points[i1] and points[i2] (both kept) by pts {x, z, ...}. Only ahead of the
--- vehicle (i1 >= the current segment), so the progress so far stays valid.
function PF:replaceRange(i1, i2, pts)
    local out = {}
    for i = 1, i1 do out[i] = self.points[i] end
    for _, p in ipairs(pts) do table.insert(out, p) end
    for i = i2, #self.points do table.insert(out, self.points[i]) end
    self.points = out
    self:measure()
end

--- Adds points {x, z, ...} at the end of the path (a helper of a team taking its next row)
function PF:append(pts)
    for _, p in ipairs(pts) do table.insert(self.points, p) end
    self:measure()
end

local function project(px, pz, a, b)
    local dx, dz = b.x - a.x, b.z - a.z
    local len2 = dx * dx + dz * dz
    if len2 < 1e-9 then
        return 0, math.sqrt((px - a.x) ^ 2 + (pz - a.z) ^ 2)
    end
    local t = ((px - a.x) * dx + (pz - a.z) * dz) / len2
    local tc = math.max(0, math.min(1, t))
    local cx, cz = a.x + tc * dx, a.z + tc * dz
    return t, math.sqrt((px - cx) ^ 2 + (pz - cz) ^ 2)
end

local function angleDiff(a, b)
    local d = (a - b) % (2 * math.pi)
    if d > math.pi then d = d - 2 * math.pi end
    return math.abs(d)
end

--- Index of the next cusp at or after the current segment's end, or nil
function PF:getNextCuspIx()
    local pts = self.points
    for i = self.ix + 1, #pts - 1 do
        if pts[i].cusp then return i end
    end
    return nil
end

--- Updates the progress from the position and heading (math angle atan2(dz, dx), the way the vehicle faces) of the
--- point that should follow the path.
function PF:update(px, pz, heading)
    local pts = self.points
    local bestIx, bestT, bestDist
    local i = self.ix
    -- look ahead along the path a limited distance only, never backwards, never past a cusp
    while i < #pts and (pts[i].d - self.s) < 30 do
        local a, b = pts[i], pts[i + 1]
        local t, dist = project(px, pz, a, b)
        local segHeading = math.atan2(b.z - a.z, b.x - a.x)
        local moving = heading
        if moving and b.rev then moving = moving + math.pi end
        local aligned = moving == nil or angleDiff(segHeading, moving) < math.rad(75) or (b.d - a.d) < 0.5
        -- prefer the earliest segment that fits, later ones must be clearly closer
        if aligned and (t <= 1 or i == #pts - 1 or b.cusp) then
            if bestDist == nil or dist < bestDist - 0.5 then
                bestIx, bestT, bestDist = i, t, dist
            end
        end
        if b.cusp then break end
        i = i + 1
    end
    if bestIx then
        self.ix = bestIx
        local a, b = pts[bestIx], pts[bestIx + 1]
        local t = math.max(0, math.min(1, bestT))
        self.s = math.max(self.s, a.d + t * (b.d - a.d))
        self.crossTrack = bestDist
    end
end

--- Distance to the next cusp (where the vehicle has to stop and change direction), math.huge if none
function PF:getDistanceToCusp()
    local ix = self:getNextCuspIx()
    if ix == nil then return math.huge end
    return math.max(0, self.points[ix].d - self.s)
end

--- The vehicle stopped at the cusp: go on with the next segment (the other direction)
function PF:passCusp()
    local ix = self:getNextCuspIx()
    if ix then
        self.ix = ix
        self.s = math.max(self.s, self.points[ix].d)
    end
end

--- Driving in reverse on the current segment?
function PF:isReversing()
    local b = self.points[math.min(self.ix + 1, #self.points)]
    return b.rev == true
end

--- Point at path distance s
function PF:getPointAt(s)
    local pts = self.points
    if s <= 0 then return pts[1].x, pts[1].z, 1 end
    if s >= self.length then return pts[#pts].x, pts[#pts].z, #pts - 1 end
    local i = self.ix
    if pts[i].d > s then i = 1 end
    while i < #pts - 1 and pts[i + 1].d < s do i = i + 1 end
    local a, b = pts[i], pts[i + 1]
    local f = (b.d - a.d) > 0 and (s - a.d) / (b.d - a.d) or 0
    return a.x + (b.x - a.x) * f, a.z + (b.z - a.z) * f, i
end

--- Target point to steer to, and the path's direction there (math angle). Beyond the end of the path or a cusp,
--- the line is extended, so the vehicle stays straight while it stops.
function PF:getGoal(lookahead)
    local s = self.s + lookahead
    local pts = self.points
    local endIx = self:getNextCuspIx() or #pts
    local endD = pts[endIx].d
    if s <= endD then
        local x, z, i = self:getPointAt(s)
        local a, b = pts[i], pts[i + 1]
        return x, z, math.atan2(b.z - a.z, b.x - a.x)
    end
    local a, b = pts[endIx - 1], pts[endIx]
    local len = math.max(b.d - a.d, 0.01)
    local over = s - endD
    return b.x + (b.x - a.x) / len * over, b.z + (b.z - a.z) / len * over, math.atan2(b.z - a.z, b.x - a.x)
end

function PF:getRemaining()
    return math.max(0, self.length - self.s)
end

function PF:isFinished()
    return self:getRemaining() < 0.5
end

--- Signed curvature (1/m, positive turning left in x/z) of the path around distance s
function PF:getCurvatureAt(s)
    local x0, z0 = self:getPointAt(s - 3)
    local x1, z1 = self:getPointAt(s)
    local x2, z2 = self:getPointAt(s + 3)
    if (x1 - x0) ^ 2 + (z1 - z0) ^ 2 < 1e-4 or (x2 - x1) ^ 2 + (z2 - z1) ^ 2 < 1e-4 then
        return 0
    end
    local h1, h2 = math.atan2(z1 - z0, x1 - x0), math.atan2(z2 - z1, x2 - x1)
    local d = (h2 - h1) % (2 * math.pi)
    if d > math.pi then d = d - 2 * math.pi end
    return d / 3
end

--- Tightest curve radius in the next 'distance' meters (math.huge on straights), up to the next cusp
function PF:getMinRadiusAhead(distance)
    local pts = self.points
    local minR = math.huge
    local i = self.ix
    local endD = self.s + distance
    -- heading change over windows of ~4 m
    while i < #pts - 1 and pts[i].d < endD do
        if pts[i].cusp and i > self.ix then break end
        local j = i + 1
        while j < #pts and pts[j].d - pts[i].d < 4 and not pts[j].cusp do j = j + 1 end
        if j >= #pts then break end
        local a, b, c = pts[i], pts[i + 1], pts[j]
        local h1 = math.atan2(b.z - a.z, b.x - a.x)
        local h2 = math.atan2(c.z - pts[j - 1].z, c.x - pts[j - 1].x)
        local dh = angleDiff(h1, h2)
        local len = c.d - a.d
        if dh > 0.02 and len > 0 then
            minR = math.min(minR, len / dh)
        end
        if pts[j].cusp then break end
        i = i + 1
    end
    return minR
end

--- Should the implements be lowered, given how far ahead of the guidance point the front of the work area is
--- (negative when behind) and where its back is? lead: lower this much early (lowering takes time).
--- 'raiseLate': metres the back of the work area may go past the end of a worked stretch (negative: comes up before)
function PF:isInWork(frontOffset, backOffset, lead, raiseLate)
    local front = self.s + frontOffset + (lead or 0)
    local back = self.s + backOffset
    for _, w in ipairs(self.workIntervals) do
        if front >= w.from and back <= w.to + (raiseLate or 0) then
            return true
        end
    end
    return false
end

--- Distance from the front of the work area to the start of the next work interval (math.huge if none)
function PF:getDistanceToNextWork(frontOffset)
    local front = self.s + frontOffset
    for _, w in ipairs(self.workIntervals) do
        if w.from > front then
            return w.from - front
        end
    end
    return math.huge
end

--- Type of the current segment ("H", "R", "T", "C"), whether it is worked, whether it is driven in reverse
function PF:getCurrentSegment()
    local b = self.points[math.min(self.ix + 1, #self.points)]
    return b.t, b.work, b.rev == true
end

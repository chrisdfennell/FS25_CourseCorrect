-- Guidance: shortest forward-only paths between two poses for a vehicle with a minimum turning radius
-- (Dubins paths: three pieces, each a left arc, a right arc or a straight line).
-- A pose is {x, y, h} with h the heading as a math angle.

GuidanceDubins = {}
local Dubins = GuidanceDubins

local TWO_PI = 2 * math.pi

local function mod2pi(a)
    a = math.fmod(a, TWO_PI)
    if a < 0 then a = a + TWO_PI end
    return a
end

-- Each word returns t, p, q (lengths of the three pieces in units of the radius) or nil.
-- d is the distance between the poses divided by the radius, a and b the start and end headings relative
-- to the line between them.
local words = {}

function words.LSL(a, b, d, sa, sb, ca, cb)
    local tmp = 2 + d * d - 2 * math.cos(a - b) + 2 * d * (sa - sb)
    if tmp < 0 then return nil end
    local th = math.atan2(cb - ca, d + sa - sb)
    return mod2pi(th - a), math.sqrt(tmp), mod2pi(b - th)
end

function words.RSR(a, b, d, sa, sb, ca, cb)
    local tmp = 2 + d * d - 2 * math.cos(a - b) + 2 * d * (sb - sa)
    if tmp < 0 then return nil end
    local th = math.atan2(ca - cb, d - sa + sb)
    return mod2pi(a - th), math.sqrt(tmp), mod2pi(th - b)
end

function words.LSR(a, b, d, sa, sb, ca, cb)
    local tmp = -2 + d * d + 2 * math.cos(a - b) + 2 * d * (sa + sb)
    if tmp < 0 then return nil end
    local p = math.sqrt(tmp)
    local th = math.atan2(-ca - cb, d + sa + sb) - math.atan2(-2, p)
    return mod2pi(th - a), p, mod2pi(th - b)
end

function words.RSL(a, b, d, sa, sb, ca, cb)
    local tmp = -2 + d * d + 2 * math.cos(a - b) - 2 * d * (sa + sb)
    if tmp < 0 then return nil end
    local p = math.sqrt(tmp)
    local th = math.atan2(ca + cb, d - sa - sb) - math.atan2(2, p)
    return mod2pi(a - th), p, mod2pi(b - th)
end

function words.RLR(a, b, d, sa, sb, ca, cb)
    local tmp = (6 - d * d + 2 * math.cos(a - b) + 2 * d * (sa - sb)) / 8
    if math.abs(tmp) > 1 then return nil end
    local p = mod2pi(TWO_PI - math.acos(tmp))
    local t = mod2pi(a - math.atan2(ca - cb, d - sa + sb) + p / 2)
    return t, p, mod2pi(a - b - t + p)
end

function words.LRL(a, b, d, sa, sb, ca, cb)
    local tmp = (6 - d * d + 2 * math.cos(a - b) + 2 * d * (sb - sa)) / 8
    if math.abs(tmp) > 1 then return nil end
    local p = mod2pi(TWO_PI - math.acos(tmp))
    local t = mod2pi(-a - math.atan2(ca - cb, d + sa - sb) + p / 2)
    return t, p, mod2pi(mod2pi(b) - a - t + p)
end

Dubins.WORDS = {"LSL", "RSR", "LSR", "RSL", "RLR", "LRL"}

--- All valid paths between the poses, shortest first. Each is {word = "LSL", lengths = {t, p, q}, length = meters}
function Dubins.allPaths(from, to, radius)
    local dx, dy = to.x - from.x, to.y - from.y
    local d = math.sqrt(dx * dx + dy * dy) / radius
    local th = mod2pi(math.atan2(dy, dx))
    local a, b = mod2pi(from.h - th), mod2pi(to.h - th)
    local sa, sb, ca, cb = math.sin(a), math.sin(b), math.cos(a), math.cos(b)
    local paths = {}
    for _, w in ipairs(Dubins.WORDS) do
        local t, p, q = words[w](a, b, d, sa, sb, ca, cb)
        if t then
            table.insert(paths, {word = w, lengths = {t, p, q}, length = (t + p + q) * radius})
        end
    end
    table.sort(paths, function(x, y) return x.length < y.length end)
    return paths
end

function Dubins.shortest(from, to, radius)
    return Dubins.allPaths(from, to, radius)[1]
end

local function step(pose, kind, s, radius)
    -- move pose along one piece by s (in units of the radius)
    if kind == "S" then
        return {x = pose.x + math.cos(pose.h) * s * radius, y = pose.y + math.sin(pose.h) * s * radius, h = pose.h}
    end
    local dir = kind == "L" and 1 or -1
    local h = pose.h + dir * s
    return {
        x = pose.x + dir * radius * (math.sin(h) - math.sin(pose.h)),
        y = pose.y - dir * radius * (math.cos(h) - math.cos(pose.h)),
        h = h
    }
end

--- Points along a path, about maxStep meters apart on arcs; straights get only their end points.
--- The start pose is not included, the end pose is.
function Dubins.sample(from, path, radius, maxStep)
    maxStep = maxStep or 1.5
    local pts = {}
    local pose = {x = from.x, y = from.y, h = from.h}
    for i = 1, 3 do
        local kind = path.word:sub(i, i)
        local len = path.lengths[i]
        if len > 1e-9 then
            if kind == "S" then
                pose = step(pose, kind, len, radius)
                table.insert(pts, {x = pose.x, y = pose.y, h = pose.h})
            else
                local n = math.max(1, math.ceil(len * radius / maxStep))
                local start = pose
                for k = 1, n do
                    pose = step(start, kind, len * k / n, radius)
                    table.insert(pts, {x = pose.x, y = pose.y, h = pose.h})
                end
            end
        end
    end
    return pts
end

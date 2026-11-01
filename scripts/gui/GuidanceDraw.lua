-- Guidance: drawing helpers. Course lines in the world, and the primitives of the panel (rectangles, lines,
-- text) in screen coordinates (0..1, origin bottom left). Client only.

GuidanceDraw = {}
local Draw = GuidanceDraw

-- The panel's colours are written as they look on screen (sRGB); the game takes overlay and text colours as linear
-- values (as in its own UI), so they go to it converted: else the dark panel comes out grey and everything paler.
-- (Converted once per colour table.)
Draw.GAMMA = 2.2
local linearCache = setmetatable({}, {__mode = "k"})
local function linear(color)
    local c = linearCache[color]
    if c == nil then
        local g = Draw.GAMMA
        c = {(color[1] or 0) ^ g, (color[2] or 0) ^ g, (color[3] or 0) ^ g, color[4] or 1}
        linearCache[color] = c
    end
    return c
end
Draw.linear = linear

-- colours of the course parts, same in the world and on the panel
Draw.COLORS = {
    H = {0.24, 0.56, 0.95}, -- headland
    R = {0.96, 0.70, 0.18}, -- row
    T = {0.93, 0.32, 0.48}, -- turn
    C = {0.62, 0.64, 0.68}, -- connection
}

Draw.WORLD_RANGE = 120 -- m around the vehicle

local pixelOverlay

local function getPixel()
    if pixelOverlay == nil then
        pixelOverlay = createImageOverlay("dataS/menu/base/graph_pixel.dds")
    end
    return pixelOverlay
end

local circleOverlay

-- a white disc (textures/circle.dds): rounded corners are its quarters
local function getCircle()
    if circleOverlay == nil then
        circleOverlay = createImageOverlay(Utils.getFilename("textures/circle.dds", Guidance.MOD_DIR))
    end
    return circleOverlay
end

local arrowOverlay

-- the vehicle's arrow (textures/arrow.dds, its own colours, pointing up)
local function getArrow()
    if arrowOverlay == nil then
        arrowOverlay = createImageOverlay(Utils.getFilename("textures/arrow.dds", Guidance.MOD_DIR))
    end
    return arrowOverlay
end

-- another vehicle's arrow (textures/arrow_tint.dds: white with a dark edge, drawn in its colour)
local tintArrowOverlay
local function getTintArrow()
    if tintArrowOverlay == nil then
        tintArrowOverlay = createImageOverlay(Utils.getFilename("textures/arrow_tint.dds", Guidance.MOD_DIR))
    end
    return tintArrowOverlay
end

--- A texture loads in the background: drawing it before that only fills the log with warnings
local function isReady(id)
    return getIsOverlayReady == nil or getIsOverlayReady(id)
end

function Draw.delete()
    if arrowOverlay ~= nil then
        delete(arrowOverlay)
        arrowOverlay = nil
    end
    if pixelOverlay ~= nil then
        delete(pixelOverlay)
        pixelOverlay = nil
    end
    if circleOverlay ~= nil then
        delete(circleOverlay)
        circleOverlay = nil
    end
end

--- Part of the disc texture (u0..u1, v0..v1, v up) in a box
local function circlePart(x, y, w, h, u0, v0, u1, v1, color)
    local id = getCircle()
    if not isReady(id) then
        return
    end
    local c = linear(color)
    setOverlayColor(id, c[1], c[2], c[3], c[4])
    setOverlayUVs(id, u0, v0, u0, v1, u1, v0, u1, v1)
    renderOverlay(id, x, y, w, h)
end

--- Rectangle with round corners, radius in screen height units
function Draw.roundRect(x, y, w, h, radius, color)
    local ry = math.min(radius, h / 2)
    local rx = math.min(ry / g_screenAspectRatio, w / 2)
    ry = rx * g_screenAspectRatio
    if rx <= 0 then
        return Draw.rect(x, y, w, h, color)
    end
    circlePart(x, y, rx, ry, 0, 0, 0.5, 0.5, color)
    circlePart(x, y + h - ry, rx, ry, 0, 0.5, 0.5, 1, color)
    circlePart(x + w - rx, y, rx, ry, 0.5, 0, 1, 0.5, color)
    circlePart(x + w - rx, y + h - ry, rx, ry, 0.5, 0.5, 1, 1, color)
    if w > 2 * rx then
        Draw.rect(x + rx, y, w - 2 * rx, h, color)
    end
    if h > 2 * ry then
        Draw.rect(x, y + ry, rx, h - 2 * ry, color)
        Draw.rect(x + w - rx, y + ry, rx, h - 2 * ry, color)
    end
end

--- Filled circle around (cx, cy), radius in screen height units
function Draw.disc(cx, cy, radius, color)
    local rx = radius / g_screenAspectRatio
    circlePart(cx - rx, cy - radius, 2 * rx, 2 * radius, 0, 0, 1, 1, color)
end

--- The vehicle's arrow centred on (cx, cy), 'size' high (screen height units), pointing at 'angle' (radians, on the
--- screen, counterclockwise from the right)
function Draw.arrow(cx, cy, size, angle, color)
    -- (in a colour: the white arrow, tinted; else the green one as it is)
    local id = color and getTintArrow() or getArrow()
    if not isReady(id) then
        return
    end
    local w = size / g_screenAspectRatio
    local c = color and linear(color) or {1, 1, 1, 1}
    setOverlayColor(id, c[1], c[2], c[3], c[4])
    -- the texture points up; turned about its middle (in the width's units, as the game turns overlays)
    setOverlayRotation(id, angle - math.pi / 2, w / 2, size / 2)
    renderOverlay(id, cx - w / 2, cy - size / 2, w, size)
end

function Draw.rect(x, y, w, h, color)
    local id = getPixel()
    setOverlayRotation(id, 0, 0, 0)
    local c = linear(color)
    setOverlayColor(id, c[1], c[2], c[3], c[4])
    renderOverlay(id, x, y, w, h)
end

-- A turned overlay is turned in the game's own pixel shape, which on some screens (a window on an ultrawide
-- monitor) isn't the one the screen units say: a long turned line then ends short or long, leaving gaps before
-- corners. Turned lines are drawn in short pieces, each from its exact start and a little longer than needed.
Draw.LINE_PIECE = 10 -- px
Draw.LINE_OVERLAP = 0.2 -- of a piece

--- Line between two screen points, thickness in screen height units
function Draw.line(x1, y1, x2, y2, thickness, color)
    local dx = x2 - x1
    local dy = (y2 - y1) / g_screenAspectRatio
    local length = math.sqrt(dx * dx + dy * dy)
    if length <= 0 then
        return
    end
    local id = getPixel()
    local c = linear(color)
    setOverlayColor(id, c[1], c[2], c[3], c[4])
    local angle = math.atan2(dy, dx)
    -- flat lines aren't turned: one piece
    local pieces = 1
    if math.abs(angle) > 0.002 and math.abs(math.abs(angle) - math.pi) > 0.002 then
        pieces = math.max(1, math.ceil(length * g_screenWidth / Draw.LINE_PIECE))
    end
    setOverlayRotation(id, angle, 0, thickness / 2)
    local step = length / pieces
    local drawn = pieces > 1 and step * (1 + Draw.LINE_OVERLAP) or step
    for i = 0, pieces - 1 do
        local f = i / pieces
        local px = x1 + (x2 - x1) * f
        local py = y1 + (y2 - y1) * f
        renderOverlay(id, px, py - thickness / 2, i == pieces - 1 and step or drawn, thickness)
    end
    setOverlayRotation(id, 0, 0, 0)
end

function Draw.text(x, y, size, text, color, align, bold)
    setTextBold(bold or false)
    setTextAlignment(align or RenderText.ALIGN_LEFT)
    local c = linear(color)
    setTextColor(c[1], c[2], c[3], c[4])
    renderText(x, y, size, text)
    setTextBold(false)
    setTextAlignment(RenderText.ALIGN_LEFT)
    setTextColor(1, 1, 1, 1)
end

function Draw.textWidth(size, text, bold)
    setTextBold(bold or false)
    local w = getTextWidth(size, text)
    setTextBold(false)
    return w
end

-----------------------------------------------------------------------------------------------------------------------
-- World
-----------------------------------------------------------------------------------------------------------------------

--- The height the course lines are drawn at there: above the ground by the player's line height (higher to see
--- them over tall crops)
local function terrainY(x, z)
    local h = GuidancePrefs and GuidancePrefs.lineHeight or 0.25
    return getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, x, 0, z) + h
end
Draw.lineY = terrainY

--- The course near the vehicle as lines on the ground, done part dimmed
function Draw.drawCourseInWorld(vehicle, course)
    local vx, _, vz = getWorldTranslation(vehicle.rootNode)
    local range2 = Draw.WORLD_RANGE * Draw.WORLD_RANGE
    local progressIx = vehicle:getGuidanceProgress()
    local wps = course.waypoints
    for i = 2, #wps do
        local a, b = wps[i - 1], wps[i]
        local near = (a.x - vx) ^ 2 + (a.z - vz) ^ 2 < range2 or (b.x - vx) ^ 2 + (b.z - vz) ^ 2 < range2
        -- long rows: also when they only pass close by
        if not near and (b.d - a.d) > Draw.WORLD_RANGE then
            local d = GuidanceGeo.distToSegment({x = vx, y = vz}, {x = a.x, y = a.z}, {x = b.x, y = b.z})
            near = d < Draw.WORLD_RANGE
        end
        if near then
            local c = Draw.COLORS[b.t] or Draw.COLORS.C
            local dim = i <= progressIx and 0.35 or 1
            local r, g, bl = c[1] * dim, c[2] * dim, c[3] * dim
            -- long pieces in steps so the line follows the ground
            local len = b.d - a.d
            local steps = math.max(1, math.min(60, math.ceil(len / 8)))
            local px, pz = a.x, a.z
            local py = terrainY(px, pz)
            for k = 1, steps do
                local f = k / steps
                local qx, qz = a.x + (b.x - a.x) * f, a.z + (b.z - a.z) * f
                local qy = terrainY(qx, qz)
                drawDebugLine(px, py, pz, r, g, bl, qx, qy, qz, r, g, bl)
                px, py, pz = qx, qy, qz
            end
        end
    end
    -- where the course starts and ends (green and red, as on the panel's map)
    local range = Draw.MARKER_RANGE * Draw.MARKER_RANGE
    for k, wp in ipairs({wps[1], wps[#wps]}) do
        if (wp.x - vx) ^ 2 + (wp.z - vz) ^ 2 < range then
            Draw.worldMarker(wp.x, wp.z, k == 1 and Draw.START_COLOR or Draw.END_COLOR,
                k == 1 and "guidance_world_start" or "guidance_world_end")
        end
    end
end

Draw.MARKER_RANGE = 400 -- m from the vehicle the course's start and end markers show
Draw.START_COLOR = {0.30, 0.85, 0.50}
Draw.END_COLOR = {0.93, 0.36, 0.36}

--- A post with a flag, a ring round its foot and its name above it, at x, z on the ground
function Draw.worldMarker(x, z, c, textKey)
    local ground = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, x, 0, z)
    local top = terrainY(x, z) + 4
    local r, g, b = c[1], c[2], c[3]
    drawDebugLine(x, ground, z, r, g, b, x, top, z, r, g, b)
    -- the flag: a triangle off the top of the post
    drawDebugLine(x, top, z, r, g, b, x + 1.4, top - 0.4, z, r, g, b)
    drawDebugLine(x + 1.4, top - 0.4, z, r, g, b, x, top - 0.8, z, r, g, b)
    drawDebugLine(x, top - 0.2, z, r, g, b, x + 1.0, top - 0.4, z, r, g, b)
    -- a ring on the ground
    local n, radius = 16, 1.5
    local px, pz = x + radius, z
    for k = 1, n do
        local a = k / n * 2 * math.pi
        local qx, qz = x + math.cos(a) * radius, z + math.sin(a) * radius
        drawDebugLine(px, terrainY(px, pz), pz, r, g, b, qx, terrainY(qx, qz), qz, r, g, b)
        px, pz = qx, qz
    end
    if Utils and Utils.renderTextAtWorldPosition and g_i18n then
        local size = getCorrectTextSize and getCorrectTextSize(0.016) or 0.016
        setTextColor(r, g, b, 1)
        setTextBold(true)
        Utils.renderTextAtWorldPosition(x, top + 0.6, z, g_i18n:getText(textKey), size, 0)
        setTextBold(false)
        setTextColor(1, 1, 1, 1)
    end
end

-----------------------------------------------------------------------------------------------------------------------
-- Course plot on the panel
-----------------------------------------------------------------------------------------------------------------------

local function simplifyRun(pts, tolerance)
    -- Douglas-Peucker on screen points {x, y, ix}
    if #pts <= 2 then return pts end
    local keep = {[1] = true, [#pts] = true}
    local function dp(first, last)
        local maxD, index = 0, nil
        local a, b = pts[first], pts[last]
        local dx, dy = b.x - a.x, b.y - a.y
        local len = math.sqrt(dx * dx + dy * dy)
        for i = first + 1, last - 1 do
            local p = pts[i]
            local d
            if len < 1e-9 then
                d = math.sqrt((p.x - a.x) ^ 2 + (p.y - a.y) ^ 2)
            else
                d = math.abs(dx * (a.y - p.y) - dy * (a.x - p.x)) / len
            end
            if d > maxD then maxD, index = d, i end
        end
        if index and maxD > tolerance then
            keep[index] = true
            dp(first, index)
            dp(index, last)
        end
    end
    dp(1, #pts)
    local out = {}
    for i = 1, #pts do
        if keep[i] then table.insert(out, pts[i]) end
    end
    return out
end

--- The course in world coordinates as runs of the same type {t, pts = {x, y (world z), ix}}, simplified to
--- 'tolerance' metres (for the big map, which pans and zooms)
function Draw.makeWorldRuns(course, tolerance)
    local runs, run = {}, nil
    local wps = course.waypoints
    for i = 1, #wps do
        local p = wps[i]
        local t = i > 1 and p.t or (wps[2] and wps[2].t or p.t)
        if run == nil or run.t ~= t then
            local start = run and run.pts[#run.pts]
            run = {t = t, pts = {}}
            if start then table.insert(run.pts, start) end
            table.insert(runs, run)
        end
        table.insert(run.pts, {x = p.x, y = p.z, ix = i})
    end
    for _, r in ipairs(runs) do
        r.pts = simplifyRun(r.pts, tolerance)
    end
    return runs
end

--- Prepares the plot of a course in a box (screen coordinates): field outline and the course as lines,
--- simplified to what can be seen at that size. Returns a plot table for Draw.drawPlot.
--- The course map in the box x, y, w, h: the whole course, or zoom times closer around center {x, z} (world)
function Draw.makePlot(course, x, y, w, h, zoom, center)
    local outline = course.outline or {}
    local minX, minZ, maxX, maxZ = math.huge, math.huge, -math.huge, -math.huge
    for _, p in ipairs(outline) do
        minX, maxX = math.min(minX, p.x), math.max(maxX, p.x)
        minZ, maxZ = math.min(minZ, p.z), math.max(maxZ, p.z)
    end
    for _, p in ipairs(course.waypoints) do
        minX, maxX = math.min(minX, p.x), math.max(maxX, p.x)
        minZ, maxZ = math.min(minZ, p.z), math.max(maxZ, p.z)
    end
    -- scale in pixels per meter, same in both directions
    local pxW, pxH = w * g_screenWidth, h * g_screenHeight
    zoom = zoom or 1
    local scale = math.min(pxW / math.max(maxX - minX, 1), pxH / math.max(maxZ - minZ, 1)) * 0.94 * zoom
    local cx, cz = (minX + maxX) / 2, (minZ + maxZ) / 2
    if zoom > 1 and center then cx, cz = center.x, center.z end
    local function toScreen(wx, wz)
        -- north up: world z grows to the south, screen y to the top
        return x + w / 2 + (wx - cx) * scale / g_screenWidth, y + h / 2 - (wz - cz) * scale / g_screenHeight
    end
    local function toWorld(sx, sy)
        return cx + (sx - x - w / 2) * g_screenWidth / scale, cz - (sy - y - h / 2) * g_screenHeight / scale
    end
    local plot = {toScreen = toScreen, toWorld = toWorld, outline = {}, runs = {}, course = course,
                  box = {x = x, y = y, w = w, h = h}, zoom = zoom, span = pxW / scale}
    for _, p in ipairs(outline) do
        local sx, sy = toScreen(p.x, p.z)
        table.insert(plot.outline, {x = sx, y = sy})
    end
    -- runs of the same type, simplified to about a pixel
    local tolerance = 0.8 / g_screenHeight
    local wps = course.waypoints
    local run
    for i = 1, #wps do
        local p = wps[i]
        local sx, sy = toScreen(p.x, p.z)
        local t = i > 1 and p.t or (wps[2] and wps[2].t or p.t)
        if run == nil or run.t ~= t then
            local start = run and run.pts[#run.pts]
            run = {t = t, pts = {}}
            if start then table.insert(run.pts, start) end
            table.insert(plot.runs, run)
        end
        table.insert(run.pts, {x = sx, y = sy, ix = i})
    end
    for _, r in ipairs(plot.runs) do
        r.pts = simplifyRun(r.pts, tolerance)
    end
    return plot
end

--- The part of the line a-b inside the box (Liang-Barsky), or nil
local function clipToBox(ax, ay, bx, by, box)
    local t0, t1 = 0, 1
    local dx, dy = bx - ax, by - ay
    for _, e in ipairs({{-dx, ax - box.x}, {dx, box.x + box.w - ax}, {-dy, ay - box.y}, {dy, box.y + box.h - ay}}) do
        local p, q = e[1], e[2]
        if p == 0 then
            if q < 0 then return nil end
        else
            local r = q / p
            if p < 0 then
                if r > t1 then return nil end
                if r > t0 then t0 = r end
            else
                if r < t0 then return nil end
                if r < t1 then t1 = r end
            end
        end
    end
    return ax + dx * t0, ay + dy * t0, ax + dx * t1, ay + dy * t1
end

function Draw.drawPlot(plot, progressIx, vehicle, thickness, others)
    local outlineColor = {0.55, 0.75, 0.45, 0.6}
    local box = plot.box
    -- zoomed in, the map is bigger than its box: only what is inside it
    local clip = (plot.zoom or 1) > 1
    local function line(ax, ay, bx, by, width, color)
        if clip then
            ax, ay, bx, by = clipToBox(ax, ay, bx, by, box)
            if ax == nil then return end
        end
        Draw.line(ax, ay, bx, by, width, color)
    end
    local function inBox(sx, sy)
        return not clip or (sx >= box.x and sx <= box.x + box.w and sy >= box.y and sy <= box.y + box.h)
    end
    local o = plot.outline
    for i = 1, #o do
        local a, b = o[i], o[i % #o + 1]
        line(a.x, a.y, b.x, b.y, thickness, outlineColor)
    end
    for _, run in ipairs(plot.runs) do
        local c = Draw.COLORS[run.t] or Draw.COLORS.C
        local done = {c[1], c[2], c[3], 0.3}
        local todo = {c[1], c[2], c[3], (run.t == "R" or run.t == "H") and 0.95 or 0.7}
        local width = (run.t == "R" or run.t == "H") and thickness or thickness * 0.7
        for i = 2, #run.pts do
            local a, b = run.pts[i - 1], run.pts[i]
            line(a.x, a.y, b.x, b.y, width, b.ix <= progressIx and done or todo)
        end
    end
    -- where the course starts and ends
    local wps = plot.course.waypoints
    local sx0, sy0 = plot.toScreen(wps[1].x, wps[1].z)
    local sx1, sy1 = plot.toScreen(wps[#wps].x, wps[#wps].z)
    if inBox(sx0, sy0) then
        Draw.disc(sx0, sy0, thickness * 3.2, {0.08, 0.10, 0.12, 0.9})
        Draw.disc(sx0, sy0, thickness * 2.2, {0.30, 0.85, 0.50, 1})
    end
    if inBox(sx1, sy1) then
        Draw.disc(sx1, sy1, thickness * 3.2, {0.08, 0.10, 0.12, 0.9})
        Draw.disc(sx1, sy1, thickness * 2.2, {0.93, 0.36, 0.36, 1})
    end
    -- the vehicle: an arrow where it's heading, on a dark disc so it shows on any colour
    if vehicle then
        local vx, _, vz = getWorldTranslation(vehicle.rootNode)
        local dx, _, dz = localDirectionToWorld(vehicle.rootNode, 0, 0, 1)
        local sx, sy = plot.toScreen(vx, vz)
        local ax, ay = plot.toScreen(vx + dx, vz + dz)
        -- direction on the screen (y squeezed by the aspect ratio)
        local ux, uy = (ax - sx) * g_screenAspectRatio, ay - sy
        local len = math.sqrt(ux * ux + uy * uy)
        if len > 0 then ux, uy = ux / len, uy / len end
        if inBox(sx, sy) then
            Draw.arrow(sx, sy, thickness * 20, math.atan2(uy, ux))
        end
    end
    -- other vehicles (a combine's unloaders): arrows in their colour; off the map, at its edge
    for _, o in ipairs(others or {}) do
        local v = o.vehicle
        if v.rootNode and not v.isDeleted then
            local vx, _, vz = getWorldTranslation(v.rootNode)
            local dx, _, dz = localDirectionToWorld(v.rootNode, 0, 0, 1)
            local sx, sy = plot.toScreen(vx, vz)
            local ax, ay = plot.toScreen(vx + dx, vz + dz)
            local ux, uy = (ax - sx) * g_screenAspectRatio, ay - sy
            local margin = thickness * 6
            local inside = inBox(sx, sy)
            sx = math.max(box.x + margin / g_screenAspectRatio, math.min(box.x + box.w - margin / g_screenAspectRatio, sx))
            sy = math.max(box.y + margin, math.min(box.y + box.h - margin, sy))
            -- (an arrow in its colour, the way it faces)
            local c = o.color
            Draw.arrow(sx, sy, thickness * 17, math.atan2(uy, ux), {c[1], c[2], c[3], inside and 1 or 0.7})
        end
    end
end

-- Guidance: the panel. One compact panel on the right side of the screen: the course of the vehicle on a small
-- map, what it will do, the few settings that matter (more behind "More settings"), and a big Start button.
-- Every change makes the course again right away, so you see what you get.

GuidanceHud = {}
local Hud = GuidanceHud
local Hud_mt = {__index = Hud}
local Draw = GuidanceDraw

Hud.WIDTH = 360 -- reference pixels (1920x1080), scaled with the UI scale
Hud.PAD = 14
Hud.ROW = 30
Hud.PLOT = 230

Hud.C = {
    bg = {0.06, 0.07, 0.085, 0.94},
    shadow = {0, 0, 0, 0.35},
    surface = {0.11, 0.125, 0.145, 1},
    chip = {0.15, 0.165, 0.19, 1},
    track = {1, 1, 1, 0.10},
    hover = {0.20, 0.22, 0.26, 1},
    line = {1, 1, 1, 0.06},
    text = {0.93, 0.94, 0.95, 1},
    muted = {0.60, 0.64, 0.69, 1},
    accent = {0.20, 0.72, 0.45, 1},
    accentHover = {0.25, 0.80, 0.51, 1},
    danger = {0.86, 0.30, 0.30, 1},
    dangerHover = {0.93, 0.38, 0.38, 1},
    warn = {0.98, 0.75, 0.25, 1},
    pill = {0.18, 0.20, 0.23, 1},
}

function Hud.new()
    local self = setmetatable({}, Hud_mt)
    self.isOpen = false
    self.vehicle = nil
    self.elements = {}
    self.mouseX, self.mouseY = 0, 0
    self.showMore = false
    self.message, self.messageTimer, self.messageIsError = nil, 0, false
    -- where the panel is (left edge, top edge; screen 0..1), nil = the default place on the right
    self.posX, self.posTop = nil, nil
    self.dragging = nil
    self:loadPosition()
    return self
end

-----------------------------------------------------------------------------------------------------------------------
-- Position: drag the panel anywhere (on its background), remembered in modSettings
-----------------------------------------------------------------------------------------------------------------------

function Hud:loadPosition()
    self.posX, self.posTop = GuidancePrefs.panelX, GuidancePrefs.panelTop
end

function Hud:savePosition()
    if self.posX == nil then
        return
    end
    GuidancePrefs.panelX, GuidancePrefs.panelTop = self.posX, self.posTop
    GuidancePrefs.save()
end

function Hud:delete()
    self:close()
    Draw.delete()
end

local function currentVehicle()
    return g_localPlayer and g_localPlayer:getCurrentVehicle()
end

function Hud:isOpenFor(vehicle)
    return self.isOpen and self.vehicle == vehicle
end

function Hud:toggle(vehicle)
    if self:isOpenFor(vehicle) and self.minimized then
        -- minimised: the mouse to the small panel (its buttons) and back to the game; + for the whole panel
        if self.miniMouse then
            self:releaseMouse()
            self.miniMouse = false
        else
            self:takeMouse()
            self.miniMouse = true
        end
    elseif self:isOpenFor(vehicle) then
        self:close()
    else
        self:open(vehicle)
    end
end

function Hud:open(vehicle)
    if vehicle == nil or vehicle.getGuidanceCourse == nil then
        return
    end
    self:close()
    self.isOpen = true
    self.vehicle = vehicle
    local settings = vehicle:getGuidanceSettings()
    if settings and not settings.prefsApplied and vehicle:getGuidancePlan() == nil then
        GuidancePrefs.applyTo(settings)
        settings.prefsApplied = true
    end
    self.plot = nil
    self:takeMouse()
end

--- The mouse for the panel: the cursor shown, the camera held still (it must not turn while we use the mouse)
function Hud:takeMouse()
    if not g_inputBinding:getShowMouseCursor() then
        g_inputBinding:setShowMouseCursor(true)
        self.showedCursor = true
    end
    self.lockedCameras = {}
    local enterable = self.vehicle and self.vehicle.spec_enterable
    if enterable and enterable.cameras then
        for _, camera in pairs(enterable.cameras) do
            if camera.isRotatable then
                camera.isRotatable = false
                table.insert(self.lockedCameras, camera)
            end
        end
    end
end

--- The mouse back to the game: the camera turns again, the cursor goes (if we showed it)
function Hud:releaseMouse()
    for _, camera in ipairs(self.lockedCameras or {}) do
        camera.isRotatable = true
    end
    self.lockedCameras = nil
    if self.showedCursor then
        g_inputBinding:setShowMouseCursor(false)
        self.showedCursor = false
    end
end

--- Minimised: only the header, the course map and start / pause / stop stay, and the mouse goes back to the game
--- (drive, look round); the panel key gives it to the small panel and back, its + brings the whole panel back
function Hud:minimize()
    if not self.isOpen or self.minimized then
        return
    end
    self.minimized = true
    self.miniMouse = false
    self.editing = false
    self.focus = nil
    self:releaseMouse()
end

function Hud:restore()
    if not self.isOpen or not self.minimized then
        return
    end
    self.minimized = false
    if not self.miniMouse then self:takeMouse() end
    self.miniMouse = false
end

function Hud:close()
    if not self.isOpen then
        return
    end
    self:releaseMouse()
    if self.dragging then
        self.dragging = nil
        self:savePosition()
    end
    self.isOpen = false
    self.minimized, self.miniMouse = false, false
    self.vehicle = nil
    self.plot = nil
end

function Hud:onVehicleDeleted(vehicle)
    if self.vehicle == vehicle then
        self:close()
    end
end

function Hud:showMessage(text, isError, seconds)
    self.message = text
    self.messageIsError = isError
    self.messageTimer = (seconds or 6) * 1000
end

--- The panel open for another vehicle (switched to with Tab): as it was (its tab, minimised), now for that one
function Hud:switchTo(vehicle)
    -- the old one's camera turns again; the new one's is held while the panel has the mouse
    for _, camera in ipairs(self.lockedCameras or {}) do
        camera.isRotatable = true
    end
    self.lockedCameras = nil
    self.vehicle = vehicle
    self.plot, self.mapCenter, self.editing, self.focus, self.offField, self.dragElement = nil, nil, false, nil, nil, nil
    local settings = vehicle:getGuidanceSettings()
    if settings and not settings.prefsApplied and vehicle:getGuidancePlan() == nil then
        GuidancePrefs.applyTo(settings)
        settings.prefsApplied = true
    end
    if not self.minimized or self.miniMouse then
        self:takeMouse()
    end
end

function Hud:update(dt)
    if self.isOpen and currentVehicle() ~= self.vehicle then
        -- Tab to another vehicle: the panel goes with it; out of the vehicle (or into one we can't drive): closed
        local now = currentVehicle()
        if now ~= nil and not now.isDeleted and now.getGuidanceCourse ~= nil then
            self:switchTo(now)
        else
            self:close()
        end
    end
    -- gone to another vehicle from the fleet: once the game has put us in, the panel opens again there
    local going = self.pendingEnter
    if going then
        if currentVehicle() == going.vehicle and not going.vehicle.isDeleted then
            self.pendingEnter = nil
            self:open(going.vehicle)
            self.view, self.fleetPage = going.view, going.page
        elseif (g_time or 0) > going.expires then
            self.pendingEnter = nil
        end
    end
    self:updateRecording()
    if self.messageTimer > 0 then
        self.messageTimer = self.messageTimer - dt
        if self.messageTimer <= 0 then self.message = nil end
    end
end

-----------------------------------------------------------------------------------------------------------------------
-- Recording a field outline: drive round it, the vehicle's track every 2 m becomes the outline (the panel may be
-- closed meanwhile)
-----------------------------------------------------------------------------------------------------------------------

Hud.RECORD_STEP = 2 -- m
Hud.RECORD_MIN_LENGTH = 40 -- m

function Hud:startRecording(vehicle)
    self.recording = {vehicle = vehicle, points = {}, length = 0}
    self:updateRecording()
end

function Hud:updateRecording()
    local rec = self.recording
    if rec == nil then
        return
    end
    if rec.vehicle.isDeleted then
        self.recording = nil
        return
    end
    local x, _, z = getWorldTranslation(rec.vehicle.rootNode)
    local last = rec.points[#rec.points]
    local d = last and math.sqrt((x - last.x) ^ 2 + (z - last.z) ^ 2) or math.huge
    if d >= Hud.RECORD_STEP then
        table.insert(rec.points, {x = x, z = z})
        if last then rec.length = rec.length + d end
    end
end

--- Closes the track into a field and saves it (shared with the farm), or tells why not
function Hud:finishRecording()
    local rec = self.recording
    self.recording = nil
    if rec == nil then
        return
    end
    local poly = {}
    for i, p in ipairs(rec.points) do poly[i] = {x = p.x, y = p.z} end
    poly = GuidanceGeo.removeDuplicates(GuidanceGeo.simplify(poly, 0.5), 0.5)
    if rec.length < Hud.RECORD_MIN_LENGTH or #poly < 3 or math.abs(GuidanceGeo.signedArea(poly)) < 200 then
        self:showMessage(t("guidance_record_tooSmall"), true)
        return
    end
    local outline = {}
    for i, p in ipairs(poly) do outline[i] = {x = p.x, z = p.y} end
    local farmId = rec.vehicle:getOwnerFarmId()
    local name = t("guidance_record_name", #GuidanceLibrary.getFieldsForFarm(farmId) + 1)
    GuidanceLibrary.addField({id = 0, name = name, farmId = farmId, outline = outline})
    self:showMessage(t("guidance_record_done", name, math.abs(GuidanceGeo.signedArea(poly)) / 10000), false)
end

--- The track so far in the panel's map box
function Hud:drawRecording(rec, bx, by, bw, bh)
    local pts = rec.points
    if #pts < 2 then return end
    local minX, minZ, maxX, maxZ = math.huge, math.huge, -math.huge, -math.huge
    for _, p in ipairs(pts) do
        minX, maxX = math.min(minX, p.x), math.max(maxX, p.x)
        minZ, maxZ = math.min(minZ, p.z), math.max(maxZ, p.z)
    end
    local scale = math.min(bw * g_screenWidth / math.max(maxX - minX, 20), bh * g_screenHeight / math.max(maxZ - minZ, 20)) * 0.85
    local cx, cz = (minX + maxX) / 2, (minZ + maxZ) / 2
    local function toScreen(x, z)
        return bx + bw / 2 + (x - cx) * scale / g_screenWidth, by + bh / 2 - (z - cz) * scale / g_screenHeight
    end
    local thickness = self:h(2)
    for i = 2, #pts do
        local ax, ay = toScreen(pts[i - 1].x, pts[i - 1].z)
        local qx, qy = toScreen(pts[i].x, pts[i].z)
        Draw.line(ax, ay, qx, qy, thickness, Hud.C.accent)
    end
    -- the way back to the start closes it
    local ax, ay = toScreen(pts[#pts].x, pts[#pts].z)
    local sx, sy = toScreen(pts[1].x, pts[1].z)
    Draw.line(ax, ay, sx, sy, thickness * 0.6, {1, 1, 1, 0.35})
    Draw.disc(sx, sy, self:h(4), {0.30, 0.85, 0.50, 1})
    Draw.disc(ax, ay, self:h(4), {1, 1, 1, 1})
end

-----------------------------------------------------------------------------------------------------------------------
-- Layout helpers (reference pixels to screen)
-----------------------------------------------------------------------------------------------------------------------

function Hud:px(x, y)
    local s = (g_gameSettings:getValue("uiScale") or 1) * ((GuidancePrefs and GuidancePrefs.panelScale) or 1)
    return getNormalizedScreenValues(x * s, y * s)
end

function Hud:w(px)
    local x = self:px(px, 0)
    return x
end

function Hud:h(px)
    local _, y = self:px(0, px)
    return y
end

function Hud:addElement(x, y, w, h, onClick)
    local e = {x = x, y = y, w = w, h = h, onClick = onClick}
    table.insert(self.elements, e)
    return e
end

function Hud:isHover(x, y, w, h)
    if self.mouseX == nil or (self.minimized and not g_inputBinding:getShowMouseCursor()) then
        return false
    end
    return self.mouseX >= x and self.mouseX <= x + w and self.mouseY >= y and self.mouseY <= y + h
end

--- Controller: move the highlight to the next / previous button of the panel (dir 1 / -1)
function Hud:moveFocus(dir)
    local n = #self.elements
    if not self.isOpen or n == 0 then
        return
    end
    self.focus = ((self.focus or (dir > 0 and 0 or 1)) - 1 + dir) % n + 1
end

--- Controller: press the highlighted button
function Hud:pressFocus()
    local e = self.isOpen and self.focus and self.elements[self.focus]
    if e and e.onClick then
        e.onClick()
    end
end

function Hud:mouseEvent(posX, posY, isDown, isUp, button)
    if self:alertMouseEvent(posX, posY, isDown, isUp, button) then
        return
    end
    if not self.isOpen then
        return
    end
    -- minimised, the mouse is the game's (unless something else shows the cursor)
    if self.minimized and not g_inputBinding:getShowMouseCursor() then
        return
    end
    -- the mouse moved: the controller's highlight goes
    if self.focus and (math.abs(posX - (self.mouseX or 0)) > 1e-4 or math.abs(posY - (self.mouseY or 0)) > 1e-4) then
        self.focus = nil
    end
    self.mouseX, self.mouseY = posX, posY
    if self.dragging then
        local d = self.dragging
        self.posX, self.posTop = d.x + posX - d.mouseX, d.top + posY - d.mouseY
        if isUp and button == Input.MOUSE_BUTTON_LEFT then
            self.dragging = nil
            self:savePosition()
        end
        return
    end
    -- the zoomed map being moved
    if self.mapPan then
        local p = self.mapPan
        -- (metres per screen unit: the map's width in metres over its width on the screen)
        local perX = p.span / p.w
        local perY = perX * g_screenHeight / g_screenWidth
        self.mapCenter = {x = p.x - (posX - p.mouseX) * perX, z = p.z + (posY - p.mouseY) * perY, zoom = p.zoom,
                          pinned = true}
        if isUp and button == Input.MOUSE_BUTTON_LEFT then self.mapPan = nil end
        return
    end
    -- something being dragged (in the course editor)
    if self.dragElement then
        local e = self.dragElement
        if isUp and button == Input.MOUSE_BUTTON_LEFT then
            self.dragElement = nil
            e.onDrag(posX, posY, "end")
        else
            e.onDrag(posX, posY, "move")
        end
        return
    end
    -- an open list: the wheel scrolls it, a click picks an option or (anywhere else) closes it
    local d = self.dropdown
    if d and d.box then
        local over = self:isHover(d.box.x, d.box.y, d.box.w, d.box.h)
        local up = (isDown and button == Input.MOUSE_BUTTON_WHEEL_UP)
        local down = (isDown and button == Input.MOUSE_BUTTON_WHEEL_DOWN)
        if over and Input.MOUSE_BUTTON_WHEEL_UP and (up or down) then
            d.scroll = (d.scroll or 0) + (up and -1 or 1)
            return
        end
        if isDown and button == Input.MOUSE_BUTTON_LEFT then
            for _, e in ipairs(self.popupElements or {}) do
                if self:isHover(e.x, e.y, e.w, e.h) then
                    e.onClick()
                    return
                end
            end
            -- (its own value again: the row's click closes it)
            local onValue = self:isHover(d.x, d.y, d.w, d.rowH)
            if not onValue then
                self.dropdown = nil
                return
            end
        end
    end
    -- the mouse wheel over the course map: zoom
    local box = self.plotShown and not self.editing and self.plot and self.plot.box
    if box and self:isHover(box.x, box.y, box.w, box.h) and Input.MOUSE_BUTTON_WHEEL_UP then
        local up = (isDown and button == Input.MOUSE_BUTTON_WHEEL_UP)
            or (Input.isMouseButtonPressed and Input.isMouseButtonPressed(Input.MOUSE_BUTTON_WHEEL_UP))
        local down = (isDown and button == Input.MOUSE_BUTTON_WHEEL_DOWN)
            or (Input.isMouseButtonPressed and Input.isMouseButtonPressed(Input.MOUSE_BUTTON_WHEEL_DOWN))
        if (up or down) and (g_time or 0) >= (self.wheelTime or 0) + Hud.WHEEL_DELAY then
            self.wheelTime = g_time or 0
            self:zoomMap(up and 1 or -1)
            return
        end
    end
    if isDown and button == Input.MOUSE_BUTTON_LEFT then
        for _, e in ipairs(self.elements) do
            if self:isHover(e.x, e.y, e.w, e.h) then
                if e.onDrag then
                    self.dragElement = e
                    e.onDrag(posX, posY, "start")
                    return
                elseif e.onClick then
                    e.onClick(posX, posY)
                    return
                end
            end
        end
        -- on the zoomed map: move the map (it stops following the vehicle till zoomed again)
        local plot = self.plot
        if box and plot and (plot.zoom or 1) > 1 and self.mapCenter and self:isHover(box.x, box.y, box.w, box.h) then
            self.mapPan = {mouseX = posX, mouseY = posY, x = self.mapCenter.x, z = self.mapCenter.z,
                           zoom = self.mapCenter.zoom, span = plot.span, w = box.w}
            return
        end
        -- anywhere else on the panel: pick it up
        local box = self.box
        if box and self:isHover(box.x, box.y, box.w, box.h) then
            self.dragging = {mouseX = posX, mouseY = posY, x = box.x, top = box.y + box.h}
        end
    end
end

--- Text vertically centred in a box of height h at y
function Hud:textIn(x, y, h, size, text, color, align, bold)
    -- under an open list: not drawn (the game draws all text after all boxes, it would show through the list)
    local box = not self.drawingDropdown and self.dropdown and self.dropdown.box
    if box then
        local w = Draw.textWidth(size, text, bold)
        local left = x
        if align == RenderText.ALIGN_CENTER then left = x - w / 2 elseif align == RenderText.ALIGN_RIGHT then left = x - w end
        if left < box.x + box.w and left + w > box.x and y < box.y + box.h and y + h > box.y then
            return
        end
    end
    Draw.text(x, y + h / 2 - size * 0.36, size, text, color, align, bold)
end

-----------------------------------------------------------------------------------------------------------------------
-- Content
-----------------------------------------------------------------------------------------------------------------------

local function t(key, ...)
    local text = g_i18n:getText(key)
    if select("#", ...) > 0 then
        return string.format(text, ...)
    end
    return text
end

function Hud:getStatus(vehicle)
    local C = Hud.C
    local course = vehicle:getGuidanceCourse()
    -- a helper without a course: what it is doing
    local helperKind = vehicle.getGuidanceHelperKind and vehicle:getGuidanceHelperKind()
    if helperKind then
        if vehicle:getIsGuidancePaused() then
            return t("guidance_status_pausedHelper"), C.warn
        end
        local phase = vehicle:getGuidanceHelperPhase()
        return phase and t("guidance_phase_" .. phase) or t("guidance_helper_" .. helperKind), C.accent
    end
    -- AutoDrive's combine unloader, set up here
    if GuidanceAutoDrive.isUnloading(vehicle) then
        return t("guidance_status_adUnload"), C.accent
    end
    if vehicle:getIsGuidanceActive() then
        local _, done = vehicle:getGuidanceProgress()
        if vehicle:getIsGuidancePaused() then
            return t("guidance_status_paused", done * 100), C.warn
        end
        for _, info in ipairs(vehicle:getGuidanceInfoTexts()) do
            if info.name == "GIVING_WAY" then
                return t("guidance_status_givingWay"), C.warn
            end
        end
        return t("guidance_status_working", done * 100), C.accent
    end
    local infos = vehicle:getGuidanceInfoTexts()
    if #infos > 0 then
        return infos[1].text, infos[1].name == "FINISHED" and C.accent or C.warn
    end
    if vehicle:getIsHelperDriving() then
        return t("guidance_status_otherHelper"), C.muted
    end
    if course or (self.helperKindFor and self:helperKindFor(vehicle)) then
        return t("guidance_status_ready"), C.text
    end
    return t("guidance_status_noCourse"), C.muted
end

--- "850 m", "1.2 km"
local function formatDistance(m)
    if m < 1000 then return string.format("%d m", math.floor(m / 10 + 0.5) * 10) end
    return string.format("%.1f km", m / 1000)
end

local function formatDuration(seconds)
    local minutes = math.floor(seconds / 60 + 0.5)
    if minutes < 60 then
        return string.format("%d min", minutes)
    end
    return string.format("%d h %02d min", math.floor(minutes / 60), minutes % 60)
end

function Hud:getSummary(vehicle, course)
    local st = course.stats
    local seconds = self:estimateSeconds(vehicle, course)
    local text = t("guidance_summary", st.area / 10000, st.headlands, st.rows, formatDuration(seconds))
    if (st.islands or 0) > 0 then
        text = text .. " · " .. t("guidance_summary_islands", st.islands)
    end
    return text
end

--- The settings rows: label, value text, and what the arrows (and a click on the value) do. Without 'scope' they
--- are the tractor's; a scope edits other values: {values (a GuidancePlan), set(name, value), names (the rows to
--- show), stats (of a course made with them, or nil)}. 'all': the rows behind "More settings" too.
function Hud:getSettingRows(vehicle, scope, all)
    local s = scope and scope.values or vehicle:getGuidanceSettings()
    local course = vehicle:getGuidanceCourse()
    local stats
    if scope then stats = scope.stats else stats = course and course.stats end
    local function change(name, value)
        return function()
            if scope then scope.set(name, value) else vehicle:guidanceChangeSetting(name, value) end
        end
    end
    -- the course page shows the course's shape; everything (team, timing, ...) is on the settings page
    local function shown(name)
        if scope then return scope.names[name] end
        return all or not Hud.SETTINGS_PAGE_ONLY[name]
    end
    local more = all or scope ~= nil or self.showMore
    local rows = {}
    local function add(name, row)
        row.name = name
        -- (changeable while the helper works)
        row.live = scope == nil and GuidanceVehicle ~= nil and GuidanceVehicle.LIVE_SETTINGS[name] == true
        if shown(name) then table.insert(rows, row) end
    end

    add("workWidth", {
        label = t("guidance_set_width"),
        value = string.format("%.1f m%s", s.workWidth, s.autoWidth and (" · " .. t("guidance_auto")) or ""),
        dec = change("workWidth", math.max(1, s.workWidth - 0.5)),
        inc = change("workWidth", math.min(60, s.workWidth + 0.5)),
        click = (not s.autoWidth) and change("autoWidth", true) or nil,
    })
    -- obstacles near the field edge: driven over (the warning says so) or worked round (More settings)
    local edge = s.edgeObstacles or 0
    local edgeNext = edge == 1 and 0 or 1
    if more then add("edgeObstacles", {
        label = t("guidance_set_edgeObstacles"),
        value = t(edge == 1 and "guidance_edge_round" or "guidance_edge_over")
            .. ((stats and (stats.notched or 0) > 0) and string.format(" · %d", stats.notched) or ""),
        dec = change("edgeObstacles", edgeNext), inc = change("edgeObstacles", edgeNext),
    }) end
    -- a vineyard: on the rows or between them (automatic: on them with a grape harvester / pre-pruner)
    if stats and stats.pattern == "vines" then
        local mode = s.vineMode or 0
        local names = {[0] = "auto", [1] = "on", [2] = "between"}
        local value = t("guidance_vine_" .. names[mode])
        if mode == 0 then value = value .. " · " .. t(stats.vineOnRows and "guidance_vine_on" or "guidance_vine_between") end
        add("vineMode", {
            label = t("guidance_set_vineMode"), value = value,
            dec = change("vineMode", (mode + 2) % 3), inc = change("vineMode", (mode + 1) % 3),
        })
    end
    -- headlands: automatic is at least 30 m and enough to turn on the field; the arrows take a pass off or add one
    -- from there, a click on the value goes back to automatic
    local spacing = s.workWidth * (1 - (s.overlap or 0))
    local passes = s.headlands
    if passes < 0 then
        passes = stats and stats.headlands or GuidanceCourseGenerator.autoHeadlands(s:getGeneratorSettings(),
            GuidanceCourseGenerator.PATTERN_ADJACENT)
    end
    local headlandText = t("guidance_headlandWidth", math.floor(passes * spacing + 0.5), passes)
    if s.headlands < 0 then
        headlandText = t("guidance_auto") .. " · " .. headlandText
    end
    add("headlands", {
        label = t("guidance_set_headlands"),
        value = headlandText,
        dec = change("headlands", math.max(0, passes - 1)),
        inc = change("headlands", math.min(GuidanceCourseGenerator.MAX_HEADLANDS, passes + 1)),
        click = s.headlands >= 0 and change("headlands", -1) or nil,
    })
    local angleText
    if s.rowAngle < 0 then
        angleText = t("guidance_auto") .. (stats and string.format(" (%d°)", math.floor(stats.rowAngle + 0.5)) or "")
    else
        angleText = string.format("%d°", s.rowAngle)
    end
    local function angleStep(dir)
        return function()
            local a = s.rowAngle
            if a < 0 then
                -- leave automatic at the angle it chose, so the arrows turn it from there
                a = stats and math.floor(stats.rowAngle / 5 + 0.5) * 5 or 0
            end
            change("rowAngle", (a + dir * 5) % 180)()
        end
    end
    add("rowAngle", {
        label = t("guidance_set_rowAngle"),
        value = angleText,
        dec = angleStep(-1),
        inc = angleStep(1),
        click = s.rowAngle >= 0 and change("rowAngle", -1) or nil,
    })

    if more then
        add("turnRadius", {
            label = t("guidance_set_radius"),
            value = string.format("%.1f m%s", s.turnRadius, s.autoRadius and (" · " .. t("guidance_auto")) or ""),
            dec = change("turnRadius", math.max(3, s.turnRadius - 0.5)),
            inc = change("turnRadius", math.min(20, s.turnRadius + 0.5)),
            click = (not s.autoRadius) and change("autoRadius", true) or nil,
        })
        local toggle = function(name) return change(name, not s[name]) end
        add("clockwise", {
            label = t("guidance_set_direction"),
            value = s.clockwise and t("guidance_clockwise") or t("guidance_counterClockwise"),
            dec = toggle("clockwise"), inc = toggle("clockwise"),
        })
        add("headlandsFirst", {
            label = t("guidance_set_headlandOrder"),
            value = s.headlandsFirst and t("guidance_first") or t("guidance_last"),
            dec = toggle("headlandsFirst"), inc = toggle("headlandsFirst"),
        })
        -- auto -> every row -> racetrack -> auto
        local nextPattern = s.pattern % #GuidancePlan.PATTERNS + 1
        local prevPattern = (s.pattern - 2) % #GuidancePlan.PATTERNS + 1
        local patternText = t("guidance_pattern_" .. (GuidancePlan.PATTERNS[s.pattern] or "auto"))
        if s.pattern == GuidancePlan.PATTERN_AUTO and stats then
            patternText = patternText .. " · " .. t("guidance_pattern_" .. stats.pattern)
        end
        add("pattern", {
            label = t("guidance_set_pattern"),
            value = patternText,
            dec = change("pattern", prevPattern), inc = change("pattern", nextPattern),
        })
        -- lands: how many rows a land has, on which side the worked ground is
        if GuidancePlan.PATTERNS[s.pattern] == "lands" or s.teamMode == GuidancePlan.TEAM_LANDS then
            local k = s.rowsPerLand or 6
            add("rowsPerLand", {
                label = t("guidance_set_rowsPerLand"), value = tostring(k),
                dec = change("rowsPerLand", math.max(2, k - 1)), inc = change("rowsPerLand", math.min(30, k + 1)),
            })
            local side = s.landsSide or 0
            local sideText
            if side == GuidancePlan.SIDE_LEFT then
                sideText = t("guidance_side_left")
            elseif side == GuidancePlan.SIDE_RIGHT then
                sideText = t("guidance_side_right")
            else
                local pipe = GuidanceVehicle and GuidanceVehicle.pipeSide and GuidanceVehicle.pipeSide(vehicle) or 0
                sideText = t("guidance_side_auto", pipe == GuidancePlan.SIDE_RIGHT and t("guidance_side_right")
                    or pipe == GuidancePlan.SIDE_LEFT and t("guidance_side_left") or t("guidance_side_any"))
            end
            add("landsSide", {
                label = t("guidance_set_landsSide"), value = sideText,
                dec = change("landsSide", (side + 2) % 3), inc = change("landsSide", (side + 1) % 3),
            })
        end
        -- rows straight, or along the field's longest edge
        local edge = s.rowShape == GuidancePlan.ROWS_EDGE
        local otherShape = edge and GuidancePlan.ROWS_STRAIGHT or GuidancePlan.ROWS_EDGE
        add("rowShape", {
            label = t("guidance_set_rowShape"),
            value = edge and t("guidance_rowShape_edge") or t("guidance_rowShape_straight"),
            dec = change("rowShape", otherShape), inc = change("rowShape", otherShape),
        })
        -- tramlines: on the sowing course's passes
        local source = vehicle.spec_guidance and vehicle.spec_guidance.tramlineSource
        add("tramlines", {
            label = t("guidance_set_tramlines"),
            value = s.tramlines and (source and t("guidance_tramlines_on", source) or t("guidance_tramlines_none"))
                or t("guidance_tramlines_off"),
            dec = change("tramlines", not s.tramlines), inc = change("tramlines", not s.tramlines),
        })
        -- how many headland passes (the innermost) have round corners, the others sharp ones
        local rounded = s.roundedPasses < 0 and passes or math.min(s.roundedPasses, passes)
        local cornerText
        if rounded >= passes then
            cornerText = t("guidance_corners_allRound")
        elseif rounded <= 0 then
            cornerText = t("guidance_corners_allSharp")
        else
            cornerText = t("guidance_corners_count", rounded, passes)
        end
        add("roundedPasses", {
            label = t("guidance_set_roundedCorners"),
            value = cornerText,
            dec = change("roundedPasses", math.max(0, rounded - 1)),
            inc = change("roundedPasses", math.min(passes, rounded + 1)),
        })
        add("keepLowered", {
            label = t("guidance_set_turns"),
            value = s.keepLowered and t("guidance_turns_keep") or t("guidance_turns_lift"),
            dec = toggle("keepLowered"), inc = toggle("keepLowered"),
        })
        -- lifted while working: switched off (the game's way), or kept running
        add("keepRunning", {
            label = t("guidance_set_keepRunning"),
            value = s.keepRunning and t("guidance_keepRunning_on") or t("guidance_keepRunning_off"),
            dec = toggle("keepRunning"), inc = toggle("keepRunning"),
        })
        -- the game's own field work helper hired here (the hire key, AutoDrive set to the game's helper): CourseCorrect
        -- works the course instead, or the game's helper does
        add("takeOver", {
            label = t("guidance_set_takeOver"),
            value = s.takeOver ~= false and t("guidance_takeOver_on") or t("guidance_takeOver_off"),
            dec = change("takeOver", s.takeOver == false), inc = change("takeOver", s.takeOver == false),
        })
        -- the automatic headland is at least this wide (0: only what the turns need)
        local minWidth = math.floor((s.minHeadlandWidth or GuidancePlan.MIN_HEADLAND_DEFAULT) + 0.5)
        add("minHeadlandWidth", {
            label = t("guidance_set_minHeadland"),
            value = string.format("%d m", minWidth),
            dec = change("minHeadlandWidth", math.max(0, minWidth - 5)),
            inc = change("minHeadlandWidth", math.min(100, minWidth + 5)),
        })
        -- several tractors on one field: alone, or a strip each (the headland passes shared out)
        local teamMode = s.teamMode or GuidancePlan.TEAM_ALONE
        local modes = {}
        for m in pairs(GuidancePlan.TEAM_MODES) do modes[#modes + 1] = m end
        table.sort(modes)
        local function stepMode(dir)
            for i, m in ipairs(modes) do
                if m == teamMode then return modes[(i - 1 + dir) % #modes + 1] end
            end
            return GuidancePlan.TEAM_ALONE
        end
        add("teamMode", {
            label = t("guidance_set_teamMode"),
            value = t("guidance_team_" .. GuidancePlan.TEAM_MODES[teamMode]),
            dec = change("teamMode", stepMode(-1)), inc = change("teamMode", stepMode(1)),
        })
        if teamMode ~= GuidancePlan.TEAM_ALONE then
            local size, index = s.teamSize or 2, math.min(s.teamIndex or 1, s.teamSize or 2)
            add("teamSize", {
                label = t("guidance_set_teamSize"),
                value = t("guidance_team_size", size),
                dec = change("teamSize", math.max(2, size - 1)), inc = change("teamSize", math.min(GuidancePlan.TEAM_MAX, size + 1)),
            })
            add("teamIndex", {
                label = t("guidance_set_teamIndex"),
                value = t("guidance_team_index", index, size),
                dec = change("teamIndex", (index - 2) % size + 1), inc = change("teamIndex", index % size + 1),
            })
        end
        -- what of the field: all of it, the headlands only, the rows only; and which rows
        local part = s.workPart or GuidancePlan.WORK_WHOLE
        local partNext, partPrev = (part + 1) % 3, (part + 2) % 3
        add("workPart", {
            label = t("guidance_set_workPart"),
            value = t("guidance_workPart_" .. GuidancePlan.WORK_PARTS[part]),
            dec = change("workPart", partPrev), inc = change("workPart", partNext),
        })
        if part ~= GuidancePlan.WORK_HEADLANDS then
            local maxRows = (stats and (stats.allRows or stats.rows)) or 999
            local from, to = s.rowFrom or 0, s.rowTo or 0
            add("rowFrom", {
                label = t("guidance_set_rowFrom"),
                value = from > 0 and tostring(from) or t("guidance_rows_first"),
                dec = change("rowFrom", math.max(0, from - 1)),
                inc = change("rowFrom", math.min(to > 0 and to or maxRows, from + 1)),
                click = from > 0 and change("rowFrom", 0) or nil,
            })
            add("rowTo", {
                label = t("guidance_set_rowTo"),
                value = to > 0 and tostring(to) or t("guidance_rows_last"),
                dec = change("rowTo", to == 0 and maxRows - 1 or math.max(math.max(1, from), to - 1)),
                inc = change("rowTo", (to == 0 or to + 1 >= maxRows) and 0 or to + 1),
                click = to > 0 and change("rowTo", 0) or nil,
            })
        end
        -- speeds: working (at most; 0 the implement's own limit), in turns, backing up
        local ws = s.workSpeedMax or 0
        add("workSpeedMax", {
            label = t("guidance_set_workSpeed"),
            value = ws > 0 and string.format("%d km/h", ws) or t("guidance_speed_implement"),
            dec = change("workSpeedMax", ws == 0 and 25 or math.max(0, ws - 1 < 3 and 0 or ws - 1)),
            inc = change("workSpeedMax", (ws == 0 or ws >= 40) and 0 or ws + 1),
            click = ws > 0 and change("workSpeedMax", 0) or nil,
        })
        local ts, rs = s.turnSpeed or 10, s.reverseSpeed or 5
        add("turnSpeed", {
            label = t("guidance_set_turnSpeed"), value = string.format("%d km/h", ts),
            dec = change("turnSpeed", math.max(4, ts - 1)), inc = change("turnSpeed", math.min(25, ts + 1)),
        })
        add("reverseSpeed", {
            label = t("guidance_set_reverseSpeed"), value = string.format("%d km/h", rs),
            dec = change("reverseSpeed", math.max(2, rs - 1)), inc = change("reverseSpeed", math.min(10, rs + 1)),
        })
        local lightsAuto = (s.lights or GuidancePlan.LIGHTS_AUTO) == GuidancePlan.LIGHTS_AUTO
        local otherLights = lightsAuto and GuidancePlan.LIGHTS_OFF or GuidancePlan.LIGHTS_AUTO
        add("lights", {
            label = t("guidance_set_lights"),
            value = lightsAuto and t("guidance_lights_auto") or t("guidance_lights_off"),
            dec = change("lights", otherLights), inc = change("lights", otherLights),
        })
        -- a harvester: how full before AutoDrive sends the unloader
        if GuidanceFieldworkDriver and GuidanceFieldworkDriver.findHarvester(vehicle) then
            local at = s.callUnloaderAt or 80
            add("callUnloaderAt", {
                label = t("guidance_set_callUnloaderAt"),
                value = string.format("%d%%", at),
                dec = change("callUnloaderAt", math.max(10, at - 5)),
                inc = change("callUnloaderAt", math.min(100, at + 5)),
            })
            -- in the rain: wait (no yield lost) or carry on
            local rainWait = s.rainWait ~= false
            add("rainWait", {
                label = t("guidance_set_rainWait"),
                value = rainWait and t("guidance_rain_wait") or t("guidance_rain_go"),
                dec = change("rainWait", not rainWait), inc = change("rainWait", not rainWait),
            })
        end
        -- a seeder / sprayer: where it refills on its own when empty (the game's roads), unless the helper buys
        if GuidanceTrips and #GuidanceTrips.refillTypes(vehicle) > 0 then
            local list = GuidanceTrips.refillStations(vehicle)
            -- off, from supplies at the field edge, or a trip to one of the stations
            local offText
            if g_currentMission and g_currentMission.missionInfo and g_currentMission.missionInfo.helperBuySeeds then
                offText = t("guidance_refill_bought")
            else
                offText = #list > 0 and t("guidance_refill_off") or t("guidance_refill_none")
            end
            local choices = {{edge = false, x = 0, z = 0, label = offText},
                             {edge = true, x = 0, z = 0, label = t("guidance_refill_edge")}}
            for _, st in ipairs(list) do
                local sx, sz = GuidanceTrips.targetOf(st)
                choices[#choices + 1] = {edge = false, x = sx, z = sz, label = GuidanceTrips.nameOf(st)}
            end
            local cur = 1
            if s.refillEdge then
                cur = 2
            elseif GuidanceTrips.find(list, s.refillX, s.refillZ) then
                for i = 3, #choices do
                    if math.abs(choices[i].x - s.refillX) < 1 and math.abs(choices[i].z - s.refillZ) < 1 then cur = i end
                end
            end
            local value = choices[cur].label
            local function pick(step)
                return function()
                    local c = choices[(cur - 1 + step) % #choices + 1]
                    if scope then
                        scope.set("refillEdge", c.edge); scope.set("refillX", c.x); scope.set("refillZ", c.z)
                    else
                        vehicle:guidanceApplySettings({refillEdge = c.edge, refillX = c.x, refillZ = c.z})
                    end
                end
            end
            add("refillX", {label = t("guidance_set_refill"), value = value, dec = pick(-1), inc = pick(1)})
        end
        -- the AutoDrive marker that takes it to this course (Go, the queue): picked, or the nearest
        local markers = GuidanceVehicle and GuidanceVehicle.autoDriveMarkers and GuidanceVehicle.autoDriveMarkers()
        if markers and #markers > 0 then
            local names = {""}
            for _, mk in ipairs(markers) do names[#names + 1] = mk.name end
            local cur = 1
            for i, nm in ipairs(names) do
                if nm == (s.adMarker or "") then cur = i end
            end
            local function pickMarker(step)
                return function()
                    local nm = names[(cur - 1 + step) % #names + 1]
                    if scope then scope.set("adMarker", nm) else vehicle:guidanceChangeSetting("adMarker", nm) end
                end
            end
            -- automatic: which one that is for this course
            local auto = t("guidance_admarker_nearest")
            local course = not scope and vehicle:getGuidanceCourse()
            if cur == 1 and course then
                local _, autoName = GuidanceVehicle.markerFor(course.plan, course)
                if autoName then auto = auto .. " (" .. autoName .. ")" end
            end
            local markerLabels = {auto}
            for i = 2, #names do markerLabels[i] = names[i] end
            add("adMarker", {label = t("guidance_set_adMarker"),
                             options = markerLabels, current = cur,
                             select = function(i)
                                 local nm = names[i]
                                 if scope then scope.set("adMarker", nm) else vehicle:guidanceChangeSetting("adMarker", nm) end
                             end,
                             value = cur == 1 and auto or names[cur],
                             dec = pickMarker(-1), inc = pickMarker(1), click = cur > 1 and function()
                                 if scope then scope.set("adMarker", "") else vehicle:guidanceChangeSetting("adMarker", "") end
                             end or nil})
        end
        -- trips with AutoDrive for fuel and repairs (it brings it back, it carries on where it stopped): at what fuel
        -- and wear
        local function choiceRow(name, label, values, texts)
            local cur, ix = s[name] or 0, 1
            for i, v in ipairs(values) do
                if v == cur then ix = i end
            end
            add(name, {label = t(label), value = texts[ix], options = texts, current = ix,
                       select = function(i) change(name, values[i])() end,
                       dec = change(name, values[math.max(1, ix - 1)]), inc = change(name, values[math.min(#values, ix + 1)])})
        end
        if GuidanceAutoDrive and GuidanceAutoDrive.get() ~= nil then
            local function percents(values)
                local texts = {}
                for i, v in ipairs(values) do texts[i] = v == 0 and t("guidance_off") or string.format("%d%%", v) end
                return values, texts
            end
            choiceRow("refuelAt", "guidance_set_refuelAt", percents({0, 10, 15, 20, 25, 30}))
            choiceRow("repairAt", "guidance_set_repairAt", percents({0, 50, 60, 70, 80, 90}))
        end
        -- the field's chain: the tractor that takes the field over once this course is done
        if GuidanceVehicle and GuidanceVehicle.vehicleKey then
            local keys, names = {""}, {t("guidance_handOver_none")}
            for _, v in ipairs(GuidanceMap.getFarmVehicles()) do
                if v ~= vehicle then
                    keys[#keys + 1], names[#names + 1] = GuidanceVehicle.vehicleKey(v), Guidance.vehicleName(v)
                end
            end
            local handOver = s.handOver or ""
            local known = false
            for _, k in ipairs(keys) do known = known or k == handOver end
            if not known then
                keys[#keys + 1], names[#names + 1] = handOver, t("guidance_handOver_gone")
            end
            choiceRow("handOver", "guidance_set_handOver", keys, names)
        end
        -- the work area off to one side of where the game says: the helper steers the other way
        local offset = s.toolOffsetX or 0
        local offsetText = t("guidance_offset_centre")
        if math.abs(offset) > 0.01 then
            offsetText = t(offset > 0 and "guidance_offset_right" or "guidance_offset_left", math.abs(offset))
        end
        local function round1(v) return math.floor(v * 10 + 0.5) / 10 end
        add("toolOffsetX", {
            label = t("guidance_set_toolOffset"),
            value = offsetText,
            dec = change("toolOffsetX", round1(math.max(-3, offset - 0.1))),
            inc = change("toolOffsetX", round1(math.min(3, offset + 0.1))),
            click = math.abs(offset) > 0.01 and change("toolOffsetX", 0) or nil,
        })
        -- a helper working when the game was saved: carries on after loading, or waits
        add("autoResume", {
            label = t("guidance_set_autoResume"),
            value = (s.autoResume ~= false) and t("guidance_resume_carryOn") or t("guidance_resume_wait"),
            dec = change("autoResume", s.autoResume == false), inc = change("autoResume", s.autoResume == false),
        })
        -- when the implements go down and come up: on time, or metres early / late
        local function timing(value)
            if math.abs(value) < 0.01 then return t("guidance_timing_onTime") end
            return t(value > 0 and "guidance_timing_late" or "guidance_timing_early", math.abs(value))
        end
        for _, name in ipairs({"lowerLate", "raiseLate"}) do
            local value = s[name] or 0
            add(name, {
                label = t("guidance_set_" .. name),
                value = timing(value),
                dec = change(name, math.max(-5, value - 0.5)),
                inc = change(name, math.min(5, value + 0.5)),
                click = math.abs(value) > 0.01 and change(name, 0) or nil,
            })
        end
    end
    return rows
end

--- Shortened with dots to fit (plain ones, the game font may not have the ellipsis)
local function fit(text, size, width, bold)
    if Draw.textWidth(size, text, bold) <= width then
        return text
    end
    while #text > 4 and Draw.textWidth(size, text .. "...", bold) > width do
        -- the last whole character off (not half of an ä)
        text = text:gsub("[%z\1-\127\194-\244][\128-\191]*$", "")
    end
    return text .. "..."
end

Hud.DROPDOWN_ROWS = 9 -- options shown at once in an open list (more: the mouse wheel scrolls)

--- The open list of a row's options, under its value (above it near the bottom of the screen)
function Hud:drawDropdown()
    self.drawingDropdown = true
    self:drawDropdownList()
    self.drawingDropdown = false
end

function Hud:drawDropdownList()
    local d = self.dropdown
    local C = Hud.C
    local m = self:metrics()
    local itemH = d.rowH * 0.85
    local shown = math.min(#d.options, Hud.DROPDOWN_ROWS)
    d.scroll = math.max(0, math.min(d.scroll or 0, #d.options - shown))
    local widest = d.w
    for _, label in ipairs(d.options) do
        widest = math.max(widest, Draw.textWidth(m.smallSize, label) + self:w(28))
    end
    local w = math.min(widest, m.width - 2 * m.pad)
    local x = math.max(0, d.x + d.w - w)
    local h = shown * itemH + self:h(8)
    local y = d.y - h
    if y < 0.01 then y = d.y + d.rowH end
    d.box = {x = x, y = y, w = w, h = h}
    Draw.roundRect(x - self:w(2), y - self:h(3), w + self:w(4), h + self:h(4), m.smallRadius, C.shadow)
    Draw.roundRect(x, y, w, h, m.smallRadius, C.surface)
    for k = 1, shown do
        local ix = d.scroll + k
        local iy = y + h - self:h(4) - k * itemH
        local current = ix == d.current
        local hover = self:isHover(x, iy, w, itemH)
        if current or hover then
            Draw.roundRect(x + self:w(4), iy + self:h(1), w - self:w(8), itemH - self:h(2), self:h(5),
                current and C.accent or C.hover)
        end
        self:textIn(x + self:w(12), iy, itemH, m.smallSize, fit(d.options[ix], m.smallSize, w - self:w(24)),
            current and {1, 1, 1, 1} or C.text, nil, current)
        table.insert(self.popupElements, {x = x, y = iy, w = w, h = itemH, onClick = function()
            self.dropdown = nil
            if d.select then d.select(ix) end
        end})
    end
    -- more than shown: a thin bar where the shown ones are
    if #d.options > shown then
        local barH = h * shown / #d.options
        local barY = y + h - barH - (h - barH) * d.scroll / (#d.options - shown)
        Draw.roundRect(x + w - self:w(4), barY, self:w(2), barH, self:h(1), C.muted)
    end
end

-----------------------------------------------------------------------------------------------------------------------
-- Drawing: a frame (background, header, tabs) and the views in it
-----------------------------------------------------------------------------------------------------------------------

Hud.TABS = {
    {view = "vehicle", key = "guidance_tab_course"},
    {view = "team", key = "guidance_tab_team"},
    {view = "library", key = "guidance_tab_saved"},
    {view = "fleet", key = "guidance_tab_fleet"},
    {view = "settings", key = "guidance_tab_settings"},
}

--- Common sizes, in screen units
function Hud:metrics()
    return {
        pad = self:w(Hud.PAD), padY = self:h(Hud.PAD), rowH = self:h(Hud.ROW), width = self:w(Hud.WIDTH),
        textSize = self:h(13), smallSize = self:h(11.5), titleSize = self:h(17),
        radius = self:h(12), smallRadius = self:h(7),
        headerH = self:h(54), tabsH = self:h(36),
    }
end

--- Background, header (title, subtitle, status, close) and the tabs, for content 'contentH' high. Returns the
--- panel's left edge and the top of the content
function Hud:drawFrame(m, contentH, subtitle, status, statusColor)
    local C = Hud.C
    local width = m.width
    local tabsH = self.minimized and 0 or m.tabsH
    local height = m.headerH + tabsH + contentH + m.padY
    local x = self.posX or (1 - width - self:w(24))
    local top = self.posTop or 0.86
    x = math.max(0, math.min(1 - width, x))
    top = math.max(height, math.min(1, top))
    local y = top - height
    self.box = {x = x, y = y, w = width, h = height}

    Draw.roundRect(x - self:w(3), y - self:h(6), width + self:w(6), height + self:h(6), m.radius * 1.3, C.shadow)
    Draw.roundRect(x, y, width, height, m.radius, C.bg)
    Draw.roundRect(x + m.radius, top - self:h(3), width - 2 * m.radius, self:h(3), self:h(1.5), C.accent)

    -- header
    local cy = top - m.headerH
    self:textIn(x + m.pad, cy + m.headerH * 0.46, m.headerH * 0.5, m.titleSize, Guidance.TITLE, C.text, nil, true)
    self:textIn(x + m.pad, cy + m.headerH * 0.06, m.headerH * 0.45, m.smallSize, subtitle, C.muted)
    local pillH = self:h(24)
    local pillY = cy + (m.headerH - pillH) / 2
    local closeW = self:w(28)
    local closeX = x + width - m.pad - closeW
    -- minimise (only the course map stays, the mouse back to the game) / the whole panel again
    local miniX = closeX - self:w(4) - closeW
    local miniHover = self:isHover(miniX, pillY, closeW, pillH)
    if miniHover then Draw.roundRect(miniX, pillY, closeW, pillH, pillH / 2, C.hover) end
    self:textIn(miniX + closeW / 2, pillY, pillH, m.textSize, self.minimized and "+" or "–",
        miniHover and C.text or C.muted, RenderText.ALIGN_CENTER, true)
    self:addElement(miniX, pillY, closeW, pillH, function()
        if self.minimized then self:restore() else self:minimize() end
    end)
    -- help: the topic of where the panel is (again: back)
    local helpX = miniX
    if not self.minimized then
        helpX = miniX - self:w(4) - closeW
        local helpHover = self:isHover(helpX, pillY, closeW, pillH)
        local helpOn = self.view == "help"
        if helpHover or helpOn then Draw.roundRect(helpX, pillY, closeW, pillH, pillH / 2, helpOn and C.accent or C.hover) end
        self:textIn(helpX + closeW / 2, pillY, pillH, m.textSize, "?", (helpHover or helpOn) and C.text or C.muted,
            RenderText.ALIGN_CENTER, true)
        self:addElement(helpX, pillY, closeW, pillH, function() self:openHelp() end)
    end
    if status then
        -- as wide as the status, but not over the title or the vehicle's name under it (a long status is shortened;
        -- with no room left it isn't shown here, the view says it too)
        local leftW = math.max(Draw.textWidth(m.titleSize, Guidance.TITLE, true), Draw.textWidth(m.smallSize, subtitle or ""))
        local room = helpX - self:w(6) - (x + m.pad + leftW + self:w(8))
        local pillW = math.min(Draw.textWidth(m.smallSize, status) + self:w(30), room)
        if pillW < self:w(70) then status = nil end
        status = status and fit(status, m.smallSize, pillW - self:w(30))
    end
    if status then
        local pillW = Draw.textWidth(m.smallSize, status) + self:w(30)
        local pillX = helpX - self:w(6) - pillW
        Draw.roundRect(pillX, pillY, pillW, pillH, pillH / 2, C.pill)
        Draw.disc(pillX + self:w(13), pillY + pillH / 2, self:h(4), statusColor)
        self:textIn(pillX + self:w(22), pillY, pillH, m.smallSize, status, C.text)
    end
    local closeHover = self:isHover(closeX, pillY, closeW, pillH)
    if closeHover then Draw.roundRect(closeX, pillY, closeW, pillH, pillH / 2, C.hover) end
    self:textIn(closeX + closeW / 2, pillY, pillH, m.textSize, "×", closeHover and C.text or C.muted, RenderText.ALIGN_CENTER)
    self:addElement(closeX, pillY, closeW, pillH, function() self:close() end)
    if self.minimized then
        return x, cy
    end

    -- tabs
    cy = cy - m.tabsH
    local tabH = self:h(28)
    local tabY = cy + (m.tabsH - tabH) / 2
    local tabsW = width - 2 * m.pad
    local tabW = tabsW / #Hud.TABS
    Draw.roundRect(x + m.pad, tabY, tabsW, tabH, tabH / 2, C.chip)
    for k, tab in ipairs(Hud.TABS) do
        local tx = x + m.pad + (k - 1) * tabW
        local view = self.view or "vehicle"
        if view == "help" then view = self.helpFrom or "vehicle" end
        if view == "import" or view == "queue" or view == "contracts" then view = "library" end
        local selected = view == tab.view
        local hover = not selected and self:isHover(tx, tabY, tabW, tabH)
        if selected or hover then
            Draw.roundRect(tx + self:w(2), tabY + self:h(2), tabW - self:w(4), tabH - self:h(4), (tabH - self:h(4)) / 2,
                selected and C.surface or C.hover)
        end
        self:textIn(tx + tabW / 2, tabY, tabH, m.smallSize, fit(t(tab.key), m.smallSize, tabW - self:w(6), selected),
            selected and C.text or C.muted, RenderText.ALIGN_CENTER, selected)
        if not selected then
            self:addElement(tx, tabY, tabW, tabH, function()
                self.view = tab.view
                -- the saved courses open on the folder of the field we're on again
                self.libraryFolder, self.libraryFolderChosen, self.libraryPage = nil, false, 1
            end)
        end
    end
    return x, cy
end

--- A rounded button; onClick nil draws it disabled
function Hud:button(bx, by, bw, bh, label, color, hoverColor, textColor, onClick, size)
    local hover = onClick ~= nil and self:isHover(bx, by, bw, bh)
    Draw.roundRect(bx, by, bw, bh, math.min(self:h(7), bh / 2), hover and hoverColor or color)
    self:textIn(bx + bw / 2, by, bh, size or self:h(13), label, textColor, RenderText.ALIGN_CENTER, true)
    if onClick then self:addElement(bx, by, bw, bh, onClick) end
end

--- Seconds for the whole course and still to go (see GuidanceVehicle.getGuidanceTimes)
function Hud:estimateSeconds(vehicle, course)
    local total, left = vehicle:getGuidanceTimes()
    if total == nil then
        local times = course:getTimes(vehicle:getGuidanceWorkSpeed())
        total = times[#times]
        left = total
    end
    return total, left
end

function Hud:draw()
    if not self.isOpen or self.vehicle == nil then
        return
    end
    self.elements = {}
    self.plotShown = false
    self.dropdownSeen = false
    self:drawView()
    -- an open list on top of everything (closed when its row isn't shown any more)
    if self.dropdown and not self.dropdownSeen then self.dropdown = nil end
    self.popupElements = {}
    if self.dropdown then self:drawDropdown() end
    -- the controller's highlight
    local e = self.focus and self.elements[self.focus]
    if e then
        local C, t2 = Hud.C, self:h(2)
        local w2 = t2 / g_screenAspectRatio
        Draw.rect(e.x - w2, e.y - t2, e.w + 2 * w2, t2, C.accent)
        Draw.rect(e.x - w2, e.y + e.h, e.w + 2 * w2, t2, C.accent)
        Draw.rect(e.x - w2, e.y, w2, e.h, C.accent)
        Draw.rect(e.x + e.w, e.y, w2, e.h, C.accent)
    elseif self.focus then
        self.focus = nil
    end
end

function Hud:drawView()
    if self.minimized then
        return self:drawMini()
    end
    if self.view == "import" then
        return self:drawImport()
    end
    if self.view == "queue" then
        return self:drawQueue()
    end
    if self.view == "contracts" then
        return self:drawContracts()
    end
    if self.view == "help" then
        return self:drawHelp()
    end
    if self.view == "fleet" and self.fleetView == "log" then
        return self:drawWorkLog()
    end
    if self.view == "fleet" then
        return self:drawFleet()
    elseif self.view == "library" then
        return self:drawLibrary()
    elseif self.view == "settings" then
        return self:drawSettings()
    elseif self.view == "team" then
        return self:drawTeam()
    end
    -- a helper without a course (unloader, bales, silo): its own view
    local kind = self.vehicle and self:helperKindFor(self.vehicle)
    if kind then
        return self:drawHelper(kind)
    end
    return self:drawVehicle()
end

--- The details of a course: {label, value} pairs
function Hud:getDetails(vehicle, course)
    local st = course.stats
    local seconds, secondsLeft = self:estimateSeconds(vehicle, course)
    local _, done = vehicle:getGuidanceProgress()
    local spacing = course.plan.workWidth * (1 - (course.plan.overlap or 0))
    local list = {
        {t("guidance_detail_area"), string.format("%.2f ha", st.area / 10000)},
        {t("guidance_detail_length"), string.format("%.1f km", course.length / 1000)},
        {t("guidance_detail_working"), string.format("%.1f km", st.workLength / 1000)},
        {t("guidance_detail_time"), formatDuration(seconds)},
        {t("guidance_detail_headlands"), string.format("%d · %d m", st.headlands, math.floor(st.headlands * spacing + 0.5))},
        {t("guidance_detail_rows"), tostring(st.rows)},
        {t("guidance_detail_turns"), tostring(st.turns or 0)},
        {t("guidance_detail_reverse"), string.format("%d m", math.floor((st.reverseLength or 0) + 0.5))},
    }
    if st.team then
        local mode = GuidancePlan.TEAM_MODES[course.plan.teamMode or 0] or "strips"
        table.insert(list, {t("guidance_detail_team"), t("guidance_teamRole_" .. mode, st.team.index or 1, st.team.size or 1)})
    end
    if done > 0 and done < 1 then
        table.insert(list, 5, {t("guidance_detail_left"), formatDuration(secondsLeft)})
    end
    if (st.islands or 0) > 0 then
        table.insert(list, {t("guidance_detail_islands"), tostring(st.islands)})
    end
    -- what it takes, against what is in the tanks
    for _, item in ipairs(GuidancePlanner.get(vehicle, course, seconds, 1 - done)) do
        local value
        if item.bought then
            value = t("guidance_plan_bought")
        else
            value = string.format("%d / %d l", math.floor(item.needed + 0.5), math.floor(item.have + 0.5))
        end
        local label = item.label or t("guidance_plan_" .. item.kind)
        if item.pf then label = t("guidance_plan_pf", label) end
        table.insert(list, {label, value})
    end
    return list
end

--- The field the vehicle is on (looked up once a second)
function Hud:getFieldHere(vehicle)
    local now = g_time or 0
    if self.fieldHereVehicle ~= vehicle or now - (self.fieldHereTime or -1e9) > 1000 then
        local x, _, z = getWorldTranslation(vehicle.rootNode)
        local ok, id = Guidance.try(GuidanceCourse.getFieldIdAt, x, z)
        self.fieldHere = ok and id or nil
        self.fieldHereVehicle, self.fieldHereTime = vehicle, now
    end
    return self.fieldHere
end

--- Setting rows (see getSettingRows): label, - value +. Returns the new top.
function Hud:drawSettingRows(x, cy, rows, editable)
    local C = Hud.C
    local m = self:metrics()
    local pad, rowH, width, textSize = m.pad, m.rowH, m.width, m.textSize
    local chipW, chipH = self:w(24), self:h(22)
    local valueW = self:w(120)
    for i, row in ipairs(rows) do
        cy = cy - rowH
        if i > 1 then Draw.rect(x + pad, cy + rowH, width - 2 * pad, self:h(1), C.line) end
        self:textIn(x + pad, cy, rowH, textSize, row.label, C.muted)
        local rightX = x + width - pad
        local incX = rightX - chipW
        local valueX = incX - valueW
        local decX = valueX - chipW
        local chipY = cy + (rowH - chipH) / 2
        for _, chip in ipairs({{decX, "-", row.dec}, {incX, "+", row.inc}}) do
            local cx, label, fn = chip[1], chip[2], chip[3]
            local usable = (editable or row.live) and fn ~= nil
            local hover = usable and self:isHover(cx, chipY, chipW, chipH)
            Draw.roundRect(cx, chipY, chipW, chipH, chipH / 2, hover and C.hover or C.chip)
            self:textIn(cx + chipW / 2, chipY, chipH, textSize, label, usable and C.text or C.muted,
                RenderText.ALIGN_CENTER, true)
            if usable then self:addElement(cx, chipY, chipW, chipH, fn) end
        end
        -- a row with options: its value opens a list of them to pick from (a dropdown)
        local usableRow = editable or row.live
        if usableRow and row.options and #row.options > 1 then
            local id = row.label
            local d = self.dropdown
            if d and d.id == id then
                self.dropdownSeen = true
                d.x, d.y, d.w, d.rowH, d.options, d.current, d.select = valueX, cy, valueW, rowH, row.options, row.current, row.select
            end
            row.click = function()
                if self.dropdown and self.dropdown.id == id then
                    self.dropdown = nil
                    return
                end
                local scroll = math.max(0, math.min((row.current or 1) - 3, #row.options - Hud.DROPDOWN_ROWS))
                self.dropdown = {id = id, x = valueX, y = cy, w = valueW, rowH = rowH, options = row.options,
                                 current = row.current, select = row.select, scroll = scroll}
                self.dropdownSeen = true
            end
        end
        local valueHover = (editable or row.live) and row.click and self:isHover(valueX, cy, valueW, rowH)
        -- a value too long for the space between the chips gets a little smaller (not below three quarters)
        local valueSize = textSize
        local room = valueW - self:w(8)
        local tw = Draw.textWidth(textSize, row.value, true)
        if tw > room then
            valueSize = textSize * math.max(0.75, room / tw)
        end
        -- (and still too long: cut short, not over the chips)
        self:textIn(valueX + valueW / 2, cy, rowH, valueSize, fit(row.value, valueSize, room, true),
            valueHover and C.accentHover or C.text, RenderText.ALIGN_CENTER, true)
        if (editable or row.live) and row.click then self:addElement(valueX, cy, valueW, rowH, row.click) end
    end
    return cy
end

--- A switch of options ({value, label}), 'segTotal' wide at the right edge (the whole width without a label).
--- Returns the new top.
function Hud:drawSwitch(x, cy, h, label, options, selectedValue, onSelect, enabled, segTotal)
    local C = Hud.C
    local m = self:metrics()
    cy = cy - h
    if label then
        self:textIn(x + m.pad, cy, h, m.textSize, label, C.muted)
    end
    local segH = self:h(26)
    local segY = cy + (h - segH) / 2
    segTotal = segTotal or (m.width - 2 * m.pad)
    local segX0 = x + m.width - m.pad - segTotal
    local segW = segTotal / #options
    Draw.roundRect(segX0, segY, segTotal, segH, segH / 2, C.chip)
    for k, option in ipairs(options) do
        local sx = segX0 + (k - 1) * segW
        local selected = selectedValue == option[1]
        local hover = enabled and not selected and self:isHover(sx, segY, segW, segH)
        if selected or hover then
            Draw.roundRect(sx + self:w(2), segY + self:h(2), segW - self:w(4), segH - self:h(4), (segH - self:h(4)) / 2,
                selected and C.accent or C.hover)
        end
        self:textIn(sx + segW / 2, segY, segH, m.smallSize, fit(option[2], m.smallSize, segW - self:w(6), selected),
            selected and {1, 1, 1, 1} or C.text, RenderText.ALIGN_CENTER, selected)
        if enabled and not selected then
            self:addElement(sx, segY, segW, segH, function() onSelect(option[1]) end)
        end
    end
    return cy
end

function Hud.startModes()
    return {
        {GuidancePlan.START_CONTINUE, t("guidance_start_continue")},
        {GuidancePlan.START_NEAREST, t("guidance_start_nearest")},
        {GuidancePlan.START_FIRST, t("guidance_start_first")},
    }
end

--- The progress bar through the course and how much of it is done (and how long it still takes), in a row h high
function Hud:drawProgress(m, x, y, h, vehicle, course, doneFraction)
    local C = Hud.C
    local active = vehicle:getIsGuidanceActive()
    local paused = active and vehicle:getIsGuidancePaused()
    local barH = self:h(5)
    local barY = y + (h - barH) / 2
    local label = string.format("%d%%", math.floor(doneFraction * 100 + 0.5))
    if active and doneFraction < 1 then
        local _, left = self:estimateSeconds(vehicle, course)
        label = label .. " · " .. t("guidance_progress_left", formatDuration(left))
    end
    local barW = m.width - 2 * m.pad - Draw.textWidth(m.smallSize, label) - self:w(10)
    Draw.roundRect(x + m.pad, barY, barW, barH, barH / 2, C.track)
    if doneFraction > 0 then
        Draw.roundRect(x + m.pad, barY, math.max(barH, barW * doneFraction), barH, barH / 2, paused and C.warn or C.accent)
    end
    self:textIn(x + m.width - m.pad, y, h, m.smallSize, label, C.muted, RenderText.ALIGN_RIGHT)
end

Hud.MAP_ZOOMS = {1, 2, 4, 8}
Hud.WHEEL_DELAY = 120 -- ms between two zoom steps of the mouse wheel

--- The map closer (step 1) or further out (-1)
function Hud:zoomMap(step)
    local ix = math.max(1, math.min(#Hud.MAP_ZOOMS, (self.mapZoomIx or 1) + step))
    if ix ~= (self.mapZoomIx or 1) then
        self.mapZoomIx = ix
        self.mapCenter = nil
    end
end
Hud.MAP_RECENTER = 0.2 -- zoomed in, the map centres on the vehicle again once it is this part of the view away

--- The course map, with what is done and where the vehicle is; + / - zoom in round the vehicle (it follows it) and
--- out to the whole course (not while the course editor is open)
Hud.UNLOADER_COLORS = {busy = {1.0, 0.72, 0.22, 1}, waiting = {0.62, 0.72, 0.86, 1}}

--- A combine's AutoDrive unloaders for its map (looked for once a second): list of {vehicle, color}; on their way
--- or unloading amber, waiting at the field's marker blue-grey
function Hud:unloadersShown(vehicle)
    local now = g_time or 0
    local c = self.unloadersCache
    if c == nil or c.vehicle ~= vehicle or now - c.time > 1000 then
        local list = {}
        for _, u in ipairs(GuidanceAutoDrive.unloadersOf(vehicle)) do
            list[#list + 1] = {vehicle = u.vehicle, color = u.busy and Hud.UNLOADER_COLORS.busy or Hud.UNLOADER_COLORS.waiting}
        end
        c = {vehicle = vehicle, time = now, list = list}
        self.unloadersCache = c
    end
    return c.list
end

function Hud:drawCoursePlot(vehicle, course, plotX, plotY, plotW, plotH)
    local C = Hud.C
    local zoomIx = self.editing and 1 or (self.mapZoomIx or 1)
    local zoom = Hud.MAP_ZOOMS[zoomIx]
    local center
    if zoom > 1 then
        local vx, _, vz = getWorldTranslation(vehicle.rootNode)
        local c = self.mapCenter
        local span = self.plot and self.plot.span or 100
        if c == nil or c.zoom ~= zoom or (not c.pinned and (vx - c.x) ^ 2 + (vz - c.z) ^ 2 > (span * Hud.MAP_RECENTER) ^ 2) then
            c = {x = vx, z = vz, zoom = zoom}
            self.mapCenter = c
        end
        center = c
    end
    local key = string.format("%.5f%.5f%d%.1f%.1f", plotX, plotY, zoom, center and center.x or 0, center and center.z or 0)
    if self.plot == nil or self.plot.course ~= course or self.plotBox ~= key then
        self.plot = Draw.makePlot(course, plotX, plotY, plotW, plotH, zoom, center)
        self.plotBox = key
    end
    Draw.drawPlot(self.plot, vehicle:getGuidanceProgress(), vehicle, self:h(1.6), self:unloadersShown(vehicle))
    if self.editing then
        return
    end
    -- zoom: + and - at the bottom right
    local bs = self:h(22)
    local bw = bs / g_screenAspectRatio
    local bx, by = plotX + plotW - 2 * bw - self:w(10), plotY + self:h(6)
    self.plotShown = true
    local function zoomTo(ix)
        return function() self:zoomMap(ix - zoomIx) end
    end
    self:button(bx, by, bw, bs, "–", C.chip, C.hover, zoomIx > 1 and C.text or C.muted,
        zoomIx > 1 and zoomTo(zoomIx - 1) or nil, self:h(14))
    self:button(bx + bw + self:w(4), by, bw, bs, "+", C.chip, C.hover, zoomIx < #Hud.MAP_ZOOMS and C.text or C.muted,
        zoomIx < #Hud.MAP_ZOOMS and zoomTo(zoomIx + 1) or nil, self:h(14))
end

--- Minimised: the header, the progress and the course map; the panel key for the rest
function Hud:drawMini()
    local vehicle = self.vehicle
    local C = Hud.C
    local m = self:metrics()
    local course = vehicle:getGuidanceCourse()
    local _, doneFraction = vehicle:getGuidanceProgress()
    local progressH = (course and (vehicle:getIsGuidanceActive() or doneFraction > 0)) and self:h(16) or 0
    local plotH = self:h(Hud.PLOT)
    local hintH = self:h(22)
    local buttonsH = self:h(30)
    local status, statusColor = self:getStatus(vehicle)
    local x, cy = self:drawFrame(m, progressH + plotH + m.padY * 0.5 + buttonsH + hintH, vehicle:getName(), status,
        statusColor)
    if progressH > 0 then
        cy = cy - progressH
        self:drawProgress(m, x, cy, progressH, vehicle, course, doneFraction)
    end
    cy = cy - plotH
    local plotX, plotW = x + m.pad, m.width - 2 * m.pad
    Draw.roundRect(plotX, cy, plotW, plotH, m.smallRadius, C.surface)
    if course then
        self:drawCoursePlot(vehicle, course, plotX, cy, plotW, plotH)
    else
        self:textIn(plotX + plotW / 2, cy, plotH, m.smallSize, t("guidance_mini_noCourse"), C.muted, RenderText.ALIGN_CENTER)
    end
    -- start / pause / stop, as on the whole panel (clicked once Ctrl+J has given the mouse to the panel)
    cy = cy - m.padY * 0.5 - buttonsH
    local gap = self:w(8)
    local half = (plotW - gap) / 2
    local white = {1, 1, 1, 1}
    if vehicle:getIsGuidanceActive() then
        local paused = vehicle:getIsGuidancePaused()
        self:button(plotX, cy, half, buttonsH, paused and t("guidance_btn_resume") or t("guidance_btn_pause"),
            paused and C.accent or C.surface, paused and C.accentHover or C.hover, paused and white or C.text,
            function() vehicle:guidanceSetPaused(not paused) end, m.smallSize)
        self:button(plotX + half + gap, cy, half, buttonsH, t("guidance_btn_stop"), C.danger, C.dangerHover, white,
            function() vehicle:guidanceStop() end, m.smallSize)
    elseif vehicle:getIsHelperDriving() then
        self:button(plotX, cy, plotW, buttonsH, t("guidance_btn_stopHelper"), C.danger, C.dangerHover, white,
            function() vehicle:guidanceStopHelper() end, m.smallSize)
    else
        self:button(plotX, cy, plotW, buttonsH, t("guidance_btn_start"), course and C.accent or C.pill, C.accentHover,
            course and white or C.muted, course and function()
                -- not at the course's field: the whole panel, where it asks (AutoDrive can take it there)
                local atField, distance = vehicle:guidanceAtCourseField()
                if atField then
                    vehicle:guidanceStartStop()
                    return
                end
                local _, markerName = GuidanceVehicle.markerFor(course.plan, course)
                self.offField = {vehicle = vehicle, distance = distance, marker = markerName, time = g_time or 0}
                self.view = "vehicle"
                self:restore()
            end or nil, m.smallSize)
    end
    cy = cy - hintH
    local hint = self.miniMouse and t("guidance_mini_hintBack") or t("guidance_mini_hint")
    self:textIn(x + m.width / 2, cy, hintH, m.smallSize, fit(hint, m.smallSize, m.width - 2 * m.pad), C.muted,
        RenderText.ALIGN_CENTER)
end

function Hud:drawVehicle()
    local vehicle = self.vehicle
    local C = Hud.C
    local m = self:metrics()
    local pad, padY, rowH, width = m.pad, m.padY, m.rowH, m.width
    local textSize, smallSize = m.textSize, m.smallSize
    local course = vehicle:getGuidanceCourse()
    local rows = self:getSettingRows(vehicle)
    local active = vehicle:getIsGuidanceActive()
    local paused = active and vehicle:getIsGuidancePaused()
    local editable = not vehicle:getIsGuidanceActive()
    local details = course and self.showDetails and self:getDetails(vehicle, course) or {}

    local _, doneFraction = vehicle:getGuidanceProgress()
    local progressH = (course and (active or doneFraction > 0)) and self:h(16) or 0
    local plotH = self:h(Hud.PLOT)
    local summaryH = self:h(26)
    local detailRowH = self:h(19)
    local detailsH = #details > 0 and (math.ceil(#details / 2) * detailRowH + self:h(6)) or 0
    local startAtH = self:h(34)
    local moreH = self:h(26)
    local buttonsH = self:h(44)
    local messageH = self.message and self:h(24) or 0
    local offField = course and course.stats.offField or 0
    -- islands inside the headland passes (near the edge) aren't worked round: the passes go over them
    local ignoredIslands = course and course.stats.islandsIgnored or 0
    local offH = offField > 0 and self:h(22) or 0
    local islandH = ignoredIslands > 0 and self:h(22) or 0
    -- a convoy on a field too narrow for it: its passes leave strips unworked (no rows at all, or less worked)
    local convoyGap = 0
    local plan = course and vehicle:getGuidancePlan()
    if plan and plan.teamMode == GuidancePlan.TEAM_CONVOY and (plan.teamSize or 1) > 1 and course.stats.area then
        local worked = (course.stats.workLength or 0) * plan:getCourseWidth() / math.max(1, math.abs(course.stats.area))
        if (course.stats.rows or 0) == 0 or worked < 0.93 then
            convoyGap = math.max(1, math.floor((1 - math.min(1, worked)) * 100 + 0.5))
        end
    end
    local convoyH = convoyGap > 0 and self:h(22) or 0
    local warnH = offH + islandH + convoyH
    -- something that runs out before the end
    local shortages = {}
    if course then
        local seconds = self:estimateSeconds(vehicle, course)
        shortages = GuidancePlanner.shortages(GuidancePlanner.get(vehicle, course, seconds, 1 - doneFraction),
            1 - doneFraction)
    end
    local shortageH = #shortages > 0 and self:h(22) or 0
    -- the saved courses to work next
    local queue = vehicle:getGuidanceQueue()
    local queueH = #queue > 0 and self:h(28) or 0
    -- the course was made with another implement
    local toolWas = course and not active and vehicle.getGuidanceToolChange and vehicle:getGuidanceToolChange()
    local toolH = toolWas and self:h(28) or 0
    -- a baler / loader wagon on a field the rake has a course on: its passes are where the windrows lie
    local rake = not active and GuidanceVehicle ~= nil and GuidanceVehicle.hasPickup(vehicle)
        and GuidanceVehicle.windrowSource(vehicle) or nil
    if rake and vehicle:guidanceFollowsCourseOf(rake) then rake = nil end
    local rakeH = rake and self:h(28) or 0
    warnH = warnH + shortageH + queueH + toolH + rakeH
    -- the job switch (this vehicle could also be an unloader / bale collector / silo compacter)
    local switchH = self:jobSwitchHeight(vehicle)
    -- Start pressed away from the course's field: asked whether AutoDrive should take it there
    local away = self.offField
    if away and (away.vehicle ~= vehicle or active or course == nil or (g_time or 0) - away.time > Hud.OFF_FIELD_ASK
            or vehicle:guidanceAtCourseField()) then
        self.offField, away = nil, nil
    end
    local awayH = away and self:h(42) or 0
    local thenH = (vehicle:getGuidanceSettings().startMode == GuidancePlan.START_FIRST) and startAtH or 0
    local contentH = switchH + progressH + plotH + summaryH + detailsH + warnH + padY * 0.5 + #rows * rowH + moreH + startAtH
        + thenH
        + padY * 0.5 + awayH + buttonsH + messageH

    local status, statusColor = self:getStatus(vehicle)
    local x, cy = self:drawFrame(m, contentH, vehicle:getName(), status, statusColor)
    if switchH > 0 then
        cy = self:drawJobSwitch(x, cy, vehicle, "field")
    end

    -- progress through the course (once there is some)
    if progressH > 0 then
        cy = cy - progressH
        self:drawProgress(m, x, cy, progressH, vehicle, course, doneFraction)
    end

    -- course map (or the outline being recorded)
    cy = cy - plotH
    local plotX, plotW = x + pad, width - 2 * pad
    Draw.roundRect(plotX, cy, plotW, plotH, m.smallRadius, C.surface)
    local recording = self.recording ~= nil and self.recording.vehicle == vehicle
    if recording then
        self:drawRecording(self.recording, plotX, cy + self:h(26), plotW, plotH - self:h(30))
        self:textIn(plotX + plotW / 2, cy + self:h(4), self:h(22), smallSize,
            t("guidance_record_status", self.recording.length), C.accent, RenderText.ALIGN_CENTER, true)
    elseif course and self.confirmClear == vehicle and editable then
        -- clearing the course: asked first, in the map's place (nothing of the map under it shows through)
        local boxW = plotW * 0.86
        setTextWrapWidth(boxW)
        self:textIn(plotX + plotW / 2, cy + plotH * 0.5, plotH * 0.3, textSize, t("guidance_clear_ask"), C.text,
            RenderText.ALIGN_CENTER)
        setTextWrapWidth(0)
        local gap, bh = self:w(8), self:h(30)
        local bw = (boxW - gap) / 2
        local bx, by = plotX + (plotW - boxW) / 2, cy + plotH * 0.5 - bh - self:h(12)
        self:button(bx, by, bw, bh, t("guidance_btn_clearCourse"), C.danger, C.dangerHover, {1, 1, 1, 1}, function()
            self.confirmClear = nil
            vehicle:guidanceSetPlan(nil)
            self:showMessage(t("guidance_course_cleared"), false)
        end, smallSize)
        self:button(bx + bw + gap, by, bw, bh, t("guidance_away_cancel"), C.chip, C.hover, C.text,
            function() self.confirmClear = nil end, smallSize)
    elseif course then
        self:drawCoursePlot(vehicle, course, plotX, cy, plotW, plotH)
        -- the course editor: its own drawing on the map and what a click / drag there does
        if self.editing then
            self:drawEditor(vehicle, self.plot)
        end
        -- edit (when it can be changed) / done
        if editable then
            local label = self.editing and t("guidance_edit_done") or t("guidance_edit")
            local bw, bh = Draw.textWidth(smallSize, label, true) + self:w(18), self:h(22)
            self:button(plotX + plotW - bw - self:w(6), cy + plotH - bh - self:h(6), bw, bh, label,
                self.editing and C.accent or C.chip, self.editing and C.accentHover or C.hover,
                self.editing and {1, 1, 1, 1} or C.text, function()
                    self.editing = not self.editing
                    self.editTool = self.editTool or "direction"
                end, smallSize)
        end
        -- clear the course off the tractor (asked first, see above)
        if editable and not self.editing then
            local label = t("guidance_btn_clearCourse")
            local bw, bh = Draw.textWidth(smallSize, label, true) + self:w(18), self:h(22)
            self:button(plotX + self:w(6), cy + plotH - bh - self:h(6), bw, bh, label, C.chip, C.hover, C.text,
                function() self.confirmClear = vehicle end, smallSize)
        end
    else
        -- the hint names the button as it is labelled right now; saved courses for this field are offered
        local hint = vehicle:getGuidanceError() or t("guidance_hint_noCourse", t("guidance_btn_makeCourse"))
        local fieldId = self:getFieldHere(vehicle)
        local saved = fieldId and GuidanceLibrary.countForField(vehicle:getOwnerFarmId(), fieldId) or 0
        setTextWrapWidth(plotW - 2 * pad)
        self:textIn(plotX + plotW / 2, cy + (saved > 0 and plotH * 0.12 or 0), plotH, textSize, hint, C.muted,
            RenderText.ALIGN_CENTER)
        setTextWrapWidth(0)
        if saved > 0 then
            local bw, bh = plotW * 0.7, self:h(30)
            self:button(plotX + (plotW - bw) / 2, cy + plotH * 0.22, bw, bh, t("guidance_offer_saved", saved), C.accent,
                C.accentHover, {1, 1, 1, 1}, function() self.view = "library" end, smallSize)
        end
        local contracts = #GuidanceContracts.running(vehicle:getOwnerFarmId())
        if contracts > 0 then
            local bw, bh = plotW * 0.7, self:h(30)
            self:button(plotX + (plotW - bw) / 2, cy + plotH * 0.06, bw, bh, t("guidance_contracts_open", contracts),
                C.chip, C.hover, C.text, function() self.view = "contracts" end, smallSize)
        end
    end

    -- summary (a click shows the details), and a warning if the headland is too narrow to turn on the field
    cy = cy - summaryH
    if course then
        local summary = self:getSummary(vehicle, course)
        local hint = self.showDetails and " -" or " +"
        local hover = self:isHover(x + pad, cy, width - 2 * pad, summaryH)
        self:textIn(x + pad, cy, summaryH, smallSize, fit(summary, smallSize, width - 2 * pad - self:w(16)),
            hover and C.text or C.muted)
        self:textIn(x + width - pad, cy, summaryH, smallSize, hint, C.accent, RenderText.ALIGN_RIGHT, true)
        self:addElement(x + pad, cy, width - 2 * pad, summaryH, function() self.showDetails = not self.showDetails end)
    end
    if detailsH > 0 then
        cy = cy - detailsH
        Draw.roundRect(x + pad, cy, width - 2 * pad, detailsH, m.smallRadius, C.surface)
        local colW = (width - 2 * pad) / 2
        for k, d in ipairs(details) do
            local col, line = (k - 1) % 2, math.floor((k - 1) / 2)
            local dx = x + pad + col * colW + self:w(10)
            local dy = cy + detailsH - self:h(3) - (line + 1) * detailRowH
            self:textIn(dx, dy, detailRowH, smallSize, d[1], C.muted)
            self:textIn(dx + colW - self:w(20), dy, detailRowH, smallSize, d[2], C.text, RenderText.ALIGN_RIGHT, true)
        end
    end
    if toolH > 0 then
        cy = cy - toolH
        local againW = Draw.textWidth(smallSize, t("guidance_implAgain"), true) + self:w(16)
        self:textIn(x + pad, cy, toolH, smallSize,
            fit(t("guidance_implChanged", toolWas), smallSize, width - 2 * pad - againW - self:w(8)), C.warn)
        self:button(x + width - pad - againW, cy + self:h(3), againW, toolH - self:h(6), t("guidance_implAgain"),
            C.chip, C.hover, C.text, function()
                local ok, err, info = vehicle:guidanceGenerate()
                if not ok then self:showMessage(err or t("guidance_err_generic"), true)
                elseif info then self:showMessage(info, false) end
            end, smallSize)
        warnH = warnH - toolH
    end
    if rakeH > 0 then
        cy = cy - rakeH
        local followW = Draw.textWidth(smallSize, t("guidance_windrows_follow"), true) + self:w(16)
        self:textIn(x + pad, cy, rakeH, smallSize,
            fit(t("guidance_windrows_of", rake:getName()), smallSize, width - 2 * pad - followW - self:w(8)), C.text)
        self:button(x + width - pad - followW, cy + self:h(3), followW, rakeH - self:h(6), t("guidance_windrows_follow"),
            C.accent, C.hover, C.text, function()
                local ok, err = vehicle:guidanceFollowCourseOf(rake)
                if not ok then self:showMessage(err or t("guidance_err_generic"), true) end
            end, smallSize)
        warnH = warnH - rakeH
    end
    if queueH > 0 then
        cy = cy - queueH
        local entry = GuidanceLibrary.getEntry(queue[1])
        local text = t("guidance_queue_next", entry and entry.name or "?")
        if #queue > 1 then text = text .. " " .. t("guidance_queue_more", #queue - 1) end
        local manageW = Draw.textWidth(smallSize, t("guidance_queue_manage"), true) + self:w(16)
        self:textIn(x + pad, cy, queueH, smallSize, fit(text, smallSize, width - 2 * pad - manageW - self:w(8)), C.text)
        self:button(x + width - pad - manageW, cy + self:h(3), manageW, queueH - self:h(6), t("guidance_queue_manage"),
            C.chip, C.hover, C.text, function() self.view, self.queuePage = "queue", 1 end, smallSize)
        warnH = warnH - queueH
    end
    if shortageH > 0 then
        cy = cy - shortageH
        -- all that run out, the first first: "Seed runs out at about 85% · Fertilizer at 60%"
        local parts = {}
        for k, sh in ipairs(shortages) do
            local name = sh.item.label or t("guidance_plan_" .. sh.item.kind)
            local pct = math.floor(sh.at * 100 + 0.5)
            parts[k] = k == 1 and t("guidance_plan_runsOut", name, pct) or t("guidance_plan_runsOutToo", name, pct)
        end
        self:textIn(x + pad, cy, shortageH, smallSize, fit(table.concat(parts, " · "), smallSize, width - 2 * pad), C.warn)
        warnH = warnH - shortageH
    end
    if offH > 0 then
        cy = cy - offH
        self:textIn(x + pad, cy, offH, smallSize, offField == 1 and t("guidance_warn_offField1")
            or t("guidance_warn_offField", offField), C.warn)
    end
    if convoyH > 0 then
        cy = cy - convoyH
        self:textIn(x + pad, cy, convoyH, smallSize, fit(t("guidance_warn_convoyNarrow", plan.teamSize, convoyGap),
            smallSize, width - 2 * pad), C.warn)
    end
    if islandH > 0 then
        cy = cy - islandH
        self:textIn(x + pad, cy, islandH, smallSize, fit(t("guidance_warn_islandsIgnored", ignoredIslands), smallSize,
            width - 2 * pad), C.warn)
    end

    -- settings: label, - value +
    cy = self:drawSettingRows(x, cy - padY * 0.5, rows, editable)

    -- more / fewer settings
    cy = cy - moreH
    local moreText = self.showMore and t("guidance_lessSettings") or t("guidance_moreSettings")
    local moreW = Draw.textWidth(smallSize, moreText) + self:w(12)
    local moreHover = self:isHover(x + pad, cy, moreW, moreH)
    self:textIn(x + pad, cy, moreH, smallSize, moreText, moreHover and C.text or C.accent)
    self:addElement(x + pad, cy, moreW, moreH, function() self.showMore = not self.showMore end)
    -- record a field of your own (a meadow, an odd corner, part of a field) by driving round it
    if editable and not recording then
        local recText = t("guidance_record_start")
        local recW = Draw.textWidth(smallSize, recText) + self:w(12)
        local recX = x + width - pad - recW
        local recHover = self:isHover(recX, cy, recW, moreH)
        self:textIn(x + width - pad, cy, moreH, smallSize, recText, recHover and C.text or C.accent, RenderText.ALIGN_RIGHT)
        self:addElement(recX, cy, recW, moreH, function() self:startRecording(vehicle) end)
    end

    -- start at: continue / nearest / first, as one switch
    local s = vehicle:getGuidanceSettings()
    cy = self:drawSwitch(x, cy, startAtH, t("guidance_set_startAt"), Hud.startModes(),
        s.startMode or GuidancePlan.START_CONTINUE,
        function(mode) vehicle:guidanceChangeSetting("startMode", mode) end, true, self:w(210))
    -- First: where later starts of this course begin
    if thenH > 0 then
        cy = self:drawSwitch(x, cy, thenH, t("guidance_set_startAfter"), Hud.startModes(),
            s.startAfter or GuidancePlan.START_FIRST,
            function(mode) vehicle:guidanceChangeSetting("startAfter", mode) end, true, self:w(210))
    end

    -- the question (Start away from the field): what it is, then the buttons below answer it
    if awayH > 0 then
        cy = cy - padY * 0.5 - awayH
        local fieldName = GuidanceLibrary.fieldName(course.plan.fieldId)
        local text = away.marker and t("guidance_away_go", fieldName, formatDistance(away.distance), away.marker)
            or t("guidance_away_noMarker", fieldName, formatDistance(away.distance))
        self:textLines(x + pad, cy, awayH, smallSize, text, width - 2 * pad, C.warn)
        cy = cy + padY * 0.5
    end
    -- buttons: new course + start, or pause/resume + stop while working
    cy = cy - padY * 0.5 - buttonsH
    local gap = self:w(10)
    local half = (width - 2 * pad - gap) / 2
    local leftX, rightX = x + pad, x + pad + half + gap
    local white = {1, 1, 1, 1}
    if recording then
        self:button(leftX, cy, half, buttonsH, t("guidance_record_cancel"), C.surface, C.hover, C.text,
            function() self.recording = nil end)
        local enough = self.recording.length >= Hud.RECORD_MIN_LENGTH
        self:button(rightX, cy, half, buttonsH, t("guidance_record_finish"), enough and C.accent or C.pill, C.accentHover,
            enough and white or C.muted, enough and function() self:finishRecording() end or nil)
    elseif away then
        -- go there with AutoDrive (or start here anyway), or not
        self:button(leftX, cy, half, buttonsH, t("guidance_away_cancel"), C.surface, C.hover, C.text,
            function() self.offField = nil end)
        if away.marker then
            self:button(rightX, cy, half, buttonsH, t("guidance_away_goBtn"), C.accent, C.accentHover, white, function()
                self.offField = nil
                vehicle:guidanceGoTo(0)
                self:showMessage(t("guidance_go_sent", GuidanceLibrary.fieldName(course.plan.fieldId)), false)
            end)
        else
            self:button(rightX, cy, half, buttonsH, t("guidance_away_startAnyway"), C.accent, C.accentHover, white,
                function()
                    self.offField = nil
                    vehicle:guidanceStartStop()
                end)
        end
    elseif active then
        if paused then
            self:button(leftX, cy, half, buttonsH, t("guidance_btn_resume"), C.accent, C.accentHover, white,
                function() vehicle:guidanceSetPaused(false) end)
        else
            self:button(leftX, cy, half, buttonsH, t("guidance_btn_pause"), C.surface, C.hover, C.text,
                function() vehicle:guidanceSetPaused(true) end)
        end
        self:button(rightX, cy, half, buttonsH, t("guidance_btn_stop"), C.danger, C.dangerHover, white,
            function() vehicle:guidanceStartStop() end)
    else
        self:button(leftX, cy, half, buttonsH, course and t("guidance_btn_newCourse") or t("guidance_btn_makeCourse"),
            C.surface, C.hover, editable and C.text or C.muted, editable and function()
                local ok, err, info = vehicle:guidanceGenerate()
                if not ok then
                    self:showMessage(err or t("guidance_err_generic"), true)
                elseif info then
                    self:showMessage(info, false)
                end
            end or nil)
        if vehicle:getIsHelperDriving() then
            -- another helper has the vehicle (the game's own, started with its hire key): it can be stopped here
            self:button(rightX, cy, half, buttonsH, t("guidance_btn_stopHelper"), C.danger, C.dangerHover, white,
                function() vehicle:guidanceStopHelper() end)
        else
            local canStart = course ~= nil
            self:button(rightX, cy, half, buttonsH, t("guidance_btn_start"), canStart and C.accent or C.pill,
                C.accentHover, canStart and white or C.muted, canStart and function()
                    -- not at the course's field: ask first (AutoDrive can take it there)
                    local atField, distance = vehicle:guidanceAtCourseField()
                    if atField then
                        vehicle:guidanceStartStop()
                        return
                    end
                    local _, markerName = GuidanceVehicle.markerFor(course.plan, course)
                    self.offField = {vehicle = vehicle, distance = distance, marker = markerName, time = g_time or 0}
                end or nil)
        end
    end

    -- message
    if self.message then
        cy = cy - messageH
        self:textIn(x + pad, cy, messageH, smallSize, self.message, self.messageIsError and C.danger or C.muted)
    end
end

-----------------------------------------------------------------------------------------------------------------------
-- Helpers without a course: unloader, bale collector, silo compacter (the Course tab shows them when the vehicle is
-- one; a switch on top picks the job when it could be more than one)
-----------------------------------------------------------------------------------------------------------------------

--- The helper jobs the vehicle could do (looked at once a second): list of kinds
function Hud:helperKinds(vehicle)
    self.helperKindCache = self.helperKindCache or {}
    local c = self.helperKindCache[vehicle]
    local now = g_time or 0
    if c == nil or now - c.time > 1000 then
        local ok, kinds = Guidance.try(vehicle.getGuidanceHelperKinds, vehicle)
        local info = GuidanceVehicleInfo and GuidanceVehicleInfo.get(vehicle)
        c = {time = now, kinds = ok and kinds or {}, fieldWork = info == nil or info.hasImplement}
        self.helperKindCache[vehicle] = c
    end
    return c.kinds, c.fieldWork
end

--- The helper job the Course tab shows for the vehicle, or nil for its field work
function Hud:helperKindFor(vehicle)
    if vehicle.getGuidanceHelperKind == nil then return nil end
    local running = vehicle:getGuidanceHelperKind()
    if running then return running end
    if vehicle:getIsGuidanceActive() then return nil end
    local kinds, fieldWork = self:helperKinds(vehicle)
    if #kinds == 0 then return nil end
    self.helperChoice = self.helperChoice or {}
    local choice = self.helperChoice[vehicle]
    if choice == "field" then return nil end
    for _, k in ipairs(kinds) do
        if k == choice then return k end
    end
    -- by itself: the job it is made for (no field work implement: a helper)
    if fieldWork and vehicle:getGuidanceCourse() ~= nil then return nil end
    if fieldWork then return nil end
    return kinds[1]
end

--- The job switch (field work, unloader, bales, silo), when there is more than one: its height
function Hud:jobSwitchHeight(vehicle)
    if vehicle:getIsGuidanceActive() then return 0 end
    local kinds = self:helperKinds(vehicle)
    return #kinds > 0 and self:h(34) or 0
end

function Hud:drawJobSwitch(x, cy, vehicle, current)
    local kinds = self:helperKinds(vehicle)
    local options = {{"field", t("guidance_job_field")}}
    for _, k in ipairs(kinds) do table.insert(options, {k, t("guidance_helper_" .. k)}) end
    return self:drawSwitch(x, cy, self:h(34), nil, options, current or "field", function(value)
        self.helperChoice = self.helperChoice or {}
        self.helperChoice[vehicle] = value
    end, true)
end

--- The unloader's rows: AutoDrive's own settings of the truck and of the combine it serves, read from AutoDrive every
--- frame and changed through the server (AutoDrive's menu shows the same)
function Hud:unloaderRows(vehicle)
    local AD = GuidanceAutoDrive
    local rows = {}
    local sm = vehicle.ad.stateModule
    -- the combine it serves (the truck and it get the marker of its field as first target)
    local combines = AD.combines(vehicle:getOwnerFarmId())
    local served = AD.combineOf(vehicle)
    local labels, cur = {}, nil
    for i, c in ipairs(combines) do
        labels[i] = Guidance.vehicleName(c.vehicle)
        if c.number then labels[i] = labels[i] .. " · " .. t("guidance_unloadCombine_field", c.number) end
        if c.vehicle == served then cur = i end
    end
    local function pickCombine(i)
        local c = combines[i]
        if c then AD.ask(vehicle, AD.OP_COMBINE, c.vehicle) end
    end
    rows[#rows + 1] = {label = t("guidance_set_unloadCombine"), value = cur and labels[cur] or t("guidance_unloadCombine_none"),
                       dec = function() if #combines > 0 then pickCombine(((cur or 1) - 2) % #combines + 1) end end,
                       inc = function() if #combines > 0 then pickCombine((cur or 0) % #combines + 1) end end,
                       options = labels, current = cur, select = pickCombine}
    -- where it unloads: an AutoDrive marker (its second target)
    local markers = GuidanceVehicle.autoDriveMarkers() or {}
    local target = sm:getSecondMarkerId()
    local names, at = {}, nil
    for i, m in ipairs(markers) do
        names[i] = m.name
        if m.id == target then at = i end
    end
    local function pickMarker(i)
        if markers[i] then AD.ask(vehicle, AD.OP_UNLOAD_AT, nil, "", markers[i].id) end
    end
    rows[#rows + 1] = {label = t("guidance_set_unloadAt"), value = at and names[at] or t("guidance_unloadAD_pick"),
                       dec = function() if #markers > 0 then pickMarker(((at or 1) - 2) % #markers + 1) end end,
                       inc = function() if #markers > 0 then pickMarker((at or 0) % #markers + 1) end end,
                       options = names, current = at, select = pickMarker}
    -- AutoDrive's settings, one row each: of the truck, or of the combine it serves
    local function settingRow(label, name, owner, format)
        if owner == nil then return end
        local values, ix = AD.setting(name, owner)
        if values == nil then return end
        local function to(i)
            if values[i] ~= nil then AD.ask(vehicle, AD.OP_SETTING, owner, name, i) end
        end
        local options = {}
        for i, v in ipairs(values) do options[i] = format(v) end
        rows[#rows + 1] = {label = t(label), value = options[ix] or "?",
                           dec = function() to(math.max(1, ix - 1)) end, inc = function() to(math.min(#values, ix + 1)) end,
                           options = options, current = ix, select = to}
    end
    local function percent(v) return string.format("%d%%", math.floor(v * 100 + 0.5)) end
    local function metres(v) return (string.format("%+.2f m", v):gsub("^%+0%.00", "0.00")) end
    local function onOff(v) return v and t("guidance_on") or t("guidance_off") end
    local ad = AD.get()
    local sides = {[ad.CHASEPOS_AUTO or 0] = t("guidance_pipeSide_auto"), [ad.CHASEPOS_LEFT or 1] = t("guidance_pipeSide_left"),
                   [ad.CHASEPOS_REAR or 2] = t("guidance_pipeSide_rear"), [ad.CHASEPOS_RIGHT or 3] = t("guidance_pipeSide_right")}
    settingRow("guidance_set_unloadFull", "unloadFillLevel", vehicle, percent)
    settingRow("guidance_set_avoidCrop", "avoidFruit", vehicle,
        function(v) return v and t("guidance_avoidCrop_on") or t("guidance_avoidCrop_off") end)
    settingRow("guidance_set_pipeSide", "chaseSide", served, function(v) return sides[v] or tostring(v) end)
    settingRow("guidance_set_unloadSide", "pipeOffset", vehicle, metres)
    -- (AutoDrive Overdrive since od.60: forward + / back - along the combine; not there before, no row)
    settingRow("guidance_set_unloadAlong", "pipeZOffset", vehicle, metres)
    settingRow("guidance_set_followDistance", "followDistance", vehicle, function(v) return string.format("%.2f m", v) end)
    settingRow("guidance_set_secondUnloader", "callSecondUnloader", served, onOff)
    -- ours: driving when the server restarted, it starts again after loading (AutoDrive doesn't on a server)
    local carryOn = vehicle:getGuidanceSettings().autoResume ~= false
    local resumeTexts = {t("guidance_resume_carryOn"), t("guidance_resume_wait")}
    local function setResume(on) vehicle:guidanceChangeSetting("autoResume", on) end
    rows[#rows + 1] = {label = t("guidance_set_autoResume"), value = resumeTexts[carryOn and 1 or 2],
                       dec = function() setResume(not carryOn) end, inc = function() setResume(not carryOn) end,
                       options = resumeTexts, current = carryOn and 1 or 2, select = function(i) setResume(i == 1) end}
    return rows
end

function Hud:drawHelper(kind)
    local vehicle = self.vehicle
    local C = Hud.C
    local m = self:metrics()
    local pad, padY, rowH, width = m.pad, m.padY, m.rowH, m.width
    local smallSize = m.smallSize
    -- (the unloader: AutoDrive drives it)
    local adUnloader = kind == "unload" and GuidanceAutoDrive.isUnloading(vehicle)
    local running = vehicle:getGuidanceHelperKind() ~= nil or adUnloader

    -- settings
    local rows = {}
    if kind == "unload" then
        rows = self:unloaderRows(vehicle)
    end

    local switchH = self:jobSwitchHeight(vehicle)
    local about = t("guidance_helperAbout_" .. kind)
    local aboutLines = math.min(6, self:countLines(about, smallSize, width - 2 * pad))
    local aboutH = self:h(17) * aboutLines + self:h(8)
    local phaseH = self:h(26)
    local buttonsH = self:h(44)
    local messageH = self.message and self:h(24) or 0
    local contentH = switchH + aboutH + phaseH + #rows * rowH + padY + buttonsH + messageH

    local status, statusColor = self:getStatus(vehicle)
    local x, cy = self:drawFrame(m, contentH, vehicle:getName(), status, statusColor)
    if switchH > 0 then
        cy = self:drawJobSwitch(x, cy, vehicle, kind)
    end
    -- what it does
    cy = cy - aboutH
    self:textLines(x + pad, cy + self:h(4), aboutH - self:h(8), smallSize, about, width - 2 * pad, C.muted, aboutLines)
    -- what it is doing now
    cy = cy - phaseH
    local phase = vehicle:getGuidanceHelperPhase()
    -- (after the job: why the wrapper left bales)
    local phaseText = (adUnloader and t("guidance_phase_adUnload"))
        or ((running or (GuidanceVehicle ~= nil and GuidanceVehicle.END_PHASES[phase or ""])) and phase and t("guidance_phase_" .. phase))
        or t("guidance_helperReady_" .. kind)
    self:textIn(x + pad, cy, phaseH, m.textSize, fit(phaseText, m.textSize, width - 2 * pad, true),
        running and C.accent or C.text, nil, true)
    if #rows > 0 then
        -- (the unloader's: changed while it works too, it takes them at once)
        cy = self:drawSettingRows(x, cy, rows, not running or kind == "unload")
    end
    -- buttons
    cy = cy - padY - buttonsH
    local gap = self:w(10)
    local half = (width - 2 * pad - gap) / 2
    local white = {1, 1, 1, 1}
    if adUnloader then
        self:button(x + pad, cy, width - 2 * pad, buttonsH, t("guidance_btn_stop"), C.danger, C.dangerHover, white,
            function() GuidanceAutoDrive.ask(vehicle, GuidanceAutoDrive.OP_STOP) end)
    elseif running then
        local paused = vehicle:getIsGuidancePaused()
        self:button(x + pad, cy, half, buttonsH, paused and t("guidance_btn_resume") or t("guidance_btn_pause"),
            paused and C.accent or C.surface, paused and C.accentHover or C.hover, paused and white or C.text,
            function() vehicle:guidanceSetPaused(not paused) end)
        self:button(x + pad + half + gap, cy, half, buttonsH, t("guidance_btn_stop"), C.danger, C.dangerHover, white,
            function() vehicle:guidanceStop() end)
    elseif vehicle:getIsHelperDriving() then
        self:button(x + pad, cy, width - 2 * pad, buttonsH, t("guidance_btn_stopHelper"), C.danger, C.dangerHover, white,
            function() vehicle:guidanceStopHelper() end)
    else
        self:button(x + pad, cy, width - 2 * pad, buttonsH, t("guidance_btn_start"), C.accent, C.accentHover, white,
            function()
                -- the unloader: AutoDrive's, once it knows the combine and where to unload (it drives to the combine's
                -- field by itself)
                if kind == "unload" then
                    local sm = vehicle.ad.stateModule
                    if GuidanceAutoDrive.combineOf(vehicle) == nil then
                        self:showMessage(t("guidance_unloadAD_noCombine"), true)
                    elseif sm:getSecondMarker() == nil then
                        self:showMessage(t("guidance_unloadAD_noTarget"), true)
                    else
                        GuidanceAutoDrive.ask(vehicle, GuidanceAutoDrive.OP_START)
                    end
                    return
                end
                local ok, err = vehicle:guidanceStartHelper(kind)
                if not ok and err then self:showMessage(err, true) end
            end)
    end
    if self.message then
        cy = cy - messageH
        self:textIn(x + pad, cy, messageH, smallSize, self.message, self.messageIsError and C.danger or C.muted)
    end
end

-----------------------------------------------------------------------------------------------------------------------
-- Saved courses: save this one, load, rename or delete the farm's saved ones (this field's first)
-----------------------------------------------------------------------------------------------------------------------

Hud.LIBRARY_PAGE = 6

function Hud:saveCourse(vehicle)
    local course, plan = vehicle:getGuidanceCourse(), vehicle:getGuidancePlan()
    if course == nil or plan == nil then
        return
    end
    local name = t("guidance_saved_name", GuidanceLibrary.fieldName(plan.fieldId), plan.workWidth)
    GuidanceLibrary.add(GuidanceLibrary.newEntry(name, vehicle:getOwnerFarmId(), plan, course))
    self:showMessage(t("guidance_saved_done", name), false)
end

function Hud:renameCourse(entry)
    if TextInputDialog == nil or TextInputDialog.show == nil then
        return
    end
    Guidance.try(TextInputDialog.show, function(_, text, clickOk)
        if clickOk and text ~= nil and text ~= "" then
            GuidanceLibrary.rename(entry.id, text)
        end
    end, self, entry.name, t("guidance_saved_renamePrompt"), nil, 40, g_i18n:getText("button_ok"))
end

function Hud:drawLibrary()
    local vehicle = self.vehicle
    local C = Hud.C
    local m = self:metrics()
    local pad, padY, width = m.pad, m.padY, m.width
    local farmId = vehicle:getOwnerFarmId()
    local fieldHere = self:getFieldHere(vehicle)
    local all = GuidanceLibrary.getForFarm(farmId, fieldHere)

    -- a folder for every field: opening the tab on a field with saved courses opens its folder
    if self.libraryFolder == nil and not self.libraryFolderChosen and fieldHere
            and GuidanceLibrary.countForField(farmId, fieldHere) > 0 then
        self.libraryFolder = fieldHere
    end
    local folder = self.libraryFolder
    local items = {}
    if folder == nil then
        local byField = {}
        for _, e in ipairs(all) do
            local f = byField[e.plan.fieldId]
            if f == nil then
                f = {fieldId = e.plan.fieldId, count = 0, area = e.area}
                byField[e.plan.fieldId] = f
                table.insert(items, f)
            end
            f.count = f.count + 1
        end
        for _, f in ipairs(GuidanceLibrary.getFieldsForFarm(farmId)) do
            if byField[f.id] == nil then
                byField[f.id] = {fieldId = f.id, count = 0, area = 0}
                table.insert(items, byField[f.id])
            end
        end
        table.sort(items, function(a, b)
            if (a.fieldId == fieldHere) ~= (b.fieldId == fieldHere) then return a.fieldId == fieldHere end
            -- the map's fields by number, then the recorded ones
            if (a.fieldId < 0) ~= (b.fieldId < 0) then return a.fieldId > 0 end
            return math.abs(a.fieldId) < math.abs(b.fieldId)
        end)
    else
        for _, e in ipairs(all) do
            if e.plan.fieldId == folder then table.insert(items, e) end
        end
        if #items == 0 and (folder > 0 or GuidanceLibrary.getField(folder) == nil) then
            self.libraryFolder, folder = nil, nil
            self.libraryFolderChosen = true
            return self:drawLibrary()
        end
    end

    local pages = math.max(1, math.ceil(#items / Hud.LIBRARY_PAGE))
    self.libraryPage = math.max(1, math.min(pages, self.libraryPage or 1))
    local first = (self.libraryPage - 1) * Hud.LIBRARY_PAGE + 1
    local shown = math.max(1, math.min(Hud.LIBRARY_PAGE, #items - first + 1))

    local saveH, rowH = self:h(44), self.libraryFolder and self:h(82) or self:h(56)
    -- in a folder: back (and delete a recorded field); all fields: import a course file
    local folderH = self:h(34)
    local pagerH = pages > 1 and self:h(32) or 0
    local messageH = self.message and self:h(24) or 0
    local contentH = saveH + padY * 0.5 + folderH + shown * rowH + pagerH + messageH
    local subtitle = folder and GuidanceLibrary.fieldName(folder) or t("guidance_saved_subtitle", #all)
    local x, cy = self:drawFrame(m, contentH, subtitle)

    -- save the vehicle's course (into its field's folder)
    cy = cy - saveH
    local canSave = vehicle:getGuidanceCourse() ~= nil
    self:button(x + pad, cy, width - 2 * pad, saveH, canSave and t("guidance_saved_save") or t("guidance_saved_nothing"),
        canSave and C.accent or C.pill, C.accentHover, canSave and {1, 1, 1, 1} or C.muted,
        canSave and function() self:saveCourse(vehicle) end or nil)
    cy = cy - padY * 0.5

    if folder == nil then
        cy = cy - folderH
        local bw, bh = self:w(150), self:h(26)
        self:button(x + pad, cy + (folderH - bh) / 2, bw, bh, t("guidance_saved_import"), C.chip, C.hover, C.text,
            function()
                self.view, self.importFiles, self.importPage = "import", Hud.importList(), 1
            end, m.smallSize)
        local qLabel = t("guidance_queue_open", #vehicle:getGuidanceQueue())
        local qw = Draw.textWidth(m.smallSize, qLabel, true) + self:w(16)
        self:button(x + width - pad - qw, cy + (folderH - bh) / 2, qw, bh, qLabel, C.chip, C.hover, C.text,
            function() self.view, self.queuePage = "queue", 1 end, m.smallSize)
        -- the farm's contracts: a course for one in one go
        local contracts = #GuidanceContracts.running(vehicle:getOwnerFarmId())
        if contracts > 0 then
            local cLabel = t("guidance_contracts_open", contracts)
            local cw = Draw.textWidth(m.smallSize, cLabel, true) + self:w(16)
            local left, right = x + pad + bw, x + width - pad - qw
            self:button(left + (right - left - cw) / 2, cy + (folderH - bh) / 2, cw, bh, cLabel, C.chip, C.hover, C.text,
                function() self.view = "contracts" end, m.smallSize)
        end
    end
    -- in a folder: back to all fields
    if folder then
        cy = cy - folderH
        local bw, bh = self:w(110), self:h(26)
        self:button(x + pad, cy + (folderH - bh) / 2, bw, bh, "< " .. t("guidance_folder_back"), C.chip, C.hover, C.text,
            function()
                self.libraryFolder, self.libraryFolderChosen, self.libraryPage = nil, true, 1
            end, m.smallSize)
        if folder < 0 then
            -- a recorded field can go (with its courses)
            local now = g_time or 0
            local confirming = self.confirmDeleteField == folder and now - (self.confirmTime or 0) < 4000
            local dw = self:w(110)
            self:button(x + width - pad - dw, cy + (folderH - bh) / 2, dw, bh,
                confirming and t("guidance_saved_sure") or t("guidance_record_delete"), confirming and C.danger or C.chip,
                C.dangerHover, C.text, function()
                    if confirming then
                        GuidanceLibrary.deleteField(folder)
                        self.confirmDeleteField, self.libraryFolder, self.libraryFolderChosen = nil, nil, true
                    else
                        self.confirmDeleteField, self.confirmTime = folder, now
                    end
                end, m.smallSize)
        else
            self:textIn(x + width - pad, cy, folderH, m.smallSize, t("guidance_folder_count", #items), C.muted,
                RenderText.ALIGN_RIGHT)
        end
    end

    if #items == 0 then
        cy = cy - rowH
        self:textIn(x + pad, cy, rowH, m.textSize, t("guidance_saved_empty"), C.muted)
    end
    local now = g_time or 0
    local buttonH = self:h(26)
    local editable = not vehicle:getIsGuidanceActive()
    for k = first, math.min(#items, first + Hud.LIBRARY_PAGE - 1) do
        local item = items[k]
        cy = cy - rowH
        if k > first then Draw.rect(x + pad, cy + rowH, width - 2 * pad, self:h(1), C.line) end
        local buttons
        if folder == nil then
            buttons = {{t("guidance_folder_open"), C.chip, C.hover, function()
                self.libraryFolder, self.libraryPage = item.fieldId, 1
            end}}
        else
            local confirming = self.confirmDelete == item.id and now - (self.confirmTime or 0) < 4000
            buttons = {
                {t("guidance_saved_load"), C.accent, C.accentHover, editable and function()
                    vehicle:guidanceSetPlan(item.plan:copy())
                    self.view = "vehicle"
                    self:showMessage(t("guidance_saved_loaded", item.name), false)
                end or nil},
                {t("guidance_saved_go"), C.chip, C.hover, function()
                    vehicle:guidanceGoTo(item.id)
                    self.view = "vehicle"
                    self:showMessage(t("guidance_go_sent", item.name), false)
                end},
                {t("guidance_saved_queue"), C.chip, C.hover, function()
                    local queue = {}
                    for _, id in ipairs(vehicle:getGuidanceQueue()) do table.insert(queue, id) end
                    table.insert(queue, item.id)
                    vehicle:guidanceSetQueue(queue)
                    self:showMessage(t("guidance_queue_added", item.name, #queue), false)
                end},
                {t("guidance_saved_rename"), C.chip, C.hover, function() self:renameCourse(item) end},
                {t("guidance_saved_export"), C.chip, C.hover, function()
                    local name = GuidanceLibrary.exportCourse(item)
                    if name then
                        self:showMessage(t("guidance_saved_exported", name), false)
                    else
                        self:showMessage(t("guidance_err_generic"), true)
                    end
                end},
                {confirming and t("guidance_saved_sure") or t("guidance_saved_delete"), confirming and C.danger or C.chip,
                    C.dangerHover, function()
                        if confirming then
                            GuidanceLibrary.delete(item.id)
                            self.confirmDelete = nil
                        else
                            self.confirmDelete, self.confirmTime = item.id, now
                        end
                    end},
            }
        end
        local textW
        if folder == nil then
            -- a folder: its button on the right
            local bw = self:w(58)
            local bx = x + width - pad - bw
            local btn = buttons[1]
            self:button(bx, cy + (rowH - buttonH) / 2, bw, buttonH, btn[1], btn[2], btn[3], C.text, btn[4], m.smallSize)
            textW = bx - (x + pad) - self:w(6)
        else
            -- a course: name and numbers over the whole width, its buttons below
            local gap = self:w(5)
            local bw = (width - 2 * pad - gap * (#buttons - 1)) / #buttons
            for b, btn in ipairs(buttons) do
                self:button(x + pad + (b - 1) * (bw + gap), cy + self:h(6), bw, buttonH, btn[1], btn[2], btn[3],
                    btn[4] and C.text or C.muted, btn[4], m.smallSize)
            end
            textW = width - 2 * pad
        end
        local here
        local name, line
        if folder == nil then
            here = item.fieldId == fieldHere
            name = GuidanceLibrary.fieldName(item.fieldId)
            line = item.count == 1 and t("guidance_folder_one") or t("guidance_folder_count", item.count)
            if item.fieldId < 0 then line = t("guidance_record_folder") .. " · " .. line end
            if here then line = line .. " · " .. t("guidance_folder_here") end
            -- a folder: a small folder-coloured tab left of the name
            Draw.roundRect(x + pad, cy + rowH * 0.56, self:w(14), self:h(10), self:h(2), C.warn)
            self:textIn(x + pad + self:w(20), cy + rowH * 0.48, rowH * 0.45, m.textSize, name, C.text, nil, true)
        else
            here = true
            name = item.name
            line = t("guidance_saved_info", item.area / 10000, formatDuration(item.time), item.plan.workWidth)
            if (item.plan.adMarker or "") ~= "" then line = line .. " · " .. t("guidance_saved_marker", item.plan.adMarker) end
            self:textIn(x + pad, cy + rowH - self:h(26), self:h(22), m.textSize, fit(name, m.textSize, textW, true), C.text,
                nil, true)
            self:textIn(x + pad, cy + rowH - self:h(46), self:h(20), m.smallSize, fit(line, m.smallSize, textW), C.muted)
        end
        if folder == nil then
            self:textIn(x + pad, cy + rowH * 0.06, rowH * 0.45, m.smallSize, fit(line, m.smallSize, textW),
                here and C.accent or C.muted)
        end
    end

    -- pages
    if pagerH > 0 then
        cy = cy - pagerH
        local bw, bh = self:w(70), self:h(24)
        local by = cy + (pagerH - bh) / 2
        self:button(x + pad, by, bw, bh, "<", C.chip, C.hover, C.text,
            self.libraryPage > 1 and function() self.libraryPage = self.libraryPage - 1 end or nil, m.smallSize)
        self:button(x + width - pad - bw, by, bw, bh, ">", C.chip, C.hover, C.text,
            self.libraryPage < pages and function() self.libraryPage = self.libraryPage + 1 end or nil, m.smallSize)
        self:textIn(x + width / 2, cy, pagerH, m.smallSize, string.format("%d / %d", self.libraryPage, pages), C.muted,
            RenderText.ALIGN_CENTER)
    end

    if self.message then
        cy = cy - messageH
        self:textIn(x + pad, cy, messageH, m.smallSize, self.message, self.messageIsError and C.danger or C.muted)
    end
end

-----------------------------------------------------------------------------------------------------------------------
-- Fleet: all the farm's Guidance vehicles, with their status, and buttons to start, pause, go on or stop them
-----------------------------------------------------------------------------------------------------------------------

Hud.FLEET_PAGE = 10

--- Can we go to (get into) this vehicle from the fleet? Not the one we're in, not one someone else is in
function Hud:canGoTo(vehicle)
    if g_localPlayer == nil or g_localPlayer.requestToEnterVehicle == nil or vehicle == currentVehicle() then
        return false
    end
    if vehicle.spec_enterable == nil then
        return false
    end
    return vehicle.getIsEnterableFromMenu == nil or vehicle:getIsEnterableFromMenu() == true
end

--- Into that vehicle, as the game's own vehicle switching does; the panel comes back there on the same page
function Hud:goTo(vehicle)
    if not self:canGoTo(vehicle) then
        return
    end
    self.pendingEnter = {vehicle = vehicle, view = self.view, page = self.fleetPage, expires = (g_time or 0) + 5000}
    g_localPlayer:requestToEnterVehicle(vehicle)
end

function Hud:drawFleet()
    local C = Hud.C
    local m = self:metrics()
    local pad, width = m.pad, m.width
    local list = GuidanceMap.getFarmVehicles()
    -- working first, then those with a course, then the rest (each by name, as the list comes)
    local function rank(v)
        if v:getIsGuidanceActive() then return 1 end
        if v:getGuidanceCourse() ~= nil then return 2 end
        return 3
    end
    local order = {}
    for i, v in ipairs(list) do order[v] = i end
    table.sort(list, function(a, b)
        local ra, rb = rank(a), rank(b)
        if ra ~= rb then return ra < rb end
        return order[a] < order[b]
    end)
    local withCourse = 0
    for _, v in ipairs(list) do
        if v:getGuidanceCourse() ~= nil then withCourse = withCourse + 1 end
    end
    local rowH = self:h(52)
    local pages = math.max(1, math.ceil(#list / Hud.FLEET_PAGE))
    self.fleetPage = math.max(1, math.min(pages, self.fleetPage or 1))
    local first = (self.fleetPage - 1) * Hud.FLEET_PAGE + 1
    local shown = math.min(Hud.FLEET_PAGE, #list - first + 1)
    local pagerH = pages > 1 and self:h(32) or 0
    local switchH = self:h(38)
    local x, cy = self:drawFrame(m, switchH + math.max(1, shown) * rowH + pagerH, t("guidance_fleet_count", #list, withCourse))
    cy = self:drawFleetSwitch(x, cy, switchH)

    if #list == 0 then
        cy = cy - rowH
        self:textIn(x + pad, cy, rowH, m.textSize, t("guidance_fleet_empty"), C.muted)
        return
    end

    local buttonH, buttonW = self:h(26), self:w(56)
    for i = first, first + shown - 1 do
        local v = list[i]
        cy = cy - rowH
        if i > first then Draw.rect(x + pad, cy + rowH, width - 2 * pad, self:h(1), C.line) end
        local status, statusColor = self:getStatus(v)
        local active = v:getIsGuidanceActive()
        local paused = active and v:getIsGuidancePaused()
        -- buttons on the right: pause/go on and stop while working, start otherwise
        local buttons = {}
        local canGo = self:canGoTo(v)
        if canGo then
            table.insert(buttons, {t("guidance_btn_goTo"), C.chip, C.hover, function() self:goTo(v) end, self:w(46)})
        end
        if active then
            if paused then
                table.insert(buttons, {t("guidance_btn_resume"), C.accent, C.accentHover, function() v:guidanceSetPaused(false) end})
            else
                table.insert(buttons, {t("guidance_btn_pause"), C.chip, C.hover, function() v:guidanceSetPaused(true) end})
            end
            table.insert(buttons, {t("guidance_btn_stop"), C.danger, C.dangerHover, function() v:guidanceStop() end})
        elseif v:getIsHelperDriving() then
            table.insert(buttons, {t("guidance_btn_stop"), C.danger, C.dangerHover, function() v:guidanceStopHelper() end})
        elseif v:getGuidanceCourse() ~= nil then
            table.insert(buttons, {t("guidance_btn_start"), C.accent, C.accentHover, function() v:guidanceStartStop() end})
        end
        local bx = x + width - pad
        local by = cy + (rowH - buttonH) / 2
        for k = #buttons, 1, -1 do
            local b = buttons[k]
            local bw = b[5] or buttonW
            bx = bx - bw
            self:button(bx, by, bw, buttonH, b[1], b[2], b[3], C.text, b[4], m.smallSize)
            bx = bx - self:w(6)
        end
        -- name, status with its dot, progress
        local textW = bx - (x + pad) - self:w(8)
        -- the name: a click goes there too
        local nameY, nameH = cy + rowH * 0.48, rowH * 0.45
        local nameHover = canGo and self:isHover(x + pad, nameY, textW, nameH)
        self:textIn(x + pad, nameY, nameH, m.textSize, fit(Guidance.vehicleName(v), m.textSize, textW, true),
            nameHover and C.accent or C.text, nil, true)
        if canGo then
            self:addElement(x + pad, nameY, textW, nameH, function() self:goTo(v) end)
        end
        Draw.disc(x + pad + self:w(4), cy + rowH * 0.28, self:h(3.5), statusColor)
        local _, done = v:getGuidanceProgress()
        local statusW = textW * 0.74 - self:w(12)
        if active and done > 0 and done < 1 then
            -- the bar shows how far: the time left instead of the percentage (without "left" if that's too long)
            local _, left = v:getGuidanceTimes()
            if left then
                local state = t(paused and "guidance_status_pausedShort" or "guidance_status_workingShort") .. " · "
                status = state .. t("guidance_progress_left", formatDuration(left))
                if Draw.textWidth(m.smallSize, status) > statusW then
                    status = state .. formatDuration(left)
                end
            end
        end
        self:textIn(x + pad + self:w(12), cy + rowH * 0.06, rowH * 0.45, m.smallSize,
            fit(status, m.smallSize, statusW), C.muted)
        if v:getGuidanceCourse() and done > 0 then
            local barW = math.max(self:w(20), textW * 0.24)
            local barX = x + pad + textW - barW
            local barY = cy + rowH * 0.24
            Draw.roundRect(barX, barY, barW, self:h(4), self:h(2), C.track)
            Draw.roundRect(barX, barY, math.max(self:h(4), barW * done), self:h(4), self:h(2), paused and C.warn or C.accent)
        end
    end
    if pagerH > 0 then
        cy = cy - pagerH
        local bw, bh = self:w(70), self:h(24)
        local by = cy + (pagerH - bh) / 2
        self:button(x + pad, by, bw, bh, "<", C.chip, C.hover, C.text,
            self.fleetPage > 1 and function() self.fleetPage = self.fleetPage - 1 end or nil, m.smallSize)
        self:button(x + width - pad - bw, by, bw, bh, ">", C.chip, C.hover, C.text,
            self.fleetPage < pages and function() self.fleetPage = self.fleetPage + 1 end or nil, m.smallSize)
        self:textIn(x + width / 2, cy, pagerH, m.smallSize, string.format("%d / %d", self.fleetPage, pages), C.muted,
            RenderText.ALIGN_CENTER)
    end
end

-----------------------------------------------------------------------------------------------------------------------
-- Settings: the tractor's (saved with it), the field's (on the server, used whoever makes a course there), the
-- player's own defaults (on this PC, for tractors not set up yet)
-----------------------------------------------------------------------------------------------------------------------

Hud.SETTINGS_PAGE_ONLY = {refillX = true, keepRunning = true, takeOver = true, tramlines = true, minHeadlandWidth = true, teamMode = true, teamSize = true, teamIndex = true, autoResume = true,
                          rowFrom = true, rowTo = true, workSpeedMax = true, turnSpeed = true, reverseSpeed = true,
                          lights = true,
                          lowerLate = true, raiseLate = true, callUnloaderAt = true, toolOffsetX = true, rainWait = true,
                          adMarker = true, refuelAt = true, repairAt = true, handOver = true}
Hud.FIELD_ROWS = {headlands = true, rowAngle = true, clockwise = true, headlandsFirst = true, pattern = true,
                  roundedPasses = true}
Hud.USER_ROWS = {minHeadlandWidth = true, roundedPasses = true, keepLowered = true, keepRunning = true, takeOver = true, lowerLate = true, raiseLate = true,
                 autoResume = true, workSpeedMax = true, turnSpeed = true, reverseSpeed = true, lights = true,
                 clockwise = true,
                 headlandsFirst = true, pattern = true}

--- The field the settings are about: the course's, else the one the tractor is on
function Hud:getSettingsField(vehicle)
    local plan = vehicle:getGuidancePlan()
    if plan then
        return plan.fieldId
    end
    return self:getFieldHere(vehicle)
end

--- Rows, a note on what they are and buttons ({label, onClick or nil}) for one scope
function Hud:getScopeContent(vehicle, scope, editable)
    local settings = vehicle:getGuidanceSettings()
    local course = vehicle:getGuidanceCourse()
    local onOff = function(value) return value and t("guidance_on") or t("guidance_off") end
    if scope == "field" then
        local fieldId = self:getSettingsField(vehicle)
        if fieldId == nil then
            return {}, t("guidance_scope_noField"), {}, false
        end
        local stored = GuidanceLibrary.fieldSettings[fieldId]
        local values = settings:copy()
        for name, value in pairs(stored or {}) do values[name] = value end
        local plan = vehicle:getGuidancePlan()
        local rows = self:getSettingRows(vehicle, {
            values = values,
            names = Hud.FIELD_ROWS,
            stats = plan and plan.fieldId == fieldId and course and course.stats or nil,
            set = function(name, value)
                local v = GuidanceLibrary.fieldValuesOf(values)
                v[name] = value
                GuidanceLibrary.setFieldSettings(fieldId, v)
            end,
        })
        local name = GuidanceLibrary.fieldName(fieldId)
        local note = stored and t("guidance_scope_fieldNote", name) or t("guidance_scope_fieldUnset", name)
        local buttons = {
            {t("guidance_scope_useTractor"), function()
                GuidanceLibrary.setFieldSettings(fieldId, GuidanceLibrary.fieldValuesOf(settings))
                self:showMessage(t("guidance_scope_fieldSaved", name), false)
            end},
            {t("guidance_scope_forget"), stored and function()
                GuidanceLibrary.setFieldSettings(fieldId, nil)
                self:showMessage(t("guidance_scope_fieldForgotten", name), false)
            end or nil},
        }
        return rows, note, buttons, true
    elseif scope == "user" then
        local values = settings:copy()
        for _, name in ipairs(GuidancePrefs.PLAN_DEFAULTS) do values[name] = GuidancePrefs[name] end
        local rows = self:getSettingRows(vehicle, {
            values = values,
            names = Hud.USER_ROWS,
            set = function(name, value) GuidancePrefs.set(name, value) end,
        })
        local function toggle(name) return function() GuidancePrefs.set(name, not GuidancePrefs[name]) end end
        table.insert(rows, {label = t("guidance_set_rememberFields"), value = onOff(GuidancePrefs.rememberFields),
                            dec = toggle("rememberFields"), inc = toggle("rememberFields")})
        table.insert(rows, {label = t("guidance_set_notifications"), value = onOff(GuidancePrefs.notifications),
                            dec = toggle("notifications"), inc = toggle("notifications")})
        table.insert(rows, {label = t("guidance_set_soundAlerts"), value = onOff(GuidancePrefs.soundAlerts ~= false),
                            dec = toggle("soundAlerts"), inc = toggle("soundAlerts")})
        table.insert(rows, {label = t("guidance_set_alertsOnScreen"), value = onOff(GuidancePrefs.alertsOnScreen ~= false),
                            dec = toggle("alertsOnScreen"), inc = toggle("alertsOnScreen"),
                            click = (GuidancePrefs.alertsX ~= nil) and function()
                                GuidancePrefs.alertsX, GuidancePrefs.alertsTop = nil, nil
                                GuidancePrefs.save()
                            end or nil})
        local scale = GuidancePrefs.panelScale or 1
        local function setScale(v) return function() GuidancePrefs.set("panelScale", math.floor(v * 10 + 0.5) / 10) end end
        table.insert(rows, {label = t("guidance_set_panelScale"), value = string.format("%d%%", math.floor(scale * 100 + 0.5)),
                            dec = setScale(math.max(0.7, scale - 0.1)), inc = setScale(math.min(1.5, scale + 0.1)),
                            click = math.abs(scale - 1) > 0.01 and setScale(1) or nil})
        -- the course lines in the world: on the ground, or up to see them over tall crops
        local heights = GuidancePrefs.LINE_HEIGHTS
        local hIx = 1
        for k, h in ipairs(heights) do
            if math.abs(h - (GuidancePrefs.lineHeight or heights[1])) < 0.01 then hIx = k end
        end
        local function setHeight(k) return function() GuidancePrefs.set("lineHeight", heights[k]) end end
        local hValue = hIx == 1 and t("guidance_lineHeight_ground")
            or string.format("%.1f m (%d ft)", heights[hIx], math.floor(heights[hIx] * 3.281 + 0.5))
        table.insert(rows, {label = t("guidance_set_lineHeight"), value = hValue,
                            dec = hIx > 1 and setHeight(hIx - 1) or nil,
                            inc = hIx < #heights and setHeight(hIx + 1) or nil})
        table.insert(rows, {label = t("guidance_set_debugOverlay"), value = onOff(GuidancePrefs.debugOverlay == true),
                            dec = toggle("debugOverlay"), inc = toggle("debugOverlay")})
        -- Precision Farming: automatic (used when installed) or off
        local pfValue = GuidancePrefs.precisionFarming == false and t("guidance_pf_off")
            or (GuidancePlanner.PF.isLoaded() and t("guidance_pf_autoFound") or t("guidance_pf_autoMissing"))
        local function pfToggle() GuidancePrefs.set("precisionFarming", GuidancePrefs.precisionFarming == false) end
        table.insert(rows, {label = t("guidance_set_precisionFarming"), value = pfValue, dec = pfToggle, inc = pfToggle})
        local buttons = {
            {t("guidance_scope_applyTractor"), editable and function()
                local v = {}
                for _, name in ipairs(GuidancePrefs.PLAN_DEFAULTS) do v[name] = GuidancePrefs[name] end
                vehicle:guidanceApplySettings(v)
                self:showMessage(t("guidance_scope_applied"), false)
            end or nil},
            -- a text file for a GitHub issue: version, vehicle, settings, what the helper did, the last log lines
            {t("guidance_report_btn"), function()
                local ok, path = Guidance.try(GuidanceDebug.writeReport, vehicle)
                if ok and path then
                    -- (the whole path, on as many lines as it takes, long enough to read)
                    self:showMessage(t("guidance_report_written", path), false, 20)
                else
                    self:showMessage(t("guidance_report_failed"), true)
                end
            end},
        }
        return rows, t("guidance_scope_userNote"), buttons, true
    end
    -- the tractor's: everything, as on the course page
    local buttons = {
        {t("guidance_scope_saveDefaults"), function()
            for _, name in ipairs(GuidancePrefs.PLAN_DEFAULTS) do GuidancePrefs[name] = settings[name] end
            GuidancePrefs.save()
            self:showMessage(t("guidance_scope_savedDefaults"), false)
        end},
    }
    -- one section at a time (all of them don't fit on a screen)
    local section = Hud.TRACTOR_SECTIONS[self.settingsSection or "course"] or Hud.TRACTOR_SECTIONS.course
    local rows = {}
    for _, row in ipairs(self:getSettingRows(vehicle, nil, true)) do
        if section[row.name] then table.insert(rows, row) end
    end
    return rows, t("guidance_scope_tractorNote", vehicle:getName()), buttons, editable
end

-- the tractor's settings in sections
Hud.TRACTOR_SECTIONS = {
    course = {workWidth = true, headlands = true, rowAngle = true, turnRadius = true, clockwise = true,
              headlandsFirst = true, pattern = true, roundedPasses = true, minHeadlandWidth = true, workPart = true,
              rowFrom = true, rowTo = true, rowsPerLand = true, landsSide = true, rowShape = true, tramlines = true,
              edgeObstacles = true},
    driving = {refillX = true, keepLowered = true, keepRunning = true, takeOver = true, workSpeedMax = true, turnSpeed = true, reverseSpeed = true, lights = true,
               callUnloaderAt = true, rainWait = true, toolOffsetX = true, autoResume = true, lowerLate = true,
               raiseLate = true, adMarker = true, refuelAt = true, repairAt = true, handOver = true},
    team = {teamMode = true, teamSize = true, teamIndex = true},
}

function Hud:drawSettings()
    local vehicle = self.vehicle
    local C = Hud.C
    local m = self:metrics()
    local pad, padY, rowH, width = m.pad, m.padY, m.rowH, m.width
    local smallSize = m.smallSize
    local editable = not vehicle:getIsGuidanceActive()
    local scope = self.settingsScope or "tractor"
    local rows, note, buttons, rowsEditable = self:getScopeContent(vehicle, scope, editable)

    local scopeH, noteH, startAtH = self:h(40), self:h(26), self:h(34)
    local sectionH = scope == "tractor" and self:h(36) or 0
    local buttonsH = #buttons > 0 and self:h(36) or 0
    local messageLines = self.message and math.min(5, self:countLines(self.message, smallSize, width - 2 * pad)) or 0
    local messageH = messageLines > 0 and (messageLines * self:h(16) + self:h(8)) or 0
    local userThen = scope == "user" and GuidancePrefs.startMode == GuidancePlan.START_FIRST
    local contentH = scopeH + sectionH + noteH + padY * 0.5 + #rows * rowH + (scope == "user" and startAtH or 0)
        + (userThen and startAtH or 0)
        + padY * 0.5 + buttonsH + messageH

    local status, statusColor = self:getStatus(vehicle)
    local x, cy = self:drawFrame(m, contentH, vehicle:getName(), status, statusColor)

    -- this tractor / this field / my defaults
    cy = self:drawSwitch(x, cy, scopeH, nil, {
        {"tractor", t("guidance_scope_tractor")},
        {"field", t("guidance_scope_field")},
        {"user", t("guidance_scope_user")},
    }, scope, function(value) self.settingsScope = value end, true)
    if sectionH > 0 then
        cy = self:drawSwitch(x, cy, sectionH, nil, {
            {"course", t("guidance_section_course")},
            {"driving", t("guidance_section_driving")},
            {"team", t("guidance_section_team")},
        }, self.settingsSection or "course", function(value) self.settingsSection = value end, true)
    end
    cy = cy - noteH
    self:textIn(x + pad, cy, noteH, smallSize, fit(note, smallSize, width - 2 * pad), C.muted)

    cy = self:drawSettingRows(x, cy - padY * 0.5, rows, rowsEditable)
    if scope == "user" then
        cy = self:drawSwitch(x, cy, startAtH, t("guidance_set_startAt"), Hud.startModes(), GuidancePrefs.startMode,
            function(mode) GuidancePrefs.set("startMode", mode) end, true, self:w(210))
        if userThen then
            cy = self:drawSwitch(x, cy, startAtH, t("guidance_set_startAfter"), Hud.startModes(),
                GuidancePrefs.startAfter or GuidancePlan.START_FIRST,
                function(mode) GuidancePrefs.set("startAfter", mode) end, true, self:w(210))
        end
    end

    if buttonsH > 0 then
        cy = cy - padY * 0.5 - buttonsH
        local gap = self:w(10)
        local bw = (width - 2 * pad - gap * (#buttons - 1)) / #buttons
        for k, b in ipairs(buttons) do
            self:button(x + pad + (k - 1) * (bw + gap), cy, bw, buttonsH, b[1], C.surface, C.hover,
                b[2] and C.text or C.muted, b[2], smallSize)
        end
    end
    if self.message then
        cy = cy - messageH
        self:textLines(x + pad, cy + self:h(4), messageH - self:h(8), smallSize, self.message, width - 2 * pad,
            self.messageIsError and C.danger or C.muted, messageLines)
    end
end

-----------------------------------------------------------------------------------------------------------------------
-- Team: several tractors on one field. Pick them, pick how they share it, make all their courses, start them all.
-----------------------------------------------------------------------------------------------------------------------

Hud.TEAM_PAGE = 7

--- Text broken into at most maxLines lines that fit the width (the last one shortened with dots if needed)
--- A word too wide for a line (a file path) in pieces that fit: broken after a slash where it can be
local function splitLong(word, size, width)
    local pieces = {}
    while Draw.textWidth(size, word) > width and #word > 1 do
        local cut
        for i = #word - 1, 1, -1 do
            local c = word:sub(i, i)
            if (c == "/" or c == "\\") and Draw.textWidth(size, word:sub(1, i)) <= width then
                cut = i
                break
            end
        end
        if cut == nil then
            -- no slash that fits: as many letters as fit
            cut = 1
            while cut < #word and Draw.textWidth(size, word:sub(1, cut + 1)) <= width do cut = cut + 1 end
        end
        pieces[#pieces + 1] = word:sub(1, cut)
        word = word:sub(cut + 1)
    end
    pieces[#pieces + 1] = word
    return pieces
end

local function wrapLines(text, size, width, maxLines)
    local lines, line = {}, ""
    local words = {}
    for word in string.gmatch(text, "%S+") do
        for _, piece in ipairs(splitLong(word, size, width)) do words[#words + 1] = piece end
    end
    for _, word in ipairs(words) do
        local try = line == "" and word or (line .. " " .. word)
        if Draw.textWidth(size, try) <= width or line == "" then
            line = try
        else
            table.insert(lines, line)
            line = word
        end
    end
    if line ~= "" then table.insert(lines, line) end
    if #lines > maxLines then
        local rest = table.concat(lines, " ", maxLines)
        for i = #lines, maxLines, -1 do lines[i] = nil end
        lines[maxLines] = fit(rest, size, width)
    end
    return lines
end

--- Up to two lines of small text in a box of height h at y (top line first)
--- How many lines a text takes in that width
function Hud:countLines(text, size, width)
    return #wrapLines(text, size, width, 99)
end

function Hud:textLines(x, y, h, size, text, width, color, maxLines)
    maxLines = maxLines or 2
    local lines = wrapLines(text, size, width, maxLines)
    local lineH = h / maxLines
    for i, l in ipairs(lines) do
        local ly = #lines == 1 and y + (h - lineH) / 2 or y + h - i * lineH
        self:textIn(x, ly, lineH, size, l, color)
    end
end
Hud.TEAM_MODES = {GuidancePlan.TEAM_STRIPS, GuidancePlan.TEAM_LANDS, GuidancePlan.TEAM_CONVOY, GuidancePlan.TEAM_NEXT_ROW}

--- A vehicle's work width (from its settings, or its implement when automatic), looked at now and then only
function Hud:teamWidth(vehicle)
    self.teamWidths = self.teamWidths or {}
    local cached = self.teamWidths[vehicle]
    local now = g_time or 0
    if cached == nil or now - cached.time > 2000 then
        local s = vehicle:getGuidanceSettings()
        local w = s.workWidth
        if s.autoWidth and GuidanceVehicleInfo then
            local ok, info = Guidance.try(GuidanceVehicleInfo.get, vehicle)
            if ok and info then w = info.workWidth end
        end
        cached = {w = w, time = now}
        self.teamWidths[vehicle] = cached
    end
    return cached.w
end

--- What a member does in its team: "Strip 2 of 3", "Lane 1 of 3", "Rows as they come"
local function teamRole(plan)
    local mode = GuidancePlan.TEAM_MODES[plan.teamMode or 0] or "alone"
    return t("guidance_teamRole_" .. mode, plan.teamIndex or 1, plan.teamSize or 1)
end

--- The team being put together: the tractors ticked (in order, the first leads). Starts as the team that works
--- this field already, or just this tractor.
function Hud:getTeamPick(vehicle, fieldId)
    if self.teamPickField ~= fieldId or self.teamPick == nil then
        self.teamPickField = fieldId
        self.teamPick = fieldId and GuidanceTeam.membersOn(fieldId) or {}
        if #self.teamPick > 0 then
            self.teamModePick = self.teamPick[1]:getGuidancePlan().teamMode
        else
            self.teamPick = {vehicle}
        end
    end
    -- gone (sold, deleted)
    for i = #self.teamPick, 1, -1 do
        if self.teamPick[i].isDeleted then table.remove(self.teamPick, i) end
    end
    return self.teamPick
end

function Hud:drawTeam()
    local vehicle = self.vehicle
    local C = Hud.C
    local m = self:metrics()
    local pad, padY, width = m.pad, m.padY, m.width
    local smallSize, textSize = m.smallSize, m.textSize
    local fieldId = self:getSettingsField(vehicle)
    local pick = self:getTeamPick(vehicle, fieldId)
    local mode = self.teamModePick or GuidancePlan.TEAM_STRIPS
    if mode == GuidancePlan.TEAM_ALONE then mode = GuidancePlan.TEAM_STRIPS end
    self.teamModePick = mode

    local candidates = GuidanceMap.getFarmVehicles()
    local isPicked = {}
    for i, v in ipairs(pick) do isPicked[v] = i end
    -- the picked ones first (in their order), then the others
    table.sort(candidates, function(a, b)
        local pa, pb = isPicked[a], isPicked[b]
        if pa and pb then return pa < pb end
        if pa or pb then return pa ~= nil end
        return Guidance.vehicleName(a) < Guidance.vehicleName(b)
    end)
    local pages = math.max(1, math.ceil(#candidates / Hud.TEAM_PAGE))
    self.teamPage = math.max(1, math.min(pages, self.teamPage or 1))
    local first = (self.teamPage - 1) * Hud.TEAM_PAGE + 1
    local shown = math.min(Hud.TEAM_PAGE, #candidates - first + 1)

    local width0 = pick[1] and self:teamWidth(pick[1]) or 0
    local mismatch = {}
    for i = 2, #pick do
        if math.abs(self:teamWidth(pick[i]) - width0) > 0.25 then table.insert(mismatch, pick[i]) end
    end

    local fieldH, modeH, aboutH, headH = self:h(28), self:h(40), self:h(36), self:h(22)
    local rowH = self:h(40)
    local pagerH = pages > 1 and self:h(30) or 0
    local warnH = #mismatch > 0 and self:h(34) or 0
    local buttonsH = self:h(40)
    local messageH = self.message and self:h(24) or 0
    local contentH = fieldH + modeH + aboutH + headH + shown * rowH + pagerH + warnH + padY * 0.5 + buttonsH + messageH
    local status, statusColor = self:getStatus(vehicle)
    local x, cy = self:drawFrame(m, contentH, vehicle:getName(), status, statusColor)

    -- the field
    cy = cy - fieldH
    local fieldText = fieldId and t("guidance_team_field", GuidanceLibrary.fieldName(fieldId)) or t("guidance_team_noField")
    self:textIn(x + pad, cy, fieldH, textSize, fieldText, fieldId and C.text or C.warn, nil, true)

    -- how they share it
    local options = {}
    for _, md in ipairs(Hud.TEAM_MODES) do
        table.insert(options, {md, t("guidance_team_" .. GuidancePlan.TEAM_MODES[md])})
    end
    cy = self:drawSwitch(x, cy, modeH, nil, options, mode, function(value) self.teamModePick = value end, true)
    cy = cy - aboutH
    self:textLines(x + pad, cy, aboutH, smallSize, t("guidance_teamAbout_" .. GuidancePlan.TEAM_MODES[mode]),
        width - 2 * pad, C.muted)

    -- the tractors: tick the ones in the team
    cy = cy - headH
    self:textIn(x + pad, cy, headH, smallSize, t("guidance_team_pick", #pick), C.muted)
    for i = first, first + shown - 1 do
        local v = candidates[i]
        cy = cy - rowH
        if i > first then Draw.rect(x + pad, cy + rowH, width - 2 * pad, self:h(1), C.line) end
        local place = isPicked[v]
        local box = self:h(18)
        local boxX = x + pad
        local boxY = cy + (rowH - box) / 2
        local hover = self:isHover(x + pad, cy, width - 2 * pad, rowH)
        Draw.roundRect(boxX, boxY, box / g_screenAspectRatio, box, self:h(4), place and C.accent or (hover and C.hover or C.chip))
        if place then
            self:textIn(boxX + box / g_screenAspectRatio / 2, boxY, box, smallSize, tostring(place), {1, 1, 1, 1},
                RenderText.ALIGN_CENTER, true)
        end
        local textX = boxX + box / g_screenAspectRatio + self:w(8)
        local textW = x + width - pad - textX
        local name = Guidance.vehicleName(v)
        if place == 1 and #pick > 1 then name = name .. " · " .. t("guidance_team_lead") end
        self:textIn(textX, cy + rowH * 0.5, rowH * 0.45, textSize, fit(name, textSize, textW, true), C.text, nil, true)
        -- its width, what it does in the team now, what it is doing
        local plan = v:getGuidancePlan()
        local line = string.format("%.1f m", self:teamWidth(v))
        if plan and plan.fieldId == fieldId and (plan.teamMode or 0) ~= GuidancePlan.TEAM_ALONE then
            line = line .. " · " .. teamRole(plan)
        end
        local st = self:getStatus(v)
        if st then line = line .. " · " .. st end
        self:textIn(textX, cy + rowH * 0.06, rowH * 0.45, smallSize, fit(line, smallSize, textW), C.muted)
        self:addElement(x + pad, cy, width - 2 * pad, rowH, function()
            if place then
                table.remove(pick, place)
            elseif #pick < GuidancePlan.TEAM_MAX then
                table.insert(pick, v)
            else
                self:showMessage(t("guidance_team_full", GuidancePlan.TEAM_MAX), true)
            end
        end)
    end
    if pagerH > 0 then
        cy = cy - pagerH
        local bw, bh = self:w(70), self:h(24)
        local by = cy + (pagerH - bh) / 2
        self:button(x + pad, by, bw, bh, "<", C.chip, C.hover, C.text,
            self.teamPage > 1 and function() self.teamPage = self.teamPage - 1 end or nil, smallSize)
        self:button(x + width - pad - bw, by, bw, bh, ">", C.chip, C.hover, C.text,
            self.teamPage < pages and function() self.teamPage = self.teamPage + 1 end or nil, smallSize)
        self:textIn(x + width / 2, cy, pagerH, smallSize, string.format("%d / %d", self.teamPage, pages), C.muted,
            RenderText.ALIGN_CENTER)
    end
    if warnH > 0 then
        cy = cy - warnH
        local names = {}
        for _, v in ipairs(mismatch) do table.insert(names, Guidance.vehicleName(v)) end
        self:textLines(x + pad, cy, warnH, smallSize, t("guidance_team_widths", table.concat(names, ", "), width0),
            width - 2 * pad, C.warn)
    end

    -- make the courses, start them all, stop them all
    cy = cy - padY * 0.5 - buttonsH
    local gap = self:w(8)
    local bw = (width - 2 * pad - 2 * gap) / 3
    local members = fieldId and GuidanceTeam.membersOn(fieldId) or {}
    local canMake = fieldId ~= nil and #pick > 0
    self:button(x + pad, cy, bw, buttonsH, t("guidance_team_make"), canMake and C.accent or C.pill, C.accentHover,
        canMake and {1, 1, 1, 1} or C.muted, canMake and function()
            local ok, err = GuidanceTeam.makeCourses(pick, fieldId, mode)
            if ok then
                self:showMessage(t("guidance_team_made", #pick, GuidanceLibrary.fieldName(fieldId)), false)
            else
                self:showMessage(err or t("guidance_err_generic"), true)
            end
        end or nil, smallSize)
    local startable, stoppable = {}, {}
    for _, v in ipairs(members) do
        if v:getIsGuidanceActive() then
            table.insert(stoppable, v)
        elseif v:getGuidanceCourse() and not v:getIsHelperDriving() then
            table.insert(startable, v)
        end
    end
    self:button(x + pad + bw + gap, cy, bw, buttonsH, t("guidance_team_startAll", #startable),
        #startable > 0 and C.accent or C.pill, C.accentHover, #startable > 0 and {1, 1, 1, 1} or C.muted,
        #startable > 0 and function()
            for _, v in ipairs(startable) do v:guidanceStartStop() end
        end or nil, smallSize)
    self:button(x + pad + 2 * (bw + gap), cy, bw, buttonsH, t("guidance_team_stopAll"),
        #stoppable > 0 and C.danger or C.pill, C.dangerHover, #stoppable > 0 and {1, 1, 1, 1} or C.muted,
        #stoppable > 0 and function()
            for _, v in ipairs(stoppable) do v:guidanceStop() end
        end or nil, smallSize)

    if self.message then
        cy = cy - messageH
        self:textIn(x + pad, cy, messageH, smallSize, fit(self.message, smallSize, width - 2 * pad),
            self.messageIsError and C.danger or C.muted)
    end
end

-----------------------------------------------------------------------------------------------------------------------
-- Fleet tab: the vehicles, or the work log (what the helpers did, totals per field and tractor)
-----------------------------------------------------------------------------------------------------------------------

Hud.LOG_PAGE = 7

function Hud:drawFleetSwitch(x, cy, h)
    return self:drawSwitch(x, cy, h, nil, {{"vehicles", t("guidance_fleet_vehicles")}, {"log", t("guidance_fleet_log")}},
        self.fleetView or "vehicles", function(value) self.fleetView, self.logPage = value, 1 end, true)
end

local function logDuration(seconds)
    local minutes = math.floor((seconds or 0) / 60 + 0.5)
    if minutes < 60 then return string.format("%d min", minutes) end
    return string.format("%d h %02d min", math.floor(minutes / 60), minutes % 60)
end

function Hud:drawWorkLog()
    local vehicle = self.vehicle
    local C = Hud.C
    local m = self:metrics()
    local pad, width = m.pad, m.width
    local list = GuidanceLibrary.getStats(vehicle:getOwnerFarmId())
    -- totals: all, and the field worked most
    local area, seconds, fuel = 0, 0, 0
    local byField = {}
    for _, e in ipairs(list) do
        area, seconds, fuel = area + e.area, seconds + e.seconds, fuel + e.fuel
        byField[e.fieldId] = (byField[e.fieldId] or 0) + e.area
    end
    local pages = math.max(1, math.ceil(#list / Hud.LOG_PAGE))
    self.logPage = math.max(1, math.min(pages, self.logPage or 1))
    local first = (self.logPage - 1) * Hud.LOG_PAGE + 1
    local shown = math.min(Hud.LOG_PAGE, #list - first + 1)
    local switchH, totalH, rowH = self:h(38), self:h(46), self:h(44)
    local pagerH = pages > 1 and self:h(30) or 0
    local x, cy = self:drawFrame(m, switchH + totalH + math.max(1, shown) * rowH + pagerH, t("guidance_log_count", #list))
    cy = self:drawFleetSwitch(x, cy, switchH)

    cy = cy - totalH
    Draw.roundRect(x + pad, cy + self:h(4), width - 2 * pad, totalH - self:h(8), m.smallRadius, C.surface)
    self:textIn(x + pad + self:w(10), cy + totalH / 2, totalH / 2 - self:h(4), m.smallSize, t("guidance_log_total"), C.muted)
    self:textIn(x + pad + self:w(10), cy + self:h(6), totalH / 2 - self:h(4), m.textSize,
        string.format("%.1f ha · %s · %d l", area / 10000, logDuration(seconds), math.floor(fuel + 0.5)), C.text, nil, true)

    if #list == 0 then
        cy = cy - rowH
        self:textIn(x + pad, cy, rowH, m.textSize, t("guidance_log_empty"), C.muted)
        return
    end
    for i = first, first + shown - 1 do
        local e = list[i]
        cy = cy - rowH
        if i > first then Draw.rect(x + pad, cy + rowH, width - 2 * pad, self:h(1), C.line) end
        local title = GuidanceLibrary.fieldName(e.fieldId) .. " · " .. (e.vehicle or "")
        self:textIn(x + pad, cy + rowH * 0.5, rowH * 0.45, m.textSize, fit(title, m.textSize, width - 2 * pad, true), C.text,
            nil, true)
        local when = e.day and t("guidance_log_when", e.day.day or 0, e.day.hour or 0, e.day.minute or 0) or ""
        local line = string.format("%.2f ha · %s · %d l · %s", e.area / 10000, logDuration(e.seconds),
            math.floor(e.fuel + 0.5), when)
        self:textIn(x + pad, cy + rowH * 0.06, rowH * 0.45, m.smallSize, fit(line, m.smallSize, width - 2 * pad), C.muted)
    end
    if pagerH > 0 then
        cy = cy - pagerH
        local bw, bh = self:w(70), self:h(24)
        local by = cy + (pagerH - bh) / 2
        self:button(x + pad, by, bw, bh, "<", C.chip, C.hover, C.text,
            self.logPage > 1 and function() self.logPage = self.logPage - 1 end or nil, m.smallSize)
        self:button(x + width - pad - bw, by, bw, bh, ">", C.chip, C.hover, C.text,
            self.logPage < pages and function() self.logPage = self.logPage + 1 end or nil, m.smallSize)
        self:textIn(x + width / 2, cy, pagerH, m.smallSize, string.format("%d / %d", self.logPage, pages), C.muted,
            RenderText.ALIGN_CENTER)
    end
end

-----------------------------------------------------------------------------------------------------------------------
-- Import: the course files in the player's folder (modSettings/FS25_Guidance/courses)
-----------------------------------------------------------------------------------------------------------------------

Hud.IMPORT_PAGE = 7

-----------------------------------------------------------------------------------------------------------------------
-- The queue: the saved courses the vehicle works next, in order. Moved up and down, gone to now, taken out, cleared.
-----------------------------------------------------------------------------------------------------------------------

Hud.QUEUE_PAGE = 5
Hud.OFF_FIELD_ASK = 30000 -- ms the "not on the field" question stays

--- The farm's running contracts on fields: a course on one for this tractor, and off there
function Hud:drawContracts()
    local vehicle = self.vehicle
    local C = Hud.C
    local m = self:metrics()
    local pad, width = m.pad, m.width
    local list = GuidanceContracts.running(vehicle:getOwnerFarmId())
    local shown = math.min(#list, Hud.QUEUE_PAGE)
    local headH, hintH, rowH = self:h(34), self:h(40), self:h(72)
    local messageH = self.message and self:h(24) or 0
    local x, cy = self:drawFrame(m, headH + hintH + math.max(1, shown) * rowH + messageH, t("guidance_contracts_title", #list))
    cy = cy - headH
    local bw, bh = self:w(110), self:h(26)
    self:button(x + pad, cy + (headH - bh) / 2, bw, bh, "< " .. t("guidance_folder_back"), C.chip, C.hover, C.text,
        function() self.view = "library" end, m.smallSize)
    cy = cy - hintH
    self:textLines(x + pad, cy, hintH, m.smallSize, t("guidance_contracts_hint"), width - 2 * pad, C.muted)
    if #list == 0 then
        cy = cy - rowH
        self:textLines(x + pad, cy, rowH, m.textSize, t("guidance_contracts_none"), width - 2 * pad, C.muted)
    end
    local plan = vehicle:getGuidancePlan()
    local buttonH = self:h(24)
    for i = 1, shown do
        local c = list[i]
        cy = cy - rowH
        if i > 1 then Draw.rect(x + pad, cy + rowH, width - 2 * pad, self:h(1), C.line) end
        -- "Harvest wheat", its field, size, how far it is done, and whether this tractor has the course
        local parts = {GuidanceLibrary.fieldName(c.fieldId)}
        if c.area then parts[#parts + 1] = string.format("%.1f ha", c.area) end
        if c.done then parts[#parts + 1] = string.format("%d%%", math.floor(c.done * 100 + 0.5)) end
        local hasCourse = plan ~= nil and plan.fieldId == c.fieldId and vehicle:getGuidanceCourse() ~= nil
        if hasCourse then parts[#parts + 1] = t("guidance_contracts_hasCourse") end
        self:textIn(x + pad, cy + rowH - self:h(25), self:h(20), m.textSize, fit(c.title, m.textSize, width - 2 * pad, true),
            C.text, nil, true)
        self:textIn(x + pad, cy + rowH - self:h(44), self:h(18), m.smallSize,
            fit(table.concat(parts, " · "), m.smallSize, width - 2 * pad), C.muted)
        local function make()
            if hasCourse then return true end
            local ok, err = vehicle:guidanceCourseForField(c.fieldId)
            if not ok then self:showMessage(err or t("guidance_err_generic"), true) end
            return ok
        end
        local gap = self:w(5)
        local w = (width - 2 * pad - gap) / 2
        self:button(x + pad, cy + self:h(5), w, buttonH, t("guidance_contracts_make"), C.chip, C.hover, C.text,
            function()
                if make() then
                    self.view = "vehicle"
                    self:showMessage(t("guidance_contracts_made", c.title), false)
                end
            end, m.smallSize)
        self:button(x + pad + w + gap, cy + self:h(5), w, buttonH, t("guidance_saved_go"), C.accent, C.accentHover,
            {1, 1, 1, 1}, function()
                if make() then
                    vehicle:guidanceGoTo(0)
                    self.view = "vehicle"
                    self:showMessage(t("guidance_go_sent", c.title), false)
                end
            end, m.smallSize)
    end
    if self.message then
        cy = cy - messageH
        self:textIn(x + pad, cy, messageH, m.smallSize, self.message, self.messageIsError and C.danger or C.muted)
    end
end

function Hud:drawQueue()
    local vehicle = self.vehicle
    local C = Hud.C
    local m = self:metrics()
    local pad, width = m.pad, m.width
    local queue = vehicle:getGuidanceQueue()
    local pages = math.max(1, math.ceil(#queue / Hud.QUEUE_PAGE))
    self.queuePage = math.max(1, math.min(pages, self.queuePage or 1))
    local first = (self.queuePage - 1) * Hud.QUEUE_PAGE + 1
    local shown = math.min(Hud.QUEUE_PAGE, #queue - first + 1)
    local headH, hintH, rowH = self:h(34), self:h(40), self:h(72)
    local footH = #queue > 0 and self:h(38) or 0
    local pagerH = pages > 1 and self:h(30) or 0
    local messageH = self.message and self:h(24) or 0
    local total = 0
    for _, id in ipairs(queue) do
        local e = GuidanceLibrary.getEntry(id)
        total = total + (e and e.time or 0)
    end
    local x, cy = self:drawFrame(m, headH + hintH + math.max(1, shown) * rowH + footH + pagerH + messageH,
        t("guidance_queue_title", #queue))
    -- back to the course; the time it all takes
    cy = cy - headH
    local bw, bh = self:w(110), self:h(26)
    self:button(x + pad, cy + (headH - bh) / 2, bw, bh, "< " .. t("guidance_queue_back"), C.chip, C.hover, C.text,
        function() self.view = "vehicle" end, m.smallSize)
    if #queue > 0 then
        self:textIn(x + width - pad, cy, headH, m.smallSize, t("guidance_queue_total", formatDuration(total)), C.muted,
            RenderText.ALIGN_RIGHT)
    end
    cy = cy - hintH
    self:textLines(x + pad, cy, hintH, m.smallSize, t("guidance_queue_hint"), width - 2 * pad, C.muted)
    if #queue == 0 then
        cy = cy - rowH
        self:textLines(x + pad, cy, rowH, m.textSize, t("guidance_queue_empty"), width - 2 * pad, C.muted)
    end
    local function without(i)
        local list = {}
        for k, id in ipairs(queue) do
            if k ~= i then list[#list + 1] = id end
        end
        return list
    end
    local function swapped(i, j)
        local list = {}
        for k, id in ipairs(queue) do list[k] = id end
        list[i], list[j] = list[j], list[i]
        return list
    end
    local buttonH = self:h(24)
    for i = first, first + shown - 1 do
        local id = queue[i]
        local entry = GuidanceLibrary.getEntry(id)
        cy = cy - rowH
        if i > first then Draw.rect(x + pad, cy + rowH, width - 2 * pad, self:h(1), C.line) end
        -- "2. Field 6 · sowing", its field, time and AutoDrive marker
        local name = string.format("%d. %s", i, entry and entry.name or t("guidance_queue_gone"))
        local parts = {}
        if entry then
            parts[#parts + 1] = GuidanceLibrary.fieldName(entry.plan.fieldId)
            parts[#parts + 1] = formatDuration(entry.time or 0)
            if (entry.plan.adMarker or "") ~= "" then
                parts[#parts + 1] = t("guidance_saved_marker", entry.plan.adMarker)
            end
        end
        self:textIn(x + pad, cy + rowH - self:h(25), self:h(20), m.textSize, fit(name, m.textSize, width - 2 * pad, true),
            C.text, nil, true)
        self:textIn(x + pad, cy + rowH - self:h(44), self:h(18), m.smallSize,
            fit(table.concat(parts, " · "), m.smallSize, width - 2 * pad), C.muted)
        local buttons = {
            {t("guidance_queue_up"), i > 1 and function() vehicle:guidanceSetQueue(swapped(i, i - 1)) end or nil},
            {t("guidance_queue_down"), i < #queue and function() vehicle:guidanceSetQueue(swapped(i, i + 1)) end or nil},
            {t("guidance_saved_go"), entry and function()
                -- out of the queue, and there now
                vehicle:guidanceSetQueue(without(i))
                vehicle:guidanceGoTo(id)
                self.view = "vehicle"
                self:showMessage(t("guidance_go_sent", entry.name), false)
            end or nil},
            {t("guidance_queue_remove"), function() vehicle:guidanceSetQueue(without(i)) end},
        }
        local gap = self:w(5)
        local w = (width - 2 * pad - gap * (#buttons - 1)) / #buttons
        for b, btn in ipairs(buttons) do
            self:button(x + pad + (b - 1) * (w + gap), cy + self:h(5), w, buttonH, btn[1],
                b == 3 and C.accent or C.chip, b == 3 and C.accentHover or C.hover,
                btn[2] and (b == 3 and {1, 1, 1, 1} or C.text) or C.muted, btn[2], m.smallSize)
        end
    end
    if footH > 0 then
        -- all of it out (a second click within 4 s)
        cy = cy - footH
        local now = g_time or 0
        local confirming = self.confirmQueueClear ~= nil and now - self.confirmQueueClear < 4000
        local cw = self:w(140)
        self:button(x + width - pad - cw, cy + (footH - bh) / 2, cw, bh,
            confirming and t("guidance_saved_sure") or t("guidance_queue_clearAll"), confirming and C.danger or C.chip,
            C.dangerHover, C.text, function()
                if confirming then
                    vehicle:guidanceSetQueue({})
                    self.confirmQueueClear = nil
                else
                    self.confirmQueueClear = now
                end
            end, m.smallSize)
    end
    if pagerH > 0 then
        cy = cy - pagerH
        local pw = self:w(70)
        local by = cy + (pagerH - bh) / 2
        self:button(x + pad, by, pw, bh, "<", C.chip, C.hover, C.text,
            self.queuePage > 1 and function() self.queuePage = self.queuePage - 1 end or nil, m.smallSize)
        self:button(x + width - pad - pw, by, pw, bh, ">", C.chip, C.hover, C.text,
            self.queuePage < pages and function() self.queuePage = self.queuePage + 1 end or nil, m.smallSize)
        self:textIn(x + width / 2, cy, pagerH, m.smallSize, string.format("%d / %d", self.queuePage, pages), C.muted,
            RenderText.ALIGN_CENTER)
    end
    if self.message then
        cy = cy - messageH
        self:textIn(x + pad, cy, messageH, m.smallSize, fit(self.message, m.smallSize, width - 2 * pad),
            self.messageIsError and C.danger or C.muted)
    end
end

-----------------------------------------------------------------------------------------------------------------------
-- Help: the ? at the top of the panel. A list of topics, and each topic's page; opened on the topic of where you are.
-----------------------------------------------------------------------------------------------------------------------

--- The topic for where the panel is: the tab, the helper job
function Hud:helpTopicFor()
    local view = self.view or "vehicle"
    if view == "team" then return "team" end
    if view == "library" or view == "queue" or view == "import" or view == "contracts" then return "saved" end
    if view == "settings" then return "settings" end
    if view == "fleet" then return "problems" end
    local vehicle = self.vehicle
    local kind = vehicle and self.helperKindFor and self:helperKindFor(vehicle)
    if kind == "unload" then return "harvest" end
    if kind == "bales" then return "grass" end
    if kind == "silo" or kind == "shovel" then return "loader" end
    if vehicle and vehicle.getGuidanceCourse and vehicle:getGuidanceCourse() == nil then return "start" end
    return "course"
end

function Hud:openHelp()
    if self.view == "help" then
        self.view = self.helpFrom or "vehicle"
        return
    end
    self.helpFrom = self.view or "vehicle"
    self.helpTopic = GuidanceHelp.index(self:helpTopicFor())
    self.view = "help"
end

function Hud:drawHelp()
    local C = Hud.C
    local m = self:metrics()
    local pad, width = m.pad, m.width
    local topics = GuidanceHelp.topics()
    local headH = self:h(34)
    local bw, bh = self:w(110), self:h(26)
    local topic = self.helpTopic and topics[self.helpTopic]
    local function back()
        self.view = self.helpFrom or "vehicle"
    end
    if topic == nil then
        -- the topics
        local rowH = self:h(30)
        local x, cy = self:drawFrame(m, headH + math.max(1, #topics) * rowH + self:h(6), t("guidance_help_title"))
        cy = cy - headH
        self:button(x + pad, cy + (headH - bh) / 2, bw, bh, "< " .. t("guidance_queue_back"), C.chip, C.hover, C.text, back,
            m.smallSize)
        for i, tp in ipairs(topics) do
            cy = cy - rowH
            local hover = self:isHover(x + pad, cy, width - 2 * pad, rowH)
            if hover then Draw.roundRect(x + pad, cy + self:h(2), width - 2 * pad, rowH - self:h(4), self:h(6), C.hover) end
            self:textIn(x + pad + self:w(8), cy, rowH, m.textSize, tp.title, C.text)
            self:textIn(x + width - pad - self:w(8), cy, rowH, m.textSize, ">", C.muted, RenderText.ALIGN_RIGHT)
            self:addElement(x + pad, cy, width - 2 * pad, rowH, function() self.helpTopic = i end)
        end
        return
    end
    -- a topic: its title and paragraphs, the one before and after
    local textW = width - 2 * pad
    local lineH = self:h(17)
    local gap = self:h(9)
    local lines, textH = {}, 0
    for k, p in ipairs(topic.paras) do
        lines[k] = math.max(1, self:countLines(p, m.smallSize, textW))
        textH = textH + lines[k] * lineH + gap
    end
    local titleH, navH = self:h(30), self:h(40)
    local x, cy = self:drawFrame(m, headH + titleH + textH + navH, t("guidance_help_title"))
    cy = cy - headH
    self:button(x + pad, cy + (headH - bh) / 2, bw, bh, "< " .. t("guidance_help_topics"), C.chip, C.hover, C.text,
        function() self.helpTopic = nil end, m.smallSize)
    self:button(x + width - pad - bw, cy + (headH - bh) / 2, bw, bh, t("guidance_queue_back"), C.chip, C.hover, C.text,
        back, m.smallSize)
    cy = cy - titleH
    self:textIn(x + pad, cy, titleH, m.textSize, fit(topic.title, m.textSize, textW, true), C.text, nil, true)
    for k, p in ipairs(topic.paras) do
        local h = lines[k] * lineH
        cy = cy - h
        self:textLines(x + pad, cy, h, m.smallSize, p, textW, C.text, lines[k])
        cy = cy - gap
    end
    cy = cy - navH
    local nw = (width - 2 * pad - self:w(6)) / 2
    local prev, nxt = topics[self.helpTopic - 1], topics[self.helpTopic + 1]
    self:button(x + pad, cy + (navH - bh) / 2, nw, bh,
        prev and fit("< " .. prev.title, m.smallSize, nw - self:w(10)) or "", prev and C.chip or C.pill, C.hover, C.text,
        prev and function() self.helpTopic = self.helpTopic - 1 end or nil, m.smallSize)
    self:button(x + width - pad - nw, cy + (navH - bh) / 2, nw, bh,
        nxt and fit(nxt.title .. " >", m.smallSize, nw - self:w(10)) or "", nxt and C.chip or C.pill, C.hover, C.text,
        nxt and function() self.helpTopic = self.helpTopic + 1 end or nil, m.smallSize)
end

--- What there is to import: CourseCorrect's course files, then Courseplay's courses of this map
function Hud.importList()
    local list = GuidanceLibrary.listExports()
    if GuidanceCourseplayImport then
        for _, item in ipairs(GuidanceCourseplayImport.list()) do list[#list + 1] = item end
    end
    return list
end

function Hud:drawImport()
    local vehicle = self.vehicle
    local C = Hud.C
    local m = self:metrics()
    local pad, width = m.pad, m.width
    local files = self.importFiles or {}
    local pages = math.max(1, math.ceil(#files / Hud.IMPORT_PAGE))
    self.importPage = math.max(1, math.min(pages, self.importPage or 1))
    local first = (self.importPage - 1) * Hud.IMPORT_PAGE + 1
    local shown = math.min(Hud.IMPORT_PAGE, #files - first + 1)
    local headH, hintH, rowH = self:h(34), self:h(36), self:h(36)
    local pagerH = pages > 1 and self:h(30) or 0
    local messageH = self.message and self:h(24) or 0
    local x, cy = self:drawFrame(m, headH + hintH + math.max(1, shown) * rowH + pagerH + messageH,
        t("guidance_import_title", #files))
    cy = cy - headH
    local bw, bh = self:w(110), self:h(26)
    self:button(x + pad, cy + (headH - bh) / 2, bw, bh, "< " .. t("guidance_folder_back"), C.chip, C.hover, C.text,
        function() self.view = "library" end, m.smallSize)
    self:button(x + width - pad - bw, cy + (headH - bh) / 2, bw, bh, t("guidance_import_refresh"), C.chip, C.hover, C.text,
        function() self.importFiles = Hud.importList() end, m.smallSize)
    cy = cy - hintH
    self:textLines(x + pad, cy, hintH, m.smallSize, t("guidance_import_hint"), width - 2 * pad, C.muted)
    if #files == 0 then
        cy = cy - rowH
        self:textIn(x + pad, cy, rowH, m.textSize, t("guidance_import_none"), C.muted)
    end
    for i = first, first + shown - 1 do
        local name = files[i]
        -- (a Courseplay course: {path, label})
        local cp = type(name) == "table" and name or nil
        local shownName = cp and t("guidance_import_courseplay", cp.label) or string.gsub(name, "%.xml$", "")
        cy = cy - rowH
        if i > first then Draw.rect(x + pad, cy + rowH, width - 2 * pad, self:h(1), C.line) end
        local iw = self:w(70)
        self:textIn(x + pad, cy, rowH, m.textSize, fit(shownName, m.textSize, width - 2 * pad - iw - self:w(8)), C.text)
        self:button(x + width - pad - iw, cy + (rowH - bh) / 2, iw, bh, t("guidance_import_one"), C.accent, C.accentHover,
            {1, 1, 1, 1}, function()
                local title, plan, outline
                if cp then
                    title, plan, outline = GuidanceCourseplayImport.read(cp.path)
                else
                    title, plan, outline = GuidanceLibrary.readExport(name)
                end
                name = cp and cp.label or name
                if plan then
                    GuidanceLibrary.importCourse(title, vehicle:getOwnerFarmId(), plan, outline)
                    self:showMessage(t("guidance_import_done", title), false)
                else
                    self:showMessage(t("guidance_import_bad", name), true)
                end
            end, m.smallSize)
    end
    if pagerH > 0 then
        cy = cy - pagerH
        local pw = self:w(70)
        local by = cy + (pagerH - bh) / 2
        self:button(x + pad, by, pw, bh, "<", C.chip, C.hover, C.text,
            self.importPage > 1 and function() self.importPage = self.importPage - 1 end or nil, m.smallSize)
        self:button(x + width - pad - pw, by, pw, bh, ">", C.chip, C.hover, C.text,
            self.importPage < pages and function() self.importPage = self.importPage + 1 end or nil, m.smallSize)
        self:textIn(x + width / 2, cy, pagerH, m.smallSize, string.format("%d / %d", self.importPage, pages), C.muted,
            RenderText.ALIGN_CENTER)
    end
    if self.message then
        cy = cy - messageH
        self:textIn(x + pad, cy, messageH, m.smallSize, fit(self.message, m.smallSize, width - 2 * pad),
            self.messageIsError and C.danger or C.muted)
    end
end

-----------------------------------------------------------------------------------------------------------------------
-- Alerts on the screen: a card for every helper of the farm that needs the player (stuck, full, out of fuel, ...),
-- the worst first, how long ago; a click goes to that vehicle. With none, a small line how many are working. The
-- player drags it by its top line anywhere; it can be switched off (My defaults).
-----------------------------------------------------------------------------------------------------------------------

Hud.ALERT_MAX = 5
Hud.ALERT_WIDTH = 290
-- what a status means: how bad (1 the worst), its colour
Hud.ALERT_KINDS = {
    IS_STUCK = {1, "danger"}, FUEL_IS_EMPTY = {1, "danger"}, NO_UNLOADER = {1, "danger"},
    NEEDS_UNLOADING = {2, "warn"}, NEEDS_FILLING = {2, "warn"}, NEXT_FIELD_WAITING = {2, "warn"},
    GIVING_WAY = {3, "warn"}, FUEL_IS_LOW = {3, "warn"}, WAITING_RAIN = {3, "warn"},
    FINISHED = {4, "accent"},
}
Hud.GIVING_WAY_ALERT = 15000 -- ms a helper gives way before it is worth an alert

local function sinceText(ms)
    local s = math.floor(ms / 1000)
    if s < 60 then return t("guidance_alert_now") end
    local m = math.floor(s / 60)
    if m < 60 then return string.format("%d min", m) end
    return string.format("%d h", math.floor(m / 60))
end

--- The alerts now: list of {vehicle, name, text, rank, color, since}, the worst and oldest first
function Hud:getAlerts()
    local C, now = Hud.C, g_time or 0
    self.alertSince = self.alertSince or {}
    self.alertDismissed = self.alertDismissed or {}
    local list = {}
    for _, v in ipairs(GuidanceMap.getFarmVehicles()) do
        local best
        local seen = {}
        for _, info in ipairs(v:getGuidanceInfoTexts()) do
            local kind = Hud.ALERT_KINDS[info.name]
            if kind then
                local key = tostring(v) .. info.name
                seen[key] = true
                self.alertSince[key] = self.alertSince[key] or now
                local age = now - self.alertSince[key]
                local wanted = not (info.name == "GIVING_WAY" and age < Hud.GIVING_WAY_ALERT)
                    and self.alertDismissed[key] == nil
                if wanted and (best == nil or kind[1] < best.rank) then
                    best = {vehicle = v, name = info.name, key = key, text = info.text, rank = kind[1], color = C[kind[2]],
                            since = age}
                end
            end
        end
        -- statuses gone: forget when they came, and that they were dismissed
        local prefix = tostring(v)
        for key in pairs(self.alertSince) do
            if key:sub(1, #prefix) == prefix and not seen[key] then
                self.alertSince[key], self.alertDismissed[key] = nil, nil
            end
        end
        if best then table.insert(list, best) end
    end
    table.sort(list, function(a, b)
        if a.rank ~= b.rank then return a.rank < b.rank end
        return a.since > b.since
    end)
    return list
end

function Hud:drawAlerts()
    self.alertElements = {}
    if GuidancePrefs and GuidancePrefs.alertsOnScreen == false then
        return
    end
    local C = Hud.C
    local alerts = self:getAlerts()
    local working = 0
    for _, v in ipairs(GuidanceMap.getFarmVehicles()) do
        if v:getIsGuidanceActive() then working = working + 1 end
    end
    if #alerts == 0 and working == 0 then
        self.alertBox = nil
        return
    end
    local width = self:w(Hud.ALERT_WIDTH)
    local headH, cardH, gap = self:h(26), self:h(46), self:h(6)
    local shown = math.min(#alerts, Hud.ALERT_MAX)
    local moreH = #alerts > shown and self:h(20) or 0
    local height = headH + shown * (cardH + gap) + moreH
    local x = GuidancePrefs and GuidancePrefs.alertsX or self:w(16)
    local top = GuidancePrefs and GuidancePrefs.alertsTop or 0.78
    x = math.max(0, math.min(1 - width, x))
    top = math.max(height, math.min(1, top))
    self.alertBox = {x = x, y = top - height, w = width, h = height, top = top}
    local smallSize, textSize = self:h(11), self:h(12.5)

    -- the top line: how many need the player, how many work (also the handle to move it)
    local cy = top - headH
    local pillW = width
    Draw.roundRect(x, cy, pillW, headH, headH / 2, C.bg)
    Draw.disc(x + self:w(14), cy + headH / 2, self:h(4), #alerts > 0 and alerts[1].color or C.accent)
    local head = #alerts > 0 and t("guidance_alert_need", #alerts) or t("guidance_alert_working", working)
    if #alerts > 0 and working > 0 then head = head .. " · " .. t("guidance_alert_working", working) end
    self:textIn(x + self:w(26), cy, headH, smallSize, fit(head, smallSize, pillW - self:w(36)), C.text, nil, true)
    self.alertGrip = {x = x, y = cy, w = pillW, h = headH}

    for i = 1, shown do
        local a = alerts[i]
        cy = cy - gap - cardH
        local hover = self:isHover(x, cy, width, cardH)
        Draw.roundRect(x - self:w(2), cy - self:h(3), width + self:w(4), cardH + self:h(3), self:h(10), C.shadow)
        Draw.roundRect(x, cy, width, cardH, self:h(9), hover and C.surface or C.bg)
        -- its colour as a bar on the left
        Draw.roundRect(x, cy, self:w(5), cardH, self:h(3), a.color)
        local tx = x + self:w(14)
        local closeW = a.name == "FINISHED" and self:w(22) or 0
        local sinceW = Draw.textWidth(smallSize, sinceText(a.since)) + self:w(8)
        local textW = width - (tx - x) - sinceW - closeW - self:w(8)
        self:textIn(tx, cy + cardH * 0.5, cardH * 0.45, textSize, fit(Guidance.vehicleName(a.vehicle), textSize, textW, true),
            C.text, nil, true)
        self:textIn(tx, cy + cardH * 0.08, cardH * 0.42, smallSize, fit(a.text, smallSize, width - (tx - x) - closeW - self:w(8)),
            a.color)
        self:textIn(x + width - closeW - self:w(8), cy + cardH * 0.5, cardH * 0.45, smallSize, sinceText(a.since), C.muted,
            RenderText.ALIGN_RIGHT)
        if closeW > 0 then
            local cx = x + width - closeW - self:w(4)
            local closeHover = self:isHover(cx, cy, closeW, cardH)
            self:textIn(cx + closeW / 2, cy, cardH, textSize, "×", closeHover and C.text or C.muted, RenderText.ALIGN_CENTER)
            table.insert(self.alertElements, {x = cx, y = cy, w = closeW, h = cardH, onClick = function()
                self.alertDismissed[a.key] = true
            end})
        end
        -- a click: to that vehicle, the panel open there
        table.insert(self.alertElements, {x = x, y = cy, w = width, h = cardH, onClick = function()
            if a.vehicle == currentVehicle() then
                self:open(a.vehicle)
            else
                self:goTo(a.vehicle)
            end
        end})
    end
    if moreH > 0 then
        cy = cy - moreH
        self:textIn(x + self:w(14), cy, moreH, smallSize, t("guidance_alert_more", #alerts - shown), C.muted)
    end
end

--- Clicks on the alerts (and moving them by their top line). True if it was theirs.
function Hud:alertMouseEvent(posX, posY, isDown, isUp, button)
    local inside = function(e) return posX >= e.x and posX <= e.x + e.w and posY >= e.y and posY <= e.y + e.h end
    if self.alertDrag then
        local d = self.alertDrag
        GuidancePrefs.alertsX, GuidancePrefs.alertsTop = d.x + posX - d.mouseX, d.top + posY - d.mouseY
        if isUp and button == Input.MOUSE_BUTTON_LEFT then
            self.alertDrag = nil
            GuidancePrefs.save()
        end
        return true
    end
    if not (isDown and button == Input.MOUSE_BUTTON_LEFT) then
        return false
    end
    for _, e in ipairs(self.alertElements or {}) do
        if inside(e) then
            e.onClick()
            return true
        end
    end
    if self.alertGrip and inside(self.alertGrip) and self.alertBox then
        self.alertDrag = {mouseX = posX, mouseY = posY, x = self.alertBox.x, top = self.alertBox.top}
        return true
    end
    return false
end

-----------------------------------------------------------------------------------------------------------------------
-- Course editor (on the Course tab's map): turn the rows, set where the course starts, leave rows out, mark areas
-- to work round. Every change is a setting of the course (the same on every machine) and makes it again.
-----------------------------------------------------------------------------------------------------------------------

Hud.EDIT_TOOLS = {"direction", "start", "skipRow", "zone", "move"}

--- Distance (screen, in height units) from p to the segment a-b
local function screenDist(px, py, ax, ay, bx, by)
    local dx, dy = (bx - ax) * g_screenAspectRatio, by - ay
    local qx, qy = (px - ax) * g_screenAspectRatio, py - ay
    local len2 = dx * dx + dy * dy
    local t = len2 > 0 and math.max(0, math.min(1, (qx * dx + qy * dy) / len2)) or 0
    local ex, ey = qx - dx * t, qy - dy * t
    return math.sqrt(ex * ex + ey * ey)
end

function Hud:drawEditor(vehicle, plot)
    local C = Hud.C
    local box = plot.box
    local plan = vehicle:getGuidancePlan() or vehicle:getGuidanceSettings()
    local course = plot.course
    if plan == nil then
        return
    end
    local red = {0.93, 0.36, 0.36, 0.9}
    local thick = self:h(2.4)
    -- rows left out: red, so they can be taken back
    for _, l in ipairs(course.skippedLines or {}) do
        local ax, ay = plot.toScreen(l.a.x, l.a.z)
        local bx, by = plot.toScreen(l.b.x, l.b.z)
        Draw.line(ax, ay, bx, by, thick, red)
    end
    -- areas worked round
    for _, zone in ipairs(plan:getSkipZones()) do
        local x1, y1 = plot.toScreen(zone[1].x, zone[1].z)
        local x2, y2 = plot.toScreen(zone[3].x, zone[3].z)
        Draw.rect(math.min(x1, x2), math.min(y1, y2), math.abs(x2 - x1), math.abs(y2 - y1), {0.93, 0.36, 0.36, 0.35})
    end
    -- points moved: a ring on each
    local wps = course.waypoints
    for _, m in ipairs(plan:getMoves()) do
        local w = wps[m.ix]
        if w then
            local sx, sy = plot.toScreen(w.x, w.z)
            Draw.disc(sx, sy, self:h(5), C.warn)
        end
    end
    -- the area being drawn, the direction being turned to
    local d = self.editDrag
    if d and d.tool == "move" and d.x2 then
        local w = wps[d.ix]
        local sx, sy = plot.toScreen(w.x, w.z)
        Draw.line(sx, sy, d.x2, d.y2, self:h(2), C.warn)
        Draw.disc(d.x2, d.y2, self:h(6), C.warn)
    end
    if d and d.tool == "zone" and d.x2 then
        Draw.rect(math.min(d.x1, d.x2), math.min(d.y1, d.y2), math.abs(d.x2 - d.x1), math.abs(d.y2 - d.y1),
            {0.98, 0.75, 0.25, 0.35})
    end
    -- the tools, along the bottom of the map; the map between them and the hint at the top
    local toolH = self:h(24)
    local areaY0, areaY1 = box.y + toolH + self:h(8), box.y + box.h - self:h(30)
    local cxs, cys = box.x + box.w / 2, (areaY0 + areaY1) / 2
    if self.editTool == "direction" then
        local deg = (d and d.tool == "direction" and d.angle) or (course.stats.rowAngle or 0)
        local a = math.rad(deg)
        -- rows run (cos a, sin a) in the world: on the map z is down
        local len = (areaY1 - areaY0) * 0.46
        local ux, uy = math.cos(a) / g_screenAspectRatio, -math.sin(a)
        Draw.line(cxs - ux * len, cys - uy * len, cxs + ux * len, cys + uy * len, self:h(3), C.warn)
        Draw.disc(cxs + ux * len, cys + uy * len, self:h(7), C.warn)
        Draw.disc(cxs - ux * len, cys - uy * len, self:h(7), C.warn)
        local label = string.format("%d°", math.floor(deg + 0.5))
        local lw, lh = Draw.textWidth(self:h(12), label, true) + self:w(12), self:h(20)
        Draw.roundRect(cxs - lw / 2, cys - lh / 2, lw, lh, lh / 2, C.bg)
        self:textIn(cxs, cys - lh / 2, lh, self:h(12), label, C.text, RenderText.ALIGN_CENTER, true)
    end
    local options = {}
    for _, tool in ipairs(Hud.EDIT_TOOLS) do table.insert(options, {tool, t("guidance_tool_" .. tool)}) end
    local ty = box.y + self:h(6)
    local tw = box.w - self:w(12)
    Draw.roundRect(box.x + self:w(6), ty, tw, toolH, toolH / 2, C.bg)
    local segW = tw / #options
    for k, o in ipairs(options) do
        local sx = box.x + self:w(6) + (k - 1) * segW
        local selected = self.editTool == o[1]
        if selected then
            Draw.roundRect(sx + self:w(2), ty + self:h(2), segW - self:w(4), toolH - self:h(4), (toolH - self:h(4)) / 2, C.accent)
        end
        self:textIn(sx + segW / 2, ty, toolH, self:h(10.5), o[2], selected and {1, 1, 1, 1} or C.text,
            RenderText.ALIGN_CENTER, selected)
        if not selected then
            self:addElement(sx, ty, segW, toolH, function() self.editTool = o[1] end)
        end
    end
    -- what the tool does, top left
    self:textIn(box.x + self:w(8), box.y + box.h - self:h(24), self:h(20), self:h(10.5),
        fit(t("guidance_toolHint_" .. self.editTool), self:h(10.5), box.w * 0.62), C.muted)
    -- undo the rows and areas left out
    if (plan.skipRows or "") ~= "" or (plan.skipZones or "") ~= "" or (plan.moves or "") ~= "" then
        local label = t("guidance_edit_clear")
        local bw, bh = Draw.textWidth(self:h(10.5), label, true) + self:w(14), self:h(20)
        self:button(box.x + self:w(6), ty + toolH + self:h(4), bw, bh, label, C.chip, C.hover, C.text, function()
            vehicle:guidanceApplySettings({skipRows = "", skipZones = "", moves = ""})
        end, self:h(10.5))
    end
    -- the map itself: clicks and drags (added last: the buttons on it come first)
    local mapEl = self:addElement(box.x, areaY0, box.w, areaY1 - areaY0)
    local tool = self.editTool
    if tool == "move" then
        -- a point of the course, dragged somewhere else
        mapEl.onDrag = function(px, py, phase)
            if phase == "start" then
                local best, bestD
                for i, w in ipairs(wps) do
                    local sx, sy = plot.toScreen(w.x, w.z)
                    local dd = math.sqrt(((sx - px) * g_screenAspectRatio) ^ 2 + (sy - py) ^ 2)
                    if bestD == nil or dd < bestD then best, bestD = i, dd end
                end
                self.editDrag = best and bestD < self:h(12) and {tool = tool, ix = best} or nil
                return
            end
            local e = self.editDrag
            if e == nil then return end
            e.x2, e.y2 = px, py
            if phase == "end" then
                self.editDrag = nil
                local wx, wz = plot.toWorld(px, py)
                vehicle:guidanceApplySettings({moves = plan:withMove(e.ix, wx, wz)})
            end
        end
    elseif tool == "direction" or tool == "zone" then
        mapEl.onDrag = function(px, py, phase)
            if tool == "direction" then
                local wx, wz = plot.toWorld(px, py)
                local cxw, czw = plot.toWorld(cxs, cys)
                local deg = math.deg(math.atan2(wz - czw, wx - cxw)) % 180
                deg = math.floor(deg / 5 + 0.5) * 5 % 180
                self.editDrag = {tool = tool, angle = deg}
                if phase == "end" then
                    self.editDrag = nil
                    vehicle:guidanceChangeSetting("rowAngle", deg)
                end
            else
                if phase == "start" then
                    self.editDrag = {tool = tool, x1 = px, y1 = py}
                else
                    self.editDrag.x2, self.editDrag.y2 = px, py
                end
                if phase == "end" then
                    local e = self.editDrag
                    self.editDrag = nil
                    if e.x2 and math.abs(e.x2 - e.x1) > 0.003 and math.abs(e.y2 - e.y1) > 0.003 then
                        local ax, az = plot.toWorld(e.x1, e.y1)
                        local bx, bz = plot.toWorld(e.x2, e.y2)
                        local zone = string.format("%.1f %.1f %.1f %.1f", ax, az, bx, bz)
                        local zones = (plan.skipZones or "") ~= "" and (plan.skipZones .. ";" .. zone) or zone
                        vehicle:guidanceApplySettings({skipZones = zones})
                    end
                end
            end
        end
    else
        mapEl.onClick = function(px, py)
            if tool == "start" then
                local wx, wz = plot.toWorld(px, py)
                vehicle:guidanceApplySettings({startX = wx, startZ = wz})
            else
                -- the row nearest the click (worked or left out)
                local best, bestD
                local wps = course.waypoints
                for i = 2, #wps do
                    local a, b = wps[i - 1], wps[i]
                    -- every piece of a row (curved rows have bends)
                    if a.line and a.line > 0 and b.line == a.line and not b.rs then
                        local ax, ay = plot.toScreen(a.x, a.z)
                        local bx, by = plot.toScreen(b.x, b.z)
                        local dd = screenDist(px, py, ax, ay, bx, by)
                        if bestD == nil or dd < bestD then best, bestD = a.line, dd end
                    end
                end
                for _, l in ipairs(course.skippedLines or {}) do
                    local ax, ay = plot.toScreen(l.a.x, l.a.z)
                    local bx, by = plot.toScreen(l.b.x, l.b.z)
                    local dd = screenDist(px, py, ax, ay, bx, by)
                    if bestD == nil or dd < bestD then best, bestD = l.line, dd end
                end
                if best and bestD < self:h(10) then
                    vehicle:guidanceApplySettings({skipRows = plan:toggleSkipRow(best)})
                end
            end
        end
    end
end

--- Is the mouse wheel ours now (over the open panel with the mouse ours, or a list open)? Then the camera doesn't zoom
function Hud:wantsWheel()
    if not self.isOpen or (self.minimized and not g_inputBinding:getShowMouseCursor()) then
        return false
    end
    if self.dropdown then return true end
    local b = self.box
    return b ~= nil and self.mouseX ~= nil and self:isHover(b.x, b.y, b.w, b.h)
end

-- the vehicle camera's zoom (the mouse wheel): not while the wheel scrolls a list or zooms our map
if VehicleCamera ~= nil and VehicleCamera.zoomSmoothly ~= nil and Utils ~= nil and Utils.overwrittenFunction ~= nil then
    VehicleCamera.zoomSmoothly = Utils.overwrittenFunction(VehicleCamera.zoomSmoothly, function(camera, superFunc, ...)
        local hud = Guidance and Guidance.hud
        if hud and hud.wantsWheel and hud:wantsWheel() then
            return
        end
        return superFunc(camera, ...)
    end)
end

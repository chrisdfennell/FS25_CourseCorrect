-- Guidance: what we need to know about a vehicle and its implements to plan and drive a course.
--   workWidth   width worked in one pass (m)
--   sideOffset  how far the middle of the work area is to the side of the vehicle (m, + = left)
--   turnRadius  smallest radius the vehicle with its implements can drive (m)
--   frontOffset distance from the guidance point (AI direction node) to the front of the work area, + = ahead
--   backOffset  same for the back of the work area (negative for implements behind the tractor)
--   canReverse  nothing is towed, the vehicle can back up along a path (three-point turns, square corners)
--   towLength   something is towed: how far behind the guidance point the middle of its work area is (else 0)

GuidanceVehicleInfo = {}
local VI = GuidanceVehicleInfo

VI.DEFAULT_WIDTH = 6
VI.DEFAULT_RADIUS = 6
VI.MIN_RADIUS, VI.MAX_RADIUS = 3, 20

local function try(fn, ...)
    if fn == nil then return false end
    local ok, a, b, c, d, e = pcall(fn, ...)
    if not ok then
        Guidance.debug("VehicleInfo: %s", tostring(a))
        return false
    end
    return true, a, b, c, d, e
end

--- Front, back, left and right of the work areas of all AI implements, relative to the direction node
local function measureMarkers(vehicle, node)
    local front, back, left, right
    if vehicle.updateAIFieldWorkerImplementData then
        try(vehicle.updateAIFieldWorkerImplementData, vehicle)
    end
    local implements = vehicle.getAttachedAIImplements and vehicle:getAttachedAIImplements() or {}
    for _, implement in pairs(implements) do
        local obj = implement.object
        if obj and obj.getAIMarkers then
            if obj.updateAIMarkerWidth then try(obj.updateAIMarkerWidth, obj) end
            local ok, leftMarker, rightMarker, backMarker = try(obj.getAIMarkers, obj)
            if ok and leftMarker and rightMarker then
                local xl, _, zl = localToLocal(leftMarker, node, 0, 0, 0)
                local xr, _, zr = localToLocal(rightMarker, node, 0, 0, 0)
                local zb = math.min(zl, zr)
                if backMarker then
                    local _, _, z = localToLocal(backMarker, node, 0, 0, 0)
                    zb = math.min(zb, z)
                end
                front = math.max(front or -math.huge, zl, zr)
                back = math.min(back or math.huge, zb)
                left = math.max(left or -math.huge, xl, xr)
                right = math.min(right or math.huge, xl, xr)
            end
        end
    end
    return front, back, left, right
end

--- Width and side offset as the game's own helper sees them
local function getGameCourseSettings(vehicle)
    if FieldCourseSettings == nil or FieldCourseSettings.generate == nil then
        return nil
    end
    local ok, settings = try(FieldCourseSettings.generate, vehicle)
    if ok and settings and settings.implementWidth and settings.implementWidth > 0.5 then
        return settings.implementWidth, settings.sideOffset or 0
    end
    return nil
end

local function getTurnRadius(vehicle)
    local radius = 0
    local ok, r = try(vehicle.getAIMinTurningRadius, vehicle)
    if ok and r then radius = math.max(radius, r) end
    if vehicle.maxTurningRadius then radius = math.max(radius, vehicle.maxTurningRadius) end
    -- towed implements may need more room, the game only tells us on the server
    if vehicle.isServer and AIVehicleUtil and AIVehicleUtil.getMaxToolRadius and vehicle.getAttachedAIImplements then
        for _, implement in pairs(vehicle:getAttachedAIImplements()) do
            local okTool, toolRadius = try(AIVehicleUtil.getMaxToolRadius, implement)
            if okTool and toolRadius then radius = math.max(radius, toolRadius) end
        end
    end
    if radius <= 0 then radius = VI.DEFAULT_RADIUS end
    return math.max(VI.MIN_RADIUS, math.min(VI.MAX_RADIUS, radius))
end

--- Is this implement towed (it has wheels and swings on its hitch), so backing up needs more than steering the
--- tractor? Three-point mounted implements lifted with a top link and headers are not.
local function isTowed(implement)
    local joint = implement.getActiveInputAttacherJoint and implement:getActiveInputAttacherJoint()
    if joint and AttacherJoints then
        local jt = joint.jointType
        if jt == AttacherJoints.JOINTTYPE_CUTTER or jt == AttacherJoints.JOINTTYPE_CUTTERHARVESTER then
            return false
        end
        if jt == AttacherJoints.JOINTTYPE_IMPLEMENT and joint.topReferenceNode ~= nil then
            return false
        end
    end
    local wheels = implement.spec_wheels and implement.spec_wheels.wheels
    return wheels ~= nil and #wheels > 0
end

local function canReverse(vehicle)
    if vehicle.getChildVehicles == nil then
        return false
    end
    for _, child in pairs(vehicle:getChildVehicles()) do
        if child ~= vehicle then
            local ok, towed = try(isTowed, child)
            if not ok or towed then
                return false
            end
        end
    end
    return true
end

--- How far the middle of the work area is to the left of the guidance point right now (plows move it when they
--- turn over), or nil without AI markers
function VI.measureSideOffset(vehicle)
    local node = vehicle.getAIDirectionNode and vehicle:getAIDirectionNode() or vehicle.rootNode
    local _, _, left, right = measureMarkers(vehicle, node)
    if left and right then
        return (left + right) / 2
    end
    return nil
end

function VI.get(vehicle)
    local info = {}
    local node = vehicle.getAIDirectionNode and vehicle:getAIDirectionNode() or vehicle.rootNode
    local front, back, left, right = measureMarkers(vehicle, node)
    local width, sideOffset = getGameCourseSettings(vehicle)
    if width == nil and left and right then
        width = left - right
        sideOffset = (left + right) / 2
    end
    info.hasImplement = front ~= nil
    info.workWidth = width or VI.DEFAULT_WIDTH
    info.sideOffset = sideOffset or 0
    info.frontOffset = front or 0
    info.backOffset = back or -3
    info.turnRadius = getTurnRadius(vehicle)
    info.canReverse = canReverse(vehicle)
    info.towLength = (not info.canReverse and front ~= nil) and math.max(0, -(info.frontOffset + info.backOffset) / 2) or 0
    -- after the end of a row, drive on until the back of the work area is out of it
    info.runOut = math.max(2, -info.backOffset + 0.5)
    return info
end

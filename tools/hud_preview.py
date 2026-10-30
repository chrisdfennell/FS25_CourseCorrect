"""Draws the CourseCorrect panel outside the game: the mod's own panel code runs (Lua 5.1 through lupa) on stand-ins for
the engine's drawing calls, which are recorded and painted with Pillow. For checking the layout and look.

Usage:
    python hud_preview.py <map.i3d> <field number> <out dir>
"""
import math
import os
import re
import sys
from pathlib import Path

from lupa import lua51
from PIL import Image, ImageDraw, ImageFont

sys.path.insert(0, str(Path(__file__).resolve().parent))
import field_preview as fp  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
W, H = 1920, 1080

STUBS = r"""
g_screenWidth, g_screenHeight, g_screenAspectRatio = 1920, 1080, 1920 / 1080
DRAW = {}
local overlays, state = {}, {color = {1, 1, 1, 1}, rot = 0, uvs = nil}
local text = {align = 0, bold = false, color = {1, 1, 1, 1}}
function createImageOverlay(path) table.insert(overlays, path) return #overlays end
function delete() end
function setOverlayColor(id, r, g, b, a) state.color = {r, g, b, a} end
function setOverlayRotation(id, rot, px, py) state.rot = rot end
function getIsOverlayReady() return true end
function setOverlayUVs(id, ...) state.uvs = {...} end
function renderOverlay(id, x, y, w, h)
    table.insert(DRAW, {kind = "overlay", tex = overlays[id], x = x, y = y, w = w, h = h, rot = state.rot,
                        color = state.color, uvs = overlays[id]:find("circle") and state.uvs or nil})
end
function setTextBold(b) text.bold = b end
function setTextAlignment(a) text.align = a end
function setTextColor(r, g, b, a) text.color = {r, g, b, a} end
function setTextWrapWidth() end
function renderText(x, y, size, s)
    table.insert(DRAW, {kind = "text", x = x, y = y, size = size, text = s, align = text.align, bold = text.bold,
                        color = text.color})
end
function getTextWidth(size, s) return TEXT_WIDTH(size, s, text.bold) end
function getNormalizedScreenValues(x, y) return x / 1920, y / 1080 end
g_gameSettings = {getValue = function() return 1 end}
g_time = 0
g_farmlandManager = {getFarmlandAtWorldPosition = function() return nil end}
g_fruitTypeManager = {getFruitTypeByIndex = function() return {seedUsagePerSqm = 0.02} end}
RenderText = {ALIGN_LEFT = 0, ALIGN_CENTER = 1, ALIGN_RIGHT = 2}
Input = {MOUSE_BUTTON_LEFT = 1}
Utils = {getFilename = function(f, dir) return dir .. f end}
Guidance = {MOD_DIR = "", TITLE = "CourseCorrect", debug = function() end, info = function() end,
            vehicleName = function(v) return v:getName() end}
function getWorldTranslation(n) return n.x, 0, n.z end
function localDirectionToWorld(n) return math.cos(n.h), 0, math.sin(n.h) end
getUserProfileAppPath = nil
"""

SCENE = r"""
function makeScene(course, mode, showMore)
    -- the Course tab before a start, with its More settings open
    if mode == "more" then mode = "ready" end
    local plan = GuidancePlan.new()
    plan.workWidth, plan.turnRadius, plan.autoWidth = 6, 6, true
    local active = mode ~= "ready" and mode ~= "library" and mode ~= "folders" and mode ~= "recording"
        and mode:sub(1, 4) ~= "set_" and mode:sub(1, 4) ~= "edit" and mode ~= "otherHelper"
        and mode:sub(1, 6) ~= "helper" and mode ~= "jobswitch"
    local wps = course.waypoints
    local progressIx = active and math.floor(#wps * 0.45) or 1
    local p = wps[progressIx]
    local q = wps[math.min(progressIx + 1, #wps)]
    local node = {x = p.x, z = p.z, h = math.atan2(q.z - p.z, q.x - p.x)}
    local v = {rootNode = node}
    function v:getGuidanceCourse() return course end
    function v:getGuidanceSettings() return plan end
    function v:getIsGuidanceActive() return active end
    function v:getIsGuidancePaused() return mode == "paused" end
    function v:getIsAIActive() return active or mode == "otherHelper" end
    function v:getIsHelperDriving() return active or mode == "otherHelper" end
    function v:getGuidanceProgress() return progressIx, course.waypoints[progressIx].d / course.length end
    function v:getGuidanceInfoTexts() return {} end
    function v:getGuidanceError() return nil end
    function v:getName() return "Magnum 400 PowerDrive" end
    function v:getSpeedLimit() return 12 end
    function v:getGuidanceWorkSpeed() return 12 end
    function v:getGuidancePlan() return (mode == "set_field" or mode:sub(1, 4) == "edit") and plan or nil end
    function v:getGuidanceTimes()
        local times = course:getTimes(12)
        return times[#times], times[#times] - times[progressIx]
    end
    function v:getGuidanceQueue() return QUEUE or {} end
    -- a seeder with 900 l seed, a tractor with 300 l diesel
    v.spec_motorized = {consumers = {{usage = 60, fillUnitIndex = 1, fillType = 1}}}
    v.spec_sowingMachine = {fillUnitIndex = 2, seeds = {1}, currentSeed = 1}
    -- and 400 l fertiliser in its own tank
    v.spec_sprayer = {usageScale = {default = 1, workingWidth = 6}}
    function v:getSprayerFillUnitIndex() return 3 end
    function v:getFillUnitFillType(ix) return 7 end
    g_fillTypeManager = {getFillTypeByIndex = function() return {title = "Fertilizer", name = "FERTILIZER"} end}
    g_sprayTypeManager = {getSprayTypeByFillTypeIndex = function() return {litersPerSecond = 0.0081} end}
    function v:getFillUnitFillLevel(ix) return ix == 1 and 300 or ix == 3 and 400 or 900 end
    -- the farm's vehicles for the fleet view: this one and two more
    local function other(name, isActive, isPaused, frac, info, noCourse)
        local o = {rootNode = node, spec_guidance = {}, spec_enterable = {}}
        function o:getGuidanceCourse() return (not noCourse) and course or nil end
        function o:getIsEnterableFromMenu() return true end
        local oplan = GuidancePlan.new()
        oplan.workWidth = 6
        function o:getGuidanceSettings() return oplan end
        function o:getGuidancePlan() return (not noCourse) and oplan or nil end
        o.teamPlan = oplan
        function o:getIsGuidanceActive() return isActive end
        function o:getIsGuidancePaused() return isPaused end
        function o:getIsAIActive() return isActive end
        function o:getIsHelperDriving() return isActive end
        function o:getGuidanceProgress() return 1, frac end
        function o:getGuidanceInfoTexts() return info or {} end
        function o:getName() return name end
        function o:getOwnerFarmId() return 1 end
        function o:getGuidanceTimes() return 6000, 6000 * (1 - frac) end
        return o
    end
    v.spec_guidance = {}
    function v:getOwnerFarmId() return 1 end
    g_currentMission = {getFarmId = function() return 1 end, vehicleSystem = {vehicles = {v,
        other("Fendt 1050 Vario with Lizard SM 82", true, true, 0.31),
        other("New Holland CR11", false, false, 1, {{name = "FINISHED", text = "Course finished"}}),
        other("John Deere 8R 410", true, false, 0.82)}}}
    local hud = GuidanceHud.new()
    hud.isOpen, hud.vehicle, hud.showMore = true, v, showMore
    if mode == "log" then
        hud.view, hud.fleetView = "fleet", "log"
        GuidanceLibrary.fieldName = function(id) return "Field " .. id end
        GuidanceLibrary.stats = {
            {fieldId = 9, vehicle = "Magnum 400 PowerDrive", farmId = 1, area = 56400, seconds = 3360, fuel = 41.2, day = {day = 12, hour = 14, minute = 30}},
            {fieldId = 12, vehicle = "Fendt 1050 Vario", farmId = 1, area = 182000, seconds = 9300, fuel = 160, day = {day = 12, hour = 17, minute = 5}},
            {fieldId = 3, vehicle = "John Deere 8R 410", farmId = 1, area = 43000, seconds = 2500, fuel = 30.5, day = {day = 13, hour = 8, minute = 45}},
        }
    end
    if mode == "import" then
        hud.view, hud.importFiles = "import", {"Field 9 - plowing.xml", "Field 12 - sowing 12 m.xml", "Steves meadow.xml"}
    end
    if mode == "team" then
        hud.view = "team"
        hud.fieldHere, hud.fieldHereVehicle, hud.fieldHereTime = 9, v, 0
        local list = g_currentMission.vehicleSystem.vehicles
        -- a convoy of three on field 9: this tractor leads, two more; and one other tractor not in it
        plan.fieldId, plan.teamMode, plan.teamSize, plan.teamIndex = 9, GuidancePlan.TEAM_CONVOY, 3, 1
        function v:getGuidancePlan() return plan end
        for k = 2, 3 do
            local o = list[k]
            o.teamPlan.fieldId, o.teamPlan.teamMode, o.teamPlan.teamSize, o.teamPlan.teamIndex = 9, GuidancePlan.TEAM_CONVOY, 3, k
        end
        list[2].teamPlan.workWidth = 9
        GuidanceLibrary.fieldName = function(id) return "Field " .. id end
    end
    if mode == "fleet" then
        hud.view = "fleet"
        -- a big fleet like a real one: most without a course; we sit in the Magnum
        local list = g_currentMission.vehicleSystem.vehicles
        for _, name in ipairs({"6R 250", "AF11", "Apache 1958", "Big X 1180", "Condor Endurance II", "DT 2800H S5",
                               "FH16 780", "M1240", "PHOENIX 6x6 Agro-Truck", "Steiger 715 Quadtrac", "T-Rex"}) do
            table.insert(list, other(name, false, false, 0, nil, true))
        end
        g_localPlayer = {requestToEnterVehicle = function() end, getCurrentVehicle = function() return v end}
        v.spec_enterable = {}
    end
    if mode == "library" then
        hud.view = "library"
        GuidanceLibrary.entries = {}
        for i, name in ipairs({"Field 9 · 6.0 m", "Field 9 · Lizard SM 82 ploughing", "Field 12 · sowing",
                               "Field 3 · 12.3 m cultivator", "Field 27 · combine"}) do
            local e = GuidanceLibrary.newEntry(name, 1, plan, course)
            e.id = i
            e.plan.fieldId = i <= 2 and 9 or 10 + i
            table.insert(GuidanceLibrary.entries, e)
        end
        hud.fieldHere, hud.fieldHereVehicle, hud.fieldHereTime = 9, v, 0
    end
    if mode == "folders" then
        hud.view = "library"
        hud.libraryFolderChosen = true
        hud.fieldHere, hud.fieldHereVehicle, hud.fieldHereTime = 9, v, 0
    end
    if mode:sub(1, 4) == "set_" then
        hud.view = "settings"
        hud.settingsScope = ({set_tractor = "tractor", set_field = "field", set_user = "user"})[mode]
        if mode == "set_tractor" then
            plan.teamMode, plan.teamSize, plan.teamIndex = GuidancePlan.TEAM_STRIPS, 3, 2
            -- shown as a combine: the unloader row appears
            v.spec_combine, v.spec_pipe = {fillUnitIndex = 1}, {}
            plan.toolOffsetX = -0.3
        end
        hud.fieldHere, hud.fieldHereVehicle, hud.fieldHereTime = 9, v, 0
        plan.fieldId = 9
        if mode == "set_field" then
            GuidanceLibrary.fieldSettings[9] = {headlands = 4, rowAngle = 35, clockwise = false, headlandsFirst = true,
                                                pattern = 2, roundedPasses = 2}
        end
    end
    if mode == "edit" then
        -- the course editor: rows 3 and 4 left out, one area worked round, the row tool picked; the course made again
        hud.editing, hud.editTool = true, "skipRow"
        plan.autoWidth = false
        plan.skipRows = "3 4"
        local p = course.waypoints[math.floor(#course.waypoints * 0.6)]
        plan.skipZones = string.format("%.1f %.1f %.1f %.1f", p.x - 15, p.z - 10, p.x + 15, p.z + 10)
        local settings = plan:getGeneratorSettings()
        settings.islands = plan:getSkipZones()
        local result = GuidanceCourseGenerator.generate(course.outline, settings)
        course = GuidanceCourse.new(result, plan, course.outline)
    end
    if mode == "edit_direction" then
        hud.editing, hud.editTool = true, "direction"
    end
    if mode == "details" then
        hud.showDetails = true
        QUEUE = {2, 3}
    end
    if mode == "recording" then
        -- three sides of a meadow driven so far
        local pts, len = {}, 0
        local corners = {{0, 0}, {160, 0}, {170, 90}, {40, 100}}
        for c = 1, 3 do
            local a, b = corners[c], corners[c + 1]
            for k = 0, 19 do
                local f = k / 20
                local q = {x = a[1] + (b[1] - a[1]) * f, z = a[2] + (b[2] - a[2]) * f}
                if #pts > 0 then len = len + math.sqrt((q.x - pts[#pts].x) ^ 2 + (q.z - pts[#pts].z) ^ 2) end
                table.insert(pts, q)
            end
        end
        hud.recording = {vehicle = v, points = pts, length = len}
    end
    hud.mouseX, hud.mouseY = -1, -1
    DRAW = {}
    -- helpers without a course
    function v:getGuidanceHelperKinds() return {} end
    function v:getGuidanceHelperKind() return nil end
    function v:getGuidanceHelperPhase() return nil end
    local helperModes = {helper_unload = {"unload"}, helper_unloadRun = {"unload", "unloadFollow"},
                         helper_bales = {"bales"}, helper_siloRun = {"silo", "siloWait"}}
    local hm = helperModes[mode]
    if hm then
        function v:getGuidanceHelperKinds() return {hm[1]} end
        function v:getGuidanceCourse() return nil end
        GuidanceVehicleInfo = {get = function() return {hasImplement = false} end}
        local station = {owningPlaceable = {getName = function() return "Grain elevator (Riverside)" end},
                         getAITargetPositionAndDirection = function() return 100, 200, 1, 0 end,
                         getAISupportedFillTypes = function() return {[1] = true} end}
        g_currentMission.storageSystem = {getUnloadingStations = function() return {station} end}
        g_currentMission.accessHandler = {canFarmAccess = function() return true end}
        UnloadingStation = nil
        plan.unloadX, plan.unloadZ, plan.unloadFull = 100, 200, 95
        if hm[2] then
            function v:getGuidanceHelperKind() return hm[1] end
            function v:getGuidanceHelperPhase() return hm[2] end
            function v:getIsGuidanceActive() return true end
            function v:getIsAIActive() return true end
        end
    end
    if mode == "jobswitch" then
        function v:getGuidanceHelperKinds() return {"silo"} end
        GuidanceVehicleInfo = {get = function() return {hasImplement = true} end}
    end
    if mode == "alerts" then
        -- the farm's helpers: one stuck, one full, one finished, two working; nothing on the panel
        local list = g_currentMission.vehicleSystem.vehicles
        local function infos(...)
            local out = {}
            for _, n in ipairs({...}) do out[#out + 1] = {name = n, text = TEXTS["guidance_info_" .. n] or n} end
            return function() return out end
        end
        list[2].getGuidanceInfoTexts = infos("IS_STUCK")
        list[3].getGuidanceInfoTexts = infos("FINISHED")
        list[4].getGuidanceInfoTexts = infos("NEEDS_UNLOADING")
        g_time = 600000
        hud.alertSince = {[tostring(list[2]) .. "IS_STUCK"] = 600000 - 4 * 60000,
                          [tostring(list[3]) .. "FINISHED"] = 600000 - 22 * 60000,
                          [tostring(list[4]) .. "NEEDS_UNLOADING"] = 600000 - 30000}
        hud.isOpen = false
        hud:drawAlerts()
        return DRAW, hud.alertBox
    end
    hud:draw()
    return DRAW, hud.box
end
"""


def load_texts():
    xml = (ROOT / "translations/translation_en.xml").read_text(encoding="utf-8")
    return {m.group(1): m.group(2).replace("&amp;", "&") for m in re.finditer(r'name="([^"]+)" text="([^"]*)"', xml)}


def font(size_px, bold):
    try:
        return ImageFont.truetype("segoeuib.ttf" if bold else "segoeui.ttf", max(1, int(round(size_px))))
    except OSError:
        return ImageFont.load_default(size=max(1, int(round(size_px))))


ROT_SQUEEZE = float(os.environ.get("ROT_SQUEEZE", "1"))
ARROW = Image.open(Path(__file__).resolve().parent / "arrow_preview.png").convert("RGBA")


def paint(draws, background):
    img = background.copy().convert("RGBA")
    for d in draws.values():
        layer = Image.new("RGBA", img.size, (0, 0, 0, 0))
        g = ImageDraw.Draw(layer)
        c = d.color
        rgba = tuple(int(round(255 * max(0, min(1, c[i])))) for i in (1, 2, 3, 4))
        if d.kind == "overlay" and d.tex.endswith("arrow.dds"):
            w, h = int(round(d.w * W)), int(round(d.h * H))
            sprite = ARROW.resize((max(1, w), max(1, h)), Image.LANCZOS).rotate(math.degrees(d.rot), expand=False)
            layer.paste(sprite, (int(round(d.x * W)), int(round((1 - d.y) * H - h))), sprite)
        elif d.kind == "overlay":
            x0, y1 = d.x * W, (1 - d.y) * H
            w, h = d.w * W, d.h * H
            if d.uvs is not None:
                u0, v0, u1, v1 = d.uvs[1], d.uvs[2], d.uvs[5], d.uvs[4]
                # the part of the disc in this box: scale the whole disc so that part fills it
                full_w, full_h = w / (u1 - u0), h / (v1 - v0)
                left = x0 - u0 * full_w
                top = y1 - h - (1 - v1) * full_h
                g.ellipse([left, top, left + full_w, top + full_h], fill=rgba)
                mask = Image.new("L", img.size, 0)
                ImageDraw.Draw(mask).rectangle([x0, y1 - h, x0 + w, y1], fill=255)
                layer.putalpha(Image.composite(layer.getchannel("A"), Image.new("L", img.size, 0), mask))
            elif abs(d.rot) > 1e-6:
                # a line: rotated about its left end, middle of its height
                cx, cy = x0, y1 - h / 2
                ang = d.rot
                ux, uy = math.cos(ang), -math.sin(ang) * (H / W) * (W / H)
                # rotation is in screen space (width scaled by the aspect ratio): undo that for pixels
                length = w
                dx, dy = math.cos(ang) * length, -math.sin(ang) * length * (W / H) / (W / H)
                # ROT_SQUEEZE imitates a screen where the game turns overlays in another pixel shape
                ex, ey = cx + math.cos(ang) * length, cy - math.sin(ang) * length * ROT_SQUEEZE
                g.line([cx, cy, ex, ey], fill=rgba, width=max(1, int(round(h))))
            else:
                g.rectangle([x0, y1 - h, x0 + w, y1], fill=rgba)
        else:
            f = font(d.size * H, d.bold)
            anchor = {0: "ls", 1: "ms", 2: "rs"}.get(int(d.align), "ls")
            g.text((d.x * W, (1 - d.y) * H), d.text, font=f, fill=rgba, anchor=anchor)
        img = Image.alpha_composite(img, layer)
    return img


def main():
    i3d, field, out = sys.argv[1], f"field{sys.argv[2]}", Path(sys.argv[3])
    out.mkdir(parents=True, exist_ok=True)
    texts = load_texts()
    lua = lua51.LuaRuntime(unpack_returned_tuples=True)
    lua.execute(STUBS)
    lua.globals().g_i18n = lua.table_from({"getText": lambda _self, key: texts.get(key, key)})
    lua.globals().TEXTS = lua.table_from(texts)

    def text_width(size, s, bold):
        return font(size * H, bold).getlength(s) / W
    lua.globals().TEXT_WIDTH = text_width
    for rel in ["scripts/Prefs.lua", "scripts/ai/Team.lua", "scripts/geometry/Geo.lua", "scripts/geometry/Dubins.lua", "scripts/course/CourseGenerator.lua",
                "scripts/course/Course.lua", "scripts/course/Library.lua", "scripts/ai/Planner.lua", "scripts/ai/Trips.lua",
                "scripts/gui/GuidanceDraw.lua",
                "scripts/gui/GuidanceMap.lua",
                "scripts/gui/GuidanceHud.lua"]:
        lua.execute((ROOT / rel).read_text(encoding="utf-8"))
    if os.environ.get("LINE_PIECE"):
        lua.execute("GuidanceDraw.LINE_PIECE = " + os.environ["LINE_PIECE"])
    # the driver isn't loaded here: its harvester check, as it is
    lua.execute("GuidanceFieldworkDriver = {findHarvester = function(v) return v.spec_combine and v.spec_pipe and v or nil end}")
    lua.execute(SCENE)
    pts = fp.read_fields(i3d)[field]
    outline = lua.table_from([lua.table_from({"x": x, "z": z}) for x, z in pts])
    plan = lua.globals().GuidancePlan.new()
    res = lua.globals().GuidanceCourseGenerator.generate(outline, plan.getGeneratorSettings(plan))
    result = res[0] if isinstance(res, tuple) else res
    course = lua.globals().GuidanceCourse.new(result, plan, outline)
    # a blurry field-ish background, like the game behind the panel
    bg = Image.new("RGB", (W, H), (70, 62, 40))
    bgd = ImageDraw.Draw(bg)
    for i in range(0, W, 40):
        bgd.line([i, 0, i - 300, H], fill=(84, 74, 48), width=18)
    for mode, more in (("ready", False), ("working", False), ("paused", True), ("fleet", False),
                       ("library", False), ("folders", False), ("details", False),
                       ("recording", False), ("set_tractor", False), ("set_field", False), ("set_user", False), ("otherHelper", False), ("team", False), ("log", False), ("import", False), ("alerts", False),
                       ("edit", False), ("edit_direction", False), ("more", True),
                       ("helper_unload", False), ("helper_unloadRun", False), ("helper_bales", False),
                       ("helper_siloRun", False), ("jobswitch", False)):
        draws, box = lua.globals().makeScene(course, mode, more)
        img = paint(draws, bg)
        x0, y0 = box.x * W - 20, (1 - box.y - box.h) * H - 20
        img.crop((int(x0), int(max(0, y0)), int(x0 + box.w * W + 40), int((1 - box.y) * H + 20))).save(
            out / f"panel_{mode}.png")
        print("written", out / f"panel_{mode}.png")


if __name__ == "__main__":
    main()

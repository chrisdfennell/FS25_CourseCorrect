"""Checks offline the editor's moved points, the problem report and the debug overlay:

- a moved point is where the editor put it, its neighbours along the course follow (less further away), points
  further than the reach stay; the moves go over the network and into the savegame with the plan; any other change of
  the course drops them, a new course starts without them;
- the problem report has the version, the vehicle, its settings and the mod's last log lines, and is written through
  the game's file functions;
- the overlay draws a working helper's way, its target and its text.

Usage:
    python support_test.py <map.i3d> [field number]
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import field_preview as fp  # noqa: E402
import helpers_test  # noqa: E402
import smoke_test  # noqa: E402

LUA = r"""
function checkSupport(flat)
    local r = {}
    makeField(7, flat)
    local v = makeVehicle(flat[1] + 30, flat[2] + 30, 0, "Test tractor")
    g_currentMission.vehicleSystem = {vehicles = {v}}
    local ok, err = v:guidanceGenerate()
    assert(ok, "generate: " .. tostring(err))
    local course = v:getGuidanceCourse()
    local wps = course.waypoints
    -- a point in the middle of a long stretch
    local ix = math.floor(#wps / 2)
    local before = {}
    for i, w in ipairs(wps) do before[i] = {x = w.x, z = w.z, d = w.d} end
    local plan = v:getGuidancePlan()
    local tx, tz = wps[ix].x + 4, wps[ix].z - 3
    v:guidanceApplySettings({moves = plan:withMove(ix, tx, tz)})
    local moved = v:getGuidanceCourse().waypoints
    local function dist(a, b) return math.sqrt((a.x - b.x) ^ 2 + (a.z - b.z) ^ 2) end
    r.movedThere = math.abs(moved[ix].x - tx) < 0.01 and math.abs(moved[ix].z - tz) < 0.01
    -- neighbours: within reach moved less, beyond unmoved
    local nearOk, farOk = true, true
    for i = 1, #moved do
        local along = math.abs(before[i].d - before[ix].d)
        local shift = dist(moved[i], before[i])
        if along >= GuidanceCourse.MOVE_REACH and shift > 1e-6 then farOk = false end
        if along > 0.5 and along < GuidanceCourse.MOVE_REACH and shift > dist(moved[ix], before[ix]) + 1e-6 then nearOk = false end
    end
    r.neighbours = nearOk and farOk
    -- over the network and into the savegame
    local stream = {}
    v:getGuidancePlan():writeStream(stream)
    local copy = GuidancePlan.readStream(stream)
    r.streamed = copy.moves == v:getGuidancePlan().moves and copy.moves ~= ""
    -- another change drops them
    v:guidanceApplySettings({headlands = 3})
    r.dropped = (v:getGuidancePlan().moves or "") == ""
    -- a new course starts without them
    v:guidanceApplySettings({moves = v:getGuidancePlan():withMove(ix, tx, tz)})
    v:guidanceGenerate()
    r.newCourse = (v:getGuidancePlan().moves or "") == ""

    -- the problem report
    Guidance.info("a test line for the report")
    local text = GuidanceDebug.reportText(v)
    r.report = text:find(Guidance.VERSION, 1, true) ~= nil and text:find("Test tractor", 1, true) ~= nil
        and text:find("workWidth =", 1, true) ~= nil and text:find("a test line for the report", 1, true) ~= nil
    WRITTEN = nil
    getUserProfileAppPath = function() return "profile/" end
    createFolder = function() end
    FileAccess = {WRITE = 2}
    createFile = function(path, mode) return {path = path} end
    fileWrite = function(f, s) WRITTEN = {path = f.path, text = s} end
    delete = delete or function() end
    local path = GuidanceDebug.writeReport(v)
    r.written = path ~= nil and WRITTEN ~= nil and WRITTEN.path:find("modSettings/FS25_CourseCorrect/report.txt", 1, true) ~= nil
        and #WRITTEN.text > 200
    REPORT = text

    -- the overlay: a helper working, lines and text drawn
    local LINES, TEXTS = 0, 0
    drawDebugLine = function() LINES = LINES + 1 end
    Utils = Utils or {}
    Utils.renderTextAtWorldPosition = function() TEXTS = TEXTS + 1 end
    v.getIsGuidanceActive = function() return true end
    v.spec_guidance.driver = {state = 3, follower = GuidancePathFollower.new({{x = 0, z = 0, t = "C"}, {x = 50, z = 0, t = "R", work = true}}),
                              debugTarget = {10, 0, 12}}
    GuidanceDebug.drawVehicle(v, v.spec_guidance, 0, 0)
    r.overlay = LINES >= 3 and TEXTS >= 3
    v.spec_guidance.driver = nil
    return r
end
"""


def main():
    i3d = sys.argv[1]
    field = f"field{sys.argv[2] if len(sys.argv) > 2 else 9}"
    fields = fp.read_fields(i3d)
    flat = [c for p in fields[field] for c in p]
    lua = smoke_test.fresh_lua(fields, field)
    lua.execute(helpers_test.LUA)
    lua.execute(LUA)
    r = lua.globals().checkSupport(lua.table_from(flat))
    ok = True
    for name in ("movedThere", "neighbours", "streamed", "dropped", "newCourse", "report", "written", "overlay"):
        good = bool(r[name])
        ok = ok and good
        print(f"{name}: {'OK' if good else 'FAILED'}")
    print("OK" if ok else "FAILED")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()

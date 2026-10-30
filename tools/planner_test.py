"""Checks offline what a course takes (scripts/ai/Planner.lua): seed and the seeder's fertiliser by the game's own
rates; with Precision Farming its seed rates (the one set, or the best for each spot's soil, from its real
PrecisionFarming.xml) and its fertiliser and lime by what each spot still needs (stand-in maps with known numbers);
everything that runs out listed, the first first.

Usage:
    python planner_test.py <map.i3d> <PrecisionFarming.xml> [field number]
"""
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import field_preview as fp  # noqa: E402
import smoke_test  # noqa: E402

LUA = r"""
function makeCourse(flat)
    local pts = {}
    for i = 1, #flat - 1, 2 do pts[#pts + 1] = {x = flat[i], z = flat[i + 1]} end
    local plan = GuidancePlan.new()
    plan.workWidth, plan.turnRadius, plan.autoWidth, plan.runOut = 6, 6, false, 3
    plan.fieldId = 0
    local result = GuidanceCourseGenerator.generate(pts, plan:getGeneratorSettings())
    return GuidanceCourse.new(result, plan, pts)
end

WHEAT, FERTILIZER, LIME = 2, 7, 9
g_fruitTypeManager = {getFruitTypeByIndex = function(_, i) return {name = "WHEAT", seedUsagePerSqm = 0.0308} end}
g_fillTypeManager = {getFillTypeByIndex = function(_, i)
    if i == FERTILIZER then return {title = "Fertilizer", name = "FERTILIZER"} end
    if i == LIME then return {title = "Lime", name = "LIME"} end
    return {title = "?", name = "?"}
end}
g_sprayTypeManager = {getSprayTypeByFillTypeIndex = function() return {litersPerSecond = 0.0081} end}
FillType = {UNKNOWN = 0, DEF = 99}

--- a seeder (wheat) with a fertiliser tank: seed in unit 1, fertiliser (or lime) in unit 2
function makeSeeder(seed, fert, fillType)
    local v = {}
    v.spec_sowingMachine = {fillUnitIndex = 1, seeds = {WHEAT}, currentSeed = 1}
    v.spec_sprayer = {usageScale = {default = 1, workingWidth = 6}}
    function v:getSprayerFillUnitIndex() return 2 end
    function v:getFillUnitFillType(ix) return ix == 2 and (fillType or FERTILIZER) or 0 end
    function v:getFillUnitFillLevel(ix) return ix == 1 and seed or fert end
    return v
end

--- Precision Farming stand-ins: soil 1 west of x0, soil 3 east; nitrogen 4 west, 10 east (target 10 everywhere);
--- pH 2 west, 6 east (optimal 6); 20 l/ha per nitrogen state, 300 l/ha per pH state
function setPF(x0)
    g_modIsLoaded.FS25_precisionFarming = true
    local soilMap = {getTypeIndexAtWorldPos = function(_, x, z) return x < x0 and 1 or 3 end}
    g_precisionFarming = {soilMap = soilMap}
    PF_EXT = {
        soilMap = soilMap,
        nitrogenMap = {
            getLevelAtWorldPos = function(_, x, z) return x < x0 and 4 or 10 end,
            getNitrogenTargetLevel = function(_, fruit, soil) return 10 end,
            getFertilizerUsageByStateChange = function(_, states, ft) return states * 20 end,
        },
        pHMap = {
            getLevelAtWorldPos = function(_, x, z) return x < x0 and 2 or 6 end,
            getOptimalPHValueForSoilTypeIndex = function(_, soil) return 6 end,
            getLimeUsageByStateChange = function(_, states) return states * 300 end,
        },
        sprayAmountAutoMode = true, sprayAmountManual = 3, lastLitersPerHectar = 0,
    }
    FS25_precisionFarming = {ExtendedSprayer = {getCurrentSprayerMode = function(v)
        local ft = v:getFillUnitFillType(2)
        return ft == LIME, ft == FERTILIZER
    end}}
end

function withPF(v, seedAuto, seedRate)
    v["spec_FS25_precisionFarming.extendedSprayer"] = PF_EXT
    v["spec_FS25_precisionFarming.extendedSowingMachine"] = {seedRateAutoMode = seedAuto, manualSeedRate = seedRate}
    return v
end

function find(list, kind)
    for _, item in ipairs(list) do if item.kind == kind then return item end end
end

--- share of the sample points west of x0 (soil 1, nitrogen 4, pH 2)
function westShare(course, x0)
    local w, n = 0, 0
    local nextD, step = 0, math.max(GuidancePlanner.SAMPLE_STEP, course.stats.workLength / GuidancePlanner.MAX_SAMPLES)
    for _, p in ipairs(course.waypoints) do
        if (p.d or 0) >= nextD and (p.t == "R" or p.t == "H") then
            n = n + 1
            if p.x < x0 then w = w + 1 end
            nextD = (p.d or 0) + step
        end
    end
    return w / n
end
"""


def xml_stubs(lua, pf_xml):
    root = ET.parse(pf_xml).getroot()

    def resolve(key):
        path, _, attr = key.partition("#")
        parts = path.split(".")
        if parts[0] != root.tag:
            return None
        node = root
        for part in parts[1:]:
            name, idx = part, 0
            if "(" in part:
                name, idx = part[:part.index("(")], int(part[part.index("(") + 1:-1])
            kids = [c for c in node if c.tag == name]
            if idx >= len(kids):
                return None
            node = kids[idx]
        return node.get(attr) if attr else node

    G = lua.globals()
    G.fileExists = lambda p: Path(p).exists()
    G.loadXMLFile = lambda name, p: 1
    G.delete = lambda h: None
    G.hasXMLProperty = lambda h, key: resolve(key) is not None
    G.getXMLString = lambda h, key: resolve(key)
    G.getXMLInt = lambda h, key: int(resolve(key)) if resolve(key) is not None else None
    G.g_modNameToDirectory = lua.table_from({"FS25_precisionFarming": str(Path(pf_xml).parent) + "/"})


def main():
    i3d, pf_xml = sys.argv[1], sys.argv[2]
    field = f"field{sys.argv[3] if len(sys.argv) > 3 else 9}"
    fields = fp.read_fields(i3d)
    pts = fields[field]
    flat = [c for p in pts for c in p]
    lua = smoke_test.fresh_lua(fields, field)
    lua.execute(LUA)
    xml_stubs(lua, pf_xml)
    G = lua.globals()
    course = G.makeCourse(lua.table_from(flat))
    area = course.stats.workLength * 6
    ok = True

    def check(name, good, info=""):
        nonlocal ok
        ok = ok and bool(good)
        print(f"{name}: {info}{': ' if info else ''}{'OK' if good else 'FAILED'}")

    def close(a, b, tol=0.01):
        return abs(a - b) <= tol * max(abs(b), 1e-9)

    P = G.GuidancePlanner
    # without Precision Farming: the game's rates; the seeder's fertiliser counted too
    v = G.makeSeeder(100, 50)
    items = P.compute(v, course, 3600, 1)
    seed, fert = G.find(items, "seed"), G.find(items, "fertilizer")
    check("game seed", seed and close(seed.needed, area * 0.0308) and not seed.pf,
          f"{seed.needed:.0f} l for {area / 10000:.2f} ha" if seed else "none")
    want = 0.0081 * 6 * 3.6 * course.stats.workLength
    check("seeder's fertiliser", fert and close(fert.needed, want) and fert.label == "Fertilizer",
          f"{fert.needed:.0f} l '{fert.label}'" if fert else "none")
    # (the helper does not buy them: then they run out)
    lua.execute("g_currentMission.missionInfo.helperBuySeeds = false; g_currentMission.missionInfo.helperBuyFertilizer = false")
    items = P.compute(v, course, 3600, 1)
    sh = P.shortages(items, 1)
    check("all that run out", len(list(sh.values())) == 2 and sh[1].at <= sh[2].at,
          ", ".join(f"{s.item.kind} at {100 * s.at:.0f}%" for s in sh.values()))

    # Precision Farming: seed rate set to high (wheat 0.04312 per m²)
    xs = sorted(p[0] for p in pts)
    x0 = xs[len(xs) // 2]
    G.setPF(x0)
    west = G.westShare(course, x0)
    v = G.withPF(G.makeSeeder(100, 50), False, 3)
    seed = G.find(P.compute(v, course, 3600, 1), "seed")
    check("PF seed set", seed and seed.pf and close(seed.needed, area * 0.04312),
          f"{seed.needed:.0f} l (high rate {area * 0.04312:.0f} l)" if seed else "none")
    # automatic: wheat on soil 1 best at high (0.04312), on soil 3 all the same, so low (0.01848)
    v = G.withPF(G.makeSeeder(100, 50), True, None)
    seed = G.find(P.compute(v, course, 3600, 1), "seed")
    want = area * (west * 0.04312 + (1 - west) * 0.01848)
    check("PF seed by soil", seed and close(seed.needed, want, 0.001),
          f"{seed.needed:.0f} l ({100 * west:.0f}% on soil 1; {want:.0f} l)" if seed else "none")
    # fertiliser automatic: 6 states short west (120 l/ha), none east
    fert = G.find(P.compute(v, course, 3600, 1), "fertilizer")
    want = area / 10000 * 120 * west
    check("PF fertiliser by need", fert and fert.pf and close(fert.needed, want, 0.001),
          f"{fert.needed:.0f} l (want {want:.0f} l)" if fert else "none")
    # fertiliser set: 3 states, 60 l/ha everywhere
    G.PF_EXT.sprayAmountAutoMode = False
    fert = G.find(P.compute(v, course, 3600, 1), "fertilizer")
    check("PF fertiliser set", fert and close(fert.needed, area / 10000 * 60),
          f"{fert.needed:.0f} l (want {area / 10000 * 60:.0f} l)" if fert else "none")
    G.PF_EXT.sprayAmountAutoMode = True
    # lime automatic: 4 states short west (1200 l/ha)
    v = G.withPF(G.makeSeeder(100, 50, G.LIME), True, None)
    lime = G.find(P.compute(v, course, 3600, 1), "spray")
    want = area / 10000 * 1200 * west
    check("PF lime by need", lime and lime.label == "Lime" and close(lime.needed, want, 0.001),
          f"{lime.needed:.0f} l (want {want:.0f} l)" if lime else "none")
    # half the course done: half of it still needed (by the remaining spots)
    half = G.find(P.compute(v, course, 3600, 0.5), "spray")
    check("remaining part", half and 0 < half.needed < lime.needed, f"{half.needed:.0f} l of {lime.needed:.0f} l")
    # the panel asks every frame: worked out again only every 2 s
    G.g_time = 1000
    a = P.get(v, course, 3600, 1)
    G.g_time = 2500
    b = P.get(v, course, 3600, 1)
    G.g_time = 3500
    c = P.get(v, course, 3600, 1)
    same = G.rawequal
    check("kept 2 s", same(a, b) and not same(c, a))
    print("OK" if ok else "FAILED")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()

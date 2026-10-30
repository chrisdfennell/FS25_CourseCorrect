"""Drives generated courses with a simple vehicle model through the mod's PathFollower (Lua 5.1 via lupa).

Checks that the follower gets to the end of the course, how far off the path the vehicle gets on worked
stretches, and how far off in turns.

Usage:
    python sim_follow.py <map.i3d> [--fields 1,2] [--width 6] [--radius 6] [--png out_dir]
"""
import argparse
import math
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import field_preview as fp  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent


def simulate(lua, course, vehicle_radius, speed=3.0, dt=0.1):
    pts = lua.table_from([lua.table_from({"x": w["x"], "z": w["z"], "work": w["work"], "t": w["t"],
                                          "rev": w.get("rev") or None})
                          for w in course["waypoints"]])
    pf = lua.globals().GuidancePathFollower.new(pts)
    w0, w1 = course["waypoints"][0], course["waypoints"][1]
    x, z = w0["x"], w0["z"]
    h = math.atan2(w1["z"] - w0["z"], w1["x"] - w0["x"])
    max_k = 1 / vehicle_radius
    work_err, turn_err, steps = 0.0, 0.0, 0
    worst = None
    trace = []
    length = pf.length
    max_steps = int(length / (speed * dt) * 1.6) + 1000
    stuck = 0
    last_s = -1
    cusps = 0
    while not pf.isFinished(pf) and steps < max_steps:
        pf.update(pf, x, z, h)
        if pf.getDistanceToCusp(pf) < 0.5:
            pf.passCusp(pf)
            cusps += 1
        reversing = bool(pf.isReversing(pf))
        radius = pf.getMinRadiusAhead(pf, 12)
        v = speed if radius > 20 else min(speed, 1.6)
        if reversing:
            v = min(v, 1.4)
        to_cusp = pf.getDistanceToCusp(pf)
        if to_cusp < 1e9:
            v = min(v, max(0.4, math.sqrt(2 * 0.6 * to_cusp)))
        lookahead = 3.0 if reversing else max(3.0, min(8.0, 0.8 * v + 2.5))
        gx, gz = pf.getGoal(pf, lookahead)[:2]
        # backing up: the same pure pursuit, as if the vehicle faced the way it moves
        hm = h + math.pi if reversing else h
        alpha = math.atan2(gz - z, gx - x) - hm
        alpha = (alpha + math.pi) % (2 * math.pi) - math.pi
        dist = max(math.hypot(gx - x, gz - z), 0.1)
        k = max(-max_k, min(max_k, 2 * math.sin(alpha) / dist))
        hm += v * dt * k
        x += v * dt * math.cos(hm)
        z += v * dt * math.sin(hm)
        h = hm - math.pi if reversing else hm
        t, work, _ = pf.getCurrentSegment(pf)
        if work:
            if pf.crossTrack > work_err:
                worst = (x, z, pf.ix, t, pf.s)
            work_err = max(work_err, pf.crossTrack)
        else:
            turn_err = max(turn_err, pf.crossTrack)
        if steps % 5 == 0:
            trace.append((x, z))
        steps += 1
        if pf.s <= last_s + 1e-6:
            stuck += 1
        else:
            stuck = 0
        last_s = pf.s
        if stuck > 600:
            break
    return {"finished": bool(pf.isFinished(pf)), "s": pf.s, "length": length, "work_err": work_err,
            "turn_err": turn_err, "time_min": steps * dt / 60, "trace": trace, "worst": worst, "cusps": cusps}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("i3d")
    ap.add_argument("--fields", default="")
    ap.add_argument("--width", type=float, default=6)
    ap.add_argument("--radius", type=float, default=6)
    ap.add_argument("--png", default=None)
    ap.add_argument("--reverse", action="store_true", help="vehicle can back up (three-point turns, square corners)")
    ap.add_argument("--headlands", type=int, default=-1)
    args = ap.parse_args()
    fields = fp.read_fields(args.i3d)
    wanted = {f"field{n}" for n in args.fields.split(",") if n} or set(fields)
    lua = fp.load_lua()
    lua.execute((ROOT / "scripts/ai/PathFollower.lua").read_text(encoding="utf-8"))
    ok = True
    for name in sorted(wanted, key=lambda n: int("".join(c for c in n if c.isdigit()) or 0)):
        course, err = fp.generate(lua, fields[name], {"workWidth": args.width, "turnRadius": args.radius,
                                                       "headlands": args.headlands, "allowReverse": args.reverse})
        if course is None:
            print(f"{name}: {err}")
            continue
        r = simulate(lua, course, args.radius * 0.9)
        ok = ok and r["finished"] and r["work_err"] < 1.5
        print(f"{name}: finished={r['finished']} {r['s']:.0f}/{r['length']:.0f} m, max off path working "
              f"{r['work_err']:.2f} m, turning {r['turn_err']:.2f} m, {r['time_min']:.0f} min at 3 m/s, "
              f"{r['cusps']} direction changes")
        if r["worst"] and r["work_err"] > 1:
            wx, wz, wix, wt, ws = r["worst"]
            wps = course["waypoints"]
            ctx = "".join(w["t"] for w in wps[max(0, wix - 4):wix + 4])
            print(f"    worst at ({wx:.0f},{wz:.0f}) segment {wix} type {wt} s={ws:.0f} context {ctx}")
        if args.png:
            from PIL import ImageDraw
            out = Path(args.png)
            out.mkdir(parents=True, exist_ok=True)
            fp.render(name, fields[name], course, out / f"{name}_sim.png")
            from PIL import Image
            img = Image.open(out / f"{name}_sim.png")
            xs = [p[0] for p in fields[name]]
            zs = [p[1] for p in fields[name]]
            minx, maxx, minz, maxz = min(xs), max(xs), min(zs), max(zs)
            scale = (1100 - 80) / max(maxx - minx, maxz - minz, 1)
            d = ImageDraw.Draw(img)
            tr = [(40 + (px - minx) * scale, 40 + (pz - minz) * scale) for px, pz in r["trace"]]
            d.line(tr, fill=(255, 255, 255), width=1)
            img.save(out / f"{name}_sim.png")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()

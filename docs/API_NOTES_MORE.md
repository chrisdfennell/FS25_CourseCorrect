# FS25 API notes: vineyards / orchards, shovels (wheel loader, front loader)

Learned from reading how Courseplay (GPL) and AutoDrive (GPL) call the game: reference only, nothing copied.

## Vineyards and orchards

- `g_currentMission.vineSystem.nodes`: scene node -> owning placeable. Each placeable: `spec_vine.vineSegments`
  (segment table -> list of `{node}`), a segment has world end points `x1, z1, x2, z2`; `spec_vine.width` is the row
  spacing. There is no row object: rows are made by stepping sideways from a node by the width
  (`localToWorld(node, k * width, 0, 0)`) and joining the parallel segments met there into one line per row.
- All vine placeables of a field share one angle (snapped); rows of uneven length / gaps aren't handled by CP.
- Tools: `spec_vineCutter` (grape harvester, on a vehicle with `spec_combine`: full when its free capacity is 0) and
  `spec_vinePrepruner`. The game's own helper can't work them. Grape harvesters straddle the row (on the row); a
  pre-pruner works the row from beside it (its tool offset); a sprayer drives between rows and sprays both sides
  (every other gap). Some vine tools have no work area: use the row spacing as width.
- Driving among vines: the vines trip collision / proximity checks (don't treat them as obstacles); turns at the row
  ends (Dubins), rows run on ~20 m past the vines' ends.

## Shovels (wheel loader, telehandler, front loader)

- Shovel implement: `spec_shovel.shovelNodes[1]` (`node`, `fillUnitIndex`, `width`). Not trailers / conveyors.
- Full / empty: `getFillUnitFillLevelPercentage(ix)` >= 0.99 / <= 0.01. Fill type: `spec_shovel.loadingFillType`.
- Tipping: `getShovelTipFactor() >= 0` (tilted to unload) with a discharge state other than OFF;
  `spec_shovel.shovelDischargeInfo` (`node`, `minSpeedAngle`, `maxSpeedAngle`); bucket angle from that node's forward
  direction. Activated-discharge shovels: `setIsTurnedOn(true)` + `setDischargeState(DISCHARGE_STATE_OBJECT)`. Target
  under it: `updateRaycast(node)`, `getDischargeTargetObject(node)`.
- Arm and bucket: the combination's `spec_cylindered.movingTools` with axis `AXIS_FRONTLOADER_ARM` (arm),
  `AXIS_FRONTLOADER_TOOL` (bucket), `AXIS_FRONTLOADER_ARM2` (telescope); moved with `Cylindered.setToolRotation(vehicle,
  tool, speed, dt, diff)` + `Cylindered.setDirty` + `raiseDirtyFlags(tool.dirtyFlag)` and the cylindered dirty flag;
  stop: `tool.move = 0`. Which way is "up": try it and watch the shovel's height.
- Positions: loading (arm low ~0.1 m, bucket level), transport (~0.2 m, bucket tilted back), pre-unload (~2.8 m),
  unload (at the trailer's height + 0.5 m, bucket tipped).
- A heap: `DensityMapHeightUtil.getFillTypeAtLine(x1, y1, z1, x2, y2, z2, width)` along a probe line (nil / UNKNOWN:
  none), its extent by stepping; amount `DensityMapHeightUtil.getFillLevelAtArea(ft, sx, sz, wx, wz, hx, hz)`.
- Trailer to load: a standing vehicle with Trailer / MixerWagon in reach, a fill unit that takes the fill type with
  room (`getFillUnitFreeCapacity(ix, ft, farm)`, `getIsFillAllowedFromFarm`), its `getFillUnitExactFillRootNode`.
- Cycle: into the heap with the bucket down (stop while the arm moves), out backwards when full / at the end / stuck,
  to a point beside the trailer (90°), arm up, creep in until the bucket is over the fill node, tip, back off.

## Auger wagon into a parked trailer, heaps, traffic (from CP / AD, approaches only)

- Parked trailer: any Trailer vehicle standing still (root speed < 0.1), not ours, inside the field or within 20 m of
  it, with a fill unit that takes the load (`getFillUnitSupportsFillType`, `getFillUnitAllowsFillType`,
  `getFillUnitFreeCapacity(ix, ft, farm) > 0`, `getIsFillAllowedFromFarm`) and an exact fill root node: the nearest.
  Come along its side with the pipe towards it (pipe end ~1.6 m inside the near edge), straight run-in, slow at the
  end; open the pipe (`setPipeState`), `spec_pipe.automaticDischarge = true`: the game fills the trailer. Creep so the
  discharge node is over the fill node (|dz| < 0.2 m). Stopped filling (`getCanDischargeToObject` false): wagon
  < 10 % = empty; the same trailer still has room elsewhere: on to its next fill node; else it is full.
- Heap: rear tip side (discharge node near the centreline, `canDischargeToGround`), `setPreferedTipSide`, then each
  frame `setManualDischargeState(DISCHARGE_STATE_GROUND)` while `getCanDischargeToGround(node)`; stand while the level
  falls, roll on when it stops (the ground there is full): a long pile. Done: OFF, wait `getAIHasFinishedDischarge`.
  The next load beside / behind the last heap (scan the ground fill type along lines to find it).
- Traffic: blocked by the same vehicle > ~7 s: one of the two moves (backs off ~25 m, or forward when the other is
  behind) and puts the other "on hold" (~20 s) so both never yield at once; head-on with a combine: back along it,
  offset beside it. AD: stuck 15 s -> reverse away from the blocked side until the front is clear 4 s (max 20 s / 30 m).

## Choppers (forage harvesters) and the grass chain

- A chopper: `spec_combine.isBufferCombine == true` (its tank capacity is huge, ~math.huge); auto-aim spout when
  `spec_pipe.numAutoAimingStates > 0`. Spout: `getDischargeNodeByIndex(getPipeDischargeNodeIndex())`, `.maxDistance`
  the throw. Target: `getDischargeTargetObject(node)` (only when it can hit), `spec_pipe.nearestObjectInTriggers`.
- A chopper only runs with a fill type: when not turning, `setForcedFillTypeIndex(ft)` (its discharge fill type, or
  the trailer's fill type / first supported one); nil to release. Keep the pipe at state 2.
- It doesn't stop by itself without a trailer: the driver holds it while nothing is under the spout (not in turns).
- Chasing: beside it on the side with less crop at (chopper width + trailer width) / 2 + 1 m, or straight behind it
  (first pass / crop on both sides); speed = its speed + clamp(2 x gap, -10, 15), at least 2 km/h while closing in
  (the game stops a vehicle below ~2 km/h). Full: leave; the next one takes over (the second waits behind the first).
- Grass chain: no mod plans windrows. Balers / loader wagons (`spec_baler`, `spec_forageWagon`, `Pickup`) follow the
  rake's course (the same course, the windrows lie on its passes). Windrows on the ground: windrow fill types
  (`fruitType.windrowFillType`), `DensityMapHeightUtil.getFillTypeAtArea` / `getFillLevelAtArea`.
- Baler: `spec_baler` (`nonStopBaling`, `hasUnloadingAnimation`, `unloadingState` vs `Baler.UNLOADING_CLOSED`,
  `platformDropInProgress`, `platformAIDropSpeed`); a round baler that stops to eject: slow over its last 200 l, stand
  while full / unloading; out of net / twine: `getConsumableIsAvailable(...)` false -> stop. Unfold it
  (`setFoldDirection(turnOnFoldDirection)`). Forage wagon full: `getFillUnitFreeCapacity <= 0` -> stop (full).

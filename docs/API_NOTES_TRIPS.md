# FS25 API notes: road trips, stations, bales (for the unloader, refill trips, bale collector)

Learned from reading how Courseplay (CP, GPL) and AutoDrive (AD, GPL) call the game: reference only, nothing copied.
The game's own source is packed; where a fact is inferred from how the mods use the game it says so.

## The game's road driving and discharge tasks

- Tasks: `AITaskDriveTo.new(isServer, job)`, `AITaskDischarge.new(isServer, job)`, added with `job:addTask(task)`; each
  gets `task.taskIndex` in the order added.
- Drive-to: `setVehicle(rootVehicle)`, `setTargetPosition(x, z)`, `setTargetDirection(dirX, dirZ)`,
  `setTargetOffset(offset)` (negative: stop that far before the target, e.g. the discharge node's z offset).
- Deliver logic of the game (`AIJobDeliver.getNextTaskIndex(job)`, `AIJobDeliver.canContinueWork(job)`,
  `AIJobDeliver.getIsAvailableForVehicle(job, vehicle)`) works on any job that has: `waitForFillingTask` (the task
  that fills up; it ends itself with `skip()` when full), `driveToUnloadingTask`, `dischargeTask`,
  `unloadingStationParameter` (object with `getUnloadingStation()`), `dischargeNodeInfos` (list of
  `{dirty = true, vehicle, dischargeNode, offsetZ}` from `v:getAIDischargeNodes()` of the vehicle and every child,
  `offsetZ` = 3rd return of `v:getAIDischargeNodeZAlignedOffset(node, rootVehicle)`, sorted by offsetZ descending),
  `supportedFillTypes` (= `station:getAISupportedFillTypes()`), `currentTaskIndex`.
  Inferred: after the filling task it picks a dirty node, sets the drive-to / discharge targets and returns the
  drive-to index; `driveToUnloadingTask.x` stays nil when no target was found. Set every info `dirty = true` when the
  drive-to starts.
- Looping jobs (`getIsLooping` true) go back to the start task index after the last task.
- `canContinueWork` returns ok, aiMessage; check a supported fill type is loaded while driving there
  (`AIMessageErrorNoValidFillTypeLoaded`).

## Stations

- Unloading: `g_currentMission.storageSystem:getUnloadingStations()`, keep `accessHandler:canPlayerAccess(st)`,
  `st:isa(UnloadingStation)`, non-empty `st:getAISupportedFillTypes()`. `st:getIsFillTypeAISupported(ft)`,
  `st:getFreeCapacity(ft, farmId)`. Name / map position: `st.owningPlaceable` (`getName()`,
  `getHotspot(1):getWorldPosition()`).
- Loading: `storageSystem:getLoadingStations()`, `accessHandler:canFarmAccess(farmId, ls)`,
  `ls:getAISupportedFillTypes()[ft]`, `ls:getFillLevel(ft, farmId)`.
- Drive target of either: `st:getAITargetPositionAndDirection(FillType.UNKNOWN)` -> x, z, dirX, dirZ; else
  `st.unloadTriggers[1]` (`supportsAIUnloading` -> its `getAITargetPositionAndDirection()`, else `exactFillRootNode`).
- Saving a choice: network id (`NetworkUtil.getObjectId`) is not kept across saves; keep the position, find the
  nearest station again.

## Filling at a load trigger (AD's way, no game task for it)

- Stations have `.loadTriggers`; a trigger's place: `getWorldTranslation(trigger.triggerNode)`. The trailer is in
  reach when it is in `trigger.fillableObjects` (`{object, fillUnitIndex}`).
- Start: `trigger.autoStart = true`, `trigger.selectedFillType = ft`, `trigger:onFillTypeSelection(ft)`; loading
  when `trigger.isLoading`; then `autoStart = false`. Done when free capacity <= 0.1 or `isLoading` turns false.
- Check first: `getFillUnitSupportsToolType(i, ToolType.TRIGGER)`, `getFillUnitSupportsFillType`,
  `getFillUnitAllowsFillType`, `getFillUnitFreeCapacity(i) > 0`; stock `trigger.source:getAllFillLevels(farmId)` or
  `trigger.hasInfiniteCapacity`.

## Discharging by hand (AD)

- `trailer:getCanDischargeToObject(trailer:getCurrentDischargeNode())` and `getDischargeState() == OFF`, a moment
  later `setDischargeState(Dischargeable.DISCHARGE_STATE_OBJECT)`; done when empty and
  `getTipState() == Trailer.TIPSTATE_CLOSED`. Ground (heap, bunker silo): `DISCHARGE_STATE_GROUND`. Tip side:
  `getCurrentDischargeNodeIndex()`, `spec_trailer.dischargeNodeIndexToTipSide`, `setPreferedTipSide(index)`.

## Jobs

- Start on the server: `currentTaskIndex = 0`, `vehicle:createAgent(helperIndex)`, `vehicle:aiJobStarted(job,
  helperIndex, farmId)`; stop: `deleteAgent()`, `aiJobFinished()`, `AIJob.stop`. A task's `skip()` finishes it (or
  makes it finish as soon as it starts); `getIsFinished()` moves the job on.
- MP: stream `isDirectStart`, `jobId`, every named parameter, `currentTaskIndex` (UInt8), then `setValues()`.

## Bales

- All bales: `g_currentMission.slotSystem.objectLimits[SlotSystem.LIMITED_OBJECT_BALE].objects` (pairs; the same
  bale may appear more than once: key by `object.id`). A bale: `object:isa(Bale)`, `object.nodeId` and
  `entityExists(nodeId)` (nodeId may be 0).
- Position `getWorldTranslation(bale.nodeId)`, yaw from `getWorldRotation`. `bale.isRoundBale`, `bale.diameter`
  (round) / `bale.length` (square), `bale.width`. `bale:getFillType()`, `bale.wrappingState > 0` wrapped.
  Access: `accessHandler:canFarmAccess(farmId, bale)`. On a loader: `bale.mountObject ~= nil`.
- Loader / wrapper: implements with `spec_baleLoader` / `spec_baleWrapper` (`SpecializationUtil.hasSpecialization`).
  Grab point: `spec.baleGrabber.grabNode` (else rootNode).
- Loader: work position `spec_baleLoader.isInWorkPosition`; toggle with
  `loader:doStateChange(BaleLoader.CHANGE_BUTTON_WORK_TRANSPORT)` (call on the vehicle). Grabbing:
  `grabberMoveState ~= nil`. Full: `getFillUnitFreeCapacity(spec.fillUnitIndex) <= 0.01`. Can take a bale:
  `loader:getBaleTypeByBale(bale) ~= nil` (and the same type as `spec.currentBaleType` when not empty).
- Unloading: when `spec.emptyState == BaleLoader.EMPTY_NONE` (and `getIsAutomaticBaleUnloadingAllowed()`),
  `startAutomaticBaleUnloading()`; running while `getIsAutomaticBaleUnloadingInProgress()`; creep forward ~5 m so the
  stack is clear; ready again when not unloading, `getIsBaleLoaderFoldingPlaying()` false, `emptyState ==
  EMPTY_NONE`; then back to work position.
- Wrapper: `wrapper:getIsBaleWrappable(bale)`; busy while `spec_baleWrapper.baleWrapperState ~=
  BaleWrapper.STATE_NONE`; finished `STATE_WRAPPER_FINSIHED` (the game's spelling) -> `doStateChange(
  BaleWrapper.CHANGE_WRAPPER_START_DROP_BALE)`. A wrapped bale is a new object: look again.
- Approach: towards the bale, shifted sideways by the grab point's offset, the last ~20 m straight and slow (half
  work speed, ~2 km/h while grabbing). Picked when the grabber moved (or the bale is mounted / gone). Not reached:
  try another bale, later from another side; give a bale up after a few tries. Bales aren't reserved: two helpers
  must not take the same one.

## Combine pipe, trailers, tipping (unloader)

- Pipe: `spec_pipe.currentState` / `targetState` (0 moving, 1 closed, 2 open; choppers sit open, auto-aiming:
  `spec_pipe.numAutoAimingStates > 0`, `spec_combine.isBufferCombine`). `numStates <= 1`: fixed pipe. Change with
  `setPipeState(state)` when `getIsPipeStateChangeAllowed(state)` and not moving.
- `spec_pipe.automaticDischarge`: the combine discharges by itself into a trailer under the open pipe (set it true
  while we run the pipe, restore after). Under the pipe: `spec_pipe.numObjectsInTriggers`, `objectsInTriggers`;
  `getDischargeTargetObject(node)` -> object, fillUnitIndex (only when it can really fill it).
- Discharge node: `getPipeDischargeNodeIndex()` -> `getDischargeNodeByIndex(ix)` (else `getCurrentDischargeNode()`);
  `.node`, `.fillUnitIndex`. Side / fore-aft: `localToLocal(node.node, combine:getAIDirectionNode(), 0, 0, 0)`, x > 0
  left. Measure only with the pipe out (never unfold instantly just to measure: it breaks the vehicle).
- Combine tank `spec_combine.fillUnitIndex`; still threshing `spec_combine.isFilling`.
- Trailers: children with the Trailer specialization; fill nodes `getFillUnitExactFillRootNode(ix)` (may be at the
  bottom: also `getFillUnitAutoAimTargetNode(ix)`), `getFillUnitFreeCapacity(ix)`, `getFillUnitSupportsFillType`,
  `getFillUnitAllowsFillType`.
- Lining up: the trailer's fill node's z in the combine's direction node minus the pipe's z; speed = combine speed +
  a share of that, clamped.
- Auger wagon into a trailer: open its pipe, it discharges while `getCanDischargeToObject(getCurrentDischargeNode())`;
  if stalled `setDischargeState(DISCHARGE_STATE_OBJECT)`; stop with OFF. To the ground: GROUND while
  `getCanDischargeToGround(node)`.
- Tipper onto a heap: tip side with `canDischargeToGround`, `setPreferedTipSide(spec_trailer.dischargeNodeIndexToTipSide[
  node.index].index)`, then each frame `setManualDischargeState(DISCHARGE_STATE_GROUND)` while
  `getCanDischargeToGround(node)`; empty: OFF, wait `getAIHasFinishedDischarge(node)`.

## Bunker silos (compacter)

- List: placeables' `spec_bunkerSilo.bunkerSilo` and `spec_multiBunkerSilo.bunkerSilos[...]` (`placeableSystem.placeables`).
  Use only if `interactionTriggerNode` exists.
- Area: `silo.bunkerSiloArea` (`inner` on some): `sx, sz` start, `wx, wz` width corner, `hx, hz` length corner;
  fourth corner h + (w - s). Start -> height is the length (driving direction).
- `silo.compactedPercent` (0..100), `silo.state` (`BunkerSilo.STATE_FILL`, `STATE_DRAIN`), `silo.fillLevel`.
- Compacter implement: `spec_bunkerSiloCompacter`; lanes = ceil(width / work width), 0.5 m from the walls. Stop at
  99 % compacted or when it is not filling any more.

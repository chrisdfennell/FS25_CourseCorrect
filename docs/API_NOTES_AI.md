# FS25 API notes: specializations, AI jobs, driving, implements, fields

Learned from reading how Courseplay (CP, GPL, reference only, nothing copied) calls the game. Signatures are inferred
from usage (no base game source on disk). `Cp*` names are CP's own helpers, not engine API.

## Specialization
- modDesc `<specializations><specialization name="x" className="X" filename="..."/>`; the spec table on the vehicle is `vehicle["spec_" .. modName .. ".x"]`.
- Add to vehicle types: `TypeManager.finalizeTypes = Utils.prependedFunction(TypeManager.finalizeTypes, fn)`; in fn check `typeManager.typeName == "vehicle"`, loop `typeManager.types`, `typeManager:addSpecialization(typeName, modName .. ".x")` when `SpecializationUtil.hasSpecialization(AIFieldWorker, entry.specializations)`.
- Events from any spec exist before listeners are wired (CP relies on it).
- Skip shop preview vehicles: `vehicle.propertyState == VehiclePropertyState.SHOP_CONFIG`.
- `onUpdate` only while active: `self:raiseActive()`.
- Last job is saved at `vehicles.vehicle(?).aiJobVehicle.lastJob`: a custom job's params need schema registration there.

## AI job
- In loadMap: `g_currentMission.aiJobTypeManager:registerJobType(name, title, Class)` → `AIJobType[name]`; `aiJobTypeManager:createJob(AIJobType.X)`. Cheap insurance for MP: fall back to name lookup in `AIJobTypeManager.getJobTypeIndex`.
- Subclass `AIJob.new(isServer, mt)`. `self.vehicleParameter = AIParameterVehicle.new()`, `self:addNamedParameter("vehicle", p)`, `AIParameterGroup.new(title):addParameter(p)` into `self.groupedParameters`. `self:addTask(task)`.
- Task (duck typed): `start()`, `stop(wasJobStopped)`, `update(dt)`, `reset()`, `skip()`, `validate(ignoreUnset)`, `getIsFinished()`, `setVehicle(v)`.
- Start: `job:applyCurrentState(vehicle, g_currentMission, farmId, isDirectStart)`, `job:setValues()`, `ok, err = job:validate(farmId)`, `g_client:getServerConnection():sendEvent(AIJobStartRequestEvent.new(job, farmId))`.
- `getIsStartable(connection)`: `g_currentMission:getHasPlayerPermission("hireAssistant", connection, farmId)`, `vehicle:getIsInUse(connection)`; errors `AIJobFieldWork.START_ERROR_*`.
- `start(farmId)`: helper `g_helperManager:getRandomHelper().index`; server: `vehicle:createAgent(helperIndex)`, `vehicle:aiJobStarted(job, helperIndex, farmId)`.
- `stop(aiMessage)`: server: `vehicle:deleteAgent()`, `vehicle:aiJobFinished()`, then `AIJob.stop(self, aiMessage)`. Clear `spec_aiFieldWorker.isActive` (client desync).
- writeStream/readStream: isDirectStart, has jobId + Int32 jobId, each named parameter's writeStream, currentTaskIndex UInt8, own data; readStream ends with setValues().
- saveToXMLFile/loadFromXMLFile: call AIJob super first. `getTitle()`, `getDescription()`, `getPricePerMs()`.
- Stop: `vehicle:stopCurrentAIJob(AIMessageX.new())`. Base messages: AIMessageErrorOutOfFill, ErrorOutOfFuel, ErrorVehicleBroken, ErrorBlockedByObject, ErrorOutOfMoney, ErrorUnknown, ErrorWrongSeason, ErrorNoValidFillTypeLoaded, SuccessFinishedJob, SuccessStoppedByUser. No base "is full" message: register own (`g_currentMission.aiMessageManager:registerMessage(name, class)`, subclass AIMessage with `.name` and `getI18NText()`).

## Driving
- Field work via vanilla AIFieldWorker (server): `spec_aiFieldWorker.isActive = true`, `vehicle:updateAIFieldWorkerImplementData()`, `vehicle:raiseAIEvent("onAIFieldWorkerStart", "onAIImplementStart")`, traffic collision if `getAINeedsTrafficCollisionBox()`, replace `spec_aiFieldWorker.driveStrategies` with own strategy. Vanilla calls `strategy:update(dt)` and `strategy:getDriveData(dt, vX, vY, vZ)` → `tX, tZ, moveForwards, maxSpeedKmh, distanceToStop`. Stop: `vehicle:stopFieldWorker()`.
- Vanilla AIDriveStrategyFieldCourse.delete raises implements: neutralize while we're active.
- Set `vehicle.aiDriveTarget = {x, z}`, `vehicle.aiDriveDirection = {dx, dz}` for collision prediction.
- Direct: `worldToLocal(vehicle:getAISteeringNode(), tX, tY, tZ)` → `AIVehicleUtil.driveToPoint(vehicle, dt, 1, maxSpeed ~= 0, moveForwards, pX, pZ, maxSpeedKmh)`. Reverse: `getAIReverserNode()`.
- maxSpeed exactly 0 or > 0.5 (did-not-move timer).
- Nodes: `getAIDirectionNode()`, `getAISteeringNode()`, `getAIReverserNode()`.
- Motor: `stopMotor()/startMotor()`, `getMotorState()`, `getCanMotorRun` override.

## Implements
- Start `raiseAIEvent("onAIFieldWorkerStart","onAIImplementStart")`; prepare/unfold `("onAIFieldWorkerPrepareForWork","onAIImplementPrepareForWork")`; lower each `impl.object:aiImplementStartLine()` for `vehicle:getAttachedAIImplements()` + `vehicle:raiseStateChange(VehicleStateChange.AI_START_LINE)`; raise `aiImplementEndLine()` + `VehicleStateChange.AI_END_LINE`; turning `("onAIFieldWorkerTurnProgress","onAIImplementTurnProgress", progress, isLeft)`; end `("onAIFieldWorkerEnd","onAIImplementEnd")`.
- MP: start, prepare and start-line in separate frames, speed 0 meanwhile. Then wait for `vehicle:getCanAIFieldWorkerContinueWork()` (+1 frame).
- Per implement: `getCanAIImplementContinueWork()` → canContinue, stopAI, stopReason.
- Fold: `vehicle:prepareForAIDriving()`, `getIsAIReadyToDrive()`, `getIsAIPreparingToDrive()`. Unfold retry `getIsFoldAllowed(spec_foldable.turnOnFoldDirection, false)` / `setFoldState(dir, true)`.
- Turn on: `getCanBeTurnedOn()`, `getIsTurnedOn()`, `setIsTurnedOn(b)`, `getIsLowered()`.
- Markers: `obj:updateAIMarkerWidth()`, `obj:getAIMarkers()` → left, right, back, inverted, width; side offset `getAIImplementSideOffset()` (negative = left). Distances via `localToLocal(marker, vehicle:getAIDirectionNode(), 0,0,0)`.
- Game's own: `FieldCourseSettings.generate(vehicle)` → settings, implementData (work width etc.).
- Size: `getAIAgentSize()` (pcall) → width, length, lengthOffset, frontOffset, height.
- Turn radius: max of `vehicle.maxTurningRadius`, `vehicle:getAIMinTurningRadius()`, `AIVehicleUtil.getMaxToolRadius({object = impl})` (server only, AIImplement children only).
- Fill: `getFillUnits()`, `getFillUnitFillLevel(i)`, `getFillUnitCapacity(i)`, `getFillUnitFillLevelPercentage(i)`, `getFillUnitFreeCapacity(i)`, `getFillUnitFillType(i)`; `getSprayerFillUnitIndex()`, `spec_sowingMachine.fillUnitIndex`; fuel `spec_motorized.propellantFillUnitIndices`; `g_currentMission.missionInfo.helperBuySeeds`. Damage `getDamageAmount()`.

## Fields
- `g_farmlandManager:getFarmlandAtWorldPosition(x, z):getField()`; `field:getId()`; `field:getDensityMapPolygon():getVerticesList()` → flat x,z,x,z (initial map state). `g_fieldManager:getFields()`.
- On field: `FSDensityMapUtil.getFieldDataAtWorldPosition(x, y, z)` → isOnField.
- Live detection incl. islands: `FieldCourseField.generateAtPosition(x, z, FieldCourseSettings.generate(vehicle), cb(courseField, success))`, call `courseField:update(dt, 0.00025)` per frame until cb; `courseField.fieldRootBoundary.boundaryLine` ({{x,z},...}, first repeated), `courseField.islands[i].rootBoundary.boundaryLine`.

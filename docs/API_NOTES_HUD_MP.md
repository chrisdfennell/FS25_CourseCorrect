# FS25 API notes: HUD, input, map drawing, multiplayer, persistence

Learned from reading Courseplay (CP, GPL, reference only, nothing copied) and AutoDrive (AD). Engine/game API only.

## HUD drawing
- `Overlay.new(file|nil, x, y, w, h)`, `:setUVs`, `:setColor(r,g,b,a)`, `:setAlignment(Overlay.ALIGN_VERTICAL_*, Overlay.ALIGN_HORIZONTAL_*)`, `:setPosition`, `:setDimension`, `:render()`, `:delete()`.
- Raw: `createImageOverlay(path)`, `setOverlayColor`, `setOverlayUVs`, `setOverlayRotation(id, rad, px, py)` (reset to 0 after!), `renderOverlay(id, x, y, w, h)`, `delete(id)`.
- Solid colour: `g_baseUIFilename` + `g_colorBgUVs`, or `dataS/menu/base/graph_pixel.dds`.
- Sprite sheets: `g_overlayManager:addTextureConfigFile(xml, "prefix")` (`<slice id=".." uvs="4px 4px 32px 32px"/>`), `g_overlayManager:createOverlay("prefix.id", x, y, w, h)`. Base slices like `"gui.icon_options_help2"`.
- Text (global state, reset after): `setTextBold`, `setTextAlignment(RenderText.ALIGN_LEFT|CENTER|RIGHT)`, `setTextColor`, `setTextWrapWidth(0)`, `setTextLineBounds(0,2)`, `renderText(x, y, size, str)`, `getTextWidth(size, str)`.
- Pixels to screen: `getNormalizedScreenValues(px, py)` (origin bottom-left, 0..1), `g_screenWidth/Height`, `g_screenAspectRatio`, UI scale `g_gameSettings:getValue("uiScale")`.
- Hit test: `GuiUtils.checkOverlayOverlap(mx, my, x, y, w, h)`.
- Draw hooks: vehicle spec event `onDrawUIInfo` (check `g_localPlayer:getCurrentVehicle() == self`), or `addModEventListener(obj)` with `obj:draw()` gated by `not g_gui:getIsGuiVisible() and not g_noHudModeEnabled`.
- Dedicated server never draws: create overlays lazily / only when `g_dedicatedServer == nil` / `self.isClient`.

## Mouse
- Mod listener `obj:mouseEvent(posX, posY, isDown, isUp, button)`; `Input.MOUSE_BUTTON_LEFT|RIGHT`, wheel via `Input.isMouseButtonPressed(Input.MOUSE_BUTTON_WHEEL_UP)`.
- Cursor: `g_inputBinding:setShowMouseCursor(b)` / `getShowMouseCursor()`.
- Stop camera rotating while cursor is on: `for _, cam in pairs(vehicle.spec_enterable.cameras) do cam.isRotatable = false end` (save and restore; restore in onLeaveVehicle).
- Scroll zoom: override `Enterable.actionEventCameraZoomInOut` while mouse over HUD. Click-to-switch: overwrite `enterVehicleRaycastClickToSwitch`.
- AD and CP both bind RMB to toggle the cursor. AD's own HUD must keep working.

## Input
- modDesc `<actions><action name="X"/></actions>` + `<inputBinding><actionBinding action="X"><binding device="KB_MOUSE_DEFAULT" input="KEY_lctrl KEY_h"/></actionBinding></inputBinding>`; `InputAction.X`; l10n `input_X`.
- Vehicle `onRegisterActionEvents(isActiveForInput, isActiveForInputIgnoreSelection)`, client only: `self:clearActionEventsTable(t)`, `local _, id = self:addActionEvent(t, InputAction.X, self, cb, false, true, false, true, nil)`, `g_inputBinding:setActionEventText/TextPriority(GS_PRIO_HIGH)/TextVisibility/Active`.

## Map / 3D drawing
- Minimap/PDA: `IngameMap.drawFields` append (`g_currentMission.hud.ingameMap`). World to map: `u = (wx + map.worldCenterOffsetX) / map.worldSizeX * 0.5 + 0.25` (same with z), `map.layout:getMapObjectPosition(u, v, 0, 0, 0, true)` → x, y, rot, visible. Full screen map: `map.fullScreenLayout`. Lines = rotated 1px overlays.
- 3D debug: `DebugUtil.drawDebugLine(x1,y1,z1, x2,y2,z2, r,g,b)` every frame. Terrain height: `getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, x, 300, z)`.

## Multiplayer
- Event: `X = {}; local X_mt = Class(X, Event); InitEventClass(X, "X")`, `emptyNew() return Event.new(X_mt)`, `writeStream(streamId, connection)`, `readStream(...)` ends with `self:run(connection)`. In `run`, if `not connection:getIsServer()` it came from a client: apply and `g_server:broadcastEvent(X.new(...), nil, connection, vehicle)`.
- Send: `if g_server then g_server:broadcastEvent(ev, nil, nil, obj) else g_client:getServerConnection():sendEvent(ev) end`.
- `NetworkUtil.writeNodeObject(streamId, vehicle)` / `readNodeObject`. `streamWriteFloat32/Int32/UInt8/UIntN/Bool/String`.
- Join in progress: vehicle spec events `onWriteStream/onReadStream(streamId, connection)`. Continuous state: `onWriteUpdateStream/onReadUpdateStream`, `self:getNextDirtyFlag()`, `raiseDirtyFlags`.

## Persistence
- Savegame per vehicle: in `initSpecialization` `Vehicle.xmlSchemaSavegame:register(XMLValueType.STRING, "vehicles.vehicle(?)." .. modName .. ".specName#attr")`; load in `onLoad(savegame)` (`savegame.xmlFile:getValue(savegame.key .. ...)`, skip if `savegame.resetVehicles`); save in `Spec:saveToXMLFile(xmlFile, key, usedModNames)` with `xmlFile:setValue(key .. "#attr", v)`.
- modSettings: `getUserProfileAppPath() .. "modSettings/" .. modName .. "/"`, `createFolder`, `XMLSchema.new`, `XMLFile.create(name, path, root, schema)`, `XMLFile.loadIfExists`, `:iterate(key, fn)`, `:save()`, `:delete()`.

## Translations / GUI
- `<l10n filenamePrefix="translations/translation"/>`, `translations/translation_en.xml`: `<l10n><texts><text name="key" text="..."/></texts></l10n>`, `g_i18n:getText(key)`.
- Screens: `g_gui:loadProfiles(xml)`, `g_gui:loadGui(xml, name, instance[, isFrame])`, `g_gui:showGui(name)`.

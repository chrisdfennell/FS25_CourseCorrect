-- CourseCorrect's own help: short topics on how to use it, shown in the panel (the ? at its top). The text comes from
-- help/help_<language>.xml (the game's language; English when there is no file for it), so it can be translated
-- without touching the code.

GuidanceHelp = {}
local Help = GuidanceHelp

--- The topics: list of {id, title, paras}, read once
function Help.topics()
    if Help.loaded == nil then
        local dir = Guidance.MOD_DIR or ""
        Help.loaded = Help.read(dir .. "help/help_" .. tostring(g_languageShort or "en") .. ".xml")
            or Help.read(dir .. "help/help_en.xml") or {}
    end
    return Help.loaded
end

--- One help file: its topics, or nil
function Help.read(path)
    if loadXMLFile == nil or (fileExists ~= nil and not fileExists(path)) then return nil end
    local xml = loadXMLFile("guidanceHelp", path)
    if xml == nil or xml == 0 then return nil end
    local list = {}
    for i = 0, 99 do
        local key = string.format("help.topic(%d)", i)
        local id = getXMLString(xml, key .. "#id")
        if id == nil then break end
        local topic = {id = id, title = getXMLString(xml, key .. "#title") or id, paras = {}}
        for j = 0, 49 do
            local p = getXMLString(xml, string.format("%s.p(%d)", key, j))
            if p == nil then break end
            topic.paras[#topic.paras + 1] = p
        end
        list[#list + 1] = topic
    end
    delete(xml)
    return #list > 0 and list or nil
end

--- The place of a topic in the list, or nil
function Help.index(id)
    for i, topic in ipairs(Help.topics()) do
        if topic.id == id then return i end
    end
    return nil
end

local config = require("modules/config")
local utils = require("modules/utils")
local GameUI = require("modules/GameUI")
local style = require("modules/style")

local target = nil

--- Parts of a node that ArchiveXL can remove one by one, and the node types that have them.
--- Since 2.5 the collisions of a sector are cooked into worldCookedCollisionNode: one nodeData entry per former collision node.
local elementKinds = {
    actor = {
        list = "actorDeletions",
        expected = "expectedActors",
        label = "Collision Actors",
        types = { worldCollisionNode = true, worldCookedCollisionNode = true }
    },
    instance = {
        list = "instanceDeletions",
        expected = "expectedInstances",
        label = "Instances",
        types = { worldInstancedMeshNode = true, worldInstancedDestructibleMeshNode = true, worldInstancedOccluderNode = true }
    }
}

-- Elements shown in the UI for removals whose element count is unknown, so that an unticked element stays listed
local knownElements = setmetatable({}, { __mode = "k" })

--- Calls fn and returns its result, or nil if it fails (e.g. a property that does not exist in this game version)
local function try(fn)
    local ok, value = pcall(fn)
    if ok then return value end
end

local function positiveInt(value)
    value = tonumber(value)
    if value and value > 0 then return math.floor(value) end
end

---@param nodeType string
---@return table?
local function getElementKind(nodeType)
    for _, kind in pairs(elementKinds) do
        if kind.types[nodeType] then return kind end
    end
end

---@param entry removalEntry
---@return table?
local function getEntryElementKind(entry)
    for _, kind in pairs(elementKinds) do
        if entry[kind.list] then return kind end
    end
end

--- Number of actors / instances of the targeted node (of its inner node for cooked nodes), nil if unknown
---@param nodeData table RHT target data
---@param kind table
---@return number?
local function getElementCount(nodeData, kind)
    local node = nodeData.nodeDefinition
    -- Index of the cooked inner node (2.5), only used when RHT gives a valid one
    local inner = nodeData.innerIndex
    local hasInner = type(inner) == "number" and type(nodeData.innerCount) == "number" and inner >= 0 and inner < nodeData.innerCount

    if kind == elementKinds.actor then
        -- worldCookedCollisionNode (2.5) does not expose its actors to scripts: RHT's actorCount (set when the
        -- collision is hit in Inspect) is the actor count of the targeted inner node, checked against the sectors.
        -- actorOffset only splits a node into physics proxies of 64 actors.
        return (IsDefined(node) and positiveInt(try(function() return node.numActors end))) -- worldCollisionNode (2.31)
            or positiveInt(nodeData.actorCount)
    end

    if IsDefined(node) then
        local count = (hasInner and positiveInt(try(function() return node.transformRanges[inner + 1].numTransforms end))) -- worldInstancedMeshNode (2.5)
            or positiveInt(try(function() return node.worldTransformsBuffer.numElements end)) -- worldInstancedMeshNode (2.31)
            or positiveInt(try(function() return #node.instanceTransforms end)) -- worldInstancedDestructibleMeshNode
            or positiveInt(try(function() return node.cookedInstanceTransforms.numElements end)) -- worldInstancedDestructibleMeshNode
        if count then return count end
    end

    return positiveInt(nodeData.actorCount) -- RHT: instance count of the targeted mesh
end

--- Index of the actor / instance the target points at, nil if the whole node is targeted
---@param nodeData table RHT target data
---@param kind table
---@param count number?
---@return number?, string?
local function getTargetElement(nodeData, kind, count)
    -- Collisions not hit by a physics trace (e.g. from the Scanner) target the whole node
    if kind == elementKinds.actor and not nodeData.collision then return nil end

    local index = nodeData.actorIndex
    if type(index) ~= "number" and nodeData.physicsActorOffset and nodeData.physicsActorIndex then
        index = nodeData.physicsActorOffset + nodeData.physicsActorIndex
    end
    if type(index) ~= "number" or index < 0 then return nil end

    if kind == elementKinds.instance and not positiveInt(nodeData.actorCount) then return nil end
    if count and index >= count then
        return nil, string.format("[RemovalEditor] Error: %s %d is out of range (%d), re-send the node from RHT!", kind.label, index, count)
    end

    return index
end

--- Value of nbNodesUnderProxyDiff this removal accounts for
---@param entry removalEntry
---@param nodeData table? RHT target data, only needed for a whole worldInstancedMeshNode
---@return number
local function getProxyDiff(entry, nodeData)
    local kind = getEntryElementKind(entry)
    local isInstancedMesh = entry.type == "worldInstancedMeshNode"

    if kind then
        local listed, expected = #entry[kind.list], entry[kind.expected]
        if isInstancedMesh then return listed end -- Each instance counts as a node under the proxy
        if expected and listed >= expected then return 1 end
        return 0 -- The node itself stays
    end

    if isInstancedMesh then
        local count = nodeData and getElementCount(nodeData, elementKinds.instance)
        if not count then
            print("[RemovalEditor] Warning: Instance count of this worldInstancedMeshNode is unknown, its proxy might not hide properly.")
        end
        return count or 1
    end

    return 1
end

---@class removalEntry
---@field type string
---@field index number
---@field actorDeletions table?
---@field expectedActors number?
---@field instanceDeletions table?
---@field expectedInstances number?
---@field nbNodesUnderProxyDiff number?
---@field proxyHash string?
---@field proxyDiff number?
---@field nodeRefHash string?
---@field nodeRef string
---@field resource string
---@field position table
---@field orientation table
---@field debugName string

---@class proxyMutation
---@field type string
---@field index number
---@field nodeRefHash string
---@field nbNodesUnderProxyDiff number

local removal = {
    runtimeData = {
        cetOpen = false,
        rhtInstalled = false,
    },

    uiData = {
        newPresetName = "",
        newNote = "",
        switchToEdit = false
    },

    presets = {},
    notes = {},
    currentFile = "",
    directAdd = true,
    searchText = "",
    reload = false,
    reloadTransform = {}
}

function removal:getEditFlag()
    if self.uiData.switchToEdit then
        self.uiData.switchToEdit = false
        return ImGuiTabItemFlags.SetSelected
    end
    return ImGuiTabItemFlags.None
end

function removal:drawPresetUI()
    for _, file in pairs(dir("data")) do
        if file.name:match("^.+(%..+)$") == ".xl" then
            if not self.presets[file.name] then
                self.presets[file.name] = config.loadFile("data/" .. file.name)

                for  _, sector in pairs(self.presets[file.name].streaming.sectors) do
                    if not sector.nodeDeletions then
                        sector.nodeDeletions = {}
                    end
                    if not sector.nodeMutations then
                        sector.nodeMutations = {}
                    end
                end
            end
        end
    end

    self.uiData.newPresetName =  ImGui.InputTextWithHint("##newName", "Name...", self.uiData.newPresetName, 100)
    self.uiData.newPresetName = utils.sanitizeFileName(self.uiData.newPresetName) -- Sanitize
    local validName = #self.uiData.newPresetName > 0

    ImGui.SameLine()

    style.pushGreyedOut(not validName)

    if ImGui.Button("Create") and validName then
        config.tryCreateConfig("data/" .. self.uiData.newPresetName .. ".xl", {streaming = {sectors = {}}})
        self.uiData.newPresetName = ""
    end

    style.popGreyedOut(not validName)
    style.spacedSeparator()

    local elements = math.max(5, math.min(20, utils.countTableSize(self.presets))) -- Guh
    ImGui.BeginChild("##presets", -1, elements * ImGui.GetFrameHeightWithSpacing()) -- What

    for name, preset in pairs(self.presets) do
        if ImGui.TreeNodeEx(name:match("(.+)%..+$"), ImGuiTreeNodeFlags.SpanFullWidth) then
            style.drawProp("Sectors", #preset.streaming.sectors)
            style.drawProp("Removals", utils.getTotalRemovals(preset))
            style.drawProp("Mutations", utils.getTotalMutations(preset))

            ImGui.PushStyleVar(ImGuiStyleVar.FramePadding, 5, 2)

            if ImGui.Button("Edit") then
                self.currentFile = name
                self.uiData.switchToEdit = true
            end
            ImGui.SameLine()
            if ImGui.Button("Delete") then
                os.remove("data/" .. name)
                self.presets[name] = nil
                if self.currentFile == name then
                    self.currentFile = ""
                end
            end
            ImGui.SameLine()
            if ImGui.Button("Install & Reload") then
                RedHotTools.HotInstall(string.format("bin\\x64\\plugins\\cyber_engine_tweaks\\mods\\removalEditor\\data\\%s", name))
                self.reloadTransform.position = GetPlayer():GetWorldPosition()
                self.reloadTransform.rotation = GetPlayer():GetWorldOrientation():ToEulerAngles()
                self.reload = true

                Game.GetSystemRequestsHandler():LoadLastCheckpoint(true)
            end
            utils.tooltip("Make a Quick-Save to speed up the reload process.")
            ImGui.PopStyleVar(1)

            ImGui.TreePop()
        end
    end

    ImGui.EndChild()
end

--- Actor / instance list of a removal
---@param preset table
---@param entry removalEntry
---@param kind table
function removal:drawElements(preset, entry, kind)
    local list = entry[kind.list]
    local expected = entry[kind.expected]

    local label = string.format("%s (%d / %s)##elements", kind.label, #list, expected and tostring(expected) or "?")
    if not ImGui.TreeNodeEx(label, ImGuiTreeNodeFlags.SpanFullWidth) then return end

    if not expected then
        ImGui.PushStyleColor(ImGuiCol.Text, 0xff5555ff)
        ImGui.TextWrapped(string.format("No %s set: ArchiveXL removes the whole node. Re-send it from RHT's Inspect tab to fix it.", kind.expected))
        ImGui.PopStyleColor()
    end

    -- Without a known count, list the elements this removal ever had
    local indices = {}
    if expected then
        for index = 0, expected - 1 do table.insert(indices, index) end
    else
        local known = knownElements[entry] or {}
        for _, index in ipairs(list) do
            if not utils.has_value(known, index) then table.insert(known, index) end
        end
        table.sort(known)
        knownElements[entry] = known
        indices = known
    end

    local changed = false
    ImGui.BeginChild("##elements", -1, math.max(1, math.min(8, #indices)) * ImGui.GetFrameHeightWithSpacing())

    for _, index in ipairs(indices) do
        local value = utils.has_value(list, index)
        local newValue, toggled = ImGui.Checkbox(tostring(index), value)
        if toggled then
            if newValue then
                table.insert(list, index)
            else
                utils.removeItem(list, index)
            end
            changed = true
        end
    end

    ImGui.EndChild()

    if ImGui.Button("Remove whole node") then
        local diff = entry.type == "worldInstancedMeshNode" and (expected or #list) or 1
        entry[kind.list] = nil
        entry[kind.expected] = nil
        self:setProxyDiff(preset, entry, diff)
        changed = true
    elseif changed then
        self:setProxyDiff(preset, entry, getProxyDiff(entry))
    end
    utils.tooltip("Remove the node with all its " .. string.lower(kind.label) .. ", instead of a selection of them.")

    if changed then
        config.saveFile("data/" .. self.currentFile, preset)
    end

    ImGui.TreePop()
end

function removal:drawDirectTarget()
    style.pushGreyedOut(not target)
    ImGui.Spacing()

    if not target then
        ImGui.Text("No node selected, send one here first from the RedHotTools window!")
    else
        style.drawProp("Collision", target.collisionGroup)
        style.drawProp("Node Type", target.nodeType)
        style.drawProp("Node Index", target.instanceIndex .. " / " .. target.instanceCount)
        style.drawProp("World Sector", target.sectorPath)
        style.drawProp("Mesh", target.meshPath)
        style.drawProp("Material", target.materialPath)
        style.drawProp("Entity Template", target.templatePath)

        if target.nodeRef then
            style.drawProp("Node Ref", target.nodeRef)
        end
        if target.debugName then
            style.drawProp("Debug Name", target.debugName)
        end

        local position = target.nodePosition or target.entityPosition
        if position then
            style.drawProp("Position", string.format("X: %.2f Y: %.2f Z: %.2f", position.x, position.y, position.z))
        end

        local kind = getElementKind(target.nodeType)
        if kind then
            local count = getElementCount(target, kind)
            local element = getTargetElement(target, kind, count)
            style.drawProp(kind == elementKinds.actor and "Collision Actor" or "Instance",
                (element and tostring(element) or "All") .. " / " .. (count and tostring(count) or "?"))
        end

        ImGui.PushStyleColor(ImGuiCol.Text, 0xff9f9f9f)
        ImGui.TextWrapped("Note:")
        ImGui.PopStyleColor()
        ImGui.SameLine()

        local sectorName = target.sectorPath:match("(.+)%..+$"):match("[^\\]*.$")
        local note = self.notes[tostring(sectorName .. "_" .. target.instanceIndex)] or ""
        local text, changed = ImGui.InputTextWithHint("##noteAdd", "Note...", note, 100)
        if changed and #text > 0 then
            self.notes[tostring(sectorName .. "_" .. target.instanceIndex)] = text
            config.saveFile("data/notes.json", self.notes)
        elseif changed then
            self.notes[tostring(sectorName .. "_" .. target.instanceIndex)] = nil
            config.saveFile("data/notes.json", self.notes)
        end
    end

    ImGui.Spacing()

    if ImGui.Button("Add Staged Node", style.width, style.buttonY) then
        if target then
            self:addRemoval(target)
        end
    end

    style.popGreyedOut(not target)
end

function removal:drawEditUI()
    if not self.presets[self.currentFile] then
        ImGui.Text("No preset loaded.")
        return
    end

    local mode = "Direct Add [Add directly to preset when clicking button in RHT]"
    if not self.directAdd then
        mode = "Add with confirmation [Node to be removed gets staged here first]"
    end
    style.drawProp("Staging Mode", mode)
    self.directAdd = ImGui.Checkbox("Add nodes directly from RedHotTools window", self.directAdd)

    if ImGui.Button("Add all scanned & filtered nodes") then
        local nodes = GetMod("RedHotTools").GetWorldScannerFilteredResults()

        for _, node in pairs(nodes) do
            target = node
            self:addRemoval(node)
        end
    end

    if not self.directAdd then
        style.spacedSeparator()
        self:drawDirectTarget()
    end
    style.spacedSeparator()

    ImGui.PushItemWidth(400)
    self.searchText = ImGui.InputTextWithHint("##searchForNode", "Search for node (Type, Sector, Index, Note)", self.searchText, 100)
    if self.searchText ~= "" then
        ImGui.SameLine()
        if ImGui.Button("X") then
            self.searchText = ""
        end
    end

    style.spacedSeparator()

    self:drawRemovals(self.presets[self.currentFile])
end

function removal:drawRemovals(preset)
    local elements = math.max(8, math.min(20, utils.getTotalRemovals(preset)))
    ImGui.BeginChild("##removals", -1, elements * ImGui.GetFrameHeightWithSpacing())

    local deleted = nil

    for _, sector in pairs(preset.streaming.sectors) do
        for _, entry in pairs(sector.nodeDeletions) do
            if self:isRemovalSearched(sector, entry) then
                if ImGui.TreeNodeEx("##" .. tostring(entry.index) .. tostring(sector.path), ImGuiTreeNodeFlags.SpanFullWidth, self:getRemovalName(entry, sector)) then
                    ImGui.PushStyleVar(ImGuiStyleVar.FramePadding, 5, 2)

                    if not self:drawRemoval(preset, sector, entry) then
                        deleted = { sector = sector, entry = entry }
                    end

                    ImGui.PopStyleVar(1)
                    ImGui.TreePop()
                end
            end
        end
    end

    ImGui.EndChild()

    -- Deleted once the lists are no longer iterated
    if deleted then
        self:deleteRemoval(preset, deleted.sector, deleted.entry)
    end
end

function removal:drawRemoval(preset, sector, entry)
    style.drawProp("Type", entry.type)
    style.drawProp("Sector Path", sector.path)
    style.drawProp("Node Index", tostring(entry.index .. "/" .. sector.expectedNodes))
    if entry.position then
        style.drawProp("Position", string.format("X: %.2f Y: %.2f Z: %.2f", entry.position.x, entry.position.y, entry.position.z))
    end
    if entry.debugName ~= "" then
        style.drawProp("Debug Name", entry.debugName)
    end
    if entry.resource ~= "" then
        style.drawProp("Resource", entry.resource)
    end
    if entry.nodeRef ~= "" then
        style.drawProp("NodeRef", entry.nodeRef)
    end

    local kind = getEntryElementKind(entry)
    if kind then
        self:drawElements(preset, entry, kind)
    end

    ImGui.PushStyleColor(ImGuiCol.Text, 0xff9f9f9f)
    ImGui.TextWrapped("Note:")
    ImGui.PopStyleColor()
    ImGui.SameLine()

    local sectorName = sector.path:match("(.+)%..+$"):match("[^\\]*.$")
    local note = self.notes[tostring(sectorName .. "_" .. entry.index)] or ""
    local text, changed = ImGui.InputTextWithHint("##noteRemoval", "Note...", note, 100)
    if changed and #text > 0 then
        self.notes[tostring(sectorName .. "_" .. entry.index)] = text
        config.saveFile("data/notes.json", self.notes)
    elseif changed then
        self.notes[tostring(sectorName .. "_" .. entry.index)] = nil
        config.saveFile("data/notes.json", self.notes)
    end

    if ImGui.Button("Remove") then
        return false
    end

    return true
end

function removal:drawUI()
    ImGui.SetNextWindowSize(style.width + style.paddingX * 2, 0)
    ImGui.PushStyleVar(ImGuiStyleVar.WindowPadding, style.paddingX, style.paddingY)

    if ImGui.Begin("Removal Editor", ImGuiWindowFlags.NoResize + ImGuiWindowFlags.NoScrollbar) then
        if not self.runtimeData.rhtInstalled then
            ImGui.Text("RedHotTools is not installed!")
            ImGui.End()
            return
        end

        ImGui.BeginTabBar("Tabbar", ImGuiTabItemFlags.NoTooltip)

        if ImGui.BeginTabItem(" Presets ") then
            ImGui.Spacing()
            self:drawPresetUI()
            ImGui.EndTabItem()
        end

        if ImGui.BeginTabItem(" Edit ", self:getEditFlag()) then
            ImGui.Spacing()
            self:drawEditUI()
            ImGui.EndTabItem()
        end
    end
    ImGui.End()
end

--- Get the removal table to be used in the .xl file for a specific node. Changes nothing in the preset.
---@param nodeData table RHT target data
---@return removalEntry?, string?
local function getNodeRemoval(nodeData)
    local result = {
        type = nodeData.nodeType,
        index = nodeData.instanceIndex
    }

    local kind = getElementKind(nodeData.nodeType)
    if not kind then return result end

    local count = getElementCount(nodeData, kind)
    local element, err = getTargetElement(nodeData, kind, count)
    if err then return nil, err end

    if element and not count then
        -- ArchiveXL removes the whole node when a list comes without its expected count (tested in 2.5)
        return nil, string.format("[RemovalEditor] Error: %s count of this node is unknown, target it in RHT's Inspect tab and re-send it!", kind.label)
    end

    if element and not (kind == elementKinds.instance and count == 1) then
        -- A single actor / instance
        result[kind.list] = { element }
        result[kind.expected] = count
    elseif kind == elementKinds.actor and count then
        -- Whole collision node, listing its actors so that they can be un-removed one by one
        local actors = {}
        for i = 0, count - 1 do
            table.insert(actors, i)
        end
        result[kind.list] = actors
        result[kind.expected] = count
    end

    return result
end

local function isWorldNode(node)
    return node and node.sectorPath and node.instanceIndex
end

local function sendNode(node)
    target = node

    if removal.directAdd then
        removal:addRemoval(target)
    end
end

---Excludes collision nodes, as they can be expanded
---@param sector table
---@param index number
---@return boolean, removalEntry?
local function hasSectorRemoval(sector, index)
    if not sector or not index then return false end

    for _, removal in pairs(sector.nodeDeletions) do
        if removal.index == index then return true, removal end
    end

    return false
end

function removal:addSector(preset, sectorPath, instanceCount)
    local sector = utils.findSectorByPath(preset.streaming.sectors, sectorPath)
    if not sector then
        sector = {
            path = sectorPath,
            nodeDeletions = {},
            nodeMutations = {},
            expectedNodes = instanceCount,
        }
        table.insert(preset.streaming.sectors, sector)
    end

    return sector
end

---@param hash number
---@return proxyMutation?
function removal:createProxyMutation(hash)
    local proxy = nil
    local preset = self.presets[self.currentFile]
    if not preset then return end

    local hashString = tostring(hash):gsub("ULL", "")
    for _, sector in pairs(preset.streaming.sectors) do
        for _, node in pairs(sector.nodeMutations) do
            if node.nodeRefHash == hashString then
                return node
            end
        end
    end

    if not proxy then
        local sectorData = Game.GetWorldInspector():ResolveSectorDataFromNodeID(hash)

        if not sectorData or sectorData.sectorHash == 0 then
            print("[RemovalEditor] Error: Proxy node of this removal not found!")
            return
        end

        proxy = {
            type = sectorData.nodeType.value,
            index = sectorData.instanceIndex,
            nodeRefHash = tostring(hash):gsub("ULL", ""),
            nbNodesUnderProxyDiff = 0
        }

        local sectorPath = RedHotTools.GetResourcePath(sectorData.sectorHash)
        local sector = removal:addSector(preset, sectorPath, sectorData.instanceCount)
        table.insert(sector.nodeMutations, proxy)
    end

    return proxy
end

---@param preset table
---@param hashString string
---@return proxyMutation?
local function findProxyMutation(preset, hashString)
    for _, sector in pairs(preset.streaming.sectors) do
        for _, node in pairs(sector.nodeMutations) do
            if node.nodeRefHash == hashString then
                return node
            end
        end
    end
end

--- Sets the share of the proxy's nbNodesUnderProxyDiff this removal accounts for
---@param preset table
---@param entry removalEntry
---@param diff number
function removal:setProxyDiff(preset, entry, diff)
    if not entry.proxyHash then return end

    local delta = diff - (entry.proxyDiff or 0)
    if delta == 0 then return end

    local proxy = findProxyMutation(preset, entry.proxyHash)
    if proxy then
        proxy.nbNodesUnderProxyDiff = proxy.nbNodesUnderProxyDiff - delta
    elseif diff > 0 then
        print("[RemovalEditor] Error: Proxy mutation of this removal is missing, re-send the node from RHT!")
        return
    end

    entry.proxyDiff = diff
end

--- Links a new removal to the proxy mesh it is part of, once the removal is in the preset
---@param preset table
---@param entry removalEntry
---@param nodeData table RHT target data
function removal:attachProxy(preset, entry, nodeData)
    local proxyID = nodeData.nodeProxyID
    if not proxyID or proxyID == 0 then return end

    local proxy = self:createProxyMutation(proxyID)
    if not proxy then return end

    entry.proxyHash = proxy.nodeRefHash
    entry.proxyDiff = 0
    self:setProxyDiff(preset, entry, getProxyDiff(entry, nodeData))
end

--- Removes the proxy mutations no removal uses anymore, then the empty sectors
---@param preset table
function removal:cleanupPreset(preset)
    local used = {}
    for _, sector in pairs(preset.streaming.sectors) do
        for _, entry in pairs(sector.nodeDeletions) do
            if entry.proxyHash then used[entry.proxyHash] = true end
        end
    end

    for sectorKey = #preset.streaming.sectors, 1, -1 do
        local sector = preset.streaming.sectors[sectorKey]

        for mutationKey = #sector.nodeMutations, 1, -1 do
            local mutation = sector.nodeMutations[mutationKey]
            if mutation.nodeRefHash and not used[mutation.nodeRefHash]
                and mutation.nbNodesUnderProxyDiff and mutation.nbNodesUnderProxyDiff >= 0 then
                table.remove(sector.nodeMutations, mutationKey)
            end
        end

        if #sector.nodeDeletions == 0 and #sector.nodeMutations == 0 then
            table.remove(preset.streaming.sectors, sectorKey)
        end
    end
end

--- Adds an actor / instance to an existing removal of the same node
---@param preset table
---@param entry removalEntry
---@param nodeData table RHT target data
---@return boolean changed
function removal:addElementToRemoval(preset, entry, nodeData)
    local kind = getEntryElementKind(entry)
    if not kind then return false end -- The whole node is already removed

    local count = entry[kind.expected] or getElementCount(nodeData, kind)
    local element, err = getTargetElement(nodeData, kind, count)
    if err then print(err) end
    if not element then return false end

    local changed = false
    if not entry[kind.expected] and count then
        entry[kind.expected] = count -- Fills in the count missing from an older removal
        changed = true
    end
    if utils.has_value(entry[kind.list], element) then return changed end

    table.insert(entry[kind.list], element)
    self:setProxyDiff(preset, entry, getProxyDiff(entry))
    return true
end

function removal:addRemoval(nodeData)
    local preset = self.presets[self.currentFile]
    if not preset then return end

    local existingSector = utils.findSectorByPath(preset.streaming.sectors, nodeData.sectorPath)
    local hasRemoval, data = hasSectorRemoval(existingSector, nodeData.instanceIndex)

    if hasRemoval then
        if data and self:addElementToRemoval(preset, data, nodeData) then
            config.saveFile("data/" .. self.currentFile, preset)
        end
        return
    end

    -- Everything is validated before the preset is touched
    local removal, err = getNodeRemoval(nodeData)
    if not removal then
        print(err)
        return
    end

    local position = nodeData.nodePosition or nodeData.entityPosition
    local orientation = nodeData.nodeOrientation or nodeData.entityOrientation
    if position then
        removal.position = { x = position.x, y = position.y, z = position.z }
    end
    if orientation then
        removal.orientation = { i = orientation.i, j = orientation.j, k = orientation.k, r = orientation.r }
    end
    removal.nodeRef = nodeData.nodeRef or ""
    removal.resource = nodeData.meshPath or nodeData.templatePath or nodeData.materialPath or nodeData.effectPath or nodeData.recordID or ""
    removal.debugName = nodeData.debugName or ""

    local sector = self:addSector(preset, nodeData.sectorPath, nodeData.instanceCount)
    table.insert(sector.nodeDeletions, 1, removal)
    self:attachProxy(preset, removal, nodeData)

    config.saveFile("data/" .. self.currentFile, preset)

    if self.uiData.newNote ~= "" then
        local sectorName = nodeData.sectorData.sectorPath:match("(.+)%..+$"):match("[^\\]*.$")
        self.notes[tostring(sectorName .. "_" .. nodeData.sectorData.instanceIndex)] = self.uiData.newNote
        config.saveFile("data/notes.json", self.notes)
        self.uiData.newNote = ""
    end
end

function removal:getRemovalName(entry, sector)
    local sectorName = sector.path:match("(.+)%..+$"):match("[^\\]*.$")
    local name = self.notes[tostring(sectorName .. "_" .. entry.index)]
    if name then
        name = name
    else
        name = entry.type
    end
    return name .. " | " .. sectorName .. " | " .. entry.index .. " / " .. sector.expectedNodes
end

function removal:isRemovalSearched(sector, entry)
    if self.searchText == "" then return true end

    local text = string.lower(self.searchText)
    if string.match(string.lower(sector.path), text) then return true end
    if string.match(string.lower(tostring(entry.index)), text) then return true end
    if string.match(string.lower(tostring(entry.type)), text) then return true end

    local sectorName = sector.path:match("(.+)%..+$"):match("[^\\]*.$")
    local note = self.notes[tostring(sectorName .. "_" .. entry.index)]
    if note ~= nil and string.match(string.lower(note), text) ~= nil then return true end

    return false
end

function removal:deleteRemoval(preset, sector, entry)
    self:setProxyDiff(preset, entry, 0)

    local entryKey = utils.getIndex(sector.nodeDeletions, entry)
    if entryKey then
        table.remove(sector.nodeDeletions, entryKey)
    end

    self:cleanupPreset(preset)

    config.saveFile("data/" .. self.currentFile, preset)
end

function removal:new()
    registerForEvent("onInit", function()
        self.runtimeData.rhtInstalled = Game.GetWorldInspector() ~= nil

        config.tryCreateConfig("data/notes.json", self.notes)
        self.notes = config.loadFile("data/notes.json")

        GameUI.OnSessionStart(function()
            if self.reload then
                self.reload = false
                Game.GetTeleportationFacility():Teleport(GetPlayer(), self.reloadTransform.position, self.reloadTransform.rotation)
            end
        end)

        GetMod("RedHotTools").RegisterExtension({
            getTargetActions = function(node)
                if isWorldNode(node) then
                    return {
                        type = "button",
                        label = ("Send node to Removal Editor"),
                        callback = sendNode,
                    }
                end
            end
        })
    end)

    registerForEvent("onDraw", function()
        style.initStyles()

        if removal.runtimeData.cetOpen then
            self:drawUI()
        end
    end)

    registerForEvent("onOverlayOpen", function()
        self.runtimeData.cetOpen = true
    end)

    registerForEvent("onOverlayClose", function()
        self.runtimeData.cetOpen = false
    end)

    return removal
end

registerHotkey("addNode", "Add [Inspect] node", function()
    local node = GetMod("RedHotTools").GetWorldInspectorTarget()
    if not node then return end
    target = node
    removal:addRemoval(target)
end)

return removal:new()
-- The Presets tab: creating, opening, deleting and installing presets
local utils = require("modules/utils/utils")
local settings = require("modules/utils/settings")
local presets = require("modules/utils/presets")
local style = require("modules/ui/style")

local DELETE_POPUP = "Delete preset?"

local presetsUI = {
    baseUI = nil,
    newPresetName = "",
    pendingInstall = nil, -- Outdated preset waiting for its second click
    deleteFile = nil, -- Preset the delete popup is about
    openDeletePopup = false
}

--- Warning when the preset was not made for the running game version, and the button that records it
---@param name string
---@param preset table
function presetsUI.drawVersionWarning(name, preset)
    local version = presets.getOutdatedVersion(preset)
    if not version then return end

    local current = presets.gameVersion
    -- The version is a comment, which JSON cannot hold
    local isYaml = presets.isYaml(name)

    style.styledText(IconGlyphs.AlertOutline, style.warnColor)
    ImGui.SameLine()
    if version == "unknown" then
        style.styledTextWrapped(string.format("Game version unknown%s: if this preset was made before %s, its node indices are probably wrong. Convert it with ArchiveXL Sector Updater.",
            isYaml and "" or " (a JSON preset cannot record it)", current), style.warnColor)
    else
        style.styledTextWrapped(string.format("Made for %s, the game is %s: node indices may have changed. Convert it with ArchiveXL Sector Updater.", version, current), style.warnColor)
    end

    if not isYaml then return end

    if ImGui.Button("Mark as made for " .. current) then
        presets.setGameVersion(preset, current)
        presets.save(name)
    end
    style.tooltip("Writes \"# Game version: " .. current .. "\" at the start of the file, once its nodes have been checked or converted for " .. current .. ".")
end

---@param name string
local function requestDelete(name)
    if settings.deleteConfirm then
        presetsUI.deleteFile = name
        presetsUI.openDeletePopup = true
    else
        presets.delete(name)
    end
end

-- As World Builder's "Delete Data?" popup
local function drawDeletePopup()
    if presetsUI.openDeletePopup then
        ImGui.OpenPopup(DELETE_POPUP)
        presetsUI.openDeletePopup = false
    end

    if not ImGui.BeginPopupModal(DELETE_POPUP, ImGuiWindowFlags.AlwaysAutoResize) then return end

    local name = presetsUI.deleteFile or ""
    ImGui.Text(string.format("\"%s\" will be deleted from the data folder.", utils.removeExtension(name)))
    ImGui.Spacing()

    local again, changed = ImGui.Checkbox("Don't ask again", not settings.deleteConfirm)
    if changed then
        settings.deleteConfirm = not again
        settings.save()
    end
    style.tooltip("Can be turned back on in Settings")

    ImGui.Spacing()

    if ImGui.Button("Cancel") then
        presetsUI.deleteFile = nil
        ImGui.CloseCurrentPopup()
    end

    ImGui.SameLine()

    if style.dangerButton("Delete") then
        if presetsUI.deleteFile and presets.list[presetsUI.deleteFile] then
            presets.delete(presetsUI.deleteFile)
        end
        presetsUI.deleteFile = nil
        ImGui.CloseCurrentPopup()
    end

    ImGui.EndPopup()
end

---@param name string
---@param preset table
local function drawPreset(name, preset)
    if not ImGui.TreeNodeEx(utils.removeExtension(name) .. "##" .. name, ImGuiTreeNodeFlags.SpanFullWidth) then return end

    local valueX = style.getPropertiesX({ "Sectors", "Removals", "Mutations", "Game Version", "Format" })
    style.drawProp("Sectors", #preset.streaming.sectors, valueX)
    style.drawProp("Removals", utils.getTotalRemovals(preset), valueX)
    style.drawProp("Mutations", utils.getTotalMutations(preset), valueX)
    style.drawProp("Game Version", presets.getGameVersion(preset) or "unknown", valueX)
    style.drawProp("Format", presets.isYaml(name) and "YAML" or "JSON", valueX)

    presetsUI.drawVersionWarning(name, preset)

    if ImGui.Button("Edit") then
        presets.open(name)
        presetsUI.baseUI.selectTab("edit")
    end
    style.tooltip("Opens the preset in the Edit tab")
    ImGui.SameLine()

    if ImGui.Button("Delete") then
        requestDelete(name)
    end
    ImGui.SameLine()

    local inGame = IsDefined(GetPlayer())
    -- A preset made for another game version is only installed on a second click
    local outdated = presets.getOutdatedVersion(preset) ~= nil
    local confirming = outdated and presetsUI.pendingInstall == name
    style.pushGreyedOut(not inGame)
    if ImGui.Button(confirming and "Install anyway" or "Install & Reload") and inGame then
        if outdated and not confirming then
            presetsUI.pendingInstall = name
        else
            presetsUI.pendingInstall = nil
            presets.install(name)
        end
    end
    style.popGreyedOut(not inGame)
    if confirming then
        style.tooltip("This preset was not made for this game version: ArchiveXL may remove the wrong objects.")
    else
        style.tooltip("Installs the preset and reloads the last save. Make a Quick-Save first, to keep your progress and speed up the reload.")
    end

    ImGui.TreePop()
    ImGui.Spacing()
end

function presetsUI.draw()
    presets.refresh()

    style.sectionHeaderStart("NEW PRESET")

    style.setNextItemWidth(250)
    presetsUI.newPresetName = style.inputTextWithHint("##newName", "Name...", presetsUI.newPresetName, 100)
    presetsUI.newPresetName = utils.sanitizeFileName(presetsUI.newPresetName)
    local validName = presetsUI.newPresetName:match("%S") ~= nil

    ImGui.SameLine()

    style.pushGreyedOut(not validName)
    if ImGui.Button("Create") and validName then
        if presets.create(presetsUI.newPresetName:match("^%s*(.-)%s*$")) then
            presetsUI.newPresetName = ""
        end
    end
    style.popGreyedOut(not validName)
    style.tooltip(string.format("Creates an empty %s preset in the data folder (Settings > Presets to change the format).\nCharacters a file name cannot hold become \"_\".",
        settings.defaultPresetFormat == "json" and "JSON" or "YAML"))

    style.sectionHeaderEnd()
    style.sectionHeaderStart("PRESETS")

    ImGui.BeginChild("##presets", -1, 0)

    for _, name in ipairs(presets.getSortedNames()) do
        drawPreset(name, presets.list[name])
    end

    -- Files that could not be read stay listed, instead of breaking the whole window
    for name, err in pairs(presets.invalid) do
        ImGui.PushID(name)
        if style.iconButton(IconGlyphs.Reload, "Load it again, once fixed") then
            presets.invalid[name] = nil
        end
        ImGui.SameLine()
        style.styledTextWrapped(string.format("%s: cannot be loaded (%s)", name, err), style.errorColor)
        ImGui.PopID()
    end

    if utils.tableLength(presets.list) == 0 and utils.tableLength(presets.invalid) == 0 then
        style.mutedText("No preset yet, create one above.")
    end

    ImGui.EndChild()
    style.sectionHeaderEnd(true)

    drawDeletePopup()
end

return presetsUI

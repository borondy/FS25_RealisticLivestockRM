--[[
    RmMigrationManager.lua
    Handles migration from FS25_RealisticLivestock to FS25_RealisticLivestockRM

    Migration responsibilities:
    1. Detect old mod conflict (both mods installed)
    2. Detect if migration is needed (old data exists, new data doesn't)
    3. Show migration dialog to user

    NON-DESTRUCTIVE MIGRATION APPROACH:
    All migration is handled via dual-read support in the loading code:
    - RLSettings.lua tries rm_RlSettings.xml first, falls back to rlSettings.xml
    - RealisticLivestock_AnimalSystem.lua tries rm_RlAnimalSystem.xml first, falls back to animalSystem.xml
    - RmItemSystemMigration.lua patches items.xml and handTools.xml in-memory

    When the game saves, it writes to the NEW filenames only, effectively completing
    the migration. The user can revert to the old mod before saving without data loss.

    NOTE: No state file is used because FS25 replaces the entire savegame folder on save,
    only preserving files written during the save callback. Migration detection relies on
    checking whether new files (rm_RlSettings.xml) exist.
]]

local Log = RmLogging.getLogger("RLRM")

RmMigrationManager = {}

local RmMigrationManager_mt = Class(RmMigrationManager)

-- Legacy mod name - used by the in-file migration helpers (items.xml / handTools.xml
-- old-data detection). Scoped private so the conflict-detection registry below is the
-- single public source of truth for mod-compatibility checks.
local LEGACY_MOD_NAME = "FS25_RealisticLivestock"

-- Single declarative registry of known-incompatible mods, partitioned at runtime by
-- :checkModCompatibility() into self.blockingMods (severity="block", existing UX with
-- doRestart) and self.warningMods (severity="warn", new dismissible InfoDialog).
-- Block entries use the shared rm_rl_mod_conflict_message body (one-dialog UX), so
-- their reasonKey is intentionally nil. Warn entries require a per-mod reasonKey.
RmMigrationManager.KNOWN_INCOMPATIBLE_MODS = {
    { name = "FS25_RealisticLivestock",     severity = "block", reasonKey = nil },
    { name = "FS25_MoreVisualAnimals",      severity = "block", reasonKey = nil },
    { name = "FS25_EnhancedLivestock",      severity = "block", reasonKey = nil },
    { name = "FS25_EnhancedAnimalSystem",   severity = "block", reasonKey = nil },
    { name = "FS25_AnimalFoodCalculator",   severity = "warn",  reasonKey = "rl_mod_warn_FS25_AnimalFoodCalculator" },
}

-- Global instance
g_rmMigrationManager = nil

-- Pending dialog flags (set during checkModCompatibility, consumed by the startup
-- dialog queue in RealisticLivestock_FSBaseMission:onStartMission).
g_rmPendingMigration = false
g_rmMigrationConflict = false
g_rmPendingModWarning = false


function RmMigrationManager.new()
    local self = setmetatable({}, RmMigrationManager_mt)
    self.savegameDir = nil
    return self
end

function RmMigrationManager:initialize(overrideSavegameDir)
    -- Allow override of savegame directory (used for early migration before g_currentMission is ready)
    if overrideSavegameDir ~= nil then
        self.savegameDir = overrideSavegameDir
        return true
    end

    if g_currentMission == nil or g_currentMission.missionInfo == nil then
        return false
    end

    self.savegameDir = g_currentMission.missionInfo.savegameDirectory
    if self.savegameDir == nil then
        return false
    end

    return true
end

-- Set the savegame directory directly (for early migration)
function RmMigrationManager:setSavegameDir(savegameDir)
    self.savegameDir = savegameDir
end

--[[
    Check known-incompatible mods loaded on this peer and partition into
    blocking (severity="block") and warning (severity="warn") buckets.

    Sets self.blockingMods + self.warningMods (arrays of registry entries) and
    unconditionally re-assigns the global flags from the partition counts so
    they reset on every check (no stale flags between mission loads).

    Detection is peer-agnostic: g_modIsLoaded is authoritative per peer, so
    every peer (server, listen-server host, pure client, dediserver) runs this
    against its own modset. FS25 enforces identical mod sets in MP, so each
    peer effectively sees the same partition.

    Log levels per docs/conventions/logging-levels.md:
    - Per-warn: WARNING (advisory; not fatal but the user should know)
    - Block summary: ERROR (save-data/MP-corruption hazard; dediserver has no
      dialog surface so the log line is the admin-visible signal)
    - Final summary: INFO (informational trace that the check ran, regardless of state)
]]
function RmMigrationManager:checkModCompatibility()
    Log:info("Checking mod compatibility...")

    self.blockingMods = {}
    self.warningMods = {}

    if g_modIsLoaded == nil then
        Log:warning("g_modIsLoaded is nil!")
        g_rmMigrationConflict = false
        g_rmPendingModWarning = false
        Log:info("Mod compatibility check: 0 blocker(s), 0 warning(s)")
        return false
    end

    for _, entry in ipairs(RmMigrationManager.KNOWN_INCOMPATIBLE_MODS) do
        if g_modIsLoaded[entry.name] == true then
            if entry.severity == "block" then
                table.insert(self.blockingMods, entry)
                Log:debug("  block-tier match: %s", entry.name)
            elseif entry.severity == "warn" then
                table.insert(self.warningMods, entry)
                -- Resolve reason text with safe fallback to entry.name. Two miss paths:
                --   (a) reasonKey is nil    -> registry contract drift (warn-tier should
                --                              always have a reasonKey); fall back to name.
                --   (b) reasonKey unresolved -> active locale missing the key; getText
                --                              returns a placeholder string that would
                --                              leak into UX as visible text. Route through
                --                              hasText first and fall back to name.
                -- Same fallback used by showWarningDialog (single source of truth).
                local reasonText = entry.name
                if entry.reasonKey ~= nil and g_i18n:hasText(entry.reasonKey) then
                    reasonText = g_i18n:getText(entry.reasonKey)
                end
                Log:warning("Mod warning: %s - %s", entry.name, reasonText)
            else
                Log:warning("Unknown severity '%s' for mod '%s' in KNOWN_INCOMPATIBLE_MODS",
                    tostring(entry.severity), entry.name)
            end
        end
    end

    if #self.blockingMods > 0 then
        local names = {}
        for _, e in ipairs(self.blockingMods) do table.insert(names, e.name) end
        -- ERROR (escalated from prior WARNING): dediserver has no dialog surface,
        -- so this log line is the admin-visible signal that a hard-conflict mod
        -- is present. See docs/conventions/logging-levels.md.
        Log:error("Conflicting mods found: %s", table.concat(names, ", "))
    end

    g_rmMigrationConflict = #self.blockingMods > 0
    g_rmPendingModWarning = #self.warningMods > 0

    Log:info("Mod compatibility check: %d blocker(s), %d warning(s)",
        #self.blockingMods, #self.warningMods)

    return g_rmMigrationConflict or g_rmPendingModWarning
end

--[[
    Show conflict dialog listing ALL blocking-tier mods and force a restart.

    The optional callback parameter exists for queue symmetry only (so the
    startup-dialog queue can pass `showNext` in for every kind uniformly) -
    it is intentionally never invoked from this path because the dialog's OK
    handler calls doRestart(false, "") which ends the Lua state. The queue is
    abandoned at that point.

    Uses a short timer delay so the dialog overlays on the gameplay screen
    rather than getting lost during the loading->gameplay transition.

    @param callback function|nil Unused on the conflict path; doRestart wins.
]]
function RmMigrationManager:showConflictDialog(callback)
    Log:info("Scheduling conflict dialog...")

    -- Defensive: if called without a populated partition (e.g. test misuse,
    -- or queue dispatch on a manager whose check never ran), skip the dialog.
    -- The Log:error in checkModCompatibility is the only reliable surface for a
    -- block-tier conflict; presenting a dialog with an empty mod list would mislead.
    if self.blockingMods == nil or #self.blockingMods == 0 then
        Log:warning("showConflictDialog called with no blockingMods; skipping dialog")
        return
    end

    Timer.createOneshot(100, function()
        -- Guard against mid-startup unload: if the user backed out during the
        -- 100ms window, g_currentMission/g_gui can be torn down. Skip the
        -- dialog and abandon the chain; doRestart wouldn't fire either way
        -- because there's nothing to OK.
        if g_currentMission == nil or g_gui == nil then
            Log:debug("showConflictDialog timer fired post-unload; skipping")
            return
        end
        Log:info("Showing conflict dialog")

        local title = g_i18n:getText("rm_rl_conflict_title")
        local modList = ""
        for _, entry in ipairs(self.blockingMods) do
            modList = modList .. "\n- " .. entry.name
        end
        local message = string.format(g_i18n:getText("rm_rl_mod_conflict_message"), modList)

        InfoDialog.show(title .. "\n\n" .. message, function()
            Log:info("User acknowledged conflict, restarting game")
            -- Restart the game so user can disable the conflicting mod(s).
            -- callback is intentionally NOT invoked here - doRestart ends the chain.
            doRestart(false, "")
        end, self)
    end)
end

--[[
    Show warning dialog listing all warn-tier mods detected on this peer.

    Non-blocking: the user dismisses with OK and gameplay continues. The
    callback (typically the queue's `showNext`) fires after dismissal so the
    next startup dialog can present.

    Caller is responsible for guarding against headless dedicated servers
    (where InfoDialog cannot render) - see RealisticLivestock_FSBaseMission's
    queue builder, which suppresses warn-kind enqueue when g_dedicatedServer
    is set.

    @param callback function|nil Invoked after the user dismisses the dialog.
]]
function RmMigrationManager:showWarningDialog(callback)
    Log:info("Scheduling warning dialog...")

    -- Defensive: if there's nothing to warn about, advance the queue immediately
    -- rather than rendering an empty-bullet dialog with title + URL but no entries.
    if self.warningMods == nil or #self.warningMods == 0 then
        Log:warning("showWarningDialog called with no warningMods; skipping dialog")
        if callback ~= nil then callback() end
        return
    end

    Timer.createOneshot(100, function()
        -- Guard against mid-startup unload: if the user backed out during
        -- the 100ms window, advance the queue from the timer (callback is the
        -- queue's showNext) so we don't leave it stalled. The next showNext
        -- will hit its own teardown guard if needed.
        if g_currentMission == nil or g_gui == nil then
            Log:debug("showWarningDialog timer fired post-unload; skipping dialog")
            if callback ~= nil then callback() end
            return
        end
        Log:info("Showing warning dialog (%d warning(s))", #self.warningMods)

        -- Resolve i18n with safe fallbacks. g_i18n:getText on a missing key returns
        -- "Missing 'KEY' in l10n*.xml" placeholder text leaks into UX,
        -- so route through hasText first.
        local title = g_i18n:hasText("rl_mod_warn_title")
            and g_i18n:getText("rl_mod_warn_title")
            or "Mod Compatibility Warning"
        local urlLine = g_i18n:hasText("rl_mod_compat_url")
            and g_i18n:getText("rl_mod_compat_url")
            or "https://rittermod.github.io/FS25_RealisticLivestockRM/user-guide/reference-mod-compatibility"

        -- Build bullet list. Same fallback contract as checkModCompatibility:
        -- nil reasonKey OR unresolved key -> entry.name (single source of truth).
        local bullets = ""
        for _, entry in ipairs(self.warningMods) do
            local reasonText = entry.name
            if entry.reasonKey ~= nil and g_i18n:hasText(entry.reasonKey) then
                reasonText = g_i18n:getText(entry.reasonKey)
            end
            bullets = bullets .. "\n- " .. reasonText
            Log:debug("  warn entry presented: %s -> reasonKey=%s",
                entry.name, tostring(entry.reasonKey))
        end

        -- Format-string protection: rl_mod_warn_message expects exactly two %s
        -- (bullets, urlLine). A community translator dropping one would crash
        -- string.format and abort the dispatch chain. Guard with pcall and fall
        -- back to manual concatenation. Only applied to the warn body where the
        -- format string includes the URL placeholder; rm_rl_mod_conflict_message
        -- has only one %s and is unchanged byte-for-byte (block-tier scope).
        local fmtTemplate = g_i18n:hasText("rl_mod_warn_message")
            and g_i18n:getText("rl_mod_warn_message")
            or "The following mod(s) loaded with Realistic Livestock RM may cause issues:%s\n\nSee %s for details. The game will continue."
        local ok, body = pcall(string.format, fmtTemplate, bullets, urlLine)
        if not ok then
            Log:warning("rl_mod_warn_message format failed (translator dropped a %%s placeholder?): %s; falling back to plain concatenation",
                tostring(body))
            body = "The following mod(s) loaded with Realistic Livestock RM may cause issues:"
                .. bullets .. "\n\nSee " .. urlLine .. " for details. The game will continue."
        end

        InfoDialog.show(title .. "\n\n" .. body, function()
            Log:info("User dismissed warning dialog")
            if callback ~= nil then callback() end
        end, self)
    end)
end

--[[
    Check if migration is needed
    Returns true if:
    - Old data files exist AND
    - New data files don't exist
]]
function RmMigrationManager:shouldMigrate()
    if not self:initialize() then
        return false
    end

    -- Check for old data
    local hasOldSettings = fileExists(self.savegameDir .. "/rlSettings.xml")
    local hasOldAnimalSystem = fileExists(self.savegameDir .. "/animalSystem.xml")
    local hasOld = hasOldSettings or hasOldAnimalSystem

    if not hasOld then
        return false
    end

    -- Check for new data (if exists, no migration needed - user already saved with new mod)
    local hasNewSettings = fileExists(self.savegameDir .. "/rm_RlSettings.xml")
    if hasNewSettings then
        return false
    end

    return true
end

--[[
    Get list of old data files that exist
    Returns table with file info for display in migration dialog
]]
function RmMigrationManager:getOldDataFiles()
    if not self:initialize() then
        return {}
    end

    local files = {}

    if fileExists(self.savegameDir .. "/rlSettings.xml") then
        table.insert(files, { name = "rlSettings.xml", type = "Settings" })
    end

    if fileExists(self.savegameDir .. "/animalSystem.xml") then
        table.insert(files, { name = "animalSystem.xml", type = "Animal System" })
    end

    -- Check for Dewar items in items.xml (modName=LEGACY_MOD_NAME)
    if self:hasOldItemsData() then
        table.insert(files, { name = "items.xml", type = "Dewars" })
    end

    -- Check for AI Straw hand tools in handTools.xml (filename contains $moddir$<legacy>/)
    if self:hasOldHandToolsData() then
        table.insert(files, { name = "handTools.xml", type = "AI Straw Hand Tools" })
    end

    -- Check for HandToolAIStraw namespace data in items.xml (legacy namespace migration)
    local itemsPath = self.savegameDir .. "/items.xml"
    if fileExists(itemsPath) then
        local itemsXml = XMLFile.loadIfExists("items", itemsPath)
        if itemsXml ~= nil then
            local hasOldNamespace = false
            itemsXml:iterate("items.item", function(_, key)
                local oldKey = key .. ".FS25_RealisticLivestock.aiStraw"
                if itemsXml:hasProperty(oldKey) then
                    hasOldNamespace = true
                    return false -- Stop iteration
                end
            end)
            itemsXml:delete()

            if hasOldNamespace then
                table.insert(files, { name = "items.xml (namespace)", type = "AI Straw Data" })
            end
        end
    end

    return files
end

--[[
    Check if items.xml has old mod references (className/modName)
    This is different from namespace migration - this is about the item registration itself
]]
function RmMigrationManager:hasOldItemsData()
    if not self:initialize() then
        return false
    end

    local itemsPath = self.savegameDir .. "/items.xml"
    if not fileExists(itemsPath) then
        return false
    end

    local xmlFile = XMLFile.loadIfExists("items_check", itemsPath)
    if xmlFile == nil then
        return false
    end

    local hasOldData = false
    xmlFile:iterate("items.item", function(_, key)
        local modName = xmlFile:getString(key .. "#modName")
        if modName == LEGACY_MOD_NAME then
            hasOldData = true
            return false -- Stop iteration
        end
    end)

    xmlFile:delete()
    return hasOldData
end

--[[
    Check if handTools.xml has old mod references in filename attribute
    Note: Hand tools don't have a modName attribute, they use filename with $moddir$ModName/ path
]]
function RmMigrationManager:hasOldHandToolsData()
    if not self:initialize() then
        return false
    end

    local handToolsPath = self.savegameDir .. "/handTools.xml"
    if not fileExists(handToolsPath) then
        return false
    end

    local xmlFile = XMLFile.loadIfExists("handTools_check", handToolsPath)
    if xmlFile == nil then
        return false
    end

    local hasOldData = false
    local oldModPath = "$moddir$" .. LEGACY_MOD_NAME .. "/"

    xmlFile:iterate("handTools.handTool", function(_, key)
        local filename = xmlFile:getString(key .. "#filename")
        if filename ~= nil and string.find(filename, oldModPath, 1, true) then
            hasOldData = true
            return false -- Stop iteration
        end
    end)

    xmlFile:delete()
    return hasOldData
end

--[[
    Show migration dialog to user.
    Uses a short timer delay for consistency with showConflictDialog.

    @param callback function|nil Forwarded to RmMigrationDialog.show as the
        Continue-path callback so the startup-dialog queue can chain. The Quit
        path inside RmMigrationDialog calls doRestart and short-circuits the
        queue; the callback is not invoked in that case.
]]
function RmMigrationManager:showMigrationDialog(callback)
    Log:info("Scheduling migration dialog...")

    Timer.createOneshot(100, function()
        -- Mid-startup unload guard:
        -- if the user backed out during the 100ms window, advance the queue
        -- (callback is the queue's showNext). The next showNext will hit its
        -- own teardown guard if needed.
        if g_currentMission == nil or g_gui == nil then
            Log:debug("showMigrationDialog timer fired post-unload; skipping dialog")
            if callback ~= nil then callback() end
            return
        end
        Log:info("Showing migration dialog")

        if RmMigrationDialog ~= nil and RmMigrationDialog.show ~= nil then
            local files = self:getOldDataFiles()
            RmMigrationDialog.show(files, callback)
        else
            Log:error("RmMigrationDialog not available")
            if callback ~= nil then callback() end
        end
    end)
end

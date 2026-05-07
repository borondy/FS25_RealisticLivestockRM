--[[
    RmMigrationDialog.lua
    Dialog for prompting user about data migration from old RealisticLivestock mod
]]

RmMigrationDialog = {}

local RmMigrationDialog_mt = Class(RmMigrationDialog, MessageDialog)
local modDirectory = g_currentModDirectory
local Log = RmLogging.getLogger("RLRM")

-- Singleton instance
RmMigrationDialog.INSTANCE = nil


function RmMigrationDialog.register()
    local dialog = RmMigrationDialog.new()
    g_gui:loadGui(modDirectory .. "gui/RmMigrationDialog.xml", "RmMigrationDialog", dialog)
    RmMigrationDialog.INSTANCE = dialog
end


function RmMigrationDialog.new(target, customMt)
    local self = MessageDialog.new(target, customMt or RmMigrationDialog_mt)
    self.files = {}
    self.continueCallback = nil
    return self
end


--[[
    Show the migration dialog.

    @param files table|nil List of {name, type} entries shown to the user.
    @param callback function|nil Optional callback invoked AFTER the dialog
        closes via the Continue path. Used by the startup-dialog queue in
        RealisticLivestock_FSBaseMission:onStartMission to chain the warn /
        bridge dialogs once migration is acknowledged. The Quit path calls
        doRestart and short-circuits the queue (callback is not fired).
        Callback ordering: self:close() runs FIRST, then the callback fires,
        so the next queued dialog never tries to show while this one is
        still on screen.
]]
function RmMigrationDialog.show(files, callback)
    if RmMigrationDialog.INSTANCE == nil then
        RmMigrationDialog.register()
    end

    local dialog = RmMigrationDialog.INSTANCE
    dialog.files = files or {}
    dialog.continueCallback = callback
    dialog:setDialogType(DialogElement.TYPE_INFO)
    dialog:updateContent()

    Log:debug("RmMigrationDialog.show: files=%d, callback=%s",
        #dialog.files, tostring(callback ~= nil))
    g_gui:showDialog("RmMigrationDialog")
end


function RmMigrationDialog:onOpen()
    RmMigrationDialog:superClass().onOpen(self)
    FocusManager:setFocus(self.continueButton)
end


function RmMigrationDialog:onClose()
    RmMigrationDialog:superClass().onClose(self)
    self.files = {}
    -- Drop any pending continueCallback so an ESC/back-button dismiss does not
    -- leak it into the next .show() call. Note: this is a fail-safe; the
    -- ordinary Continue path already nulls continueCallback in onClickContinue
    -- before invoking it, and Quit nulls it before doRestart. We do NOT fire
    -- the callback here on dismissal - we'd rather stall the queue than
    -- present the next dialog from an already-closing context (no two
    -- startup dialogs are ever on screen simultaneously).
    if self.continueCallback ~= nil then
        Log:debug("Migration dialog: onClose dropped pending continueCallback")
        self.continueCallback = nil
    end
end


function RmMigrationDialog:onCreate()
    RmMigrationDialog:superClass().onCreate(self)
end


function RmMigrationDialog:updateContent()
    -- Update title
    if self.titleElement ~= nil then
        self.titleElement:setText(g_i18n:getText("rm_rl_migration_title"))
    end

    -- Update message
    if self.messageElement ~= nil then
        self.messageElement:setText(g_i18n:getText("rm_rl_migration_message"))
    end

    -- Update file list
    if self.fileListElement ~= nil then
        local fileText = ""
        for _, file in ipairs(self.files) do
            fileText = fileText .. "- " .. file.name .. " (" .. file.type .. ")\n"
        end
        self.fileListElement:setText(fileText)
    end
end


--[[
    User clicked "Continue" button.
    Close the dialog and continue loading - migration happens automatically via
    dual-read/new-save. Fires self.continueCallback (if set by .show()) AFTER
    closing, so the startup-dialog queue can chain the next dialog without two
    dialogs being on screen at once.

    Capture-before-close ordering: snapshot the callback into a local first,
    null the field, THEN close. This is necessary because onClose (the dialog
    base-class close hook, which fires from self:close()) also clears
    self.continueCallback as a fail-safe for ESC/back-button paths - if we
    capture after close, the callback is gone. close-before-callback ordering
    is still preserved because callback() is invoked AFTER self:close() returns.
]]
function RmMigrationDialog:onClickContinue()
    Log:info("Migration dialog: user clicked Continue")
    -- Capture BEFORE close so onClose's defensive null-out doesn't drop us.
    local callback = self.continueCallback
    self.continueCallback = nil
    self:close()
    if callback ~= nil then
        Log:debug("Migration dialog: firing continue callback")
        callback()
    end
end


--[[
    User clicked "Quit" button
    Exit to main menu - short-circuits any queued startup dialogs (callback never fires).
]]
function RmMigrationDialog:onClickQuit()
    Log:info("Migration dialog: user clicked Quit, restarting game")
    self.continueCallback = nil
    doRestart(false, "")
end

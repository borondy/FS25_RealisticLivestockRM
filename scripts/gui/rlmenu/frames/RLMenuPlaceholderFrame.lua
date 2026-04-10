--[[
    RLMenuPlaceholderFrame.lua
    Phase 0 placeholder tab for the RL Tabbed Menu shell.

    Minimal TabbedMenuFrameElement subclass with zero business logic.
    Exists only so the RLMenu shell has a visible tab during Phase 0 smoke testing.
    Deleted in Phase 1 when RLMenuMessagesFrame lands and becomes the first real tab.

    See: docs/tasks/rl-tabbed-menu-migration.md (master migration plan, Phase 0)
    Reference: ../Fresh/FS25_Fresh/scripts/gui/frames/RmOverviewFrame.lua
]]

RLMenuPlaceholderFrame = {}
local RLMenuPlaceholderFrame_mt = Class(RLMenuPlaceholderFrame, TabbedMenuFrameElement)

-- Store mod directory at source time (g_currentModDirectory is only valid during source())
local modDirectory = g_currentModDirectory

--- Construct a new RLMenuPlaceholderFrame instance.
--- Called once by setupGui() during mod load; the FS25 Paging element may deep-clone
--- the returned frame for dual-instance safety.
--- @return table self The new frame instance
function RLMenuPlaceholderFrame.new()
    local self = RLMenuPlaceholderFrame:superClass().new(nil, RLMenuPlaceholderFrame_mt)
    self.name = "RLMenuPlaceholderFrame"
    Log:trace("RLMenuPlaceholderFrame.new: instance created")
    return self
end

--- Load the placeholder frame XML and register the frame with g_gui.
--- Must run BEFORE RLMenu.setupGui() loads rlMenu.xml, because rlMenu.xml's
--- <FrameReference ref="RLMenuPlaceholderFrame"/> resolves against the registered frame name.
--- Called from RLMenu.setupGui() (not directly from main.lua).
function RLMenuPlaceholderFrame.setupGui()
    local frame = RLMenuPlaceholderFrame.new()
    g_gui:loadGui(
        Utils.getFilename("gui/rlmenu/placeholderFrame.xml", modDirectory),
        "RLMenuPlaceholderFrame",
        frame,
        true  -- true = frame-only load (not a full GUI)
    )
    Log:debug("RLMenuPlaceholderFrame.setupGui: placeholder frame registered")
end

--- Called when the Paging element activates this tab.
--- Phase 0: no data to refresh, no focus management beyond the superclass default.
function RLMenuPlaceholderFrame:onFrameOpen()
    RLMenuPlaceholderFrame:superClass().onFrameOpen(self)
    Log:trace("RLMenuPlaceholderFrame:onFrameOpen")
end

--- Called when the Paging element deactivates this tab.
--- Phase 0: no state to persist.
function RLMenuPlaceholderFrame:onFrameClose()
    RLMenuPlaceholderFrame:superClass().onFrameClose(self)
    Log:trace("RLMenuPlaceholderFrame:onFrameClose")
end

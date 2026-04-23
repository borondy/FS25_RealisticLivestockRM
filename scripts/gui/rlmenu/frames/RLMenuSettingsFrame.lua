--[[
    RLMenuSettingsFrame.lua
    RL Tabbed Menu Settings tab - shell only.

    Horizontal subcategory tab bar with two empty content panes:
      [General] - placeholder for future non-filter settings.
      [Filters] - populated by a later phase with filter CRUD UI.

    Tab highlight, pager texts, and focus are seeded in
    initializeSubCategoryPages() called from onFrameOpen on every open,
    so closures stay bound to the live frame instance across opens.

    No filter-domain logic here - no service, no list, no editor.
]]

RLMenuSettingsFrame = {}
local RLMenuSettingsFrame_mt = Class(RLMenuSettingsFrame, TabbedMenuFrameElement)

local Log = RmLogging.getLogger("RLRM")

-- Store mod directory at source time (g_currentModDirectory only valid during source())
local modDirectory = g_currentModDirectory

--- Subcategory enum. Indices match XML subCategoryTabs[] and subCategoryPages[].
RLMenuSettingsFrame.SUB_CATEGORY = {
    GENERAL = 1,
    FILTERS = 2,
}

--- Construct a new RLMenuSettingsFrame instance.
--- Called once by setupGui() during mod load.
--- @return table self The new frame instance
function RLMenuSettingsFrame.new()
    local self = RLMenuSettingsFrame:superClass().new(nil, RLMenuSettingsFrame_mt)
    self.name = "RLMenuSettingsFrame"
    Log:trace("RLMenuSettingsFrame.new: instance created")
    return self
end

--- Load the settings frame XML and register the frame with g_gui.
--- Called from RLMenu.setupGui() before the menu XML is loaded so that
--- rlMenu.xml's FrameReference ref="RLMenuSettingsFrame" resolves.
function RLMenuSettingsFrame.setupGui()
    local frame = RLMenuSettingsFrame.new()
    g_gui:loadGui(
        Utils.getFilename("gui/rlmenu/settingsFrame.xml", modDirectory),
        "RLMenuSettingsFrame",
        frame,
        true  -- frame-only load
    )
    Log:debug("RLMenuSettingsFrame.setupGui: registered")
end

--- Called by the GUI manager after all element references are wired.
--- Do NOT mutate the tree here (fires on both the original and the clone).
--- Closure binding + setTexts live in initializeSubCategoryPages() and are
--- invoked from onFrameOpen() to keep per-clone state fresh on every open.
function RLMenuSettingsFrame:onGuiSetupFinished()
    RLMenuSettingsFrame:superClass().onGuiSetupFinished(self)
    Log:trace("RLMenuSettingsFrame:onGuiSetupFinished")
end

--- Per-clone setup. Called explicitly by RLMenu:setupMenuPages() on the
--- live clone (not the original) after registerPage. No-op in P1-1 -
--- there is no tree mutation to perform; kept as a convention marker for
--- future phases that may need per-clone unlink/teardown.
function RLMenuSettingsFrame:initialize()
    Log:debug("RLMenuSettingsFrame:initialize")
end

--- Called by the Paging element when this tab becomes active.
--- Rebinds tab selection closures, seeds paging texts, resets to General,
--- and parks focus on the tab bar. Rebinding every open (rather than once
--- in onGuiSetupFinished) keeps closures captured against the live frame
--- instance and survives repeated opens.
function RLMenuSettingsFrame:onFrameOpen()
    RLMenuSettingsFrame:superClass().onFrameOpen(self)
    Log:debug("RLMenuSettingsFrame:onFrameOpen")

    self:initializeSubCategoryPages()

    -- Default to [General] on every open - deliberate, no persistence in P1-1.
    self.subCategoryPaging:setState(RLMenuSettingsFrame.SUB_CATEGORY.GENERAL, true)

    -- Explicit focus on the tab bar - the only focusable element in P1-1's
    -- empty-pane shell. Without this, FocusManager auto-layout can resolve
    -- gamepad/keyboard navigation to elements in other frames.
    FocusManager:setFocus(self.subCategoryPaging)
end

--- Called by the Paging element when this tab is deactivated.
function RLMenuSettingsFrame:onFrameClose()
    RLMenuSettingsFrame:superClass().onFrameClose(self)
    Log:debug("RLMenuSettingsFrame:onFrameClose")
end

--- Seed the subcategory tab bar: bind getIsSelected closures on each tab
--- Button and its background ThreePartBitmap, populate subCategoryPaging
--- texts with stringified indices, and size the pager to the tab box.
---
--- The closures resolve via `tonumber(self.subCategoryPaging.texts[state])`
--- rather than `subCategoryPaging:getState()` directly because `.texts`
--- is the authoritative visible-index-to-semantic-index map - needed so
--- highlight stays correct if tab visibility ever becomes dynamic.
function RLMenuSettingsFrame:initializeSubCategoryPages()
    Log:debug("RLMenuSettingsFrame:initializeSubCategoryPages: binding %d tab(s)",
        #self.subCategoryTabs)

    local subCategories = {}

    for index, button in ipairs(self.subCategoryTabs) do
        -- Tab Button's highlight (outer click surface)
        button.getIsSelected = function()
            return index == tonumber(self.subCategoryPaging.texts[self.subCategoryPaging:getState()])
        end

        -- Tab background ThreePartBitmap (renders the selected/unselected slices)
        local bg = button:getDescendantByName("background")
        if bg ~= nil then
            bg.getIsSelected = function()
                return index == tonumber(self.subCategoryPaging.texts[self.subCategoryPaging:getState()])
            end
        else
            Log:warning("RLMenuSettingsFrame:initializeSubCategoryPages: tab %d missing 'background' descendant",
                index)
        end

        table.insert(subCategories, tostring(index))
    end

    self.subCategoryBox:invalidateLayout()
    self.subCategoryPaging:setTexts(subCategories)
    self.subCategoryPaging:setSize(self.subCategoryBox.maxFlowSize + 140 * g_pixelSizeScaledX)
end

--- Pager state-change callback (XML onClick on subCategoryPaging). Resolves
--- visible state to a semantic index via .texts and toggles pane visibility.
--- Nil-guards the .texts lookup - the map is briefly out-of-sync with the
--- state during setTexts, and an early return keeps the pane set stable.
--- @param state number The paging state index (1..#texts)
function RLMenuSettingsFrame:updateSubCategoryPages(state)
    local idx = tonumber(self.subCategoryPaging.texts[state])
    if idx == nil then
        Log:trace("RLMenuSettingsFrame:updateSubCategoryPages: state=%s resolved to nil idx, skipping",
            tostring(state))
        return
    end

    Log:debug("RLMenuSettingsFrame:updateSubCategoryPages: state=%d idx=%d", state, idx)

    for index, page in ipairs(self.subCategoryPages) do
        page:setVisible(index == idx)
    end
end

--- XML onClick handler for the [General] tab button.
function RLMenuSettingsFrame:onClickGeneralTab()
    Log:trace("RLMenuSettingsFrame:onClickGeneralTab")
    self.subCategoryPaging:setState(RLMenuSettingsFrame.SUB_CATEGORY.GENERAL, true)
end

--- XML onClick handler for the [Filters] tab button.
function RLMenuSettingsFrame:onClickFiltersTab()
    Log:trace("RLMenuSettingsFrame:onClickFiltersTab")
    self.subCategoryPaging:setState(RLMenuSettingsFrame.SUB_CATEGORY.FILTERS, true)
end

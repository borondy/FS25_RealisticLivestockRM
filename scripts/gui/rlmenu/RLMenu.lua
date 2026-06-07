--[[
    RLMenu.lua
    Root controller for the RL Tabbed Menu (standalone TabbedMenu subclass).

    Opened via the unbound RL_MENU input action (user assigns a key in
    Settings -> Controls). ESC closes via the standard FS25 back-button
    pattern; the menu does NOT implement toggle-to-close (Fresh's
    quick-view pattern is unsuitable for a destination menu).

    Tabs (Buy, Sell, Move, Manage, AI, Messages, Settings) live under
    frames/ with shared logic under services/.
]]

RLMenu = RLMenu or {}
local RLMenu_mt = Class(RLMenu, TabbedMenu)

-- Store mod directory at source time (g_currentModDirectory is only valid during source())
local modDirectory = g_currentModDirectory

-- Input action name for opening the menu. Declared in modDesc.xml, unbound by default.
RLMenu.ACTION_NAME = "RL_MENU"

-- Open-mode constants. MODE_FULL is the default; MODE_DEALER hides Move/
-- Messages/Settings tabs via predicate gating so the menu acts as the
-- destination for shop "Buy Animals" and walk-up dealer triggers (the
-- legacy AnimalScreen.show dealer-shape entry redirects here).
RLMenu.MODE_FULL = "full"
RLMenu.MODE_DEALER = "dealer"

-- Highest page id registered in setupMenuPages. Used as the upper bound for
-- openFromBridge's startPageId validation. If a tab is added/removed, bump
-- this and renumber setupMenuPages in lockstep -- the spec ASKS to halt on
-- such changes.
RLMenu.PAGE_COUNT = 8

-- Dev-only GUI hot-reload (Mechanism B). When true, open() re-runs the full
-- setupGui() parse so on-disk XML/profile edits show up on reopen with no game
-- restart. Each reload leaks the prior element tree and double-registers its
-- message-center subscriptions, so it is a local-iteration tool only: never commit true.
RLMenu.DEV_RELOAD_XML = false

--- Construct a new RLMenu instance. Called once from setupGui() during mod load.
--- @param target table|nil
--- @param custom_mt table|nil
--- @return table self
function RLMenu.new(target, custom_mt)
    local self = TabbedMenu.new(target, custom_mt or RLMenu_mt)
    self.isOpen = false

    -- Shared selection state across husbandry-based tabs (Info, Move, Sell).
    -- Exported on frame close, imported on frame open. Frames that share the
    -- same husbandry selector pattern can participate by reading/writing this.
    -- { husbandry = placeable ref, animalIdentity = { farmId, uniqueId, country } }
    self.sharedSelection = nil

    -- Open mode: MODE_FULL exposes all 7 tabs (keyboard-shortcut path);
    -- MODE_DEALER hides Move/Messages/Settings via predicate gating
    -- (set by RLMenu.openFromBridge for the AnimalScreen dealer-shape redirect).
    -- Reset to MODE_FULL on every onClose so the next keyboard open is unaffected.
    self.openMode = RLMenu.MODE_FULL

    Log:trace("RLMenu.new: instance created (openMode=%s)", tostring(self.openMode))
    return self
end

--- One-time mod-load setup: profiles, frames, and the menu XML.
--- Order matters:
---   1. Profiles must load before any GUI XML that references them
---   2. Frame XMLs must load before the menu XML so FrameReference refs resolve
---   3. Menu XML loads last, linking everything together
--- Called from main.lua at end-of-file after all source() calls complete.
function RLMenu.setupGui()
    Log:debug("RLMenu.setupGui: begin")

    -- 1. Load RL menu profiles (separate file from gui/guiProfiles.xml)
    g_gui:loadProfiles(Utils.getFilename("gui/rlmenu/rlMenuProfiles.xml", modDirectory))

    -- 2. Register frames
    RLMenuMessagesFrame.setupGui()
    RLMenuInfoFrame.setupGui()
    RLMenuMoveFrame.setupGui()
    RLMenuSellFrame.setupGui()
    RLMenuBuyFrame.setupGui()
    RLMenuAIFrame.setupGui()
    RLMenuHerdsmanFrame.setupGui()
    RLMenuSettingsFrame.setupGui()

    -- 3. Create the menu instance and load its XML
    g_rlMenu = RLMenu.new()
    g_gui:loadGui(
        Utils.getFilename("gui/rlmenu/rlMenu.xml", modDirectory),
        "RLMenu",
        g_rlMenu,
        false -- false = full GUI (not a frame)
    )

    Log:debug("RLMenu.setupGui complete")
end

--- Called by TabbedMenu after all GUI XML has been parsed and bound.
--- Registers tabs with the Paging element.
function RLMenu:onGuiSetupFinished()
    Log:debug("RLMenu:onGuiSetupFinished: binding menu pages")
    RLMenu:superClass().onGuiSetupFinished(self)
    self:setupMenuPages()
end

--- Register each tab with the TabbedMenu Paging system and run its
--- per-instance initialize() on the clone. At this point
--- `self.messagesFrame` / `self.infoFrame` are the live clones produced
--- by Gui:resolveFrameReference. initialize() is optional on frames and
--- no-op when not overridden.
function RLMenu:setupMenuPages()
    local basePredicate = function() return g_currentMission ~= nil end

    -- Closure-captured instance reference for the dealer-mode predicates.
    -- We read self.openMode through this upvalue (NOT g_rlMenu) so the gating
    -- stays bound to the instance and tests can mock without touching globals.
    -- TabbedMenu:updatePages() re-runs predicates on every onOpen, so this is
    -- a pure function of openMode - no leaks across opens.
    local rlMenu = self
    local function isDealerMode()
        return rlMenu.openMode == RLMenu.MODE_DEALER
    end

    -- Wrap each registered predicate so its final per-tab decision is logged at
    -- TRACE. The spec invariant ("every predicate decision logs Log:trace")
    -- means the discriminator alone is insufficient -- each tab's pass/fail
    -- needs an observable trail at TabbedMenu:updatePages() time.
    local function traced(name, fn)
        return function()
            local result = fn()
            Log:trace("RLMenu predicate %s: %s (openMode=%s)",
                name, tostring(result), tostring(rlMenu.openMode))
            return result
        end
    end

    -- Buy tab (leftmost - most frequent commerce entry point)
    self:registerPage(self.buyFrame, 1, traced("buy", basePredicate))
    self:addPageTab(self.buyFrame, nil, nil, "rlMenu.buy_animal")
    if self.buyFrame ~= nil and self.buyFrame.initialize ~= nil then
        self.buyFrame:initialize()
    end

    -- Sell tab
    self:registerPage(self.sellFrame, 2, traced("sell", basePredicate))
    self:addPageTab(self.sellFrame, nil, nil, "rlMenu.sell_animal")
    if self.sellFrame ~= nil and self.sellFrame.initialize ~= nil then
        self.sellFrame:initialize()
    end

    -- Move tab (hidden in dealer mode)
    self:registerPage(self.moveFrame, 3, traced("move", function()
        return basePredicate() and not isDealerMode()
    end))
    self:addPageTab(self.moveFrame, nil, nil, "rlMenu.move_animal")
    if self.moveFrame ~= nil and self.moveFrame.initialize ~= nil then
        self.moveFrame:initialize()
    end

    -- Manage tab
    self:registerPage(self.infoFrame, 4, traced("info", basePredicate))
    self:addPageTab(self.infoFrame, nil, nil, "rlMenu.info_animal")
    if self.infoFrame ~= nil and self.infoFrame.initialize ~= nil then
        self.infoFrame:initialize()
    end

    -- AI tab
    self:registerPage(self.aiFrame, 5, traced("ai", basePredicate))
    self:addPageTab(self.aiFrame, nil, nil, "rlMenu.manage_animal")
    if self.aiFrame ~= nil and self.aiFrame.initialize ~= nil then
        self.aiFrame:initialize()
    end

    -- Messages tab (hidden in dealer mode)
    self:registerPage(self.messagesFrame, 6, traced("messages", function()
        return basePredicate() and not isDealerMode()
    end))
    self:addPageTab(self.messagesFrame, nil, nil, "rlMenu.notify_animal")
    if self.messagesFrame ~= nil and self.messagesFrame.initialize ~= nil then
        self.messagesFrame:initialize()
    end

    -- Herdsman tab (automated rules editor; hidden in dealer mode)
    self:registerPage(self.herdsmanFrame, 7, traced("herdsman", function()
        return basePredicate() and not isDealerMode()
    end))
    self:addPageTab(self.herdsmanFrame, nil, nil, "rlMenu.herdsman")
    if self.herdsmanFrame ~= nil and self.herdsmanFrame.initialize ~= nil then
        self.herdsmanFrame:initialize()
    end

    -- Settings tab (tail - hosts the saveable-filters editor; hidden in dealer mode)
    self:registerPage(self.settingsFrame, 8, traced("settings", function()
        return basePredicate() and not isDealerMode()
    end))
    self:addPageTab(self.settingsFrame, nil, nil, "gui.icon_options_generalSettings")
    if self.settingsFrame ~= nil and self.settingsFrame.initialize ~= nil then
        self.settingsFrame:initialize()
    end

    Log:debug(
        "RLMenu:setupMenuPages: 8 pages registered (buy, sell, move, manage, ai, messages, herdsman, settings); move/messages/herdsman/settings dealer-mode gated")
end

--- Configure the bottom button bar.
--- ESC-only Back button; no toggle-to-close action. The footer shows
--- "ESC - Back" while the menu is open, matching every other FS25 tabbed menu.
function RLMenu:setupMenuButtonInfo()
    Log:debug("RLMenu:setupMenuButtonInfo: wiring back button")
    RLMenu:superClass().setupMenuButtonInfo(self)

    self.clickBackCallback = self:makeSelfCallback(self.onButtonBack)

    self.backButtonInfo = {
        inputAction = InputAction.MENU_BACK,
        text = g_i18n:getText("button_back"),
        callback = self.clickBackCallback,
    }

    self.defaultMenuButtonInfo = { self.backButtonInfo }
    self.defaultMenuButtonInfoByActions[InputAction.MENU_BACK] = self.backButtonInfo
    self.defaultButtonActionCallbacks = {
        [InputAction.MENU_BACK] = self.clickBackCallback,
    }
end

--- Back button callback (ESC or clicking the Back footer button).
function RLMenu:onButtonBack()
    Log:debug("RLMenu:onButtonBack: closing menu via back")
    self:exitMenu()
end

--- Called by the GUI manager when the menu becomes visible.
--- Tracks open state for the open() no-op guard.
function RLMenu:onOpen()
    RLMenu:superClass().onOpen(self)
    self.isOpen = true
    Log:info("RLMenu opened")
end

--- Called by the GUI manager when the menu is closing.
--- Clears open state + resets per-frame saved-filter session state
---.
function RLMenu:onClose()
    -- Saved-filter session reset across the 4 consumer frames. Runs before
    -- superClass().onClose so frame references are still live. Nil-guards
    -- each frame (early-init edge case: menu close before a frame finished
    -- .new()).
    local frames = { self.infoFrame, self.buyFrame, self.sellFrame, self.moveFrame }
    local cleared = 0
    for _, f in ipairs(frames) do
        if f ~= nil and f.activeFilterId ~= nil then
            f.activeFilterId = nil
            f.activeFilter = nil
            cleared = cleared + 1
        end
    end
    if cleared > 0 then
        Log:debug("RLMenu:onClose: reset activeFilterId on %d frame(s)", cleared)
    end

    -- Save-from-QF handshake cleanup. openSettingsFilter stashes pendingSelectedFilterId
    -- and then asks the page selector to switch to Settings. RLMenuSettingsFrame:onFrameOpen
    -- consumes-and-clears the id on the next open. If the user ESCs out of the menu
    -- between the Save and Settings paint (or any failure interleaves), a leftover id
    -- would hijack-select an unrelated filter on the next legitimate menu open.
    -- Cleared here so the next open always starts clean.
    if self.pendingSelectedFilterId ~= nil then
        Log:debug("RLMenu:onClose: clearing leftover pendingSelectedFilterId=%s",
            tostring(self.pendingSelectedFilterId))
        self.pendingSelectedFilterId = nil
    end

    -- Clear the cross-frame shared filter id too so the next menu open starts
    -- clean. Info/Move/Sell read + write sharedSelection.activeFilterId for
    -- tab-switch preservation.
    if self.sharedSelection ~= nil and self.sharedSelection.activeFilterId ~= nil then
        Log:debug("RLMenu:onClose: clearing sharedSelection.activeFilterId=%s",
            tostring(self.sharedSelection.activeFilterId))
        self.sharedSelection.activeFilterId = nil
    end

    -- Capture dealer-mode state BEFORE super onClose so we can decide whether
    -- to force a Buy-tab anchor on next open. Reset openMode here too so any
    -- frame close hooks invoked by super see MODE_FULL (predicate-gated tabs
    -- that may run logic on close should not see leaked dealer state).
    local wasDealer = (self.openMode == RLMenu.MODE_DEALER)
    self.openMode = RLMenu.MODE_FULL

    -- Wrap super-onClose in pcall: base TabbedMenu:onClose touches
    -- currentPage:onFrameClose(), g_inputBinding, pageSelector:getState(),
    -- and g_currentMission:resetGameState(). Any one of those can nil-deref
    -- in a torn-down session and would skip the wasDealer force-reset below,
    -- leaking dealer-mode page anchoring into the next open. pcall makes the
    -- force-reset unconditional.
    local superOk, superErr = pcall(function() RLMenu:superClass().onClose(self) end)
    if not superOk then
        Log:warning("RLMenu:onClose: super-onClose threw (err=%s); continuing close",
            tostring(superErr))
    end

    -- Force restorePageIndex = 1 AFTER super onClose: TabbedMenu:onClose
    -- overwrites self.restorePageIndex with self.pageSelector:getState() (a
    -- VISIBLE-tab index). Dealer-mode visible indices differ from full-mode
    -- (e.g. dealer AI sits at visible index 4 where full-mode index 4 is
    -- Info), so a naive snapshot would mode-cross the next shortcut-open onto
    -- the wrong tab. Anchoring at 1 (Buy) is predictable for both modes.
    if wasDealer then
        self.restorePageIndex = 1
        self.restorePage = nil
    end
    Log:debug("RLMenu:onClose: openMode reset (wasDealer=%s, restorePageIndex=%s, superOk=%s)",
        tostring(wasDealer), tostring(self.restorePageIndex), tostring(superOk))

    self.isOpen = false
    Log:info("RLMenu closed")
end

--- Show the menu. No-op if any GUI is already visible to avoid stacking.
--- Invoked by the RL_MENU input action callback.
function RLMenu.open()
    if g_gui:getIsGuiVisible() then
        Log:trace("RLMenu.open: skipped, a GUI is already visible")
        return
    end

    -- Dev hot-reload: re-parse profiles + frames + menu so on-disk XML edits
    -- appear on reopen (gated by DEV_RELOAD_XML, off in release). The
    -- g_gui.currentlyReloading flag MUST bracket the re-parse: without it,
    -- re-loading rlMenuProfiles.xml silently keeps the previously-loaded
    -- profile values, so on-disk edits to existing profiles are dropped. Reset
    -- it on BOTH the success and the throw path -- a stuck `true` makes
    -- RealisticLivestock_AnimalScreen:updateInfoBox short-circuit its whole
    -- body, so the pcall guarantees the reset even if setupGui() errors.
    if RLMenu.DEV_RELOAD_XML then
        Log:debug("RLMenu.open: DEV reloading GUI XML (profiles + frames + menu)")
        g_gui.currentlyReloading = true
        local ok, err = pcall(RLMenu.setupGui)
        g_gui.currentlyReloading = false
        if not ok then
            Log:error("RLMenu.open: DEV reload failed (err=%s)", tostring(err))
        end
    end

    Log:debug("RLMenu.open: showing menu")
    g_gui:showGui("RLMenu")
end

--- Open the RL Menu from another GUI surface (the AnimalScreen.show dealer
--- redirect). Mirrors the legacy `AnimalScreen.show` pattern of calling
--- `g_gui:showGui` directly to REPLACE a non-dialog screen (e.g. the shop
--- menu). Dialog gating still applies: if a modal dialog (YesNoDialog,
--- AnimalFilterDialog, etc.) is up, the bridge bails -- replacing the
--- underlying screen would leave the dialog floating over RLMenu with no
--- owner. State mutations to g_rlMenu happen ONLY after we've decided to
--- show, and are rolled back if showGui throws (so a partial show does not
--- poison the next legitimate open).
---
--- @param startPageId number Page index in [1, RLMenu.PAGE_COUNT] to land on (Buy=1).
--- @param mode string RLMenu.MODE_FULL or RLMenu.MODE_DEALER.
function RLMenu.openFromBridge(startPageId, mode)
    -- Mod load order regression: setupGui() not yet completed when bridge
    -- fires. Caller is expected to fall through to legacy if we early-out.
    if g_rlMenu == nil then
        Log:warning("openFromBridge: g_rlMenu nil, falling back to legacy")
        return
    end

    local validMode = (mode == RLMenu.MODE_FULL or mode == RLMenu.MODE_DEALER)
    local validPage = (type(startPageId) == "number"
        and startPageId >= 1 and startPageId <= RLMenu.PAGE_COUNT)

    if not validMode or not validPage then
        Log:warning("openFromBridge: bad args mode=%s page=%s",
            tostring(mode), tostring(startPageId))
        return
    end

    -- Dialog gate: replacing the underlying screen via showGui leaves any
    -- active dialog floating, with input focus stuck on the dialog and no
    -- valid owner-screen. Bail to legacy AnimalScreen path (caller can
    -- fall through) rather than paint RLMenu under a stale dialog.
    if g_gui.getIsDialogVisible ~= nil and g_gui:getIsDialogVisible() then
        Log:warning("openFromBridge: a dialog is visible, skipping RLMenu redirect")
        return
    end

    -- Snapshot prior state so we can roll back if showGui throws. Without
    -- this, a failed open leaves g_rlMenu poisoned -- the next keyboard
    -- open would inherit dealer-mode tab gating and page-1 anchor.
    local priorOpenMode = g_rlMenu.openMode
    local priorRestorePageIndex = g_rlMenu.restorePageIndex
    local priorRestorePage = g_rlMenu.restorePage

    -- Force restorePageIndex over restorePage: TabbedMenu:onOpen reads
    -- restorePage first, so clearing it makes
    -- pageSelector:setState(restorePageIndex, true) the authoritative path.
    g_rlMenu.openMode = mode
    g_rlMenu.restorePageIndex = startPageId
    g_rlMenu.restorePage = nil

    Log:info("openFromBridge: page=%d mode=%s", startPageId, tostring(mode))

    local ok, err = pcall(function() g_gui:showGui("RLMenu") end)
    if not ok then
        Log:warning("openFromBridge: showGui threw, rolling back state (err=%s)",
            tostring(err))
        g_rlMenu.openMode = priorOpenMode
        g_rlMenu.restorePageIndex = priorRestorePageIndex
        g_rlMenu.restorePage = priorRestorePage
    end
end

--- Switch the menu to Settings -> Filters with a specific saved-filter id
--- pre-selected. Invoked from AnimalFilterDialog:doCreateAndNavigate after the
--- service `:create` succeeds.
---
--- The handshake is a two-step relay:
---   1. Here: stash `pendingSelectedFilterId` on the menu instance, then ask
---      the pageSelector to switch to Settings (page id 8).
---   2. RLMenuSettingsFrame:onFrameOpen consumes-and-clears the id BEFORE its
---      refreshData call so resolveSelectionById lights the new row in the
---      same pass; at the end of onFrameOpen it flips the subCategoryPaging
---      to FILTERS so the editor lands on the new filter.
---
--- `MultiTextOptionElement:setState(state, true)` returns nil (no refusal value
--- to branch on); the MODE_FULL gate on the Save filter button guarantees Settings
--- is reachable when this fires, so there is no "setState refused" path to clean
--- up from. The matched cleanup for the ESC-during-handshake race lives in `onClose`.
--- @param filterId string saved-filter id (return value of g_rlFilterService:create)
function RLMenu:openSettingsFilter(filterId)
    if self.pageSelector == nil then
        Log:warning("RLMenu:openSettingsFilter: pageSelector nil; aborting (filterId=%s)",
            tostring(filterId))
        return
    end
    self.pendingSelectedFilterId = filterId
    self.pageSelector:setState(8, true)
    Log:info("RLMenu:openSettingsFilter: filterId=%s (switched to Settings tab)",
        tostring(filterId))
end

-- =============================================================================
-- INPUT BINDING
-- =============================================================================

--- Input action callback registered via PlayerInputComponent hook.
--- Called by FS25's input system when the user presses the key bound to RL_MENU.
--- @param playerInputComponent table The player input component (unused)
--- @param controlling string Input context ("VEHICLE", "PLAYER", etc.)
function RLMenu.addPlayerActionEvents(playerInputComponent, controlling)
    local triggerUp = false     -- Don't trigger on key release
    local triggerDown = true    -- Trigger on key press
    local triggerAlways = false -- Not continuous
    local startActive = true    -- Active from start
    local callbackState = nil
    local disableConflictingBindings = true

    local success, actionEventId = g_inputBinding:registerActionEvent(
        RLMenu.ACTION_NAME,
        RLMenu,
        RLMenu.open,
        triggerUp, triggerDown, triggerAlways, startActive,
        callbackState, disableConflictingBindings
    )

    if not success then
        -- registerActionEvent has been observed to return false even when
        -- registration succeeded for the VEHICLE context. A non-empty
        -- actionEventId on failure usually means a duplicate registration (benign).
        if controlling == "VEHICLE" or (actionEventId ~= nil and actionEventId ~= "") then
            Log:trace("RLMenu.addPlayerActionEvents: registration returned false (controlling=%s, eventId=%s)",
                tostring(controlling), tostring(actionEventId))
        else
            Log:debug("RLMenu.addPlayerActionEvents: RL_MENU action NOT registered (controlling=%s)",
                tostring(controlling))
        end
        return
    end

    -- Hide the action event text from the HUD (we don't want a screen-edge hint)
    g_inputBinding:setActionEventTextVisibility(actionEventId, false)
    Log:debug("RLMenu.addPlayerActionEvents: RL_MENU action registered, eventId=%s",
        tostring(actionEventId))
end

--- Install the PlayerInputComponent and loadMap hooks.
--- Called once from main.lua at end-of-file before the TESTING block.
---
--- Two hooks installed:
---   1. PlayerInputComponent.registerGlobalPlayerActionEvents - so `RL_MENU` is
---      registered whenever a player input context is created.
---   2. RealisticLivestock.loadMap - defers `RLMenu.setupGui()` until AFTER
---      RealisticLivestock.loadMap has registered the `rlMenu` texture
---      config. Without this hook ordering, setupGui parses rlMenu.xml's
---      `imageSliceId="rlMenu.buy_animal"` before the texture namespace
---      exists, emitting `Warning: No texture config with prefix 'rlMenu'
---      found` at mod load. The warning was harmless in practice but noisy.
---      Hooking into loadMap resolves the ordering cleanly.
---
--- Idempotency: main.lua sources this file exactly once, so install() runs exactly once;
--- re-entry is not a supported scenario and would double-append both hooks.
function RLMenu.install()
    PlayerInputComponent.registerGlobalPlayerActionEvents = Utils.appendedFunction(
        PlayerInputComponent.registerGlobalPlayerActionEvents,
        RLMenu.addPlayerActionEvents
    )

    RealisticLivestock.loadMap = Utils.appendedFunction(
        RealisticLivestock.loadMap,
        RLMenu.setupGui
    )

    Log:debug("RLMenu.install: PlayerInputComponent + loadMap hooks installed")
end

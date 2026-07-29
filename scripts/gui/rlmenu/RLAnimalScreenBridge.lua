local Log = RmLogging.getLogger("RLRM")

--- Surviving routing seam for every `AnimalScreen.show` shape, the standalone
--- livestock-trailer activatable, and the EPP butcher direct-open (which bypasses
--- `AnimalScreen.show` and so is caught at `AnimalScreen.onOpen`, redirecting to the
--- MODE_TRAILER EPP counterpart). Lives OUTSIDE the legacy AnimalScreen monolith so the
--- redirects outlive that file's teardown.
---
--- Contract:
---   * Routing parity - `show()` walks the same `(husbandry, vehicle, isDealer)` branch
---     tree the base-game controller uses, so every trigger reaches the RLMenu open that
---     matches its legacy landing.
---   * Mutation parity - each open goes through `RLMenu.openFromBridge` /
---     `openTrailerFromBridge`, which fire the SAME server events the legacy controllers
---     did (AnimalBuyEvent / AnimalSellEvent / AnimalMoveEvent / AnimalLoadEvent /
---     AnimalUnloadEvent). This module introduces no new event class and no new bridge API.
---   * No vanilla fallback - no path here may open the vanilla screen. A missing menu
---     (`g_rlMenu` nil), a refused open, or an unrecognized / gate-failed shape logs a
---     WARN and no-ops. The activatable deliberately drops its `superFunc` fallback:
---     once the legacy monolith is gone `superFunc` IS the vanilla open.
---   * Routing tripwire - every recognized shape logs an INFO naming the decision, every
---     refusal a WARN. This is the seam's permanent per-call contract, not diagnostics.
---
--- Load-time inert apart from the three installs at the tail (needs only the base-game
--- `AnimalScreen` / `LivestockTrailerActivatable` / `Utils` tables and the logger;
--- `RLMenu` and `g_rlMenu` are read at call time).
RLAnimalScreenBridge = {}


--- Route an `AnimalScreen.show(husbandry, vehicle, isDealer)` call to the mapped RLMenu
--- open. The branch tree matches the base-game controller's shape so routing keeps legacy
--- parity; the livestock / animal-husbandry gates fail CLOSED to a terminal WARN no-op
--- rather than open a vanilla controller (those degenerate shapes are never produced by a
--- real trigger). The INFO is a routing-DECISION log, independent of the open's outcome -
--- a refused open additionally WARNs inside openFromBridge, so seeing both is expected.
--- @param husbandry table|nil animal-husbandry placeable (own-pen / pen-trailer shapes)
--- @param vehicle table|nil livestock-trailer vehicle (trailer shapes)
--- @param isDealer boolean|nil true for the dealer trailer walk-up; ignored for the
---   husbandry-present and no-argument leaves (base-game ignores it there too)
function RLAnimalScreenBridge.show(husbandry, vehicle, isDealer)
    if g_rlMenu == nil then
        Log:warning("AnimalScreen.show: g_rlMenu nil, no-op (never vanilla)")
        return
    end

    if husbandry ~= nil then
        if vehicle ~= nil then
            -- Pen-trailer: a livestock trailer triggered AT a real animal pen. Opens the
            -- Transfer tab (pen counterpart), firing the same AnimalMoveEvent legacy did.
            if vehicle.spec_livestockTrailer ~= nil and husbandry.spec_husbandryAnimals ~= nil then
                Log:info("AnimalScreen.show: pen-trailer -> RLMenu (mode=trailer counterpart=pen)")
                RLMenu.openFromBridge(nil, RLMenu.MODE_TRAILER,
                    { trailer = vehicle, counterpart = RLMenu.TRAILER_PEN, counterpartHandle = husbandry })
                return
            end
        else
            -- Own-pen walk-up: lands the full menu on the Info tab, anchored to THIS pen
            -- via the one-shot husbandry anchor. Forwards ANY non-nil husbandry (isDealer
            -- ignored, matching base-game); a non-animal husbandry opens unanchored with
            -- openFromBridge's own WARN.
            Log:info("AnimalScreen.show: own-pen walk-up -> RLMenu (mode=full anchored, lands Info)")
            RLMenu.openFromBridge(4, RLMenu.MODE_FULL, { husbandry = husbandry })
            return
        end
    elseif vehicle ~= nil then
        -- Trailer at a dealer (isDealer) or a standalone world trigger (falsy isDealer):
        -- the Transfer tab against the dealer / world counterpart. Same Buy/Sell/load
        -- events legacy fired. A non-livestock vehicle falls to the terminal WARN.
        if vehicle.spec_livestockTrailer ~= nil then
            local counterpart = (isDealer == true) and RLMenu.TRAILER_DEALER or RLMenu.TRAILER_WORLD
            Log:info("AnimalScreen.show: %s-trailer -> RLMenu (mode=trailer)",
                isDealer == true and "dealer" or "world")
            RLMenu.openFromBridge(nil, RLMenu.MODE_TRAILER, { trailer = vehicle, counterpart = counterpart })
            return
        end
    else
        -- Dealer shape: the shop "Buy Animals" button and the on-foot no-husbandry trigger.
        -- Anchors the Buy tab in dealer mode; same AnimalBuyEvent legacy fired.
        Log:info("AnimalScreen.show: dealer-shape -> RLMenu (page=1 mode=dealer)")
        RLMenu.openFromBridge(1, RLMenu.MODE_DEALER)
        return
    end

    Log:warning("AnimalScreen.show: unrecognized shape h=%s v=%s isDealer=%s, no-op (never vanilla)",
        tostring(husbandry ~= nil), tostring(vehicle ~= nil), tostring(isDealer))
end


--- Pure shape predicate: is this the EPP (butcher) controller? A third-party EPP
--- trigger direct-opens the vanilla AnimalScreen with its own controller
--- (`AnimalScreenTrailerExtendedProduction`) whose `.husbandry` IS the production point
--- (the loading trigger sets `trigger.husbandry = self`), NOT a real animal pen. Detect
--- by SHAPE, never class name (EPP is an optional third-party mod): the pp carries
--- `animalsTypeData` + `addCluster` + `getNumOfFreeAnimalSlots` and has NO
--- `spec_husbandryAnimals`, whereas a pen-trailer controller's `.husbandry` is a real
--- husbandry (`spec_husbandryAnimals` present, no `animalsTypeData`). The
--- `getNumOfFreeAnimalSlots` check makes the gate match the FULL pp contract the redirect
--- then relies on (the sidebar reads it in `getDisplayData`, and the delivery filter calls
--- `target:getNumOfFreeAnimalSlots` for every survivor in `RLAnimalMoveService`), so a
--- partial EPP-like controller cannot be redirected into a slot-API crash. Total + nil-safe:
--- any missing field -> false.
--- @param controller table|nil  the AnimalScreen's pre-assigned controller
--- @return boolean isEPP
function RLAnimalScreenBridge.isEPPControllerShape(controller)
    return controller ~= nil
        and controller.trailer ~= nil
        and controller.husbandry ~= nil
        and controller.husbandry.animalsTypeData ~= nil
        and controller.husbandry.spec_husbandryAnimals == nil
        and type(controller.husbandry.addCluster) == "function"
        and type(controller.husbandry.getNumOfFreeAnimalSlots) == "function"
end


--- Base-game `AnimalScreen.onOpen` wrapper - the redirect for the EPP butcher
--- direct-open. That trigger bypasses `AnimalScreen.show` (it sets its controller then
--- `g_gui:showGui("AnimalScreen")` directly), so the `show()` seam above never catches
--- it; `onOpen` is the earliest hook after the controller is set. Post-cutover NO
--- surviving RLRM flow opens `AnimalScreen` via `showGui` (every RLRM trigger redirects
--- at `.show` / `run`), so this hook fires ONLY for external EPP opens - the shape
--- predicate is the sole guard.
---
--- On an EPP-shaped controller: SKIP `superFunc` (the vanilla cluster-style open) and
--- swap to RLMenu MODE_TRAILER with the EPP counterpart. `counterpartHandle` is
--- `controller.husbandry` (the pp itself - no unwrap). On a refused open (`g_rlMenu`
--- nil / a dialog visible / nil trailer or pp) WARN and `g_gui:changeScreen(nil)` to
--- CLOSE the already-shown screen (mirrors base-game `AnimalScreen:onOpen`, which itself
--- `changeScreen(nil)`s from onOpen when there are no animals to show) - NEVER call
--- `superFunc` (post-cutover `superFunc` IS the vanilla open). A non-EPP-shaped
--- controller passes to `superFunc` unchanged (no
--- surviving RLRM flow should reach here).
--- @param self table  the AnimalScreen instance (`self.controller` is pre-assigned)
--- @param superFunc function  base-game AnimalScreen.onOpen
function RLAnimalScreenBridge.onOpen(self, superFunc, ...)
    local controller = self ~= nil and self.controller or nil
    if not RLAnimalScreenBridge.isEPPControllerShape(controller) then
        -- Not an EPP butcher open: pass through to the vanilla onOpen unchanged.
        return superFunc(self, ...)
    end

    local trailer = controller.trailer
    local pp = controller.husbandry
    Log:info("AnimalScreen.onOpen: EPP butcher direct-open -> RLMenu (mode=trailer counterpart=epp)")

    -- Direct swap: openFromBridge -> showGui("RLMenu") replaces the just-shown
    -- AnimalScreen. Base-game precedent: onOpen itself changeScreen()s mid-open, so
    -- redirecting from the wrapped onOpen is supported. If in-game testing shows a
    -- one-frame vanilla flash, defer this swap to the next frame via Timer.createOneshot
    -- (the documented fallback; primary is this direct swap).
    if g_rlMenu ~= nil and RLMenu.openFromBridge(nil, RLMenu.MODE_TRAILER,
            { trailer = trailer, counterpart = RLMenu.TRAILER_EPP, counterpartHandle = pp }) == true then
        return
    end

    -- Refused: close the vanilla screen rather than leave the cluster-style EPP
    -- presentation up, and NEVER call superFunc (post-cutover superFunc IS the vanilla open).
    Log:warning("AnimalScreen.onOpen: EPP redirect refused (g_rlMenu=%s), closing screen (never vanilla)",
        tostring(g_rlMenu ~= nil))
    g_gui:changeScreen(nil)
end


--- World-trailer redirect for the standalone `LivestockTrailerActivatable` ("Open animal
--- screen" prompt on a parked livestock trailer with no loading trigger). This activatable
--- opens the vanilla screen unconditionally once it runs, so a `setController`-level hook
--- cannot suppress it - the interception has to be `run` itself. Redirects to the Transfer
--- tab (world counterpart), firing the same AnimalLoadEvent / AnimalUnloadEvent legacy did.
--- Keeps its OWN `g_rlMenu` / `livestockTrailer` guards (the `show()` top guard
--- does not cover this path, and a nil trailer must never reach openTrailerFromBridge). On any
--- refusal it WARN-no-ops and NEVER calls `_superFunc` - post-cutover `_superFunc` is the
--- vanilla open.
RL_LivestockTrailerActivatable = {}

function RL_LivestockTrailerActivatable:run(_superFunc)
    if g_rlMenu ~= nil and self.livestockTrailer ~= nil
        and RLMenu.openFromBridge(nil, RLMenu.MODE_TRAILER,
            { trailer = self.livestockTrailer, counterpart = RLMenu.TRAILER_WORLD }) == true then
        Log:info("LivestockTrailerActivatable:run: world-trailer -> RLMenu (mode=trailer counterpart=world)")
        return
    end
    Log:warning("LivestockTrailerActivatable:run: g_rlMenu nil or bridge refused, no-op (never vanilla)")
end


-- Sole installer for all three overrides (the legacy monolith's own installs are removed
-- in the same slice, so there is no source-order-decided double-install / double-wrap).
-- The activatable and the onOpen redirect keep the overwrittenFunction wrap as the
-- interception mechanism; the activatable's injected superFunc is intentionally unused
-- (see RL_LivestockTrailerActivatable:run), while the onOpen wrap DOES call superFunc for
-- any non-EPP-shaped controller (the vanilla open).
AnimalScreen.show = RLAnimalScreenBridge.show
LivestockTrailerActivatable.run = Utils.overwrittenFunction(LivestockTrailerActivatable.run,
    RL_LivestockTrailerActivatable.run)
-- EPP butcher direct-open redirect: it bypasses AnimalScreen.show, so the intercept is
-- onOpen (the earliest hook after the controller is set), not the show() seam above.
AnimalScreen.onOpen = Utils.overwrittenFunction(AnimalScreen.onOpen, RLAnimalScreenBridge.onOpen)

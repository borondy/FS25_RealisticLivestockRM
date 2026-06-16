-- RLMenuTabPolicy.lua
-- Pure decision layer for RL Tabbed Menu tab visibility and the trailer-mode
-- anchor. Plain data in, plain data out: no g_*, no GUI, no XML handles, so the
-- whole module loads and runs under the headless harness (project-context
-- Rule A; mirrors RLFilterFieldCatalog as the established pure helper).
--
-- Two concerns live here so RLMenu's setupMenuPages closures stay thin wiring:
--   1. isVisible(pageKey, openMode, counterpart) -> bool   (which tabs show)
--   2. anchorPage(counterpart, trailerIsEmpty)  -> index  (which tab lands first)
--
-- Both functions are TOTAL: an unrecognized openMode, counterpart, or pageKey
-- resolves to a safe default (hidden / Buy) rather than erroring. The RLMenu
-- bridge validates the counterpart up front, so those defensive defaults are
-- reached only by the headless suite, never by a real open.
--
-- Open-mode and counterpart string values are owned here (the pure layer loads
-- first) and re-exported by RLMenu; RLMenu.MODE_FULL / MODE_DEALER keep their
-- shipped literal values, which equal MODE_FULL / MODE_DEALER below. The
-- in-game regression suite pins MODE_FULL / MODE_DEALER visibility across all
-- 8 frames, so any string drift between the two owners fails loudly.

local Log = RmLogging.getLogger("RLRM")

RLMenuTabPolicy = {}

-- =============================================================================
-- Constants
-- =============================================================================

-- Open modes (mirror RLMenu.MODE_*). MODE_FULL = keyboard-shortcut path (all
-- tabs); MODE_DEALER = shop / walk-up dealer redirect (Buy/Sell/Info/AI);
-- MODE_TRAILER = a livestock trailer drives visibility per its counterpart.
RLMenuTabPolicy.MODE_FULL = "full"
RLMenuTabPolicy.MODE_DEALER = "dealer"
RLMenuTabPolicy.MODE_TRAILER = "trailer"

-- Trailer counterparts (where the trailer is parked). PEN = husbandry pen,
-- DEALER = animal dealer, WORLD = walk-up / activatable. Re-exported by RLMenu
-- as TRAILER_PEN / TRAILER_DEALER / TRAILER_WORLD.
RLMenuTabPolicy.PEN = "pen"
RLMenuTabPolicy.DEALER = "dealer"
RLMenuTabPolicy.WORLD = "world"

-- Collapsed visible-tab anchor indices used by RLMenu.restorePageIndex. In the
-- trailer-dealer placement the visible set is exactly {Buy, Sell} (Info/AI are
-- hidden by Decision 7a), so Buy = 1 and Sell = 2 map cleanly.
RLMenuTabPolicy.ANCHOR_BUY = 1
RLMenuTabPolicy.ANCHOR_SELL = 2

-- =============================================================================
-- Visibility tables
-- =============================================================================

-- Per-mode visible-tab sets keyed by pageKey. A key absent from a table reads
-- as hidden (the `== true` test below makes nil -> false). "transfer" never
-- appears in a full / dealer set (it is a trailer pen/world tab, registered in
-- RLRM-427). MODE_TRAILER is counterpart-dependent, handled in trailerVisible.
local FULL_VISIBLE = {
    buy = true, sell = true, move = true, info = true,
    ai = true, messages = true, herdsman = true, settings = true,
}

local DEALER_VISIBLE = {
    buy = true, sell = true, info = true, ai = true,
    -- move / messages / herdsman / settings hidden in dealer mode
}

--- Trailer-mode visibility, split by counterpart.
---   dealer    -> {Buy, Sell} only (Decision 7a hides Info/AI; in-tab detail
---                panes carry Info parity for the dealer placement).
---   pen/world -> {Transfer} only (the Transfer tab arrives in RLRM-427).
--- Any other (or nil) counterpart -> nothing visible (totality default).
---@param pageKey string
---@param counterpart string|nil
---@return boolean
local function trailerVisible(pageKey, counterpart)
    if counterpart == RLMenuTabPolicy.DEALER then
        return pageKey == "buy" or pageKey == "sell"
    elseif counterpart == RLMenuTabPolicy.PEN or counterpart == RLMenuTabPolicy.WORLD then
        return pageKey == "transfer"
    end
    return false
end

-- =============================================================================
-- Public API
-- =============================================================================

--- Whether a tab is visible for the given open mode and (trailer) counterpart.
--- Total: an unrecognized openMode, counterpart, or pageKey returns false.
--- counterpart is consulted only in MODE_TRAILER (nil is fine for full/dealer).
---@param pageKey string  one of: buy, sell, move, info, ai, messages, herdsman, settings, transfer
---@param openMode string  MODE_FULL | MODE_DEALER | MODE_TRAILER
---@param counterpart string|nil  PEN | DEALER | WORLD (MODE_TRAILER only)
---@return boolean visible
function RLMenuTabPolicy.isVisible(pageKey, openMode, counterpart)
    if openMode == RLMenuTabPolicy.MODE_FULL then
        return FULL_VISIBLE[pageKey] == true
    elseif openMode == RLMenuTabPolicy.MODE_DEALER then
        return DEALER_VISIBLE[pageKey] == true
    elseif openMode == RLMenuTabPolicy.MODE_TRAILER then
        return trailerVisible(pageKey, counterpart)
    end
    -- Unrecognized open mode: nothing visible (totality default).
    return false
end

--- The collapsed visible-tab index a trailer open should land on. Dealer
--- placement only: an empty trailer anchors Buy (most-likely action is to load
--- it), a loaded trailer anchors Sell. The caller passes the already-resolved
--- emptiness bool (from RLTrailerEndpointService.isEmpty), so this stays pure.
--- Any non-dealer / unknown counterpart returns Buy as a defensive default
--- (unreachable: the bridge rejects an invalid counterpart, and pen/world never
--- computes an anchor because it does not open this slice).
---@param counterpart string|nil  PEN | DEALER | WORLD
---@param trailerIsEmpty boolean
---@return number anchorIndex  ANCHOR_BUY (1) or ANCHOR_SELL (2)
function RLMenuTabPolicy.anchorPage(counterpart, trailerIsEmpty)
    local anchor
    if counterpart == RLMenuTabPolicy.DEALER then
        anchor = trailerIsEmpty and RLMenuTabPolicy.ANCHOR_BUY or RLMenuTabPolicy.ANCHOR_SELL
    else
        anchor = RLMenuTabPolicy.ANCHOR_BUY
    end
    Log:trace("RLMenuTabPolicy.anchorPage: counterpart=%s isEmpty=%s -> %d",
        tostring(counterpart), tostring(trailerIsEmpty), anchor)
    return anchor
end

--[[
    RLTransferAdapter.lua
    The counterpart-adapter seam for the RL Tabbed Menu Transfer frame.

    One Transfer frame serves every trailer placement (pen / world); the part
    that varies per placement - where the "other side" animals come from, what
    the action button says, and what a confirmed transfer does - lives behind
    this data-in/data-out seam. Each placement supplies a small adapter object
    implementing the contract below; the frame talks only to the contract, never
    to a placement directly.

    Purity contract (this is the headless dual-run boundary):
      * No g_*, GUI, engine class, or getText - at load OR in any function. The
        whole module runs under the headless harness against plain tables.
      * A display NAME is an ENGINE STRING for a concrete adapter and an i18n KEY
        for NULL. The FRAME resolves the NULL key via getText when it builds the
        sidebar label, so this module never calls getText (which would drag in
        g_i18n and break the pure run).

    Adapter contract (each method takes self via `:`):
      * adapter:getDisplayData()                  -> { name, used, total }
            name = engine string (concrete) | i18n KEY string (NULL).
      * adapter:enumerate(context)                -> array of list items
            context = { trailer, counterpart, counterpartHandle } - see below.
      * adapter:actionLabel(direction)            -> i18n KEY for the footer button
      * adapter:dispatch(direction, animals, context) -> boolean
            true when the transfer was performed; the shell NULL logs + returns
            false (no mutation), and the frame leaves all state unchanged on false.

    `context.counterpartHandle` is the engine ref a concrete adapter enumerates
    (a husbandry placeable for pen, a spawn-place/world set for world); the
    trigger-redirect slices populate it, and the shell + NULL adapter ignore it.

    DIR_INTO_TRAILER is the direction when the counterpart side is selected
    (animals flow counterpart -> trailer); DIR_OUT_OF_TRAILER when the trailer
    side is selected (trailer -> counterpart).
]]

RLTransferAdapter = {}

local Log = RmLogging.getLogger("RLRM")

-- =============================================================================
-- Constants
-- =============================================================================

-- Source-picker sides. The sidebar holds exactly two entries: the counterpart
-- and the trailer.
RLTransferAdapter.SIDE_COUNTERPART = "counterpart"
RLTransferAdapter.SIDE_TRAILER     = "trailer"

-- Transfer directions, derived from the selected side. Counterpart side selected
-- means loading the trailer; trailer side selected means unloading it.
RLTransferAdapter.DIR_INTO_TRAILER   = "into_trailer"
RLTransferAdapter.DIR_OUT_OF_TRAILER = "out_of_trailer"

-- i18n KEYS the frame resolves (kept here as keys, never getText'd, so the seam
-- stays pure). COUNTERPART_NAME_KEY is the NULL adapter's display name; the
-- load/unload keys are the footer action labels.
RLTransferAdapter.COUNTERPART_NAME_KEY = "rl_menu_transfer_counterpart"
RLTransferAdapter.LOAD_LABEL_KEY       = "rl_menu_transfer_load"
RLTransferAdapter.UNLOAD_LABEL_KEY     = "rl_menu_transfer_unload"

-- =============================================================================
-- Pure helpers (dual-run boundary)
-- =============================================================================

--- The transfer direction implied by the selected source side. Trailer side
--- selected -> unload (out of trailer); any other side (counterpart) -> load.
--- @param side string  SIDE_COUNTERPART | SIDE_TRAILER
--- @return string direction  DIR_INTO_TRAILER | DIR_OUT_OF_TRAILER
function RLTransferAdapter.directionForSide(side)
    if side == RLTransferAdapter.SIDE_TRAILER then
        return RLTransferAdapter.DIR_OUT_OF_TRAILER
    end
    return RLTransferAdapter.DIR_INTO_TRAILER
end

--- The i18n KEY for the footer action label of a direction. OUT -> unload;
--- anything else (IN) -> load. Returns the KEY; the frame resolves it.
--- @param direction string  DIR_INTO_TRAILER | DIR_OUT_OF_TRAILER
--- @return string i18nKey
function RLTransferAdapter.actionLabelKey(direction)
    if direction == RLTransferAdapter.DIR_OUT_OF_TRAILER then
        return RLTransferAdapter.UNLOAD_LABEL_KEY
    end
    return RLTransferAdapter.LOAD_LABEL_KEY
end

--- Which source side to seed on open. An empty trailer biases toward the
--- counterpart side (the likely action is to load it); a loaded trailer biases
--- toward the trailer side (the likely action is to unload it). A nil / non-bool
--- emptiness (treated as "not known to be loaded") biases to the counterpart.
--- @param trailerIsEmpty boolean
--- @return string side  SIDE_COUNTERPART | SIDE_TRAILER
function RLTransferAdapter.initialSourceSide(trailerIsEmpty)
    if trailerIsEmpty == false then
        return RLTransferAdapter.SIDE_TRAILER
    end
    return RLTransferAdapter.SIDE_COUNTERPART
end

--- Compose a sidebar entry label as `name (used/total)`. Takes an ALREADY
--- RESOLVED name (engine string, or the frame-resolved NULL key text). Nil-safe:
--- a nil/empty name drops to a bare `(used/total)`; nil counts read as 0. Counts
--- render verbatim - `(0/0)` for an empty trailer and `used > total` are both
--- acceptable engine truths, not errors.
--- @param name string|nil  already-resolved display name
--- @param used number|nil
--- @param total number|nil
--- @return string label
function RLTransferAdapter.formatCapacityLabel(name, used, total)
    local safeUsed = used or 0
    local safeTotal = total or 0
    if name == nil or name == "" then
        return string.format("(%d/%d)", safeUsed, safeTotal)
    end
    return string.format("%s (%d/%d)", name, safeUsed, safeTotal)
end

-- =============================================================================
-- NULL adapter (shell) - empty display, empty enumeration, no-op dispatch
-- =============================================================================

--- The shell adapter: lists nothing on the counterpart side and never mutates.
--- Used for both pen and world until the concrete adapters land. getDisplayData
--- returns an i18n KEY name (the frame resolves it) so the contract stays pure.
RLTransferAdapter.NULL = {
    --- @return table display  { name = i18n KEY, used = 0, total = 0 }
    getDisplayData = function(_self)
        return {
            name  = RLTransferAdapter.COUNTERPART_NAME_KEY,
            used  = 0,
            total = 0,
        }
    end,

    --- @param _context table  { trailer, counterpart, counterpartHandle } (ignored)
    --- @return table items  always empty for the shell
    enumerate = function(_self, _context)
        return {}
    end,

    --- @param direction string  DIR_INTO_TRAILER | DIR_OUT_OF_TRAILER
    --- @return string i18nKey  generic load/unload label key
    actionLabel = function(_self, direction)
        return RLTransferAdapter.actionLabelKey(direction)
    end,

    --- No-op dispatch: logs and returns false so the frame leaves state
    --- unchanged (no event, no list change). Never mutates.
    --- @param direction string
    --- @param animals table|nil  selected animals (counted only)
    --- @param _context table
    --- @return boolean handled  always false
    dispatch = function(_self, direction, animals, _context)
        Log:debug("RLTransferAdapter.NULL:dispatch: no-op (direction=%s, %d animal(s)) - shell performs no transfer",
            tostring(direction), animals ~= nil and #animals or 0)
        return false
    end,
}

-- =============================================================================
-- Adapter selection
-- =============================================================================

-- Registry of concrete adapters keyed by counterpart string. Empty in the shell;
-- the pen / world slices register their adapters here. forCounterpart falls back
-- to NULL for any counterpart with no registered adapter.
RLTransferAdapter._adapters = {}

--- Pick the adapter for a counterpart. Returns the registered concrete adapter,
--- or NULL when none is registered (the shell registers none, so every
--- counterpart - including nil - resolves to NULL).
--- @param counterpart string|nil  RLMenu.TRAILER_PEN / TRAILER_WORLD / ...
--- @return table adapter
function RLTransferAdapter.forCounterpart(counterpart)
    local adapter = RLTransferAdapter._adapters[counterpart]
    if adapter == nil then
        Log:trace("RLTransferAdapter.forCounterpart: counterpart=%s -> NULL (no concrete adapter)",
            tostring(counterpart))
        return RLTransferAdapter.NULL
    end
    Log:trace("RLTransferAdapter.forCounterpart: counterpart=%s -> concrete adapter", tostring(counterpart))
    return adapter
end

Log:debug("RLTransferAdapter: loaded (shell - NULL adapter only)")

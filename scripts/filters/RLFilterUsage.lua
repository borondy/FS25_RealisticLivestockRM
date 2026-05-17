-- RLFilterUsage.lua
-- Canonical enum + validator for the saveable-filter `usage` scope axis.
--
-- A filter's `usage` axis controls which consumer frames the filter appears
-- on in the F-cycle picker. Three states, `nil-or-equal` match parity with
-- the other scope axes (`animalType`, `farmId`):
--
--   * `ANY`    - visible on every consumer frame (Info/Sell/Move/Buy).
--   * `OWNED`  - visible only on owned-herd frames (Info/Sell/Move).
--   * `DEALER` - visible only on dealer frames (Buy).
--
-- This module is the single source of truth for the canonical string values
-- and their wire-byte encoding. Inline string literals at boundary sites
-- (serialization, wire codec, service CRUD, GUI callbacks) reference these
-- constants so the rule + WARNING message live in one place.
--
-- Boundary policy (Locked Decision #14, renegotiated 2026-05-17):
--   * Untrusted inbound boundary (XML unknown attr, wire byte out of range,
--     service:create payload with non-nil garbage, service:update payload
--     with non-nil garbage) -> coerce to ANY + WARN.
--   * service:create(filter.usage = nil) -> silent default to ANY (per #3).
--   * service:update(payload.usage = nil) -> REJECT with WARN + return nil
--     (matches the existing name/expression completeness guard).
--   * XML attr absent on read -> silent default to ANY (legacy-save expected).
--   * Wire byte is always written/read as 1 UInt8; nil is unreachable on the
--     wire.
--
-- The `coerce(value)` helper handles ONLY the non-nil cases. Each call site
-- decides what nil means (silent default vs reject vs unreachable). The
-- function header below documents the contract.

local Log = RmLogging.getLogger("RLRM")

RLFilterUsage = {}

-- =============================================================================
-- Canonical constants
-- =============================================================================

--- Visible everywhere. Default for new filters (#3) and for legacy filters
--- loaded from saves without a `usage` attribute (#4).
RLFilterUsage.ANY = "ANY"

--- Visible on owned-herd frames only (Info / Sell / Move).
RLFilterUsage.OWNED = "OWNED"

--- Visible on dealer frames only (Buy).
RLFilterUsage.DEALER = "DEALER"

--- Forward wire-byte map: canonical string -> UInt8.
--- Frozen mapping per Locked Decision #15:
---   0 = ANY, 1 = OWNED, 2 = DEALER. Values 3-255 are reserved.
--- Ordering chosen so the default (ANY) sits at byte zero, matching common
--- protocol convention (all-zeroes stream decodes to wildcard, not bucket).
RLFilterUsage.BYTE = {
    [RLFilterUsage.ANY]    = 0,
    [RLFilterUsage.OWNED]  = 1,
    [RLFilterUsage.DEALER] = 2,
}

--- Inverse wire-byte map: UInt8 -> canonical string.
--- Unknown bytes (3-255) are absent here; the wire reader coerces them to
--- ANY + WARN at the read site.
RLFilterUsage.FROM_BYTE = {
    [0] = RLFilterUsage.ANY,
    [1] = RLFilterUsage.OWNED,
    [2] = RLFilterUsage.DEALER,
}

-- =============================================================================
-- Validator
-- =============================================================================

--- Validate a non-nil `usage` value. Returns the canonical string when input
--- matches `ANY`/`OWNED`/`DEALER`; otherwise emits a `:warning` and returns
--- `RLFilterUsage.ANY` (fail-open).
---
--- IMPORTANT: do NOT call with `nil`. Each call site handles the nil-default
--- decision explicitly because nil semantics differ by site:
---   * service:create(filter.usage = nil) -> silent default to ANY
---   * service:update(payload.usage = nil) -> reject with WARN + return nil
---   * XML attr absent -> silent default to ANY
---   * Wire stream -> unreachable (always 1 UInt8)
---
--- Callers MUST guard with an explicit `value ~= nil` branch (or equivalent)
--- before invoking coerce. Calling coerce(nil) emits a defensive WARN and
--- returns ANY.
---
--- Note: `RLFilterWire.writeFilter` intentionally uses the inline expression
--- `RLFilterUsage.BYTE[filter.usage] or 0` instead of routing through coerce.
--- That writer is a defense-in-depth fallback for an in-memory record that
--- already SHOULD have a canonical usage (service-side normalisation +
--- applyIncoming coerce upstream). Logging a WARN on every wire write for
--- this defensive case would clutter MP traffic; the asymmetry vs the
--- WARN-loud reader is intentional.
---@param value any non-nil value to validate
---@return string canonical canonical usage string (one of ANY/OWNED/DEALER)
function RLFilterUsage.coerce(value)
    if value == RLFilterUsage.ANY
        or value == RLFilterUsage.OWNED
        or value == RLFilterUsage.DEALER then
        return value
    end

    Log:warning("RLFilterUsage.coerce: unknown value '%s' (%s) coerced to ANY",
        tostring(value), type(value))
    return RLFilterUsage.ANY
end

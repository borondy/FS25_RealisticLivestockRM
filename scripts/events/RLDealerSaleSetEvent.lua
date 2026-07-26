--[[
    RLDealerSaleSetEvent.lua
    Dealer sale-availability change REQUEST (client -> server).

    The payload is the OP LIST the selector's reconcile produced - never a desired
    full set. The server applies those ops to ITS OWN registry, so the client is
    the author only of the delta it explicitly performed. A client-computed full
    set would turn every client-side staleness mode (a missed join snapshot, a
    capped payload, a concurrent admin) into a server-side DELETION of overrides
    the client never knew about, which the server would then broadcast.

    Wire format: `RLDealerSaleWire.writeList` (count prefix + N four-field records).
    A `set` op is `isSet = true` carrying its desired value; a `clear` op is
    `isSet = false` and its value slot is inert.

    Flow:
      * `sendEvent(ops)` is the only public entry. Host / singleplayer routes
        straight to `executeOnServer`; a pure client uploads the request.
      * `run(connection)` refuses a non-server receive, then validates master-user
        permission (a global admin action, as the dealer reset already establishes),
        then calls `executeOnServer`.
      * `executeOnServer(ops)` is the single server mutation funnel: apply, gate on
        "anything actually applied", broadcast the resulting authoritative set,
        then apply + regenerate the dealer.

    Persistence is NOT triggered here. The registry rides the career save through the
    dealer append in the `RLSettings` savegame write, exactly like the saveable-filter
    and herdsman-rule registries, so this path adds no save-timing behavior. No
    persistence call belongs in this file - a grep for one is the standing tripwire.

    `executeOnServer` dereferences `g_server` through the broadcast and must never
    be reached on a client - `sendEvent` and `run` are its only callers.
]]

RLDealerSaleSetEvent = {}
local RLDealerSaleSetEvent_mt = Class(RLDealerSaleSetEvent, Event)

InitEventClass(RLDealerSaleSetEvent, "RLDealerSaleSetEvent")

local Log = RmLogging.getLogger("RLRM")

--- Reconcile action tokens. Kept as named constants so the codec, the apply loop
--- and the unknown-action guard cannot drift apart on a typo.
local ACTION_SET = "set"
local ACTION_CLEAR = "clear"

--- Empty constructor used during deserialization.
---@return table self
function RLDealerSaleSetEvent.emptyNew()
    Log:trace("RLDealerSaleSetEvent.emptyNew")
    local self = Event.new(RLDealerSaleSetEvent_mt)
    return self
end

--- Construct a new request carrying a reconcile op list.
---@param ops table[]|nil ops shaped like `RLDealerSaleReconcile.diff` returns
---@return table self
function RLDealerSaleSetEvent.new(ops)
    local self = RLDealerSaleSetEvent.emptyNew()
    self.ops = ops or {}
    Log:trace("RLDealerSaleSetEvent.new: #ops=%d", #self.ops)
    return self
end

--- Server-context check, factored out so the in-game rlTest can swap it without mutating the root
--- g_server global (rlTest cannot reassign a root g_*, only a level below it - so run()'s
--- server-vs-pure-client branch and sendEvent's routing are driven through this function).
--- Production reads g_server.
---@return boolean true if this process is the authoritative server
function RLDealerSaleSetEvent.isServer()
    return g_server ~= nil
end

--- Encode one reconcile op as a wire record. Returns nil plus a reason when the op
--- is not encodable. An unknown action is REFUSED rather than defaulted, because
--- defaulting it either way would silently turn a malformed op into a real
--- registry mutation.
---
--- A `set` passes its value through VERBATIM - never `isSet and value or false`,
--- which collapses a nil into a valid `false` and would silently request
--- "not buyable" for a stage the caller never gave a value for. Passed through, a
--- nil fails the codec's boolean check and is dropped there with its key named.
--- Only a `clear`, whose value slot is inert by contract, is filled with `false`.
---@param op any
---@return table|nil rec
---@return string|nil reason
local function opToRecord(op)
    if type(op) ~= "table" then
        return nil, "op is not a table (" .. type(op) .. ")"
    end
    if op.action ~= ACTION_SET and op.action ~= ACTION_CLEAR then
        return nil, "unknown action '" .. tostring(op.action) .. "'"
    end

    local isSet = op.action == ACTION_SET
    local canBeBought = false
    if isSet then
        canBeBought = op.canBeBought
    end

    return {
        subTypeName = op.subTypeName,
        minAge      = op.minAge,
        isSet       = isSet,
        canBeBought = canBeBought,
    }
end

--- Decode one wire record back into a reconcile op. A clear carries no value, so
--- the field is left absent rather than filled with a meaningless boolean.
---@param rec table
---@return table op
local function recordToOp(rec)
    if rec.isSet then
        return {
            subTypeName = rec.subTypeName,
            minAge      = rec.minAge,
            action      = ACTION_SET,
            canBeBought = rec.canBeBought,
        }
    end
    return { subTypeName = rec.subTypeName, minAge = rec.minAge, action = ACTION_CLEAR }
end

--- Serialize the op list.
function RLDealerSaleSetEvent:writeStream(streamId, connection)
    local ops = self.ops or {}
    local records = {}

    for i = 1, #ops do
        local rec, reason = opToRecord(ops[i])
        if rec ~= nil then
            records[#records + 1] = rec
        else
            Log:warning("RLDealerSaleSetEvent:writeStream: dropping op %d - %s; that stage change is NOT requested from the server and stays as it is",
                i, tostring(reason))
        end
    end

    Log:trace("RLDealerSaleSetEvent:writeStream: #ops=%d -> #records=%d", #ops, #records)
    RLDealerSaleWire.writeList(streamId, records)
end

--- Deserialize + run on this machine. A dropped payload MUST NOT reach `run()`:
--- an empty op list is indistinguishable from "the admin changed nothing", and
--- running it would log an authorization for a request that never arrived intact.
function RLDealerSaleSetEvent:readStream(streamId, connection)
    local records, dropped = RLDealerSaleWire.readList(streamId)

    if dropped then
        self.ops = {}
        Log:warning("RLDealerSaleSetEvent:readStream: the codec dropped the payload; NOT running the request, so the server's override set and dealer stock are left untouched")
        return
    end

    local ops = {}
    for i = 1, #records do
        ops[i] = recordToOp(records[i])
    end
    self.ops = ops

    Log:trace("RLDealerSaleSetEvent:readStream: #ops=%d", #ops)
    self:run(connection)
end

--- Server receives a change request from a remote client. Permission is folded in
--- here - there is no separate permission layer.
function RLDealerSaleSetEvent:run(connection)
    local ops = self.ops or {}
    local count = #ops

    -- On a client `connection:getIsServer()` is TRUE, so a client that ever
    -- receives this class would pass the authority gate below and then nil-crash
    -- inside executeOnServer's broadcast. Refuse the receive outright.
    if not RLDealerSaleSetEvent.isServer() then
        Log:warning("RLDealerSaleSetEvent:run: received on a non-server peer; this class is a client -> server request only, dropping %d op(s) (nothing is applied locally)",
            count)
        return
    end

    local userName = "unknown"
    local user = g_currentMission.userManager:getUserByConnection(connection)
    if user ~= nil then
        userName = user.nickname or userName
    end

    local isMasterUser = connection:getIsServer()
        or g_currentMission.userManager:getIsConnectionMasterUser(connection)

    if not isMasterUser then
        Log:warning("RLDealerSaleSetEvent:run: permission denied for user '%s' (%d op(s)) - not admin; the override registry, the state broadcast and the dealer stock are all unchanged",
            tostring(userName), count)
        return
    end

    Log:info("RLDealerSaleSetEvent:run: admin '%s' authorized, applying %d dealer sale-availability op(s)",
        tostring(userName), count)

    RLDealerSaleSetEvent.executeOnServer(ops)
end

--- The single server mutation funnel. Applies the ops to the server's own
--- registry, and only when at least one op actually landed does it broadcast the
--- resulting authoritative set and regenerate the dealer.
---
--- Broadcast BEFORE the repopulate so a client holds the new flags before the
--- regenerated stock arrives via AnimalSystemStateEvent. Unconditional, as the
--- dealer reset already does - in singleplayer it reaches zero connections.
---
--- No savegame write: the registry reaches disk through the career save only.
---@param ops table[] ops shaped like `RLDealerSaleReconcile.diff` returns
function RLDealerSaleSetEvent.executeOnServer(ops)
    if type(ops) ~= "table" then
        Log:warning("RLDealerSaleSetEvent.executeOnServer: ops is not a table (%s); nothing applied, no broadcast and no dealer re-roll",
            type(ops))
        return
    end

    if g_rlDealerSaleRegistry == nil then
        Log:warning("RLDealerSaleSetEvent.executeOnServer: g_rlDealerSaleRegistry is nil; ignoring %d op(s), no broadcast and no dealer re-roll",
            #ops)
        return
    end

    local applied = 0

    for i, op in ipairs(ops) do

        if type(op) ~= "table" then

            Log:warning("RLDealerSaleSetEvent.executeOnServer: op %d is not a table (%s); skipped, that stage is unchanged",
                i, type(op))

        elseif op.action == ACTION_CLEAR then

            -- Count the removal, not the call: clear returns false for an absent or invalid key,
            -- and a clear that removed nothing changed nothing - counting it would re-roll the
            -- whole dealer for no effective change. Symmetric with the set branch below.
            if g_rlDealerSaleRegistry:clear(op.subTypeName, op.minAge) then
                applied = applied + 1
                Log:trace("RLDealerSaleSetEvent.executeOnServer: cleared override %s @%s (back to its shipped default)",
                    op.subTypeName, tostring(op.minAge))
            else
                Log:trace("RLDealerSaleSetEvent.executeOnServer: clear removed nothing for %s @%s; not counted as applied",
                    tostring(op.subTypeName), tostring(op.minAge))
            end

        elseif op.action == ACTION_SET then

            -- Count the CHANGE, not the call. `set` is an unconditional upsert that
            -- returns true even when the stored value already equals the requested one,
            -- so counting its return would let a redundant op re-roll the whole dealer
            -- for no effective change. That is reachable in multiplayer: an admin whose
            -- selector snapshot predates another admin's change diffs against the stale
            -- value and emits an op the server has already applied. Reading the current
            -- value first makes this branch genuinely symmetric with the clear branch
            -- above, which counts the removal rather than the call.
            local previous = g_rlDealerSaleRegistry:get(op.subTypeName, op.minAge)

            if g_rlDealerSaleRegistry:set(op.subTypeName, op.minAge, op.canBeBought) then
                if previous ~= op.canBeBought then
                    applied = applied + 1
                    Log:trace("RLDealerSaleSetEvent.executeOnServer: set override %s @%s -> %s (was %s)",
                        op.subTypeName, tostring(op.minAge), tostring(op.canBeBought), tostring(previous))
                else
                    Log:trace("RLDealerSaleSetEvent.executeOnServer: set %s @%s was already %s; not counted as applied",
                        op.subTypeName, tostring(op.minAge), tostring(op.canBeBought))
                end
            else
                Log:trace("RLDealerSaleSetEvent.executeOnServer: registry rejected set %s @%s; not counted as applied",
                    tostring(op.subTypeName), tostring(op.minAge))
            end

        else

            Log:warning("RLDealerSaleSetEvent.executeOnServer: unknown reconcile action '%s' for %s @%s; skipped, that stage is unchanged",
                tostring(op.action), tostring(op.subTypeName), tostring(op.minAge))

        end

    end

    if applied == 0 then
        Log:debug("RLDealerSaleSetEvent.executeOnServer: no changes (%d op(s) received, none applied); no broadcast and no dealer re-roll",
            #ops)
        return
    end

    RLDealerSaleStateEvent.broadcastToClients(g_rlDealerSaleRegistry:enumerate())

    Log:debug("RLDealerSaleSetEvent.executeOnServer: %d change(s) applied and broadcast; folding onto the live flags and regenerating the dealer",
        applied)
    RLDealerSaleApply.applyAndRepopulate()
end

--- The only public entry. Host / singleplayer executes directly; a pure client
--- uploads the request to the server.
---@param ops table[] ops shaped like `RLDealerSaleReconcile.diff` returns
function RLDealerSaleSetEvent.sendEvent(ops)
    if type(ops) ~= "table" then
        Log:warning("RLDealerSaleSetEvent.sendEvent: invalid payload (%s); nothing dispatched and no override changes",
            type(ops))
        return
    end

    Log:trace("RLDealerSaleSetEvent.sendEvent: dispatching #ops=%d", #ops)

    if RLDealerSaleSetEvent.isServer() then
        RLDealerSaleSetEvent.executeOnServer(ops)
    elseif g_client ~= nil then
        local conn = g_client:getServerConnection()
        if conn == nil then
            Log:warning("RLDealerSaleSetEvent.sendEvent: g_client has no server connection; dropping %d op(s), so the confirmed change never reaches the server",
                #ops)
            return
        end
        conn:sendEvent(RLDealerSaleSetEvent.new(ops))
    else
        Log:trace("RLDealerSaleSetEvent.sendEvent: neither server nor client; offline path, no dispatch")
    end
end

Log:trace("RLDealerSaleSetEvent: loaded")

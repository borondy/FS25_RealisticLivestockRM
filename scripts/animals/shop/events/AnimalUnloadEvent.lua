-- AnimalUnloadEvent.lua
-- Codec-only override of the base-game AnimalUnloadEvent for the RLMenu world-trailer unload.
--
-- RL identifies animals with a string identity key ("farmId uniqueId country"), not the
-- Int32 clusterId the base-game stream signatures expect. The client->server data leg
-- serializes that id, so streamWriteInt32(<string>) faults on the wire and the server then
-- receives an unresolvable id. AnimalRidingEvent / AnimalCleanEvent take the identical
-- string-codec treatment for the same reason (see RealisticLivestock_PlayerInputComponent).
--
-- SERIALIZATION ONLY: writeStream / readStream are redefined here; run / validate /
-- newServerToClient / onLoadedRideable stay the live base-game methods so the server-side
-- spawn logic is unchanged (do NOT redefine them here). The override is global by necessity:
-- every RLRM unload is string-keyed, and the only callers pass a string id (RLTrailerWorldService
-- and the dormant legacy AnimalScreenTrailer, whose id already comes from the globally
-- string-overridden getClusterId).

local Log = RmLogging.getLogger("RLRM")

assert(AnimalUnloadEvent ~= nil and AnimalUnloadEvent.run ~= nil,
    "AnimalUnloadEvent override: base-game AnimalUnloadEvent must be loaded before this file (check main.lua SECTION 13b load order)")

--- client -> server: trailer node-object + STRING cluster id (base game writes Int32 here).
--- server -> client: the reply errorCode (unchanged UIntN width).
function AnimalUnloadEvent:writeStream(streamId, connection)
    if connection:getIsServer() then
        NetworkUtil.writeNodeObject(streamId, self.trailer)
        streamWriteString(streamId, tostring(self.clusterId))
        Log:trace("AnimalUnloadEvent:writeStream: client->server clusterId='%s' (string)", tostring(self.clusterId))
    else
        streamWriteUIntN(streamId, self.errorCode, AnimalUnloadEvent.SEND_NUM_BITS)
        Log:trace("AnimalUnloadEvent:writeStream: server->client errorCode=%s", tostring(self.errorCode))
    end
end

--- Mirror of writeStream's direction split, reading the STRING cluster id (base game reads
--- Int32). The self:run(connection) tail is preserved so the server-side spawn / client-side
--- publish stay base-game.
function AnimalUnloadEvent:readStream(streamId, connection)
    if not connection:getIsServer() then
        self.trailer = NetworkUtil.readNodeObject(streamId)
        self.clusterId = streamReadString(streamId)
        Log:trace("AnimalUnloadEvent:readStream: server<-client clusterId='%s' (string)", tostring(self.clusterId))
    else
        self.errorCode = streamReadUIntN(streamId, AnimalUnloadEvent.SEND_NUM_BITS)
        Log:trace("AnimalUnloadEvent:readStream: client<-server errorCode=%s", tostring(self.errorCode))
    end
    self:run(connection)
end

Log:debug("AnimalUnloadEvent: string-clusterId codec override installed (writeStream/readStream)")

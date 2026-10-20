--[[
    RLRideableClusterStream.lua
    The horse cluster's part of a horse vehicle's join stream, written in the base horse-cluster
    layout so a client's base reader decodes it field for field.

    The pending-spawn flag exists in that layout only when the base `AnimalCluster` class declares
    `getPendingSpawnWorldPosition`, so the layout is chosen from the class at call time, never from
    the cluster: an RLRM `Animal` carries the method in every game version.
]]

RLRideableClusterStream = {}

local Log = RmLogging.getLogger("RLRM")


--- Write a horse cluster in the base horse-cluster layout, the pending-spawn flag included when the game has it.
---@param streamId number the stream to write
---@param cluster table the rideable's cluster: an RLRM Animal or a base AnimalClusterHorse
---@return nil
function RLRideableClusterStream.write(streamId, cluster)
    streamWriteUIntN(streamId, cluster.numAnimals or 1, AnimalCluster.NUM_BITS_NUM_ANIMALS)
    streamWriteUIntN(streamId, math.floor(cluster.age or 0), AnimalCluster.NUM_BITS_AGE)
    streamWriteUIntN(streamId, math.floor(cluster.health or 0), AnimalCluster.NUM_BITS_HEALTH)
    streamWriteUIntN(streamId, math.floor(cluster.reproduction or 0), AnimalCluster.NUM_BITS_REPRODUCTION)

    local withFlag = AnimalCluster.getPendingSpawnWorldPosition ~= nil
    local hasPosition = false

    if withFlag then
        local x, y, z, rx, ry, rz = cluster:getPendingSpawnWorldPosition()
        hasPosition = x ~= nil

        if streamWriteBool(streamId, hasPosition) then
            streamWriteFloat32(streamId, x)
            streamWriteFloat32(streamId, y)
            streamWriteFloat32(streamId, z)
            streamWriteFloat32(streamId, rx)
            streamWriteFloat32(streamId, ry)
            streamWriteFloat32(streamId, rz)
        end
    end

    streamWriteString(streamId, cluster.name or "")
    streamWriteUIntN(streamId, math.floor(cluster.fitness or 0), AnimalClusterHorse.NUM_BITS_FITNESS)
    streamWriteUIntN(streamId, math.floor(cluster.riding or 0), AnimalClusterHorse.NUM_BITS_RIDING)
    streamWriteUIntN(streamId, math.floor(cluster.dirt or 0), AnimalClusterHorse.NUM_BITS_DIRT)

    Log:debug("RideableStream: wrote horse cluster layout=%s flag=%s (farmId=%s uniqueId=%s)",
        withFlag and "with-flag" or "without-flag", withFlag and tostring(hasPosition) or "absent",
        tostring(cluster.farmId), tostring(cluster.uniqueId))
end

--- Sync straw pickup to the server. Mirror of ReturnStrawEvent with delta -1.
--- Sent by the client after taking a straw from a dewar via the hand tool path.
--- The server's run() calls changeStraws(-1) which raises the dirty flag and
--- auto-deletes the dewar when empty.
TakeStrawEvent = {}

local TakeStrawEvent_mt = Class(TakeStrawEvent, Event)
InitEventClass(TakeStrawEvent, "TakeStrawEvent")


--- @return table self
function TakeStrawEvent.emptyNew()
    Log:trace("TakeStrawEvent.emptyNew")
    local self = Event.new(TakeStrawEvent_mt)
    return self
end


--- @param object table Dewar vehicle (DewarData specialization)
--- @return table self
function TakeStrawEvent.new(object)
	local event = TakeStrawEvent.emptyNew()
	event.object = object
	Log:trace("TakeStrawEvent.new dewar=%s", tostring(object))
	return event
end


--- @param streamId number Network stream id
--- @param connection table Network connection
function TakeStrawEvent:readStream(streamId, connection)
	self.object = NetworkUtil.readNodeObject(streamId)
	Log:trace("TakeStrawEvent:readStream dewar=%s", tostring(self.object))
	self:run(connection)
end


--- @param streamId number Network stream id
--- @param connection table Network connection
function TakeStrawEvent:writeStream(streamId, connection)
	NetworkUtil.writeNodeObject(streamId, self.object)
	Log:trace("TakeStrawEvent:writeStream dewar=%s", tostring(self.object))
end


--- Decrement the dewar's straw count on the receiving side.
--- @param connection table Network connection
function TakeStrawEvent:run(connection)
	if self.object == nil then
		Log:warning("TakeStrawEvent:run dewar is nil (deleted before event arrived)")
		return
	end

	self.object:changeStraws(-1)
	Log:debug("TakeStrawEvent:run decremented dewar=%s", tostring(self.object:getUniqueId()))
end

AIBulkMessageEvent = {}

local AIBulkMessageEvent_mt = Class(AIBulkMessageEvent, Event)
InitEventClass(AIBulkMessageEvent, "AIBulkMessageEvent")


function AIBulkMessageEvent.emptyNew()

    local self = Event.new(AIBulkMessageEvent_mt)
    return self

end


function AIBulkMessageEvent.new(object, messages)

	local event = AIBulkMessageEvent.emptyNew()

	event.object = object
	event.messages = messages

	return event

end


function AIBulkMessageEvent:readStream(streamId, connection)

	self.object = NetworkUtil.readNodeObject(streamId)
	local numMessages = streamReadUInt16(streamId)

	self.messages = {}

	for i = 1, numMessages do

		local id = streamReadString(streamId)
		local numArgs = streamReadUInt8(streamId)
		local args = {}

		for j = 1, numArgs do table.insert(args, streamReadString(streamId)) end

		table.insert(self.messages, {
			["id"] = id,
			["args"] = args
		})

	end

	self:run(connection)

end


function AIBulkMessageEvent:writeStream(streamId, connection)

	NetworkUtil.writeNodeObject(streamId, self.object)

	streamWriteUInt16(streamId, #self.messages)

	for i = 1, #self.messages do

		local message = self.messages[i]
		message.args = message.args or {}

		streamWriteString(streamId, message.id)
		streamWriteUInt8(streamId, #message.args)

		-- Coerce each arg to a string at the wire boundary. RL message args are canonically
		-- strings everywhere they serialize (readStream reads them as strings;
		-- addRLMessageDirect tostring-coerces; the savegame uses setString) - but the engine's
		-- streamWriteString does NOT coerce a number, it throws. This one chokepoint keeps every
		-- caller safe (RLHerdsmanMessages and legacy AIAnimalManager alike). A non-string,
		-- non-number arg is a corrupt caller: WARN, then still coerce so the broadcast survives.
		for j = 1, #message.args do
			local arg = message.args[j]
			local argType = type(arg)
			if argType ~= "string" and argType ~= "number" then
				Log:warning("AIBulkMessageEvent:writeStream: message '%s' arg %d is a %s (expected string/number) - coercing via tostring",
					tostring(message.id), j, argType)
			end
			streamWriteString(streamId, tostring(arg))
		end

	end

end


function AIBulkMessageEvent:run(connection)

	-- Object must carry the husbandryAnimals spec to receive RL messages.
	-- Guard hoisted outside the loop since self.object is invariant per event.
	if self.object.addRLMessage == nil then
		Log:trace("AIBulkMessageEvent:run: skipping %d messages (object has no husbandryAnimals spec)", #self.messages)
		return
	end

	for i = 1, #self.messages do

		local message = self.messages[i]
		self.object:addRLMessage(message.id, nil, message.args)

	end

end
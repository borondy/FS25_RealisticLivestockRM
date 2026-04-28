RmSafeUtils = {}

--- Wraps a function body in xpcall with traceback logging, and emits
--- DEBUG enter/exit log lines bracketing the call. Use for outer protection
--- of timer-driven handler callbacks (HOUR/DAY/PERIOD_CHANGED, deferred
--- Timer.createOneshot bodies). The enter/exit pair makes performance
--- triageable from the log: in-game time on enter, elapsed wall-clock
--- duration on exit. Both gated at DEBUG (no production noise).
---
--- Output shape:
---   [safeCall] <context>: enter (gameTime=D125 P3 06:00)
---   [safeCall] <context>: exit  (took 42.18ms)
---
--- Exit log fires even if the body throws (xpcall itself never raises).
--- The error log on failure is preserved.
---@param context string  identifier for log/error messages (e.g. "AnimalSystem:onDayChanged")
---@param fn function     the function body to protect
---@return boolean ok
function RmSafeUtils.safeCall(context, fn)
    local startSec = getTimeSec()
    local gameTime = (RLDebugUtils and RLDebugUtils.formatGameTime and RLDebugUtils.formatGameTime()) or "?"
    Log:debug("[safeCall] %s: enter (gameTime=%s)", context, gameTime)

    local ok, err = xpcall(fn, function(e)
        return tostring(e) .. "\n" .. debug.traceback("", 2)
    end)

    local elapsedMs = (getTimeSec() - startSec) * 1000
    Log:debug("[safeCall] %s: exit  (took %.2fms)", context, elapsedMs)

    if not ok then
        Log:error("Error in %s: %s", context, tostring(err))
    end
    return ok
end

--- Calls fn inside xpcall; returns defaults on error.
--- Use inside animal loops where one bad animal shouldn't kill all.
---@param animal table           the animal (for identity in log)
---@param context string         handler name for log
---@param fn function            function() -> values
---@param defaults table|nil     array of default values on error
---@return ...                   fn results or defaults
function RmSafeUtils.safeAnimalCall(animal, context, fn, defaults)
    local results = { xpcall(fn, function(e)
        return tostring(e) .. "\n" .. debug.traceback("", 2)
    end) }
    if results[1] then
        return unpack(results, 2)
    else
        Log:error("Error in %s for animal '%s': %s",
            context, tostring(animal.uniqueId or "unknown"), tostring(results[2]))
        if defaults then return unpack(defaults) end
    end
end

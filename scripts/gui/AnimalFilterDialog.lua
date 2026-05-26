AnimalFilterDialog = {}

local animalFilterDialog_mt = Class(AnimalFilterDialog, MessageDialog)
local modDirectory = g_currentModDirectory

local Log = RmLogging.getLogger("RLRM")

function AnimalFilterDialog.register()

    local dialog = AnimalFilterDialog.new()
    g_gui:loadGui(modDirectory .. "gui/AnimalFilterDialog.xml", "AnimalFilterDialog", dialog)
    AnimalFilterDialog.INSTANCE = dialog

    -- Wire the persist callback ONCE on each master template. Every clone produced
    -- by :clone() inherits the callback target+name, so per-clone wiring is unnecessary.
    dialog.binaryOptionTemplate:setCallback("onClickCallback", "onFilterStateChanged")
    dialog.sliderTemplate:setCallback("onClickCallback", "onFilterStateChanged")

    Log:debug("[AnimalFilterDialog] register: onClickCallback -> onFilterStateChanged wired on binaryOptionTemplate + sliderTemplate")

end


function AnimalFilterDialog.new(target, customMt)

    local self = MessageDialog.new(target, customMt or animalFilterDialog_mt)

    self.items = nil
    self.filters = nil
    self.elementsToDelete = {}
    self.sliderTemplateOffset = GuiUtils.getNormalizedScreenValues("0px 45px")
    self.binaryOptionTemplateOffset = GuiUtils.getNormalizedScreenValues("0px 30px")

    return self

end


function AnimalFilterDialog.createFromExistingGui(gui)

    AnimalFilterDialog.register()
    AnimalFilterDialog.show()

end


function AnimalFilterDialog.show(items, animalTypeIndex, callback, target, isBuyMode)

    if AnimalFilterDialog.INSTANCE == nil then AnimalFilterDialog.register() end

    local dialog = AnimalFilterDialog.INSTANCE

    dialog.items = table.clone(items)
    dialog.animalTypeIndex = animalTypeIndex
    dialog.callback = callback
    dialog.target = target
    dialog.isBuyMode = isBuyMode

    g_gui:showDialog("AnimalFilterDialog")

end


function AnimalFilterDialog:onOpen()

    AnimalFilterDialog:superClass().onOpen(self)

    local dialog = self.dialogElement
    local content = self.contentContainer
    local title = self.titleText
    local list = self.filterList
    local rail = self.filterRail
    local buttons = self.buttonsPC
    Log:debug(string.format(
        "[AnimalFilterDialog] onOpen: dialog pos=%.1f,%.1f size=%.1fx%.1f | content pos=%.1f,%.1f size=%.1fx%.1f | title pos=%.1f,%.1f size=%.1fx%.1f | list pos=%.1f,%.1f size=%.1fx%.1f | rail pos=%.1f,%.1f size=%.1fx%.1f | buttons pos=%.1f,%.1f size=%.1fx%.1f",
        dialog.absPosition[1] * 1920, dialog.absPosition[2] * 1080, dialog.absSize[1] * 1920, dialog.absSize[2] * 1080,
        content.absPosition[1] * 1920, content.absPosition[2] * 1080, content.absSize[1] * 1920, content.absSize[2] * 1080,
        title.absPosition[1] * 1920, title.absPosition[2] * 1080, title.absSize[1] * 1920, title.absSize[2] * 1080,
        list.absPosition[1] * 1920, list.absPosition[2] * 1080, list.absSize[1] * 1920, list.absSize[2] * 1080,
        rail.absPosition[1] * 1920, rail.absPosition[2] * 1080, rail.absSize[1] * 1920, rail.absSize[2] * 1080,
        buttons.absPosition[1] * 1920, buttons.absPosition[2] * 1080, buttons.absSize[1] * 1920, buttons.absSize[2] * 1080
    ))

    self.filters = {}

    for i = #self.elementsToDelete, 1, -1 do
        if self.elementsToDelete[i] ~= nil then self.elementsToDelete[i]:delete() end
    end
    -- Full reset so reopen has zero residue. Authority for active widget state lives on
    -- filter.ui*; self.elementsToDelete is cleanup-only and must not be read elsewhere.
    self.elementsToDelete = {}

    local items = self.items
    local anyText = g_i18n:getText("rl_ui_any")
    local geneticsText = g_i18n:getText("rl_ui_genetics") .. ": "

    local filters = {

        {
            ["target"] = "age",
            ["name"] = g_i18n:getText("infohud_age"),
            ["template"] = "sliderTemplate",
            ["text"] = {
                ["single"] = g_i18n:getText("rl_ui_formatMonth"),
                ["multiple"] = g_i18n:getText("rl_ui_formatMonths")
            },
            ["min"] = 0,
            ["max"] = 1
        },

        {
            ["target"] = "health",
            ["name"] = g_i18n:getText("infohud_health"),
            ["requiresMonitor"] = true,
            ["template"] = "sliderTemplate",
            ["text"] = {
                ["single"] = "%s%%",
                ["multiple"] = "%s%%"
            },
            ["min"] = 0,
            ["max"] = 1
        },

        {
            ["target"] = "weight",
            ["name"] = g_i18n:getText("rl_ui_weight"),
            ["requiresMonitor"] = true,
            ["template"] = "sliderTemplate",
            ["text"] = {
                ["single"] = "%skg",
                ["multiple"] = "%skg"
            },
            ["min"] = 0,
            ["max"] = 1
        },

        {
            ["target"] = "isPregnant",
            ["name"] = g_i18n:getText("rl_ui_pregnancy"),
            ["template"] = "binaryOptionTemplate",
            ["text"] = {
                {
                    ["text"] = g_i18n:getText("rl_ui_notPregnant"),
                    ["value"] = false
                },
                {
                    ["text"] = anyText,
                    ["value"] = "ignore"
                },
                {
                    ["text"] = g_i18n:getText("rl_ui_pregnant"),
                    ["value"] = true
                }
            },
            ["default"] = 2
        },

        {
            ["target"] = "gender",
            ["name"] = g_i18n:getText("rl_ui_gender"),
            ["template"] = "binaryOptionTemplate",
            ["text"] = {
                {
                    ["text"] = g_i18n:getText("rl_ui_female"),
                    ["value"] = "female"
                },
                {
                    ["text"] = anyText,
                    ["value"] = "ignore"
                },
                {
                    ["text"] = g_i18n:getText("rl_ui_male"),
                    ["value"] = "male"
                }
            },
            ["default"] = 2
        },

        {
            ["isFunction"] = true,
            ["target"] = "getHasAnyDisease",
            ["name"] = g_i18n:getText("rl_disease"),
            ["template"] = "binaryOptionTemplate",
            ["text"] = {
                {
                    ["text"] = g_i18n:getText("rl_ui_healthy"),
                    ["value"] = false
                },
                {
                    ["text"] = anyText,
                    ["value"] = "ignore"
                },
                {
                    ["text"] = g_i18n:getText("rl_ui_hasDisease"),
                    ["value"] = true
                }
            },
            ["default"] = 2
        },

        {
            ["isFunction"] = true,
            ["target"] = "getHasName",
            ["name"] = g_i18n:getText("infohud_name"),
            ["template"] = "binaryOptionTemplate",
            ["text"] = {
                {
                    ["text"] = g_i18n:getText("rl_ui_doesntHaveName"),
                    ["value"] = false
                },
                {
                    ["text"] = anyText,
                    ["value"] = "ignore"
                },
                {
                    ["text"] = g_i18n:getText("rl_ui_doesHaveName"),
                    ["value"] = true
                }
            },
            ["default"] = 2
        },

        {
            ["isFunction"] = true,
            ["target"] = "getSellPrice",
            ["name"] = g_i18n:getText("rl_ui_value"),
            ["template"] = "sliderTemplate",
            ["text"] = {
                ["formatFunction"] = I18N.formatMoney,
                ["target"] = g_i18n,
                ["args"] = {
                    "value",
                    2,
                    true,
                    true
                }
            },
            ["min"] = 0,
            ["max"] = 1,
            -- No multiplier here: in buy mode, markup is baked into the
            -- derived value (see onOpen below) and into applyFilters, so
            -- filter.min / filter.max are in display (marked-up) space
            -- throughout. Prevents top-of-range drop after dialog OK.
        },

        {
            ["isLayered"] = true,
            ["target"] = {
                "genetics",
                "metabolism"
            },
            ["name"] = geneticsText .. g_i18n:getText("rl_ui_metabolism"),
            ["template"] = "sliderTemplate",
            ["text"] = {
                ["formatFunction"] = AnimalFilterDialog.formatGenetics,
                ["target"] = self,
                ["args"] = {
                    "value"
                }
            },
            ["min"] = 0,
            ["max"] = 1,
            ["multiplier"] = 100
        },

        {
            ["isLayered"] = true,
            ["target"] = {
                "genetics",
                "health"
            },
            ["name"] = geneticsText .. g_i18n:getText("rl_ui_health"),
            ["template"] = "sliderTemplate",
            ["text"] = {
                ["formatFunction"] = AnimalFilterDialog.formatGenetics,
                ["target"] = self,
                ["args"] = {
                    "value"
                }
            },
            ["min"] = 0,
            ["max"] = 1,
            ["multiplier"] = 100
        },

        {
            ["isLayered"] = true,
            ["target"] = {
                "genetics",
                "fertility"
            },
            ["name"] = geneticsText .. g_i18n:getText("rl_ui_fertility"),
            ["template"] = "sliderTemplate",
            ["text"] = {
                ["formatFunction"] = AnimalFilterDialog.formatGenetics,
                ["target"] = self,
                ["args"] = {
                    "value"
                }
            },
            ["min"] = 0,
            ["max"] = 1,
            ["multiplier"] = 100
        },

        {
            ["isLayered"] = true,
            ["target"] = {
                "genetics",
                "quality"
            },
            ["name"] = geneticsText .. g_i18n:getText("rl_ui_meat"),
            ["template"] = "sliderTemplate",
            ["text"] = {
                ["formatFunction"] = AnimalFilterDialog.formatGenetics,
                ["target"] = self,
                ["args"] = {
                    "value"
                }
            },
            ["min"] = 0,
            ["max"] = 1,
            ["multiplier"] = 100
        }

    }

    if self.animalTypeIndex == AnimalType.COW or self.animalTypeIndex == AnimalType.SHEEP or self.animalTypeIndex == AnimalType.CHICKEN then
        
        table.insert(filters, {
            ["isLayered"] = true,
            ["target"] = {
                "genetics",
                "productivity"
            },
            ["name"] = geneticsText .. g_i18n:getText("statistic_productivity"),
            ["template"] = "sliderTemplate",
            ["text"] = {
                ["formatFunction"] = AnimalFilterDialog.formatGenetics,
                ["target"] = self,
                ["args"] = {
                    "value"
                }
            },
            ["min"] = 0,
            ["max"] = 1,
            ["multiplier"] = 100
        })

    end


    if self.animalTypeIndex == AnimalType.COW then

        table.insert(filters, 6, {
            ["target"] = "isLactating",
            ["name"] = g_i18n:getText("rl_ui_lactating"),
            ["template"] = "binaryOptionTemplate",
            ["text"] = {
                {
                    ["text"] = g_i18n:getText("rl_ui_no"),
                    ["value"] = false
                },
                {
                    ["text"] = anyText,
                    ["value"] = "ignore"
                },
                {
                    ["text"] = g_i18n:getText("rl_ui_yes"),
                    ["value"] = true
                }
            },
            ["default"] = 2
        })

    end


    for _, item in pairs(items) do

        local animal = item.animal or item.cluster

        for _, filter in pairs(filters) do

            if (filter.requiresMonitor and not animal.monitor.active and not animal.monitor.removed) or filter.template ~= "sliderTemplate" then continue end

            local value

            if filter.isLayered then

                value = animal

                for _, target in pairs(filter.target) do

                    value = value[target]

                end

            elseif filter.isFunction then

                value = animal[filter.target](animal)

                -- Mirror the buy-mode markup applied in applyFilters (line
                -- ~628) so filter.min / filter.max are derived in the SAME
                -- space the predicate later compares against. Without this,
                -- top-of-range items would compare value*1.075 > raw_max
                -- and silently drop after dialog OK.
                if filter.target == "getSellPrice" and self.isBuyMode then value = value * 1.075 end

            else

                value = animal[filter.target]

            end

            if value < filter.min then filter.min = math.floor(value) end
            if value > filter.max then filter.max = math.ceil(value) end

            filter.hasValues = true

        end

    end


    for i = #filters, 1, -1 do

        if filters[i].template == "sliderTemplate" and not filters[i].hasValues then table.remove(filters, i) end

    end


    -- Build slider text caches and seed per-filter view-state. After this pass each filter
    -- carries authoritative widget state on the filter table itself, so the populate cell
    -- (recyclable by SmoothList) is a pure view and clicks persist back via onFilterStateChanged.
    local function buildCachedTexts(filter)
        local texts = {}
        local multiplier = filter.multiplier or 1
        for i = filter.min * multiplier, filter.max * multiplier do
            if filter.text.formatFunction ~= nil then
                local args = table.clone(filter.text.args or {})
                for argIndex, arg in pairs(args) do if arg == "value" then args[argIndex] = i end end
                table.insert(texts, filter.text.formatFunction(filter.text.target, args[1], args[2], args[3], args[4]))
            else
                table.insert(texts, string.format(filter.text[i == 1 and "single" or "multiple"], i))
            end
        end
        return texts
    end

    local binaryCount, sliderCount = 0, 0
    local sliderSummary = {}
    for _, filter in ipairs(filters) do
        if filter.template == "binaryOptionTemplate" then
            filter.uiState = filter.default or 1
            binaryCount = binaryCount + 1
        elseif filter.template == "sliderTemplate" then
            filter.cachedTexts = buildCachedTexts(filter)
            filter.uiLeftState = 1
            filter.uiRightState = #filter.cachedTexts
            sliderCount = sliderCount + 1
            local label = type(filter.target) == "table" and filter.target[2] or tostring(filter.target)
            table.insert(sliderSummary, string.format("%s=%d", label, #filter.cachedTexts))
            if #filter.cachedTexts == 0 then
                Log:warning(string.format("[AnimalFilterDialog] slider filter '%s' survived prune but built empty cachedTexts (min=%s max=%s mult=%s)",
                    filter.name, tostring(filter.min), tostring(filter.max), tostring(filter.multiplier)))
            end
        end
    end


    self.filters = filters

    Log:debug(string.format("[AnimalFilterDialog] onOpen init: %d filters (%d binary, %d slider). Slider cachedTexts: %s",
        #filters, binaryCount, sliderCount, table.concat(sliderSummary, " ")))

    self.filterList:reloadData()

end


function AnimalFilterDialog:onClose()

    AnimalFilterDialog:superClass().onClose(self)

end


---Persist callback target wired in register(); fires on every TripleOption click and
---every DoubleOptionSlider drag step. Writes the latest widget state back to the
---originating filter so it survives cell recycle.
---@param state number          # the segment / step index at the moment of the callback
---@param element table         # the cloned widget that fired; carries filterRef set in populate
---@param isLeftButtonEvent boolean # unused; carried for signature parity
function AnimalFilterDialog:onFilterStateChanged(state, element, isLeftButtonEvent)

    local filter = element and element.filterRef

    if filter == nil then
        Log:warning("[AnimalFilterDialog] onFilterStateChanged: element missing filterRef; discarding state change")
        return
    end

    if filter.template == "binaryOptionTemplate" then
        filter.uiState = state
    elseif filter.template == "sliderTemplate" then
        -- Both thumb positions are current on the element when this callback fires,
        -- even though only one moved this step.
        filter.uiLeftState = element.leftState
        filter.uiRightState = element.rightState
    end

    Log:trace(string.format("[AnimalFilterDialog] persist %s -> L=%s M=%s R=%s",
        filter.name, tostring(filter.uiLeftState), tostring(filter.uiState), tostring(filter.uiRightState)))

end


function AnimalFilterDialog:onClickOk()

    -- Reads filter.ui*; never touches self.elementsToDelete (cleanup-only, can be stale after cell recycle).
    for i = #self.filters, 1, -1 do

        local filter = self.filters[i]

        if filter.template == "sliderTemplate" then

            local multiplier = filter.multiplier or 1
            -- min/max via math.min/math.max preserves legacy getLowestState/getHighestState
            -- parity when thumbs are crossed (left thumb may be > right thumb).
            local left = filter.uiLeftState or 1
            local right = filter.uiRightState or 1

            -- Prune no-op (full-range) sliders for symmetry with the binary
            -- "ignore" prune below, so next(self.filters) ~= nil remains a
            -- truthful "Quick filter active" predicate.
            local cachedCount = filter.cachedTexts ~= nil and #filter.cachedTexts or 0
            if cachedCount > 0
                and math.min(left, right) == 1
                and math.max(left, right) == cachedCount then
                Log:trace(string.format(
                    "[AnimalFilterDialog] prune full-range slider '%s' (left=%d right=%d range=1..%d)",
                    tostring(filter.name), left, right, cachedCount))
                table.remove(self.filters, i)
                continue
            end

            filter.min = (math.min(left, right) - 1) / multiplier
            filter.max = (math.max(left, right) - 1) / multiplier

        end

        if filter.template == "binaryOptionTemplate" then

            local state = filter.uiState or filter.default or 1
            local value = filter.text[state].value

            if value == "ignore" then
                table.remove(self.filters, i)
                continue
            end

            filter.value = value

        end

    end

    -- Scrub transient dialog-internal keys so consumer callbacks (Info/Move/Sell/Buy frames +
    -- AnimalScreen) receive clean filter tables. Boundary discipline.
    for _, filter in pairs(self.filters) do
        filter.uiState = nil
        filter.uiLeftState = nil
        filter.uiRightState = nil
        filter.cachedTexts = nil
    end

    self.items = AnimalFilterDialog.applyFilters(self.items, self.filters, self.isBuyMode)

    if self.callback ~= nil then

        if self.target ~= nil then
            self.callback(self.target, self.filters, self.items)
        else
            self.callback(self.filters, self.items)
        end

    end

    self:close()

end


function AnimalFilterDialog:getNumberOfSections()

	return 1

end


function AnimalFilterDialog:getNumberOfItemsInSection(list, section)

	return #self.filters

end


function AnimalFilterDialog:getTitleForSectionHeader(list, section)

    return ""

end


function AnimalFilterDialog:populateCellForItemInSection(list, section, index, cell)

    local filter = self.filters[index]

    cell:findAllAttributes()

    cell:getAttribute("name"):setText(filter.name)

    if filter.template ~= nil then

        -- Cell pool can recycle: drop the prior clone (if any) and rebuild fresh from master.
        -- All widget state is read from filter.ui* (authoritative); the clone is a pure view.
        if self.elementsToDelete[index] ~= nil then
            self.elementsToDelete[index]:delete()
            self.elementsToDelete[index] = nil
        end

        local template = self[filter.template]:clone(cell, false, false)
        -- filterRef routes user interactions back to the originating filter via onFilterStateChanged.
        template.filterRef = filter
        template:setPosition(self[filter.template .. "Offset"][1], self[filter.template .. "Offset"][2])
        template:setVisible(true)

        if filter.template == "sliderTemplate" then

            -- Load-bearing order: setTexts resets leftState=1, rightState=#texts as a
            -- side-effect. Restore the user-set range AFTER, then repaint.
            template:setTexts(filter.cachedTexts)
            template.leftState = filter.uiLeftState
            template.rightState = filter.uiRightState
            template:updateContentElement()
            template:updateSlider()

        elseif filter.template == "binaryOptionTemplate" then

            local templateTexts = {}
            for _, data in pairs(filter.text) do table.insert(templateTexts, data.text) end
            template:setTexts(templateTexts)
            -- Direct state seed: TripleOption's setState with skipAnimation=true routes through
            -- a slider animation-skip path that always snaps the highlight to an extreme based on
            -- the sliding direction - it has no concept of "snap to MIDDLE". For non-extreme
            -- targets (state=2 / ANY), this lands the visual highlight on the wrong button.
            -- Seed state + slider geometry directly instead.
            template.state = filter.uiState
            template.oldState = filter.uiState
            template:updateSelection()
            template:updateContentElement()
            template.sliderState = (filter.uiState - 1) * (TripleOptionElement.NUM_SLIDER_STATES / 2)
            template.sliderMovingDirection = 0
            if template.sliderElement ~= nil then
                template.sliderElement:setPosition(template.sliderDelta * template.sliderState, nil)
            end

        end

        self.elementsToDelete[index] = template

    end

    for name, element in pairs(cell.attributes) do

        if name ~= "name" and name ~= "separator" then element:delete() end

    end

end


function AnimalFilterDialog.applyFilters(items, filters, isBuyMode)

    local result = {}

    for i, item in ipairs(items) do

        local animal = item.animal or item.cluster
        local meetsFilters = true

        for _, filter in pairs(filters) do

            if filter.requiresMonitor and not animal.monitor.active and not animal.monitor.removed then continue end

            if filter.template == "sliderTemplate" then

                local value

                if filter.isLayered then

                    value = animal

                    for _, target in pairs(filter.target) do value = value[target] end

                elseif filter.isFunction then

                    value = animal[filter.target](animal)

                    -- Key off the stable function-name target, NOT the
                    -- localized filter.name (e.g. "Wert", "Valor").
                    if filter.target == "getSellPrice" and isBuyMode then value = value * 1.075 end

                else

                    value = animal[filter.target]

                end

                if value < filter.min or value > filter.max then
                    meetsFilters = false
                    break
                end

            end


            if filter.template == "binaryOptionTemplate" then

                local value

                if filter.isFunction then

                    value = animal[filter.target](animal)

                else

                    value = animal[filter.target]

                end

                if value ~= filter.value then
                    meetsFilters = false
                    break
                end

            end

        end

        if meetsFilters then
            item.originalIndex = i
            table.insert(result, item)
        end

    end

    return result

end


function AnimalFilterDialog:formatGenetics(value)

    local text

    if value >= 165 then
        text = "extremelyHigh"
    elseif value >= 140 then
        text = "veryHigh"
    elseif value >= 110 then
        text = "high"
    elseif value >= 90 then
        text = "average"
    elseif value >= 70 then
        text = "low"
    elseif value >= 35 then
        text = "veryLow"
    else
        text = "extremelyLow"
    end

    return g_i18n:getText("rl_ui_genetics_" .. text)

end
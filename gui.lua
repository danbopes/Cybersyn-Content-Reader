--[[ Copyright (c) 2024 Danbopes
 * Part of Cybersyn Content Reader
 *
 * See LICENSE.md in the project directory for license information.
--]]

local flib_gui = require("__flib__.gui")
require('variables')
require('utils')
local gui = {}

-- Constants for GUI element names
local NETWORK_SELECTOR = "network_selector"
local NETWORK_ID_FIELD = "network_id_field"
local SIGNAL_DISPLAY = "signal_display"
local SIGNAL_SCROLL = "signal_scroll"

-- flib's slot buttons are 40x40 at 100% UI scale, and "auto-and-reserve-space"
-- always keeps the scrollbar gutter, so it has to be added to the pane width.
local SLOT_SIZE = 40
local SCROLLBAR_WIDTH = 12
local MIN_COLUMNS = 8
local MAX_COLUMNS = 24
local MIN_ROWS = 3
local MAX_ROWS = 20
-- Fraction of the player's screen the grid is allowed to occupy.
local WIDTH_BUDGET = 0.5
local HEIGHT_BUDGET = 0.6

--- Grid geometry for one player, in unscaled GUI pixels.
---
--- Columns grow with the signal count so a three-signal reader stays as compact
--- as it is today, while a whole-network reader widens out instead of turning
--- into a 50-row column. The screen is the hard cap either way; past it the pane
--- scrolls. Columns are only recomputed when the window is built, since a table's
--- column_count is fixed at creation and re-deriving it mid-session would mean
--- rebuilding the grid out from under the player.
---@param player LuaPlayer
---@param signal_count integer
---@return integer columns, integer max_height
local function slot_grid_size(player, signal_count)
    local scale = player.display_scale
    if scale <= 0 then scale = 1 end
    local resolution = player.display_resolution
    local usable_width = resolution.width / scale
    local usable_height = resolution.height / scale

    local max_columns = math.floor((usable_width * WIDTH_BUDGET - SCROLLBAR_WIDTH) / SLOT_SIZE)
    max_columns = math.max(MIN_COLUMNS, math.min(MAX_COLUMNS, max_columns))

    -- Aim for a grid half again as wide as it is tall.
    local columns = math.ceil(math.sqrt(signal_count * 1.6))
    columns = math.max(MIN_COLUMNS, math.min(max_columns, columns))

    -- Snapping to whole rows keeps a half-cut row from reading as a glitch.
    local rows = math.floor(usable_height * HEIGHT_BUDGET / SLOT_SIZE)
    rows = math.max(MIN_ROWS, math.min(MAX_ROWS, rows))

    return columns, rows * SLOT_SIZE
end

---@param proto LuaItemPrototype|LuaFluidPrototype
---@param quality string?
local function signal_tooltip(proto, quality)
    if not quality or quality == "normal" then
        return proto.localised_name
    end
    local quality_proto = prototypes.quality[quality]
    if not quality_proto then
        return proto.localised_name
    end
    return { "", proto.localised_name, " (", quality_proto.localised_name, ")" }
end

--- Section 2 is rebuilt from a hash table on every update, so its order drifts
--- between refreshes. Sorting into prototype order gives the grid a fixed layout
--- a player can actually scan when a network holds hundreds of signals.
---@param filters LogisticFilter[]
local function sorted_entries(filters)
    local entries = {}
    for _, filter in pairs(filters) do
        local value = filter.value
        if value and value.name then
            local kind = value.type or "item"
            local protos = prototypes[kind]
            -- Section 2 is persisted in the save, so it can still name a
            -- prototype belonging to a mod that has since been removed.
            local proto = protos and protos[value.name]
            if proto then
                local subgroup = proto.subgroup
                local group = subgroup and subgroup.group
                entries[#entries + 1] = {
                    filter = filter,
                    proto = proto,
                    -- Type, name and quality make the key a total order, so the
                    -- result is identical on every client.
                    sort_key = table.concat({
                        group and group.order or "",
                        subgroup and subgroup.order or "",
                        proto.order or "",
                        kind,
                        value.name,
                        value.quality or "normal",
                    }, "\0"),
                }
            end
        end
    end

    table.sort(entries, function(a, b) return a.sort_key < b.sort_key end)
    return entries
end

---@param combinator LuaEntity
---@return LogisticFilter[]
local function output_filters(combinator)
    local behavior = combinator.get_control_behavior()
    if not behavior then return {} end
    local section = behavior.get_section(2)
    if not section then return {} end
    return section.filters
end

---@param player LuaPlayer
local function close_gui(player)
    local ref = storage.guis[player.index]
    if not ref then return end

    -- Cleared first: destroying a window that is still player.opened comes back
    -- through on_gui_closed, and the second pass has to find nothing to do.
    storage.guis[player.index] = nil
    if ref.window and ref.window.valid then
        ref.window.destroy()
    end
    player.play_sound({ path = "entity-close/cybersyn-combinator" })
end

local function handle_network_switch(event)
    if event.name == defines.events.on_gui_elem_changed or event.name == defines.events.on_gui_text_changed then
        local player = game.get_player(event.player_index)
        if not player then return end
        local ref = storage.guis[player.index]
        if not ref then return end

        local signal = ref[NETWORK_SELECTOR].elem_value
        local network_id = tonumber(ref[NETWORK_ID_FIELD].text) or default_network

        local combinator = ref.context
        if not combinator or not combinator.valid then return end

        local behavior = combinator.get_control_behavior()
        if not behavior then return end

        local section = behavior.get_section(1)
        if section then
            section.filters = {
                {
                    value = signal,
                    min = network_id
                }
            }
        end
    end
end

-- Handle opening the combinator GUI
local function on_gui_opened(event)
    if not event.entity then return end
    if not content_readers[event.entity.name] then return end

    local player = game.get_player(event.player_index)
    if not player then return end

    player.opened = nil

    -- Create the GUI
    gui.create_gui(player, event.entity)

end

local function handle_close(event)
    if not event.element then return end

    local player = game.get_player(event.player_index)
    if not player then return end

    close_gui(player)
end

  -- Handle closing the combinator GUI
local function on_gui_closed(event)
    if not event.element or event.element.name ~= "cybersyn_content_reader_gui" then return end

    local player = game.get_player(event.player_index)
    if not player then return end

    close_gui(player)
end

-- Create the GUI for a combinator
function gui.create_gui(player, combinator)
    -- Remove any existing GUI
    local existing_frame = player.gui.screen.cybersyn_content_reader_gui
    if existing_frame then
        existing_frame.destroy()
    end

    -- Get current signal and value
    local slot = get_first_signal(combinator) or {}
    local current_signal = slot.value or nil
    local current_id = slot.min or default_network

    local columns, max_height = slot_grid_size(player, #output_filters(combinator))

    local refs, main_window = flib_gui.add(player.gui.screen, {
        type = "frame",
        name = "cybersyn_content_reader_gui",
        direction = "vertical",
        children = {
            {
                type = "flow",
                name = "titlebar",
                children = {
                    {
                        type = "label",
                        style = "frame_title",
                        caption = { "entity-name." .. combinator.name },
                        elem_mods = { ignored_by_interaction = true },
                    },
                    { type = "empty-widget", style = "flib_titlebar_drag_handle", elem_mods = { ignored_by_interaction = true } },
                    {
                        type = "sprite-button",
                        style = "frame_action_button",
                        tooltip = { "gui.close-instruction" },
                        mouse_button_filter = { "left" },
                        sprite = "utility/close",
                        hovered_sprite = "utility/close",
                        name = combinator.name,
                        handler = handle_close,
                    },
                }
            },
            {
                type = "frame",
                style = "inside_deep_frame",
                direction = "vertical",
                children = {
                    type = "frame",
                    style = "cybersyn_content_reader_network_selector_frame",
                    children = {
                        {
                            type = "label",
                            caption = "Network Signal:",
                        },
                        {
                            type = "choose-elem-button",
                            name = NETWORK_SELECTOR,
                            elem_type = "signal",
                            signal = current_signal,
                            handler = handle_network_switch,
                        },
                        {
                            type = "label",
                            caption = "Network ID:",
                            style_mods = {
                                vertical_align = "center",
                            },
                        },
                        {
                            type = "textfield",
                            name = NETWORK_ID_FIELD,
                            style_mods = {
                                width = 100,
                            },
                            numeric = true,
                            allow_negative = true,
                            text = tostring(current_id),
                            handler = handle_network_switch,
                        }
                    }
                }
            },
            {
                type = "frame",
                style = "inside_shallow_frame_with_padding",
                direction = "vertical",
                children = {
                    {
                        type = "label",
                        caption = "Signals:",
                        style = "subheader_caption_label",
                        style_mods = {
                            bottom_padding = 4,
                        }
                    },
                    {
                        type = "frame",
                        style = "deep_frame_in_shallow_frame",
                        children = {
                            {
                                type = "scroll-pane",
                                name = SIGNAL_SCROLL,
                                style = "flib_naked_scroll_pane_no_padding",
                                horizontal_scroll_policy = "never",
                                vertical_scroll_policy = "auto-and-reserve-space",
                                style_mods = {
                                    width = SLOT_SIZE * columns + SCROLLBAR_WIDTH,
                                    maximal_height = max_height,
                                },
                                children = {
                                    {
                                        type = "table",
                                        name = SIGNAL_DISPLAY,
                                        style = "slot_table",
                                        column_count = columns,
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    })

    refs.titlebar.drag_target = main_window

    storage.guis[player.index] = {
        context = combinator,
        window = main_window,
        [NETWORK_SELECTOR] = refs[NETWORK_SELECTOR],
        [NETWORK_ID_FIELD] = refs[NETWORK_ID_FIELD],
        [SIGNAL_SCROLL] = refs[SIGNAL_SCROLL],
        [SIGNAL_DISPLAY] = refs[SIGNAL_DISPLAY],
    }

    -- Update the signal display
    gui.update_signal_display(player, combinator)

    -- Centred only once the grid holds its rows: centring the empty window
    -- first leaves it hanging off the bottom of the screen as the rows arrive.
    main_window.force_auto_center()

    player.opened = main_window
end

-- Update the signal display with current signals
---@param player LuaPlayer
---@param combinator LuaEntity
function gui.update_signal_display(player, combinator)
    local ref = storage.guis[player.index]
    if not ref then return end

    --- @type LuaGuiElement
    local signal_table = ref[SIGNAL_DISPLAY]
    if not signal_table or not signal_table.valid then return end

    local entries = sorted_entries(output_filters(combinator))

    -- Clearing and refilling the table would snap the pane back to the top on
    -- every update tick, so buttons are updated in place and only the surplus is
    -- destroyed. It also saves rebuilding hundreds of elements twice a second.
    local buttons = signal_table.children
    for i = 1, #entries do
        local entry = entries[i]
        local value = entry.filter.value
        local sprite = (value.type or "item") .. "/" .. value.name
        local tooltip = signal_tooltip(entry.proto, value.quality)

        local button = buttons[i]
        if button then
            button.sprite = sprite
            button.number = entry.filter.min
            button.tooltip = tooltip
        else
            signal_table.add({
                type = "sprite-button",
                style = "flib_slot_button_default",
                sprite = sprite,
                number = entry.filter.min,
                tooltip = tooltip,
            })
        end
    end

    for i = #buttons, #entries + 1, -1 do
        buttons[i].destroy()
    end
end

--- A table's column_count cannot be changed after creation, so re-fitting the
--- grid to a new screen size means replacing the table rather than the window:
--- rebuilding the window would disturb player.opened while it is open.
---@param event EventData.on_player_display_resolution_changed|EventData.on_player_display_scale_changed
local function on_display_changed(event)
    local player = game.get_player(event.player_index)
    if not player then return end

    local ref = storage.guis[player.index]
    if not ref then return end

    local scroll = ref[SIGNAL_SCROLL]
    if not scroll or not scroll.valid then return end

    local combinator = ref.context
    if not combinator or not combinator.valid then return end

    local columns, max_height = slot_grid_size(player, #output_filters(combinator))
    scroll.style.width = SLOT_SIZE * columns + SCROLLBAR_WIDTH
    scroll.style.maximal_height = max_height

    scroll.clear()
    ref[SIGNAL_DISPLAY] = scroll.add({
        type = "table",
        name = SIGNAL_DISPLAY,
        style = "slot_table",
        column_count = columns,
    })

    gui.update_signal_display(player, combinator)

    if ref.window and ref.window.valid then
        ref.window.force_auto_center()
    end
end

function gui.on_init()
    storage.guis = {}
end

flib_gui.add_handlers({
    ["comb_closed"] = handle_close,
    ["comb_network_switch"] = handle_network_switch,
})
flib_gui.handle_events()

script.on_event(defines.events.on_gui_opened, on_gui_opened)
script.on_event(defines.events.on_gui_closed, on_gui_closed)
script.on_event(defines.events.on_player_display_resolution_changed, on_display_changed)
script.on_event(defines.events.on_player_display_scale_changed, on_display_changed)

return gui

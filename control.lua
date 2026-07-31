--[[ Copyright (c) 2018 Optera
 * Part of LTN Content Reader
 *
 * See LICENSE.md in the project directory for license information.
--]]

local gui = require('gui')
require('utils')
require('variables')

function append_item(t, station, item_hash, count, network_name, network_mask)
  if network_name == nil then
    network_name = station.network_name
  end
  if network_mask == nil then
    network_mask = station.network_mask
  end

  if not station.entity_stop or not station.entity_stop.valid then
    return
  end

  local surface = station.entity_stop.surface_index

  if not network_name then
    network_name = "__all"
  end

  if network_name == "signal-each" then
    for network_name, network_mask in pairs(network_mask) do
      append_item(t, station, item_hash, count, network_name, network_mask)
    end
    return
  end

  if not t[surface] then
    t[surface] = {}
  end

  if not t[surface][network_name] then
    t[surface][network_name] = {}
  end

  if not t[surface][network_name][network_mask] then
    t[surface][network_name][network_mask] = {}
  end

  if t[surface][network_name][network_mask][item_hash] == nil then
    t[surface][network_name][network_mask][item_hash] = count
  else
    t[surface][network_name][network_mask][item_hash] = t[surface][network_name][network_mask][item_hash] + count
  end
end

function InitSignals()
  local stations = remote.call("cybersyn", "read_global", "stations")

  local inventory_provided = {}
  local inventory_requested = {}
  local inventory_in_transit = {}

  for _, station in pairs(stations) do
		local comb1_signals, _ = get_signals(station)
		if comb1_signals then
			for _, v in pairs(comb1_signals) do
				local item = v.signal
				local count = v.count
				local item_type = v.signal.type or "item"
				local item_hash = hash_signal(item)

				if item.type ~= "virtual" then
					if station.is_p and count > 0 then
            append_item(inventory_provided, station, item_hash, count)
					end
					if station.is_r and count < 0 then
						local r_threshold = station.item_thresholds and station.item_thresholds[item.name] or
							item_type == "fluid" and station.r_fluid_threshold or
							station.r_threshold
						if station.is_stack and item_type == "item" then
							r_threshold = r_threshold * prototypes.item[item.name].stack_size
						end

						if -count >= r_threshold then
              append_item(inventory_requested, station, item_hash, count)
						end
					end
				end
			end
		end

		local deliveries = station.deliveries
		if deliveries then
			for cc_item_hash, count in pairs(deliveries) do
        -- Need to rehash to ours which includes the item type
        local item_name, quality = unhash_cc_signal(cc_item_hash)
        local type = prototypes.item[item_name] == nil and "fluid" or "item"
        local item_hash = hash_signal({ name = item_name, quality = quality, type = type })
				if count > 0 then
          append_item(inventory_in_transit, station, item_hash, count)
				end
			end
		end
	end

  storage.cybersyn_provided = inventory_provided
  storage.cybersyn_requested = inventory_requested
  storage.cybersyn_deliveries = inventory_in_transit
end

-- spread out updating combinators
function OnTick(event)
  -- global.update_interval LTN update interval are synchronized in OnDispatcherUpdated
  local offset = event.tick % storage.update_interval
  local cc_count = #storage.content_combinators
  if offset == 0 then
    InitSignals()
  end
  for i=cc_count - offset, 1, -1 * storage.update_interval do
    -- log( "("..tostring(event.tick)..") on_tick updating "..i.."/"..cc_count )
    local combinator = storage.content_combinators[i]
    if combinator.valid then
      Update_Combinator(combinator)
    else
      -- The id cannot be recovered from an invalid entity, but unit_numbers are
      -- never reused, so the stale key is inert until the next rescan clears it.
      table.remove(storage.content_combinators, i)
      Update_Tick_Subscription()
    end
  end
end

---@param combinator LuaEntity
function Update_Combinator(combinator)
  -- get network id from combinator parameters
  local first_signal = get_first_signal(combinator)
  local selected_network_id = default_network
  local selected_network_name = "__all"

  if first_signal and first_signal.value then
    selected_network_name = first_signal.value.name
    selected_network_id = first_signal.min
  end

  ---@type LogisticFilter[]
  local signals = {}
  local index = 1

  -- for many signals performance is better to aggregate first instead of letting factorio do it
  local items = {}
  local reader = content_readers[combinator.name]
  if reader then
    for surface_index, surface_data in pairs(storage[reader.table_name]) do
      if not require_same_surface or combinator.surface_index == surface_index then
        for network_name, network_data in pairs(surface_data) do
          if selected_network_name == "__all" or network_name == selected_network_name then
            for network_mask, item_data in pairs(network_data) do
              if bit32.btest(selected_network_id, network_mask) then
                for item, count in pairs(item_data) do
                  items[item] = (items[item] or 0) + count
                end
              end
            end
          end
        end
      end
    end
  end

  -- generate signals from aggregated item list
  for item, count in pairs(items) do
    local itype, iname, iquality = unhash_signal(item)
    if itype and iname and (itype == "item" and prototypes.item[iname] or itype == "fluid" and prototypes.fluid[iname]) then
      if count >  2147483647 then count =  2147483647 end
      if count < -2147483648 then count = -2147483648 end
      signals[#signals+1] = {
        value = { type=itype, quality=iquality, name=iname },
        min = count
      }
      index = index+1
    end
  end

  ---@type LuaConstantCombinatorControlBehavior
  local b = combinator.get_control_behavior()

  while b.sections_count < 2 do
    b.add_section()
  end

  b.get_section(2).filters = signals

  -- Update GUI for all players viewing this combinator
  for _, player in pairs(game.players) do
    local frame = storage.guis[player.index]
    if frame and frame.context == combinator then
      gui.update_signal_display(player, combinator)
    end
  end
end

-- The on_tick handler is only subscribed while there is something to update.
function Update_Tick_Subscription()
  if #storage.content_combinators > 0 then
    script.on_event(defines.events.on_tick, OnTick)
  else
    script.on_event(defines.events.on_tick, nil)
  end
end

---@param entity LuaEntity?
function Register_Combinator(entity)
  if not entity or not entity.valid then return end
  if not content_readers[entity.name] then return end

  local id = entity.unit_number
  if not id or storage.content_combinator_ids[id] then return end

  storage.content_combinator_ids[id] = true
  storage.content_combinators[#storage.content_combinators + 1] = entity
  Update_Tick_Subscription()
end

---@param entity LuaEntity?
function Unregister_Combinator(entity)
  if not entity or not entity.valid then return end

  local id = entity.unit_number
  storage.content_combinator_ids[id] = nil
  for i = #storage.content_combinators, 1, -1 do
    -- The validity check has to come first: reading unit_number off an
    -- invalid LuaEntity raises. It also prunes entities that were destroyed
    -- without raising any event we subscribe to.
    local c = storage.content_combinators[i]
    if not c.valid or c.unit_number == id then
      table.remove(storage.content_combinators, i)
    end
  end
  Update_Tick_Subscription()
end

-- Readers that were placed while the mod was not listening (or by a script,
-- a space platform, or a clone) are otherwise invisible to us forever, since
-- nothing else ever repopulates this list.
function Rescan_Combinators()
  local names = {}
  for name in pairs(content_readers) do names[#names + 1] = name end

  storage.content_combinators = {}
  storage.content_combinator_ids = {}
  for _, surface in pairs(game.surfaces) do
    for _, entity in pairs(surface.find_entities_filtered({ name = names })) do
      Register_Combinator(entity)
    end
  end
  Update_Tick_Subscription()
end

-- add/remove event handlers
--- @param event EventData.on_built_entity
function OnEntityCreated(event)
  Register_Combinator(event.entity)
end

--- @param event EventData.on_entity_cloned
function OnEntityCloned(event)
  Register_Combinator(event.destination)
end

function OnEntityRemoved(event)
  Unregister_Combinator(event.entity)
end

---- Initialisation  ----
do
  local function init_globals()
    storage.cybersyn_stops = storage.cybersyn_stops or {}
    storage.cybersyn_provided = storage.cybersyn_provided or {}
    storage.cybersyn_requested = storage.cybersyn_requested or {}
    storage.cybersyn_deliveries = storage.cybersyn_deliveries or {}
    storage.content_combinators = storage.content_combinators or {}
    storage.content_combinator_ids = storage.content_combinator_ids or {}
    storage.guis = storage.guis or {}
    storage.update_interval = settings.global["cybersyn_content_reader_update_interval"].value
  end

  local reader_filter = {}
  for name in pairs(content_readers) do
    reader_filter[#reader_filter + 1] = { filter = "name", name = name }
  end

  local function register_events()
    -- Cybersyn itself listens to the script-raised and space-platform variants;
    -- missing them here is what left readers permanently dead.
    -- Each event has to be registered on its own, since filters are rejected
    -- when several events share one on_event call.
    for _, id in pairs({
      defines.events.on_built_entity,
      defines.events.on_robot_built_entity,
      defines.events.on_space_platform_built_entity,
      defines.events.script_raised_built,
      defines.events.script_raised_revive,
    }) do
      script.on_event(id, OnEntityCreated, reader_filter)
    end

    script.on_event(defines.events.on_entity_cloned, OnEntityCloned, reader_filter)

    for _, id in pairs({
      defines.events.on_pre_player_mined_item,
      defines.events.on_robot_pre_mined,
      defines.events.on_space_platform_mined_entity,
      defines.events.on_entity_died,
      defines.events.script_raised_destroy,
    }) do
      script.on_event(id, OnEntityRemoved, reader_filter)
    end

    if #storage.content_combinators > 0 then
      script.on_event(defines.events.on_tick, OnTick)
    end
  end


  script.on_init(function()
    init_globals()
    gui.on_init()
    register_events()
    Rescan_Combinators()
  end)

  script.on_configuration_changed(function(data)
    init_globals()
    Rescan_Combinators()
  end)

  script.on_load(function(data)
    register_events()
  end)
end
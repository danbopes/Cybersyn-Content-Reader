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

local WORKING = defines.entity_status.working
local LOW_POWER = defines.entity_status.low_power
local CIRCUIT_RED = defines.wire_connector_id.circuit_red
local CIRCUIT_GREEN = defines.wire_connector_id.circuit_green

-- The fields of a Cybersyn station this mod actually reads. read_global copies
-- whatever it is asked for, and a whole station carries tick_signals,
-- accepted_layouts, request_start_ticks and more that we never look at, so
-- asking for the whole struct costs an order of magnitude more than asking for
-- these. Measured at 500 stations: 36ms for the full table, 6ms for the fields.
local function station_field(id, field)
  return remote.call("cybersyn", "read_global", "stations", id, field)
end

--- Resolve (and create) the [surface][network][mask] bucket for a station.
--- Hoisted out of the per-signal path: append_item re-walked all four levels
--- for every single signal, and surface/network/mask are constant per station.
local function bucket_for(t, surface, network_name, network_mask)
  local s = t[surface]
  if not s then s = {}; t[surface] = s end
  local n = s[network_name]
  if not n then n = {}; s[network_name] = n end
  local m = n[network_mask]
  if not m then m = {}; n[network_mask] = m end
  return m
end

--- Fold one station into the three aggregate tables.
local function scan_station(id, provided, requested, in_transit)
  -- read_global's second return is how many arguments it resolved before it hit
  -- a nil, which is the only way to tell "this station has no stop" from "this
  -- station does not exist". Stopping at 2 means Cybersyn has nothing under
  -- this id, so the index entry is dead and is dropped here. Clearing the key
  -- being visited is defined behaviour for pairs().
  --
  -- Cybersyn does raise on_station_removed for every removal, but the event
  -- does not always arrive: on a real 1800-station save there is a station
  -- whose removal Cybersyn raises with a live listener and whose event never
  -- reaches this mod's handler. Without this the id is walked forever.
  local stop, depth = station_field(id, "entity_stop")
  if not stop then
    if depth == 2 then storage.cybersyn_station_ids[id] = nil end
    return
  end
  if not stop.valid then return end

  local network_name = station_field(id, "network_name") or "__all"
  local network_mask = station_field(id, "network_mask")
  local surface = stop.surface_index
  -- A signal-each station serves several networks at once and its mask is a
  -- table, so it keeps the general fan-out path in append_item. It is rare
  -- enough not to be worth a second hoisted implementation.
  local is_each = (network_name == "signal-each")
  local each_station = is_each
      and { entity_stop = stop, network_name = network_name, network_mask = network_mask }
      or nil

  local comb1 = station_field(id, "entity_comb1")
  local comb1_signals = nil
  if comb1 and comb1.valid then
    local status = comb1.status
    if status == WORKING or status == LOW_POWER then
      comb1_signals = comb1.get_signals(CIRCUIT_RED, CIRCUIT_GREEN)
    end
  end

  -- Buckets are resolved on first use, not up front: append_item only ever
  -- materialises a bucket that receives an item, and creating them eagerly
  -- would leave the aggregates full of empty networks.
  local p_bucket, r_bucket, d_bucket

  if comb1_signals then
    local is_p = station_field(id, "is_p")
    local is_r = station_field(id, "is_r")
    local is_stack, item_thresholds, r_fluid_threshold, base_threshold
    if is_r then
      is_stack = station_field(id, "is_stack")
      item_thresholds = station_field(id, "item_thresholds")
      r_fluid_threshold = station_field(id, "r_fluid_threshold")
      base_threshold = station_field(id, "r_threshold")
    end

    if is_p or is_r then
      local proto_item = prototypes.item
      for _, v in pairs(comb1_signals) do
        local item = v.signal
        if item.type ~= "virtual" then
          local count = v.count
          local item_type = item.type or "item"
          local item_hash = hash_signal(item)

          if is_p and count > 0 then
            if is_each then
              append_item(provided, each_station, item_hash, count)
            else
              if not p_bucket then
                p_bucket = bucket_for(provided, surface, network_name, network_mask)
              end
              p_bucket[item_hash] = (p_bucket[item_hash] or 0) + count
            end
          end

          if is_r and count < 0 then
            local r_threshold = item_thresholds and item_thresholds[item.name] or
                item_type == "fluid" and r_fluid_threshold or
                base_threshold
            if is_stack and item_type == "item" then
              r_threshold = r_threshold * proto_item[item.name].stack_size
            end

            if -count >= r_threshold then
              if is_each then
                append_item(requested, each_station, item_hash, count)
              else
                if not r_bucket then
                  r_bucket = bucket_for(requested, surface, network_name, network_mask)
                end
                r_bucket[item_hash] = (r_bucket[item_hash] or 0) + count
              end
            end
          end
        end
      end
    end
  end

  local deliveries = station_field(id, "deliveries")
  if deliveries then
    for cc_item_hash, count in pairs(deliveries) do
      if count > 0 then
        -- Cybersyn keys deliveries by name or name|quality with no type, so
        -- they have to be rehashed into our type-carrying form.
        local item_name, quality = unhash_cc_signal(cc_item_hash)
        local type = prototypes.item[item_name] == nil and "fluid" or "item"
        local item_hash = hash_signal({ name = item_name, quality = quality, type = type })
        if is_each then
          append_item(in_transit, each_station, item_hash, count)
        else
          if not d_bucket then
            d_bucket = bucket_for(in_transit, surface, network_name, network_mask)
          end
          d_bucket[item_hash] = (d_bucket[item_hash] or 0) + count
        end
      end
    end
  end
end

function InitSignals()
  local inventory_provided = {}
  local inventory_requested = {}
  local inventory_in_transit = {}

  for id in pairs(storage.cybersyn_station_ids) do
    scan_station(id, inventory_provided, inventory_requested, inventory_in_transit)
  end

  storage.cybersyn_provided = inventory_provided
  storage.cybersyn_requested = inventory_requested
  storage.cybersyn_deliveries = inventory_in_transit
end

-- Cybersyn allocates its interop event ids at runtime with
-- script.generate_event_name, and only starts raising an event once its getter
-- has been called. Both facts mean the ids cannot be cached across a save:
-- after a load they have not been allocated again, and an id from the previous
-- session is rejected as "not a valid event".
--
-- They also cannot be fetched in on_load, where remote.call is forbidden. So
-- they are acquired on the first tick after a load instead. This local resets
-- every load, which is exactly the trigger we want.
local cybersyn_events_ready = false

function Ensure_Cybersyn_Events()
  script.on_event(remote.call("cybersyn", "get_on_station_created"), OnStationCreated)
  script.on_event(remote.call("cybersyn", "get_on_station_removed"), OnStationRemoved)

  -- Until the getters above are called Cybersyn raises nothing, so any station
  -- it created or destroyed between this load and now went unheard. One rebuild
  -- closes that window. It happens once per load, not on a timer.
  Rebuild_Station_Ids()

  cybersyn_events_ready = true
end

--- Stands in for OnTick for exactly one tick after a load, then takes itself
--- out of the way. One tick has to do the acquisition above, but only one, so
--- it is a separate handler that swaps itself for the real one rather than a
--- branch every tick forever.
---
--- The swap is after the acquisition on purpose: if that raises, this is still
--- the registered handler and the next tick retries, rather than leaving the
--- mod running forever against an index it never built.
function OnFirstTick(event)
  Ensure_Cybersyn_Events()
  script.on_event(defines.events.on_tick, OnTick)
  OnTick(event)
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
  -- counts entries written so far, so the append needs no length operator
  local index = 0

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

  -- Generate signals from the aggregated item list. signal_value_for both
  -- decodes the hash and vets the prototype, memoised per item, so neither the
  -- string split nor the prototype lookup happens per combinator any more.
  for item, count in pairs(items) do
    local value = signal_value_for(item)
    if value then
      if count >  2147483647 then count =  2147483647 end
      if count < -2147483648 then count = -2147483648 end
      index = index + 1
      signals[index] = {
        value = value,
        min = count
      }
    end
  end

  ---@type LuaConstantCombinatorControlBehavior
  local b = combinator.get_control_behavior()

  while b.sections_count < 2 do
    b.add_section()
  end

  b.get_section(2).filters = signals

  -- Update the GUI for players viewing this combinator. Only players with a
  -- reader GUI open are in storage.guis, which is almost always empty; the
  -- previous sweep walked every player on the server for every combinator.
  for player_index, frame in pairs(storage.guis) do
    if frame.context == combinator then
      local player = game.get_player(player_index)
      if player then gui.update_signal_display(player, combinator) end
    end
  end
end

-- The on_tick handler is only subscribed while there is something to update.
-- Until Cybersyn's events have been picked up, the one-shot handler that does
-- that is the one subscribed; it hands over to OnTick itself.
function Update_Tick_Subscription()
  if #storage.content_combinators > 0 then
    script.on_event(defines.events.on_tick, cybersyn_events_ready and OnTick or OnFirstTick)
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

---- Cybersyn station index ----
--
-- InitSignals used to pull Cybersyn's entire station table across the mod
-- boundary every cycle just to learn which stations exist. read_global copies
-- what it returns, so that single call was over half the cost of a refresh.
--
-- The set of stations only changes when Cybersyn says so, and it raises
-- on_station_created / on_station_removed for exactly that. Keeping the index
-- here means the whole table is read once at init and never again.
--
-- The events are not quite enough on their own: a removal can be raised and
-- still not arrive, so an id can outlive the station it names. scan_station
-- drops those as it meets them, which costs nothing because it already asks
-- for the field that gives the answer. There is still no periodic resync.

--- Read the full station table. Only correct as initialisation: on_init, or
--- on_configuration_changed where stations may have appeared or vanished while
--- this mod was not loaded to hear about it.
function Rebuild_Station_Ids()
  local ids = {}
  local stations = remote.call("cybersyn", "read_global", "stations")
  for id in pairs(stations) do ids[id] = true end
  storage.cybersyn_station_ids = ids
end

function OnStationCreated(event)
  if event and event.station_id then
    storage.cybersyn_station_ids[event.station_id] = true
  end
end

-- note: the removed event names the field old_station_id, not station_id
function OnStationRemoved(event)
  if event and event.old_station_id then
    storage.cybersyn_station_ids[event.old_station_id] = nil
  end
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
    storage.cybersyn_station_ids = storage.cybersyn_station_ids or {}
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

    Update_Tick_Subscription()
  end


  script.on_init(function()
    init_globals()
    gui.on_init()
    register_events()
    Ensure_Cybersyn_Events()
    Rescan_Combinators()
  end)

  script.on_configuration_changed(function(data)
    init_globals()

    -- Cybersyn may have been added, updated or removed, so its event ids have
    -- to be reacquired and the station index rebuilt. That is deliberately NOT
    -- done here: Cybersyn runs its own migrations in this same phase, and
    -- reading its stations mid-migration could capture a half-updated set.
    -- Clearing the flag defers both to the first tick, by which point every
    -- mod has finished configuring.
    --
    -- Cleared before the rescan, because that is what re-arms the one-shot
    -- tick handler.
    cybersyn_events_ready = false
    Rescan_Combinators()

    -- prototypes may have changed, which is the only thing that can invalidate
    -- a decoded signal
    clear_signal_value_cache()
  end)

  script.on_load(function(data)
    register_events()
    -- Cybersyn's event ids cannot be acquired here (no remote.call in on_load);
    -- OnTick picks them up on the first tick.
  end)
end
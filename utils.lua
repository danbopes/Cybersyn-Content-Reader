function get_signals(station)
	local comb1 = station.entity_comb1
	-- Cybersyn can hold a station whose combinator was destroyed or never
	-- finished initialising; reading .status off that would raise.
	if not comb1 or not comb1.valid then
		return nil, nil
	end
	local status1 = comb1.status
	---@type Signal[]?
	local comb1_signals = nil
	---@type Signal[]?
	local comb2_signals = nil
	if status1 == defines.entity_status.working or status1 == defines.entity_status.low_power then
		comb1_signals = comb1.get_signals(defines.wire_connector_id.circuit_red, defines.wire_connector_id.circuit_green)
	end
	local comb2 = station.entity_comb2
	if comb2 and comb2.valid then
		local status2 = comb2.status
		if status2 == defines.entity_status.working or status2 == defines.entity_status.low_power then
			comb2_signals = comb2.get_signals(defines.wire_connector_id.circuit_red, defines.wire_connector_id.circuit_green)
		end
	end
	return comb1_signals, comb2_signals
end

local HASH_STRING = "|"

---@param name string The name of the item
---@param quality string The name of the quality of the item or nil if it is common
---@return string
function hash_item(type, name, quality)
    if type == nil then
        type = "item"
    end

	if quality == nil or quality == "normal" then
		return type .. HASH_STRING .. name
	else
		return type .. HASH_STRING .. name .. HASH_STRING .. quality
	end
end

---@param sig SignalID
---@return string
function hash_signal(sig)
	return hash_item(sig.type, sig.name, sig.quality)
end

---@param hash string
---@return string type, string name, string? quality
function unhash_signal(hash)
	local type, nameAndQuality = split(hash)
    local name, quality = split(nameAndQuality)

    if quality == nil then
        quality = "normal"
    end

    return type, name, quality
end

---@param hash string
---@return string name, string? quality
function unhash_cc_signal(hash)
    local name, quality = split(hash)

    if quality == nil then
        quality = "normal"
    end

    return name, quality
end

function split(str)
    local index = string.find(str, HASH_STRING)
	if not index then
		return str, nil
	end

	local first = string.sub(str, 1, index - 1)
	local second = string.sub(str, index + string.len(HASH_STRING), string.len(str))

    return first, second
end

-- Decoding a hash back into a signal is a pure function of the string, so it
-- is done once per distinct item instead of once per item, per combinator, per
-- update. The cached table is the exact value handed to
-- LuaLogisticSection.filters, so the filter list is no longer rebuilt from
-- scratch either, and the prototype existence check happens once rather than
-- on every read.
--
-- NOTE: the returned table is shared by every filter referencing that item.
-- Factorio converts it on assignment and does not retain it, but nothing may
-- mutate it in place.
--
-- This is deliberately NOT in storage: it is derived, and rebuilding it costs
-- one parse per item. The only thing that can invalidate it is the prototype
-- set changing, which raises on_configuration_changed. There is no periodic
-- resync because nothing else can make an entry wrong.
local signal_values = {}

---@param hash string
---@return SignalFilter? value nil if the prototype no longer exists
function signal_value_for(hash)
  local v = signal_values[hash]
  if v ~= nil then return v or nil end

  local itype, iname, iquality = unhash_signal(hash)
  if itype and iname and (itype == "item" and prototypes.item[iname]
      or itype == "fluid" and prototypes.fluid[iname]) then
    v = { type = itype, name = iname, quality = iquality }
  else
    -- Remember the miss too. A hash naming a prototype that no longer exists
    -- would otherwise be re-parsed and re-rejected on every single update.
    v = false
  end
  signal_values[hash] = v
  return v or nil
end

--- Drop the decode cache. Only correct to call when the prototype set may have
--- changed, i.e. from on_configuration_changed.
function clear_signal_value_cache()
  signal_values = {}
end

---@param entity LuaEntity
function get_first_signal(entity)
     ---@type LuaConstantCombinatorControlBehavior
    local behavior = entity.get_control_behavior()

    if behavior == nil or behavior.sections_count < 1 then
        return nil
    end

    -- Section 1 holds the network selection; section 2 is where we write our
    -- own output. Scanning for the first *active* section would read that
    -- output back as configuration whenever section 1 is disabled.
    local section = behavior.get_section(1)
    if not section or not section.active then
        return nil
    end

    return section.get_slot(1)
end

---@param entity LuaEntity
---@param signal SignalFilter
---@param amount integer
function set_first_signal(entity, signal, amount)
    ---@type LuaConstantCombinatorControlBehavior
    local b = entity.get_or_create_control_behavior()
  
    if b.sections_count == 0 then
      b.add_section()
    end
  
    local s = b.get_section(1)
    s.active = true
    s.set_slot(1, {
      value = signal,
      min = amount
    })
end

--- @param count integer
--- @return string
function format_signal_count(count)
	local function si_format(divisor, si_symbol)
		if math.abs(math.floor(count / divisor)) >= 10 then
			count = math.floor(count / divisor)
			return string.format("%.0f%s", count, si_symbol)
		else
			count = math.floor(count / (divisor / 10)) / 10
			return string.format("%.1f%s", count, si_symbol)
		end
	end

	local abs = math.abs(count)
	return -- signals are 32bit integers so Giga is enough
			abs >= 1e9 and si_format(1e9, "G") or
			abs >= 1e6 and si_format(1e6, "M") or
			abs >= 1e3 and si_format(1e3, "k") or
			tostring(count)
end
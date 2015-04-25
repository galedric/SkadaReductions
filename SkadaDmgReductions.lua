local addonName = ...

local Skada = Skada
local floor = math.floor
local band = bit.band

local CLIENT_VERSION = tonumber((select(4, GetBuildInfo())))
local PHYSICAL_DMG, MAGICAL_DMG, ALL_DMG = 1, 126, 255

--------------------------------------------------------------------------------

local effects = {
	--- ### RAID WIDE EFFECTS ### ---
	
	[31821] = { -- Devotion Aura
		reduction = 0.2,
		duration = 6,
		school = (CLIENT_VERSION > 60100) and ALL_DMG or MAGICAL_DMG -- All damages since 6.2
	},
	[51052] = { -- Anti-Magic Zone
		reduction = 0.2,
		duration = 3,
		aura = 145629,
		school = MAGICAL_DMG
	},
	[62618] = { -- Power Word: Barrier
		reduction = 0.2,
		duration = 10,
		aura = 81782
	},
	[76577] = { -- Smoke Bomb [not tested]
		reduction = 0.1,
		duration = 5
	},
	[98008] = { -- Spirit Link Totem
		reduction = 0.1,
		duration = 6,
		aura = 98007
	},
	
	--- ### PERSONAL EFFECTS ### ---
	
	[498] = { -- Divine Protection
		reduction = function(aura) return aura[16] == 0 and 0.4 or 0.2 end,
		duration = 8,
		school = function(aura) return aura[16] == 0 and MAGICAL_DMG or ALL_DMG end
	},
	
	--- ### EXTERNAL EFFECTS ### ---
	
	[6940] = { -- Hand of Sacrifice
		reduction = 0.3,
		duration = 12,
		validate = function(aura) return aura[15] == 0 end
	},
}

local raid_effects = {
	[31821] = true, -- DA
	[51052] = true, -- AMZ
	[62618] = true, -- PW:B
	[76577] = true, -- SmB
	[98008] = true, -- SLT
}

local personnal_effects = {
	[498] = true, -- Divine Protection
}

local external_effects = {
	[6940] = true, -- Hand of Sacrifice
}

--------------------------------------------------------------------------------

local raid_effects_active = {}
local players_effects_active = {}

--------------------------------------------------------------------------------

local sources = {}
local sources_count = 0
local effects_product = 1
local effects_sum = 0

local function check_instance(set, id, instance, dmg)
	local effect = effects[id]
	local expired = false
	local aura
	
	-- Check expire time
	if instance.expire < dmg.time then
		expired = true
	else
		aura = { UnitAura(dmg.playername, effect.auraname) }
	end
	
	-- Check validate function
	if not expired and not instance.validated and effect.validate and not effect.validate(aura) then
		expired = true
	else
		instance.validated = true
	end
	
	-- Instance is expired
	if expired then 
		set[id] = nil
		return
	elseif not aura then
		return
	end
	
	-- Check damage school
	local school_valid = true
	if effect.school then
		local school_mask
		if type(effect.school) == "function" then
			school_mask = effect.school(aura)
		else
			school_mask = effect.school
		end
		school_valid = band(school_mask, dmg.school) ~= 0
	end
	
	if school_valid then
		local reduction = type(effect.reduction) == "function" and effect.reduction(aura) or effect.reduction
		
		effects_product = effects_product * (1 - reduction)
		effects_sum = effects_sum + reduction
		
		sources_count = sources_count + 1
		local source = sources[sources_count]
		if not source then
			source = {}
			sources[sources_count] = source
		end
		
		source.reduction = reduction
		source.id = instance.sourceid
		source.name = instance.sourcename
		source.effectname = effect.name
		source.effectid = id
	end
end

local function log_reduction(set, dmg)
	local time = dmg.time
	
	sources_count = 0
	effects_product = 1
	effects_sum = 0
	
	-- Handle raid-wide effects
	for id, instance in pairs(raid_effects_active) do
		check_instance(raid_effects_active, id, instance, dmg)
	end
	
	-- Handle player effect
	local player_effects = players_effects_active[dmg.playerid]
	if player_effects then
		for id, instance in pairs(player_effects) do
			check_instance(player_effects, id, instance, dmg)
		end
		if not next(player_effects) then
			players_effects_active[dmg.playerid] = nil
		end
	end
	
	if sources_count < 1 then return end
	
	-- Compute total prevented amount
	local prevented = floor(dmg.amount / effects_product - dmg.amount)
	
	for _, source in ipairs(sources) do
		local player = Skada:get_player(set, source.id, source.name)
		if player then
			local amount = (source.reduction / effects_sum) * prevented
			
			-- Add to player total.
			player.healing = player.healing + amount
			player.shielding = player.shielding + amount
			
			-- Also add to set total damage.
			set.healing = set.healing + amount
			set.shielding = set.shielding + amount
			
			-- Also add to set total damage.
			set.healing = set.healing + amount
			set.shielding = set.shielding + amount
			
			-- Add to recipient healing.
			do
				local healed = player.healed[dmg.playerid]

				-- Create recipient if it does not exist.
				if not healed then
					local _, className = UnitClass(dmg.playername)
					local playerRole = UnitGroupRolesAssigned(dmg.playername)
					healed = {name = dmg.playername, class = className, role = playerRole, amount = 0, shielding = 0}
					player.healed[dmg.playerid] = healed
				end

				healed.amount = healed.amount + amount
				healed.shielding = healed.shielding + amount
			end
			
			-- Add to spell healing
			do
				local spell = player.healingspells[source.effectname]

				-- Create spell if it does not exist.
				if not spell then
					spell = {id = source.effectid, name = source.effectname, hits = 0, healing = 0, overhealing = 0, absorbed = 0, shielding = 0, critical = 0, multistrike = 0, min = nil, max = 0}
					player.healingspells[source.effectname] = spell
				end

				spell.healing = spell.healing + amount
				spell.shielding = spell.shielding + amount
				spell.hits = (spell.hits or 0) + 1

				if not spell.min or amount < spell.min then
					spell.min = amount
				end
				if not spell.max or amount > spell.max then
					spell.max = amount
				end
			end
		end
	end
end

--------------------------------------------------------------------------------

local dmg = {}

local function SpellDamage(_, _, _, _, _, dstGUID, dstName, _, ...)
	local _, _, _, samount, _, sschool = ...

	dmg.playerid = dstGUID
	dmg.playername = dstName
	dmg.amount = samount
	dmg.school = sschool
	dmg.time = GetTime()

	log_reduction(Skada.current, dmg)
	log_reduction(Skada.total, dmg)
end

local function SwingDamage(_, _, _, _, _, dstGUID, dstName, _, ...)
	local samount, _, sschool = ...

	dmg.playerid = dstGUID
	dmg.playername = dstName
	dmg.amount = samount
	dmg.school = sschool
	dmg.time = GetTime()

	log_reduction(Skada.current, dmg)
	log_reduction(Skada.total, dmg)
end

Skada:RegisterForCL(SpellDamage, "SPELL_DAMAGE", {dst_is_interesting_nopets = true})
Skada:RegisterForCL(SpellDamage, "SPELL_PERIODIC_DAMAGE", {dst_is_interesting_nopets = true})
Skada:RegisterForCL(SpellDamage, "SPELL_BUILDING_DAMAGE", {dst_is_interesting_nopets = true})
Skada:RegisterForCL(SpellDamage, "RANGE_DAMAGE", {dst_is_interesting_nopets = true})
Skada:RegisterForCL(SwingDamage, "SWING_DAMAGE", {dst_is_interesting_nopets = true})

--------------------------------------------------------------------------------

local function SpellCast(_, _, srcGUID, srcName, _, dstGUID, dstName, _, ...)
	local spellId, spellName = ...
	
	-- Check if this is an interesting spell
	local effect = effects[spellId]
	if not effect then return end
	
	-- Set the localized name on first occurrence
	if not effect.name then
		effect.name = spellName
		effect.auraname = GetSpellInfo(effect.aura or spellId)
	end
	
	-- Raid-wide effect
	if raid_effects[spellId] then
		raid_effects_active[spellId] = {
			sourceid = srcGUID,
			sourcename = srcName,
			expire = GetTime() + effect.duration
		}
		return
	end
	
	-- Select the correct target player
	local target_player
	if personnal_effects[spellId] then
		target_player = srcGUID
	elseif external_effects[spellId] then
		target_player = dstGUID
	end
	
	if not target_player then return end
	
	-- Load player effects
	local player_effects = players_effects_active[target_player]
	if not player_effects then
		player_effects = {}
		players_effects_active[target_player] = player_effects
	end
	
	-- Register this spell
	player_effects[spellId] = {
		sourceid = srcGUID,
		sourcename = srcName,
		expire = GetTime() + effect.duration
	}
end

Skada:RegisterForCL(SpellCast, "SPELL_CAST_SUCCESS", {src_is_interesting_nopets = true})

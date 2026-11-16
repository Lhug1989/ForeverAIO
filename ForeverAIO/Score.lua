-- Score.lua: what an item is worth (ns.Score). No other addon is asked: the stats come from the game
-- (C_Item.GetItemStats), the weights from Data/Weights.lua (Forever Leveling BiS's numbers).
--   worth of an item  = sum of each stat x its weight, plus weapon DPS x the DPS weight of the slot it goes in
--   power             = your Strength, Agility, Stamina, Intellect and Spirit x their weights, plus every other
--                       stat of the gear you wear x its weight
--   gain              = 100 x (worth of the new item - worth of what it replaces) / power: "percent stronger"
-- Rules that are not plain weights:
--   * Forever gear carries hit, crit, dodge, parry and block as a flat percentage; the game reports them as
--     rating at the level-60 rate (10 hit, 14 crit, 12 dodge, 15 parry, 5 block per 1 %), turned back here.
--   * weapon DPS: main hand x dps, off hand x ohDps (half of dps when the spec has no ohDps). Ranged slot: a
--     hunter's bow, gun or crossbow x rangedDps; a wand x rangedDps; a warrior's or rogue's thrown weapon x dps
--     (user 14 Nov: thrown is "highly preferred for leveling for melee"); their bows and guns count stats only.
--     Every ranged weapon keeps a sliver of DPS weight so that an empty ranged slot is still filled.
--   * Humans get 10 % more from Spirit, Gnomes 5 % more from Intellect (as Forever Leveling BiS counts them).
--   * what a class can wear: weapon types per class and armor up to the class's type (mail and plate from 40)
--     from Forever's own skill table, shields for warriors, paladins and shamans, relics by class; hunters take
--     no thrown weapon. On top, anything the game's own tooltip shows in red is left alone.
local _, ns = ...
local E = {}
ns.Score = E

local MAIN, OFF, RANGED = 16, 17, 18
local WEAPON, ARMOR, PROJECTILE = 2, 4, 6
local THROWN, WAND, MISC_WEAPON, FISHING_POLE = 16, 19, 14, 20
local SHIELD = 6
local HEAVY_ARMOR_LEVEL = 40
local RANGED_FLOOR = 0.01             -- the least a point of ranged-slot weapon DPS is worth
local CACHE_MAX = 600
local TIP_KEEP = 20                   -- seconds a tooltip reading is kept
E.MIN_GAIN = 0.5                      -- percent: what is worn is only replaced for at least this much
E.PERCENT = 100

local function Secret(v) return issecretvalue ~= nil and issecretvalue(v) end
local function ItemInfo(item) return (C_Item and C_Item.GetItemInfo or GetItemInfo)(item) end
local function ItemInstant(item) return (C_Item and C_Item.GetItemInfoInstant or GetItemInfoInstant)(item) end

-- equip location -> the inventory slots it can go in (first = the usual one)
local SLOTS = {
    INVTYPE_HEAD = { 1 }, INVTYPE_NECK = { 2 }, INVTYPE_SHOULDER = { 3 }, INVTYPE_CLOAK = { 15 },
    INVTYPE_CHEST = { 5 }, INVTYPE_ROBE = { 5 }, INVTYPE_WRIST = { 9 }, INVTYPE_HAND = { 10 },
    INVTYPE_WAIST = { 6 }, INVTYPE_LEGS = { 7 }, INVTYPE_FEET = { 8 },
    INVTYPE_FINGER = { 11, 12 }, INVTYPE_TRINKET = { 13, 14 },
    INVTYPE_WEAPON = { 16, 17 }, INVTYPE_2HWEAPON = { 16 }, INVTYPE_WEAPONMAINHAND = { 16 },
    INVTYPE_WEAPONOFFHAND = { 17 }, INVTYPE_SHIELD = { 17 }, INVTYPE_HOLDABLE = { 17 },
    INVTYPE_RANGED = { 18 }, INVTYPE_RANGEDRIGHT = { 18 }, INVTYPE_THROWN = { 18 }, INVTYPE_RELIC = { 18 },
}
E.SLOTS = SLOTS

-- the game's stat keys (C_Item.GetItemStats) -> the weight keys
local GAME_STATS = {
    ITEM_MOD_STRENGTH_SHORT = "str", ITEM_MOD_AGILITY_SHORT = "agi", ITEM_MOD_STAMINA_SHORT = "sta",
    ITEM_MOD_INTELLECT_SHORT = "int", ITEM_MOD_SPIRIT_SHORT = "spi",
    RESISTANCE0_NAME = "armor",
    ITEM_MOD_ATTACK_POWER_SHORT = "atkpwr", ITEM_MOD_RANGED_ATTACK_POWER_SHORT = "rgdatkpwr",
    ITEM_MOD_FERAL_ATTACK_POWER_SHORT = "feratkpwr", ITEM_MOD_MELEE_ATTACK_POWER_SHORT = "feratkpwr",
    ITEM_MOD_SPELL_POWER_SHORT = "splpwr", ITEM_MOD_SPELL_DAMAGE_DONE_SHORT = "spldmg",
    ITEM_MOD_SPELL_HEALING_DONE_SHORT = "splheal", ITEM_MOD_SPELL_PENETRATION_SHORT = "splpen",
    ITEM_MOD_ARCANE_DAMAGE_DONE_SHORT = "arcsplpwr", ITEM_MOD_FIRE_DAMAGE_DONE_SHORT = "firsplpwr",
    ITEM_MOD_FROST_DAMAGE_DONE_SHORT = "frosplpwr", ITEM_MOD_HOLY_DAMAGE_DONE_SHORT = "holsplpwr",
    ITEM_MOD_NATURE_DAMAGE_DONE_SHORT = "natsplpwr", ITEM_MOD_SHADOW_DAMAGE_DONE_SHORT = "shasplpwr",
    ITEM_MOD_HASTE_RATING_SHORT = "hastertng", ITEM_MOD_EXPERTISE_RATING_SHORT = "exprtng",
    ITEM_MOD_DEFENSE_SKILL_RATING_SHORT = "defrtng", ITEM_MOD_BLOCK_VALUE_SHORT = "block",
    ITEM_MOD_MANA_REGENERATION_SHORT = "manargn", ITEM_MOD_POWER_REGEN0_SHORT = "manargn",
    ITEM_MOD_HEALTH_REGEN_SHORT = "healthrgn",
}
-- reported as rating, weighed per 1 %: { weight key, rating per 1 % }
local GAME_PCT = {
    ITEM_MOD_HIT_RATING_SHORT = { "hitPct", 10 }, ITEM_MOD_HIT_SPELL_RATING_SHORT = { "hitPct", 10 },
    ITEM_MOD_CRIT_RATING_SHORT = { "critPct", 14 }, ITEM_MOD_CRIT_SPELL_RATING_SHORT = { "critPct", 14 },
    ITEM_MOD_SPELL_CRIT_RATING_SHORT = { "critPct", 14 },
    ITEM_MOD_DODGE_RATING_SHORT = { "dodgePct", 12 }, ITEM_MOD_PARRY_RATING_SHORT = { "parryPct", 15 },
    ITEM_MOD_BLOCK_RATING_SHORT = { "blockPct", 5 },
}
local DPS_STAT = "ITEM_MOD_DAMAGE_PER_SECOND_SHORT"
local PRIMARY = { "str", "agi", "sta", "int", "spi" }            -- in UnitStat's order
local PRIMARY_KEY = { str = true, agi = true, sta = true, int = true, spi = true }
E.GAME_STATS, E.GAME_PCT = GAME_STATS, GAME_PCT

-- Weapon types (item subclass) each class can learn on Forever, and the heaviest armor it wears
-- (1 cloth, 2 leather, 3 mail, 4 plate). From the client's skill table, as Forever Leveling BiS lists it.
local function Set(...)
    local t = {}
    for _, v in ipairs({ ... }) do t[v] = true end
    return t
end
local WEAPONS = {
    WARRIOR = Set(0, 1, 2, 3, 4, 5, 6, 7, 8, 10, 13, 15, 16, 18),
    PALADIN = Set(0, 1, 4, 5, 6, 7, 8),
    HUNTER = Set(0, 1, 2, 3, 6, 7, 8, 10, 13, 15, 16, 18),
    ROGUE = Set(0, 2, 3, 4, 7, 13, 15, 16, 18),
    PRIEST = Set(4, 10, 15, 19),
    SHAMAN = Set(0, 1, 4, 5, 10, 13, 15),
    MAGE = Set(7, 10, 15, 19),
    WARLOCK = Set(7, 10, 15, 19),
    DRUID = Set(4, 5, 6, 10, 13, 15),
}
local ARMOR_MAX = { WARRIOR = 4, PALADIN = 4, HUNTER = 3, SHAMAN = 3, ROGUE = 2, DRUID = 2, PRIEST = 1, MAGE = 1,
    WARLOCK = 1 }
local SHIELD_USERS = { WARRIOR = true, PALADIN = true, SHAMAN = true }
local RELIC_OWNER = { [7] = "PALADIN", [8] = "DRUID", [9] = "SHAMAN" }      -- libram, idol, totem
local RACE_MULT = { Human = { spi = 1.10 }, Gnome = { int = 1.05 } }
E.WEAPONS, E.ARMOR_MAX = WEAPONS, ARMOR_MAX

function E.SlotsFor(id)
    local _, _, _, equipLoc = ItemInstant(id)
    return SLOTS[equipLoc]
end

function E.IsTwoHand(id)
    local _, _, _, equipLoc = ItemInstant(id)
    return equipLoc == "INVTYPE_2HWEAPON"
end

-- the heaviest armor type a class wears at a level
function E.MaxArmor(class, level)
    local max = ARMOR_MAX[class] or 1
    if max >= 3 and (level or 0) < HEAVY_ARMOR_LEVEL then max = max - 1 end
    return max
end

-- a player race's stat multipliers, or nil
function E.RaceMult()
    local ok, _, race = pcall(UnitRace, "player")
    if not ok or Secret(race) or type(race) ~= "string" then return nil end
    return RACE_MULT[race]
end

-------------------------------------------------------------------------------------------------------------------
-- Weights
-------------------------------------------------------------------------------------------------------------------
-- The weapon setup whose weights count: only an Enhancement shaman's differ (two-hander by default, "shield"
-- with a one-hander in the main hand).
function E.Setup(class, spec, mainID)
    if class == "SHAMAN" and spec == "enhancement" and mainID and not E.IsTwoHand(mainID) then return "shield" end
    return nil
end

-- The weight row for a class, spec and level (and weapon setup): the first row that reaches the level.
function E.Weights(class, spec, level, setup)
    local data = ns.WeightData
    local byClass = type(data) == "table" and type(data.classes) == "table" and data.classes[class]
    local rows = type(byClass) == "table" and byClass[spec]
    if type(rows) ~= "table" then return nil end
    if setup and type(rows.setups) == "table" and type(rows.setups[setup]) == "table" then rows = rows.setups[setup] end
    if type(level) ~= "number" or level < 1 then level = 1 end
    for _, row in ipairs(rows) do
        if type(row) == "table" and type(row.upTo) == "number" and level <= row.upTo then return row end
    end
    return rows[#rows]
end

-------------------------------------------------------------------------------------------------------------------
-- Item stats
-------------------------------------------------------------------------------------------------------------------
local statsOf, cachedN = {}, 0

local function Loaded(item, id)
    local isCached = C_Item and C_Item.IsItemDataCachedByID
    if isCached and id then
        local ok, yes = pcall(isCached, id)
        if ok and not Secret(yes) and yes ~= nil then
            if yes then return true end
            local ask = C_Item.RequestLoadItemDataByID
            if ask then pcall(ask, id) end
            return false
        end
    end
    return ItemInfo(item) ~= nil
end

-- An item's stats in weight keys ({ str = 5, critPct = 1, dps = 12.3 }), or nil while the game has not loaded
-- the item. `item` is a link (its random suffix counts) or an item ID.
function E.Stats(item)
    if item == nil then return nil end
    local hit = statsOf[item]
    if hit then return hit end
    local id = type(item) == "number" and item or ItemInstant(item)
    if not id or not Loaded(item, id) then return nil end
    local read = (C_Item and C_Item.GetItemStats) or GetItemStats
    if type(read) ~= "function" then return nil end
    local raw = read(type(item) == "number" and ("item:" .. item) or item)
    local stats = {}
    if type(raw) == "table" then
        for key, value in pairs(raw) do
            if not Secret(value) and type(value) == "number" then
                local pct, to = GAME_PCT[key], GAME_STATS[key]
                if pct then
                    to, value = pct[1], value / pct[2]
                elseif key == DPS_STAT then
                    to = "dps"
                end
                -- two game keys for one stat are the same bonus reported twice: counted once
                if to and (stats[to] == nil or value > stats[to]) then stats[to] = value end
            end
        end
    end
    if next(stats) == nil then return stats end         -- nothing read: not kept, so a too-early answer is asked again
    if cachedN >= CACHE_MAX then statsOf, cachedN = {}, 0 end
    statsOf[item], cachedN = stats, cachedN + 1
    return stats
end

-- The weight of a point of weapon DPS for an item of weapon type `sub` in `slot`.
function E.DpsWeight(slot, weights, class, sub)
    if slot == MAIN then return weights.dps or 0 end
    if slot == OFF then return weights.ohDps or 0.5 * (weights.dps or 0) end
    if slot == RANGED then
        local w = 0
        if class == "HUNTER" or sub == WAND then w = weights.rangedDps or 0
        elseif sub == THROWN then w = weights.dps or 0 end
        return math.max(w, RANGED_FLOOR)
    end
    return 0
end

-- What a stats table is worth in `slot`. sub = the item's weapon type (nil for anything else), mult = race
-- multipliers, skipPrimary = leave Strength..Spirit out (Power counts those from the character itself).
function E.Worth(stats, weights, slot, class, sub, mult, skipPrimary)
    local total = 0
    for key, value in pairs(stats) do
        if key ~= "dps" and key ~= "upTo" and not (skipPrimary and PRIMARY_KEY[key]) then
            local w = weights[key]
            if type(w) == "number" then total = total + value * w * (mult and mult[key] or 1) end
        end
    end
    if stats.dps and sub ~= nil then total = total + stats.dps * E.DpsWeight(slot, weights, class, sub) end
    return total
end

-- weapon type of an item (its subclass when it is a weapon, else nil)
local function WeaponType(item)
    local _, _, _, _, _, classID, subclassID = ItemInstant(item)
    if classID == WEAPON then return subclassID end
    return nil
end

-- worth of an item in a slot for a context (AutoGear's ctx: weights, class, mult); nil = not loaded yet
function E.ItemWorth(item, slot, ctx, skipPrimary)
    local stats = E.Stats(item)
    if not stats then return nil end
    return E.Worth(stats, ctx.weights, slot, ctx.class, WeaponType(item), ctx.mult, skipPrimary)
end

local function WornWorth(slot, ctx)
    local link = GetInventoryItemLink("player", slot)
    if not link then return 0 end
    return E.ItemWorth(link, slot, ctx)
end

-------------------------------------------------------------------------------------------------------------------
-- Power and gain
-------------------------------------------------------------------------------------------------------------------
local lastPower = setmetatable({}, { __mode = "k" })       -- weights row -> the last power that could be read

-- Your power for a weight row: nil when the game hides your stats and none was read before.
function E.Power(weights, class, mult)
    local power = 0
    for i, key in ipairs(PRIMARY) do
        local w = weights[key]
        if type(w) == "number" and w ~= 0 then
            local ok, base, effective = pcall(UnitStat, "player", i)
            if not ok or Secret(base) or Secret(effective) then return lastPower[weights] end
            local have = effective
            if type(have) ~= "number" then have = base end
            if type(have) ~= "number" then return lastPower[weights] end
            power = power + w * have
        end
    end
    local ctx = { weights = weights, class = class, mult = mult }
    for slot = 1, 18 do
        if slot ~= 4 then                               -- the shirt has no stats
            local link = GetInventoryItemLink("player", slot)
            if link then
                local worth = E.ItemWorth(link, slot, ctx, true)
                if worth then power = power + worth end
            end
        end
    end
    lastPower[weights] = power
    return power
end

-- Percent stronger with `item` in `slot` instead of what is there (and of what is in `also`: the off hand a
-- two-hander pushes out). nil while anything involved is not loaded.
function E.Gain(item, slot, ctx, also)
    local power = ctx.power
    if type(power) ~= "number" or power <= 0 then return nil end
    local new = E.ItemWorth(item, slot, ctx)
    local worn = WornWorth(slot, ctx)
    local other = 0
    if also then other = WornWorth(also, ctx) end
    if not (new and worn and other) then return nil end
    return E.PERCENT * (new - worn - other) / power
end

-------------------------------------------------------------------------------------------------------------------
-- Can the character use it?
-------------------------------------------------------------------------------------------------------------------
local function Red(c)
    if type(c) ~= "table" then return false end
    local r, g, b = c.r, c.g, c.b
    if Secret(r) or Secret(g) or Secret(b) then return false end
    if type(r) ~= "number" or type(g) ~= "number" or type(b) ~= "number" then return false end
    return r > 0.9 and g < 0.2 and b < 0.2
end

-- What the game's own tooltip says about an item: { red = a line is red (a requirement is not met),
-- unique = it is unique or unique-equipped }. Read from the bag slot when given (the real item), else from the
-- link. Nothing readable = neither (the item is then judged by the class rules alone).
local tips, tipsN = {}, 0
local NOTHING = { red = false, unique = false }
function E.Tip(link, bag, bagSlot)
    local TI = C_TooltipInfo
    if type(TI) ~= "table" or type(link) ~= "string" then return NOTHING end
    local now = type(GetTime) == "function" and GetTime() or 0
    local hit = tips[link]
    if hit and now - hit.at >= 0 and now - hit.at < TIP_KEEP then return hit end
    local data
    if bag and bagSlot and type(TI.GetBagItem) == "function" then
        local ok, d = pcall(TI.GetBagItem, bag, bagSlot)
        if ok and type(d) == "table" then data = d end
    end
    if not data and type(TI.GetHyperlink) == "function" then
        local ok, d = pcall(TI.GetHyperlink, link)
        if ok and type(d) == "table" then data = d end
    end
    if type(data) ~= "table" or type(data.lines) ~= "table" then return NOTHING end
    local tip = { red = false, unique = false, at = now }
    for i, line in ipairs(data.lines) do
        if type(line) == "table" then
            local text = line.leftText
            if Secret(text) or type(text) ~= "string" then text = nil end
            -- "Unique", "Unique-Equipped", "Unique-Equipped: Watcher's Ring (1)": one at most (never the name
            -- line). A counted form that allows more, "Unique (2)", may be worn twice and is not unique here.
            if text and i > 1 and ((type(ITEM_UNIQUE) == "string" and text:find(ITEM_UNIQUE, 1, true) == 1)
                or (type(ITEM_UNIQUE_EQUIPPABLE) == "string" and text:find(ITEM_UNIQUE_EQUIPPABLE, 1, true) == 1)) then
                local n = tonumber(text:match("%((%d+)%)%s*$"))
                if n == nil or n <= 1 then tip.unique = true end
            end
            -- red lines that say nothing about wearing it are passed over
            local harmless = text ~= nil and (text == ITEM_SCRAPABLE_NOT or text == CANNOT_UNEQUIP_COMBAT
                or text == ITEM_DISENCHANT_NOT_DISENCHANTABLE)
            if (Red(line.leftColor) and not harmless) or Red(line.rightColor) then tip.red = true end
        end
    end
    if tipsN >= CACHE_MAX then tips, tipsN = {}, 0 end
    if tips[link] == nil then tipsN = tipsN + 1 end
    tips[link] = tip
    return tip
end

-- true, or false and why, or nil while the game has not loaded the item. ctx = { class, level }.
-- The item's own level requirement is not judged here (AutoGear keeps "an upgrade once you reach its level").
function E.CanUse(id, link, ctx, bag, bagSlot)
    local _, _, _, equipLoc, _, classID, subclassID = ItemInstant(id)
    local _, _, _, _, minLevel = ItemInfo(link or id)
    if not (classID and minLevel) then return nil end
    local class = ctx.class
    if classID == WEAPON then
        if subclassID == FISHING_POLE then return false, "a fishing pole is not gear" end
        if subclassID ~= MISC_WEAPON then
            if not (WEAPONS[class] and WEAPONS[class][subclassID]) then return false, "your class cannot use that weapon type" end
            if class == "HUNTER" and subclassID == THROWN then return false, "a hunter needs a bow, gun or crossbow there" end
        end
    elseif classID == ARMOR then
        if equipLoc ~= "INVTYPE_CLOAK" and subclassID ~= 0 then
            if subclassID == SHIELD then
                if not SHIELD_USERS[class] then return false, "your class cannot use shields" end
            elseif RELIC_OWNER[subclassID] then
                if RELIC_OWNER[subclassID] ~= class then return false, "that relic is for another class" end
            elseif subclassID >= 1 and subclassID <= 4 then
                if subclassID > E.MaxArmor(class, ctx.level) then return false, "your class cannot wear that armor type (yet)" end
            else
                return false, "your class cannot use it"
            end
        end
    end
    -- the game's own word: a red tooltip line is a requirement that is not met (a weapon skill not trained, a
    -- class, race, profession or reputation the item asks for). A level that is still too low is red as well,
    -- and that case is AutoGear's.
    if minLevel <= (ctx.level or 0) and link then
        local tip = E.Tip(link, bag, bagSlot)
        if tip.red then return false, "the game shows it in red: you cannot use it right now" end
    end
    return true
end

-- Bows and crossbows shoot arrows, guns shoot bullets. Swapping one kind for the other leaves a character
-- unable to shoot until the other ammo sits in the ammo slot, so that swap is left to the player: true when
-- item `id` is such a swap against the ranged weapon that is worn while the ammo slot holds ammo of another kind
-- than the new weapon needs. Same kind, nothing worn that shoots, the right ammo already in the ammo slot, or no
-- ammo at all (the worn weapon cannot shoot either, e.g. a warrior's gun worn for its stats): false.
local AMMO_FOR = { [2] = 2, [18] = 2, [3] = 3 }           -- weapon type -> ammo type (2 arrows, 3 bullets)
function E.AmmoClash(id)
    local _, _, _, _, _, classID, sub = ItemInstant(id)
    local need = classID == WEAPON and AMMO_FOR[sub]
    if not need then return false end
    local worn = GetInventoryItemID("player", RANGED)
    if not worn then return false end
    local _, _, _, _, _, wornClass, wornSub = ItemInstant(worn)
    local have = wornClass == WEAPON and AMMO_FOR[wornSub]
    if not have or have == need then return false end
    if type(GetInventorySlotInfo) ~= "function" then return false end
    local ok, slot = pcall(GetInventorySlotInfo, "AmmoSlot")
    if not ok or Secret(slot) or type(slot) ~= "number" then return false end      -- a client without an ammo slot
    local ammo = GetInventoryItemID("player", slot)
    if not ammo or ammo == 0 then return false end
    local _, _, _, _, _, ammoClass, ammoSub = ItemInstant(ammo)
    if ammoClass == PROJECTILE and ammoSub == need then return false end
    return true
end

-- stale readings go: tooltips on a level-up or a newly trained skill (requirements met), stats on a level-up
local frame = CreateFrame("Frame")
for _, event in ipairs({ "PLAYER_LEVEL_UP", "SKILL_LINES_CHANGED" }) do
    pcall(frame.RegisterEvent, frame, event)
end
frame:SetScript("OnEvent", function(_, event)
    tips, tipsN = {}, 0
    if event == "PLAYER_LEVEL_UP" then statsOf, cachedN = {}, 0 end
end)

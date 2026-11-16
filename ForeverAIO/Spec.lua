-- Spec.lua: which spec's stat weights are used (ns.Spec).
-- "auto" (the default) = the talent tree with the most points; with no points spent, the usual levelling spec of
-- the class. /faio spec <name> picks one by hand for this character, /faio spec auto goes back.
local _, ns = ...
local Spec = {}
ns.Spec = Spec

-- Spec keys are Forever Leveling BiS's. Per class in talent-tab order: the tree with the most points wins.
-- A hunter's third tree reads as melee Survival (Forever's Survival fights in melee); "survival" is the ranged
-- variant and a druid's "bear" the tank variant of Feral: both can only be picked by hand.
local TREES = {
    WARRIOR = { "arms", "fury", "protection" },
    PALADIN = { "holy", "protection", "retribution" },
    HUNTER = { "beastmastery", "marksmanship", "survivalmelee" },
    ROGUE = { "assassination", "combat", "subtlety" },
    PRIEST = { "discipline", "holy", "shadow" },
    SHAMAN = { "elemental", "enhancement", "restoration" },
    MAGE = { "arcane", "fire", "frost" },
    WARLOCK = { "affliction", "demonology", "destruction" },
    DRUID = { "balance", "feral", "restoration" },
}
local EXTRA = { HUNTER = { "survival" }, DRUID = { "bear" } }
-- used while no talent point is spent
local LEVELING = {
    WARRIOR = "arms", PALADIN = "retribution", HUNTER = "beastmastery", ROGUE = "combat", PRIEST = "shadow",
    SHAMAN = "enhancement", MAGE = "frost", WARLOCK = "affliction", DRUID = "feral",
}
local LABEL = {
    beastmastery = "Beast Mastery", survival = "Survival (ranged)", survivalmelee = "Survival (melee)",
    feral = "Feral (cat)", bear = "Feral (bear)",
}
local CLASS_LABEL = {
    WARRIOR = "Warrior", PALADIN = "Paladin", HUNTER = "Hunter", ROGUE = "Rogue", PRIEST = "Priest",
    SHAMAN = "Shaman", MAGE = "Mage", WARLOCK = "Warlock", DRUID = "Druid",
}
Spec.TREES, Spec.LEVELING = TREES, LEVELING

local function Secret(v) return issecretvalue ~= nil and issecretvalue(v) end

function Spec.Class()
    local _, class = UnitClass("player")
    if Secret(class) or type(class) ~= "string" then return nil end
    return class
end

-- every spec key of a class: the three trees, then the hand-picked variants
function Spec.List(class)
    class = class or Spec.Class()
    local out = {}
    for _, key in ipairs(TREES[class] or {}) do out[#out + 1] = key end
    for _, key in ipairs(EXTRA[class] or {}) do out[#out + 1] = key end
    return out
end

function Spec.Valid(key, class)
    if type(key) ~= "string" then return false end
    for _, k in ipairs(Spec.List(class)) do
        if k == key then return true end
    end
    return false
end

-- "Arms Warrior", "Survival (melee) Hunter"
function Spec.Name(key, class)
    class = class or Spec.Class()
    if type(key) ~= "string" then return "?" end
    local label = LABEL[key] or (key:sub(1, 1):upper() .. key:sub(2))
    return label .. " " .. (CLASS_LABEL[class or ""] or "")
end

-- Points spent per talent tree { n1, n2, n3 }, or nil when the game does not say.
-- Forever keeps talents in the trait system: one tree whose three groups are the talent tabs.
local function PointsFromTraits()
    if not (C_ClassTalents and C_ClassTalents.GetActiveConfigID and C_Traits and C_Traits.GetConfigInfo
        and C_Traits.GetGroupDisplayInfoByTreeID and C_Traits.GetGroupCurrencyInfo) then return nil end
    local configID = C_ClassTalents.GetActiveConfigID()
    if Secret(configID) or not configID then return nil end
    local config = C_Traits.GetConfigInfo(configID)
    local treeID = type(config) == "table" and type(config.treeIDs) == "table" and config.treeIDs[1]
    if not treeID then return nil end
    local groups = C_Traits.GetGroupDisplayInfoByTreeID(treeID)
    if type(groups) ~= "table" or #groups == 0 then return nil end
    local ids, index, points = {}, {}, {}
    for i, group in ipairs(groups) do
        if type(group) ~= "table" or group.groupID == nil then return nil end
        ids[i], index[group.groupID], points[i] = group.groupID, i, 0
    end
    local spent = C_Traits.GetGroupCurrencyInfo(configID, ids)
    if type(spent) ~= "table" then return nil end
    for _, info in ipairs(spent) do
        local i = type(info) == "table" and index[info.traitNodeGroupID]
        local currency = i and type(info.currencyInfos) == "table" and info.currencyInfos[1]
        local n = type(currency) == "table" and currency.spent
        if i and type(n) == "number" and not Secret(n) then points[i] = n end
    end
    return points
end

-- the older talent-tab call, for a client that has it
local function PointsFromTabs()
    if type(GetTalentTabInfo) ~= "function" then return nil end
    local points = {}
    for tab = 1, 3 do
        local a, _, c, _, e = GetTalentTabInfo(tab)
        if a == nil then return nil end
        local n = (type(c) == "number" and not Secret(c) and c) or (type(e) == "number" and not Secret(e) and e) or 0
        points[tab] = n
    end
    return points
end

-- A reading is kept for a few seconds only (and dropped on every talent event): one taken while the game was
-- still loading talents must not stick.
local KEEP = 10
local cached, cachedAt
function Spec.Points()
    local now = type(GetTime) == "function" and GetTime() or 0
    if cached and cachedAt and now - cachedAt >= 0 and now - cachedAt < KEEP then return cached end
    local ok, points = pcall(PointsFromTraits)
    if not ok or type(points) ~= "table" then
        ok, points = pcall(PointsFromTabs)
        if not ok or type(points) ~= "table" then points = nil end
    end
    cached, cachedAt = points, now
    return points
end
function Spec.Invalidate() cached, cachedAt = nil, nil end

-- Right after a loading screen the game can be late with the talents. For a character old enough to have any
-- (level 10), unreadable talents count as "still loading" for a short while: true = better wait than score
-- with the levelling spec. After that while the levelling spec is used.
local PENDING = 15
local enteredAt
function Spec.Pending()
    if Spec.Points() then return false end
    local level = type(UnitLevel) == "function" and UnitLevel("player") or nil
    if Secret(level) or type(level) ~= "number" or level < 10 then return false end
    local now = type(GetTime) == "function" and GetTime() or 0
    return enteredAt ~= nil and now - enteredAt >= 0 and now - enteredAt < PENDING
end

-- The spec "auto" picks: its key, and true when talent points decided it.
function Spec.Auto(class)
    class = class or Spec.Class()
    local trees = TREES[class or ""]
    if not trees then return nil, false end
    local points = Spec.Points()
    local best, most = nil, 0
    for i = 1, 3 do
        local n = points and points[i] or 0
        if type(n) == "number" and n > most and trees[i] then best, most = trees[i], n end
    end
    if best then return best, true end
    return LEVELING[class], false
end

local function Picks()
    local d = ns.DB()
    if type(d.spec) ~= "table" then d.spec = {} end
    return d.spec
end

-- The spec in use: its key, and true when it was picked by hand.
function Spec.Key()
    local class = Spec.Class()
    if not class then return nil, false end
    local picked = Picks()[ns.Who()]
    if picked and Spec.Valid(picked, class) then return picked, true end
    return (Spec.Auto(class)), false
end

-- "auto" or a spec key of this class; false when the key is unknown
function Spec.Set(key)
    key = tostring(key or ""):lower()
    local picks, who = Picks(), ns.Who()
    if key == "auto" or key == "" then
        picks[who] = nil
    elseif Spec.Valid(key) then
        picks[who] = key
    else
        return false
    end
    if Spec.OnChanged then pcall(Spec.OnChanged) end
    return true
end

function Spec.Status()
    local key, byHand = Spec.Key()
    if not key then return "stat weights: your class is not readable yet" end
    return "stat weights: " .. Spec.Name(key) .. (byHand and " (picked by you)" or " (auto)")
end
ns.status[#ns.status + 1] = Spec.Status

ns.commands.spec = function(rest)
    local arg = tostring(rest or ""):lower():match("^%s*(%S*)")
    if arg ~= "" then
        if not Spec.Set(arg) then
            ns.Print("unknown spec \"" .. arg .. "\". Use: auto, " .. table.concat(Spec.List(), ", "))
            return
        end
    end
    ns.Print(Spec.Status() .. ". /faio spec auto | " .. table.concat(Spec.List(), " | "))
end

-- talents changed: read them again on the next look
local frame = CreateFrame("Frame")
for _, event in ipairs({ "TRAIT_CONFIG_UPDATED", "TRAIT_CONFIG_LIST_UPDATED", "PLAYER_TALENT_UPDATE",
    "CHARACTER_POINTS_CHANGED", "PLAYER_ENTERING_WORLD", "PLAYER_LEVEL_UP" }) do
    pcall(frame.RegisterEvent, frame, event)       -- an event this client does not know must not stop the rest
end
frame:SetScript("OnEvent", function(_, event)
    Spec.Invalidate()
    if event == "PLAYER_ENTERING_WORLD" then enteredAt = type(GetTime) == "function" and GetTime() or nil end
end)

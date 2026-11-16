-- AutoGear.lua: auto-equip, bag upgrades and the quest reward picker (ns.AutoGear).
-------------------------------------------------------------------------------------------------------------------
-- Puts on bag items that are an upgrade by the built-in stat weights (Score.lua: Forever Leveling BiS's numbers
-- for your class, spec and level), and takes the quest reward they rate highest.
-- Switches: ForeverAIODB.autoEquip / autoReward (/faio equip on|off|reset, /faio reward on|select|off).
-- Unset = ON, for every character. Rules:
--   * never in combat, dead, casting or with an item on the cursor; one item at a time; two tries, then it is left
--   * gear the player changes by hand is respected: the item they took off, and the bag items they passed over
--     for that slot, are remembered per character (new loot is a new decision); trinkets only fill an empty slot
--   * unbound bind-on-equip gear is bound without asking only up to green; "still tradeable/refundable" never
--   * only what the character can use: class rules plus the game's own red tooltip text (Score.lua)
--   * quest rewards: only when two or more choices are still waiting on the player (other addons' turn-ins go
--     first; Shift held = hands off). Best upgrade wins; if none of the choices is an upgrade and all of them
--     are gear, the one that sells for the most; anything else is left to the player.
--   * bags: an empty bag slot, else the smallest worn plain bag, gets the biggest plain bag in the bags when it
--     is bigger; a new bag that sits inside the bag it replaces is first moved to another bag. Quivers, ammo,
--     soul and profession bags are left alone, worn or carried.
--   * every decision goes to ForeverAIODB.gearLog (last 80), which is how it is checked after a play session
--   * WoWUI Tweaks has an older copy of this. Where that copy is switched on, this one stands back.
-------------------------------------------------------------------------------------------------------------------
local _, ns = ...
do
    local AG = { version = 2 }
    ns.AutoGear = AG
    local TAG = ns.TAG
    local MAIN, OFF, RANGED = 16, 17, 18
    local WEAPON_CLASS, POLE_SUBCLASS = 2, 20
    local BIND_ON_EQUIP = 2
    local BOE_MAX_QUALITY = 2           -- unbound bind-on-equip gear is bound without asking up to green
    local MAX_TRIES = 2
    local BIND_WINDOW = 0.3             -- a bind question this soon after our own equip call is ours
    local LOG_MAX = 80
    local PASS_MAX = 60                 -- items remembered in gearPass (why each was left in the bags)
    local TWIN = { [11] = 12, [12] = 11, [13] = 14, [14] = 13, [16] = 17, [17] = 16 }
    local SETTLE = 2                    -- seconds an equip gets before it counts as not done
    local REWARD_WAIT, REWARD_TRIES = 0.4, 6
    local NO_ENGINE = "the scoring part of Forever AIO did not load"
    local NOT_LOADED = "the game has not loaded it yet"

    local pending                       -- the equip in flight: { id, link, slot, gain, spec, quality }
    local oursUntil = 0                 -- equipment changes before this time are ours, not the player's
    local queued, polls = false, 0
    local tries, hinted = {}, {}        -- per item link, this session
    local worn = {}                     -- slot -> itemID, to tell what the player took off
    local judged                        -- the reward verdict for the turn-in window that is open (for the log)
    local questToken = 0                -- one reward decision per QUEST_COMPLETE
    local takenQuest, takenAt           -- the last reward anybody took (us, another addon, the player): which quest, when
    local blind = 0                     -- looks in a row that could not judge (stats, level or talents unreadable)
    local displaced = {}                -- "spec:item:slot" we swapped out ourselves this session: never swapped back
    local ready = false                 -- true once the worn gear has been read at login
    local levelHint = 0
    local greeted, complained = false, false
    local moved = {}                    -- per bag link, this session: moves out of the bag it replaces
    local swappedOut = {}               -- bag itemIDs we took off this session: never put back on by us
    local waiting = false               -- a bag item was not loaded at the last look: look again when item data arrives

    local function DB() return ns.DB() end
    local function Who() return (UnitName("player") or "?") .. "-" .. (GetRealmName() or "?") end
    local function Say(text) print(TAG .. text) end
    local function Pct(gain) return string.format("%.1f%%", gain) end
    local function ItemInfo(item) return (C_Item and C_Item.GetItemInfo or GetItemInfo)(item) end
    local function ItemInstant(item) return (C_Item and C_Item.GetItemInfoInstant or GetItemInfoInstant)(item) end

    local function Secret(v) return issecretvalue ~= nil and issecretvalue(v) end

    local function Log(entry)
        local d = DB()
        if type(d.gearLog) ~= "table" then d.gearLog = {} end
        entry.t, entry.who = date("%m-%d %H:%M:%S"), Who()
        local log = d.gearLog
        log[#log + 1] = entry
        while #log > LOG_MAX do table.remove(log, 1) end
    end

    local function Safe(fn, ...)
        local ok, err = pcall(fn, ...)
        if not ok and not complained then
            complained = true
            Say("auto gear hit an error and skipped a step: " .. tostring(err))
            pcall(Log, { k = "error", why = tostring(err) })
        end
        return ok
    end

    -- nil = default: on. Both parts work for every character until they are switched off.
    local function Setting(key)
        local d = DB()
        if d[key] ~= nil then return d[key] end
        return true
    end
    -- WoWUI Tweaks carries the older copy of this feature. Where that one is switched on, this one stands back,
    -- so the two never work on the same bags or the same quest window.
    local function Elder()
        local other = _G.WoWUI_AutoGear
        if type(other) == "table" and other ~= AG then return other end
        return nil
    end
    function AG.EquipYields()
        local other = Elder()
        if not (other and type(other.EquipOn) == "function") then return false end
        local ok, on = pcall(other.EquipOn)
        return ok and on == true
    end
    function AG.RewardYields()
        local other = Elder()
        if not (other and type(other.RewardMode) == "function") then return false end
        local ok, mode = pcall(other.RewardMode)
        return ok and mode ~= nil
    end
    function AG.EquipOn() return Setting("autoEquip") == true and not AG.EquipYields() end
    function AG.RewardMode()
        if AG.RewardYields() then return nil end
        local m = Setting("autoReward")
        if m == true then return "complete" elseif m == "select" then return "select" end
    end

    local function Skips(create)
        local d, who = DB(), Who()
        if type(d.gearSkip) ~= "table" then
            if not create then return nil end
            d.gearSkip = {}
        end
        if create and type(d.gearSkip[who]) ~= "table" then d.gearSkip[who] = {} end
        local mine = d.gearSkip[who]
        return type(mine) == "table" and mine or nil
    end

    function AG.Snapshot()
        for slot = 1, 18 do worn[slot] = GetInventoryItemID("player", slot) end
    end

    -- the spec key gear is scored by right now (Spec.lua: talents, the levelling spec, or the player's own pick)
    function AG.Key()
        local Spec = ns.Spec
        if not (Spec and Spec.Key) then return nil end
        local ok, key = pcall(Spec.Key)
        return ok and type(key) == "string" and key or nil
    end

    -- Everything a score needs, or nil and the reason (a part missing, or stats hidden by the game right now).
    function AG.Context()
        local E, Spec = ns.Score, ns.Spec
        if not (E and Spec and E.Gain and E.Power and E.Weights and E.SlotsFor and E.IsTwoHand and E.CanUse and Spec.Key) then
            return nil, NO_ENGINE
        end
        local class = select(2, UnitClass("player"))
        if Secret(class) or type(class) ~= "string" then return nil, "the game is hiding your class right now" end
        local level = UnitLevel("player")
        if Secret(level) or type(level) ~= "number" then level = 0 end
        level = math.max(level, levelHint)
        if level < 1 then return nil, "the game is hiding your level right now" end
        local key, byHand = Spec.Key()
        if not byHand and Spec.Pending and Spec.Pending() then return nil, "your talents are still loading" end
        local main = GetInventoryItemID("player", MAIN)
        local setup = key and E.Setup and E.Setup(class, key, main) or nil
        local weights = key and E.Weights(class, key, level, setup)
        if not weights then return nil, "no stat weights for this class" end
        local mult = E.RaceMult and E.RaceMult() or nil
        local power = E.Power(weights, class, mult)
        if Secret(power) or type(power) ~= "number" or power <= 0 then return nil, "the game is hiding your stats right now" end
        local classID, subclassID
        if main then local _; _, _, _, _, _, classID, subclassID = ItemInstant(main) end
        local dual = false
        if type(CanDualWield) == "function" then dual = CanDualWield() and true or false
        elseif type(IsPlayerSpell) == "function" then dual = IsPlayerSpell(674) and true or false end
        return {
            E = E, weights = weights, power = power, min = E.MIN_GAIN or 0.5, mult = mult, setup = setup,
            key = key, spec = Spec.Name and Spec.Name(key, class) or tostring(key), level = level,
            twoHand = main ~= nil and E.IsTwoHand(main) == true,
            pole = classID == WEAPON_CLASS and subclassID == POLE_SUBCLASS, dual = dual,
            class = class,
        }
    end

    -- a free slot in the backpack or a plain bag (quivers, soul and profession bags take only their own items)
    local function HasFreeBagSlot()
        local family = C_Container.GetContainerNumFreeSlots
        for bag = 0, NUM_BAG_SLOTS or 4 do
            local normal = true
            if family then
                local ok, _, kind = pcall(family, bag)
                normal = ok and (kind == nil or kind == 0)
            end
            if normal then
                for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
                    if not C_Container.GetContainerItemInfo(bag, slot) then return true end
                end
            end
        end
        return false
    end

    local function SlotOpen(slot, equipLoc, ctx, id)
        if ctx.pole and (slot == MAIN or slot == OFF) then return false, "you are holding a fishing pole" end   -- leave the hands alone
        if displaced[ctx.spec .. ":" .. id .. ":" .. slot] then return false, "it was just swapped out for something better" end   -- no ping-pong
        if slot == OFF then
            if ctx.twoHand then return false, "your two-hander leaves no room for it" end
            if (equipLoc == "INVTYPE_WEAPON" or equipLoc == "INVTYPE_WEAPONOFFHAND") and not ctx.dual then
                return false, "your class cannot dual wield"
            end
        end
        return true
    end

    -- slot, gain% for one item against what is worn. Third value true = an upgrade the character is still too low for.
    -- No upgrade: nil, the best gain seen (or nil), nil, why, and the slot that gain was for.
    -- bag, bagSlot = where the item sits, when it is in the bags (its real tooltip is read for "can I use it").
    function AG.Score(id, link, ctx, bag, bagSlot)
        local E = ctx.E
        local slots = E.SlotsFor(id)
        if not slots then return nil, nil, nil, "not something you wear" end
        local _, _, _, equipLoc = ItemInstant(id)
        local _, _, _, _, minLevel = ItemInfo(link or id)
        if minLevel == nil then return nil, nil, nil, NOT_LOADED end
        local can, cannot = E.CanUse(id, link, ctx, bag, bagSlot)
        if can == nil then return nil, nil, nil, NOT_LOADED end
        if not can then return nil, nil, nil, cannot or "your class cannot use it" end
        local twoHand = E.IsTwoHand(id)
        -- a unique item that is already on cannot go on a second time
        local unique = false
        if link and E.Tip and TWIN[slots[1]] then
            local okTip, tip = pcall(E.Tip, link, bag, bagSlot)
            unique = okTip and type(tip) == "table" and tip.unique == true
        end
        local best, gain, seen, seenSlot, shut
        for i = 1, #slots do
            local slot = slots[i]
            local open, why = SlotOpen(slot, equipLoc, ctx, id)
            if open and unique and TWIN[slot] and GetInventoryItemID("player", TWIN[slot]) == id then
                open, why = false, "you already wear one and it is unique"
            end
            -- a bow for a gun (or the reverse) cannot shoot until the other ammo is in the ammo slot
            if open and slot == RANGED and E.AmmoClash and E.AmmoClash(id) then
                open, why = false, "it shoots the other kind of ammo: put it on yourself once that ammo is in your ammo slot"
            end
            -- a two-hander from the bags pushes the off hand into the bags: without room the game refuses
            if open and bag and twoHand and slot == MAIN and GetInventoryItemID("player", OFF) and not HasFreeBagSlot() then
                open, why = false, "your bags are full: the off hand needs a free slot first"
            end
            if not open then
                shut = shut or why
            else
                local g = E.Gain(link or id, slot, ctx, twoHand and slot == MAIN and OFF or nil)
                if g then
                    if seen == nil or g > seen then seen, seenSlot = g, slot end
                    -- anything of use beats an empty slot; what is worn is only replaced for the minimum gain
                    local enough = g >= ctx.min or (g > 0 and GetInventoryItemID("player", slot) == nil)
                    if enough and (gain == nil or g > gain) then best, gain = slot, g end
                end
            end
        end
        if not best then
            if seen == nil then return nil, nil, nil, shut or NOT_LOADED end
            local why = seen > 0 and "too small a gain to swap for" or seen < 0 and "worse than what you wear"
                or shut or "no better than what is on (or none of its stats count for your spec)"
            return nil, seen, nil, why, seenSlot
        end
        return best, gain, minLevel > ctx.level
    end

    -- One bag item: slot and gain when it should go on now. Otherwise nil, the gain if one was worked out,
    -- why not, and the slot that gain was for.
    function AG.Verdict(info, ctx, skip, bag, bagSlot)
        local id, link = info.itemID, info.hyperlink
        if info.isLocked then return nil end
        if hinted[link] then return nil, nil, "left for you to put on (it binds to you, or it is a trinket)" end
        if (tries[link] or 0) >= MAX_TRIES then return nil, nil, "the game would not equip it" end
        if skip and skip[id] then return nil, nil, "you took it off or chose another (/faio equip reset forgets that)" end
        local slot, gain, tooLow, why, at = AG.Score(id, link, ctx, bag, bagSlot)
        if slot and tooLow then return nil, gain, "an upgrade once you reach its level", slot end
        if slot then return slot, gain end
        return nil, gain, why, at
    end

    -- Why a piece of gear was left in the bags: one line per item, saved for a later look (ForeverAIODB.gearPass).
    local function Pass(id, why, slot, gain)
        local d = DB()
        if type(d.gearPass) ~= "table" then d.gearPass = {} end
        local t = d.gearPass
        if t[id] == nil then
            local n = 0
            for _ in pairs(t) do n = n + 1 end
            if n >= PASS_MAX then t = {}; d.gearPass = t end
        end
        local detail = gain and string.format(" (%+.1f%%%s)", gain, slot and (", slot " .. slot) or "") or ""
        t[id] = date("%m-%d %H:%M ") .. why .. detail
    end

    -- The game's "this will bind the item" windows.
    local BIND_POPUPS = { "EQUIP_BIND", "AUTOEQUIP_BIND", "EQUIP_BIND_TRADEABLE", "EQUIP_BIND_REFUNDABLE" }
    local PLAIN_POPUP = { EQUIP_BIND = true, AUTOEQUIP_BIND = true }
    local function BindPopup()                         -- the one on screen, if any: its kind and its frame
        if type(StaticPopup_FindVisible) == "function" then
            for _, which in ipairs(BIND_POPUPS) do
                local ok, dialog = pcall(StaticPopup_FindVisible, which)
                if ok and dialog then return which, dialog end
            end
        end
        for i = 1, 4 do
            local d = _G["StaticPopup" .. i]
            if type(d) == "table" and d.IsShown and d:IsShown() then
                for _, which in ipairs(BIND_POPUPS) do if d.which == which then return which, d end end
            end
        end
    end
    local function PressOkay(dialog)                   -- the window's own Okay button: what the player's click does
        local b = dialog and (dialog.button1 or (type(dialog.GetButton1) == "function" and dialog:GetButton1()))
        if type(b) == "table" and type(b.Click) == "function" then b:Click(); return true end
    end
    local function DropBind(p)                         -- answer no and put the window away
        if CancelPendingEquip and p.bindArg ~= nil then pcall(CancelPendingEquip, p.bindArg) end
        if StaticPopup_Hide then for _, which in ipairs(BIND_POPUPS) do pcall(StaticPopup_Hide, which) end end
    end
    local function BindNote(p)                         -- what the bind question looked like, for the log
        if not (p.answered or p.bindWhich) then return nil end
        return tostring(p.bindEvent) .. "/" .. tostring(p.bindArg) .. "/" .. tostring(p.bindWhich) .. "/" .. tostring(p.bindHow)
    end

    local function Casting()
        local ok, busy = pcall(function() return UnitCastingInfo("player") ~= nil or UnitChannelInfo("player") ~= nil end)
        return ok and busy
    end

    function AG.Queue(delay)
        if queued then return end
        queued = true
        C_Timer.After(delay or 0.5, function() queued = false; Safe(AG.Scan) end)
    end

    -- Our own pick-up must never stay on the mouse. Only the bag copy we lifted, or the piece it pushed out,
    -- is put back: anything else on the mouse is the player's.
    local function Uncursor(p)
        if not (p.cursor and CursorHasItem and CursorHasItem() and ClearCursor) then return end
        if GetCursorInfo then
            local kind, cid = GetCursorInfo()
            if kind ~= "item" or (cid ~= p.id and cid ~= p.before) then return end
        end
        ClearCursor()
    end

    -- A finished (or given-up) equip: say what happened, then look for the next one.
    function AG.Settle(p, why)
        if pending ~= p then return end
        pending, oursUntil = nil, GetTime() + 1
        AG.Snapshot()
        Uncursor(p)
        if p.cursor then C_Timer.After(0.3, function() Safe(Uncursor, p) end) end     -- the swapped-out piece can land late
        if GetInventoryItemID("player", p.slot) == p.id and (not p.twin or GetInventoryItemID("player", p.twin) == p.id) then
            tries[p.link] = nil
            local passes = DB().gearPass
            if type(passes) == "table" then passes[p.id] = nil end
            if p.before and p.before ~= p.id then displaced[p.spec .. ":" .. p.before .. ":" .. p.slot] = true end
            if p.bag then
                moved[p.link] = nil
                if p.before then swappedOut[p.before] = true end
                Say((p.before and ("swapped in " .. p.link .. " (" .. tostring(p.from) .. " -> " .. tostring(p.size) .. " slots)")
                    or ("put " .. p.link .. " in an empty bag slot" .. ((p.size or 0) > 0 and (" (+" .. p.size .. " slots)") or ""))))
                Log({ k = "bag", id = p.id, slot = p.slot, size = p.size, bind = BindNote(p) })
            else
                Say("equipped " .. p.link .. " (+" .. Pct(p.gain) .. " for " .. p.spec .. ")")
                Log({ k = "equip", id = p.id, slot = p.slot, gain = p.gain, bind = BindNote(p) })
            end
        else
            if not why and p.answered then                -- our bind question went unanswered: put it away, ask once
                DropBind(p)
                why, hinted[p.link] = "the game wants your own click to bind it", true
            end
            if why then tries[p.link] = MAX_TRIES end
            if (tries[p.link] or 0) >= MAX_TRIES then
                local note = DB().gearDebug == true and BindNote(p)
                Say("left " .. p.link .. " in your bags" .. (p.bag and "" or (" (+" .. Pct(p.gain) .. ")")) .. ": " .. (why or "the game would not equip it") .. "."
                    .. (note and (" [" .. note .. "]") or ""))
            end
            Log({ k = "fail", id = p.id, slot = p.slot, gain = p.gain, why = why or "not equipped", bind = BindNote(p) })
        end
        AG.Queue(0.6)
    end

    function AG.Equip(info, slot, gain, ctx, bag, bagSlot)
        local link, id = info.hyperlink, info.itemID
        local _, _, quality, _, _, _, _, _, _, _, _, _, _, bindType = ItemInfo(link)
        quality = info.quality or quality or 0
        if info.isBound == false and bindType == BIND_ON_EQUIP and quality > BOE_MAX_QUALITY then
            hinted[link] = true
            Say(link .. " is a +" .. Pct(gain) .. " upgrade but binds to you when equipped: put it on yourself if you want it.")
            Log({ k = "hint", id = id, slot = slot, gain = gain, why = "bind on equip" })
            return AG.Queue(0.3)
        end
        local before = GetInventoryItemID("player", slot)
        if (slot == 13 or slot == 14) and before then      -- a worn trinket's use/proc effect is invisible to stat weights
            hinted[link] = true
            Say(link .. " rates +" .. Pct(gain) .. " on stats, but trinket effects are not in the weights: swap it yourself if you want it.")
            Log({ k = "hint", id = id, slot = slot, gain = gain, why = "trinket" })
            return AG.Queue(0.3)
        end
        -- A second copy of a ring, trinket or one-hand weapon that is already on: asked for by name the game may move the worn one
        -- instead, so it is handed this exact bag item.
        local twin = TWIN[slot] and GetInventoryItemID("player", TWIN[slot]) == id and TWIN[slot] or nil
        local byHand = twin and bag and bagSlot and C_Container.PickupContainerItem and EquipCursorItem and ClearCursor and CursorHasItem
        if twin and not byHand then
            hinted[link] = true
            Say("a second " .. link .. " would be +" .. Pct(gain) .. ": put it on yourself, the game does not let me pick that copy.")
            Log({ k = "hint", id = id, slot = slot, gain = gain, why = "second copy" })
            return AG.Queue(0.3)
        end
        tries[link] = (tries[link] or 0) + 1
        local p = { id = id, link = link, slot = slot, gain = gain, spec = ctx.spec, quality = quality, before = before, at = GetTime(),
            twin = twin, cursor = byHand and true or nil }
        pending, oursUntil = p, GetTime() + SETTLE + 1
        C_Timer.After(SETTLE, function() Safe(AG.Settle, p) end)      -- first, so a failing call cannot leave it pending
        C_Timer.After(BIND_WINDOW, function() Safe(function()         -- a bind question that came without an event we know
            if pending == p and not p.answered and BindPopup() then p.answered = true; AG.AnswerBind(p) end
        end) end)
        if byHand then
            ClearCursor()
            C_Container.PickupContainerItem(bag, bagSlot)
            if CursorHasItem() then EquipCursorItem(slot) end
            if CursorHasItem() and not BindPopup() then ClearCursor() end      -- refused: straight back where it was
            return
        end
        local equip = C_Item and C_Item.EquipItemByName or EquipItemByName
        equip(link, slot)
    end

    -- Bags: the bag's size is only in its tooltip ("14 Slot Bag"); without one, any plain bag beats an empty slot.
    local BAG_CLASS = 1
    local function BagSize(bag, slot)
        local tt = C_TooltipInfo and C_TooltipInfo.GetBagItem
        if not tt then return 0 end
        local ok, data = pcall(tt, bag, slot)
        if not ok or type(data) ~= "table" or type(data.lines) ~= "table" then return 0 end
        for _, line in ipairs(data.lines) do
            local t = type(line) == "table" and line.leftText
            if type(t) == "string" and not Secret(t) then
                local n = t:match("(%d+) Slot")
                if n then return tonumber(n) or 0 end
            end
        end
        return 0
    end
    local function PlainBag(id)
        local _, _, _, _, _, classID, subID = ItemInstant(id)
        return classID == BAG_CLASS and subID == 0
    end
    -- The bag slot to fill: an empty one first, else the smallest worn plain bag. size -1 = empty.
    local function BagTarget()
        local toInv = C_Container.ContainerIDToInventoryID
        if not toInv then return nil end
        local t
        for i = 1, NUM_BAG_SLOTS or 4 do
            local ok, inv = pcall(toInv, i)
            if ok and type(inv) == "number" then
                local id = GetInventoryItemID("player", inv)
                if not id then return { i = i, inv = inv, size = -1 } end
                local size = PlainBag(id) and C_Container.GetContainerNumSlots(i)
                if type(size) == "number" and size > 0 and (not t or size < t.size) then      -- unknown size: never swapped
                    t = { i = i, inv = inv, size = size, id = id }
                end
            end
        end
        return t
    end
    local function NormalBag(bag)                       -- quiver, soul and profession bags take only their own items
        local f = C_Container.GetContainerNumFreeSlots
        if not f then return true end
        local ok, _, family = pcall(f, bag)
        return ok and (family == nil or family == 0)
    end
    local function FreeSlotOutside(skipBag)
        for bag = 0, NUM_BAG_SLOTS or 4 do
            if bag ~= skipBag and NormalBag(bag) then
                for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
                    if not C_Container.GetContainerItemInfo(bag, slot) then return bag, slot end
                end
            end
        end
    end
    function AG.FillBag()
        local target = BagTarget()
        if not target or not (C_Container.PickupContainerItem and PutItemInBag and ClearCursor and CursorHasItem) then return false end
        local inv = target.inv
        local best, bBag, bSlot, bSize
        for bag = 0, NUM_BAG_SLOTS or 4 do
            for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
                local info = C_Container.GetContainerItemInfo(bag, slot)
                local link = info and info.hyperlink
                if link and info.itemID and not info.isLocked and (tries[link] or 0) < MAX_TRIES and not hinted[link]
                    and not swappedOut[info.itemID] then
                    if PlainBag(info.itemID) then
                        local size = BagSize(bag, slot)
                        if size > target.size and (target.size < 0 or size > 0) and (not best or size > bSize) then
                            best, bBag, bSlot, bSize = info, bag, slot, size
                        end
                    end
                end
            end
        end
        if not best then return false end
        local link, id = best.hyperlink, best.itemID
        local _, _, quality, _, _, _, _, _, _, _, _, _, _, bindType = ItemInfo(link)
        quality = best.quality or quality or 0
        if best.isBound == false and bindType == BIND_ON_EQUIP and quality > BOE_MAX_QUALITY then
            hinted[link] = true
            Say(link .. " would fill an empty bag slot but binds to you: put it on yourself if you want it.")
            Log({ k = "hint", id = id, slot = inv, why = "bag binds on equip" })
            return false
        end
        if bBag == target.i then                       -- it sits inside the bag it replaces: move it out first
            local toBag, toSlot = FreeSlotOutside(target.i)
            moved[link] = (moved[link] or 0) + 1
            if not toBag or moved[link] > MAX_TRIES then
                hinted[link] = true
                Say(link .. " is bigger than a bag you wear but sits inside it and there is no room elsewhere: swap it yourself.")
                Log({ k = "hint", id = id, slot = inv, why = "bag inside the bag it replaces" })
                return false
            end
            ClearCursor()
            C_Container.PickupContainerItem(bBag, bSlot)
            if CursorHasItem() then C_Container.PickupContainerItem(toBag, toSlot) end
            if CursorHasItem() then ClearCursor() end
            AG.Queue(0.6)
            return true
        end
        tries[link] = (tries[link] or 0) + 1
        local p = { id = id, link = link, slot = inv, gain = 0, spec = "bag", quality = quality, at = GetTime(), cursor = true,
            bag = true, size = bSize, before = target.id, from = target.size }
        pending, oursUntil = p, GetTime() + SETTLE + 1
        C_Timer.After(SETTLE, function() Safe(AG.Settle, p) end)
        C_Timer.After(BIND_WINDOW, function() Safe(function()
            if pending == p and not p.answered and BindPopup() then p.answered = true; AG.AnswerBind(p) end
        end) end)
        ClearCursor()
        C_Container.PickupContainerItem(bBag, bSlot)
        if CursorHasItem() then PutItemInBag(inv) end
        if not target.id and CursorHasItem() and not BindPopup() then ClearCursor() end      -- refused: straight back
        return true                                    -- a swap: Settle's Uncursor tidies the mouse afterwards
    end

    function AG.Scan()
        if not AG.EquipOn() or pending then return end
        if InCombatLockdown() or UnitIsDeadOrGhost("player") then return end      -- an event wakes us afterwards
        if (CursorHasItem and CursorHasItem()) or Casting() or BindPopup() then     -- look again shortly, a few times
            polls = polls + 1
            if polls <= 5 then AG.Queue(2) end
            return
        end
        polls = 0
        if AG.FillBag() then return end                -- Settle queues the next look
        local ctx = AG.Context()
        if not ctx then                                -- stats, level or talents not readable yet: a few more looks
            blind = blind + 1
            if blind <= 5 then AG.Queue(3) end
            return
        end
        blind = 0
        local skip = Skips()
        local bInfo, bSlot, bGain, bBag, bBagSlot
        waiting = false
        for bag = 0, NUM_BAG_SLOTS or 4 do
            for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
                local info = C_Container.GetContainerItemInfo(bag, slot)
                local id, link = info and info.itemID, info and info.hyperlink
                if id and link and ctx.E.SlotsFor(id) then
                    local inv, gain, why, at = AG.Verdict(info, ctx, skip, bag, slot)
                    if inv then
                        if bGain == nil or gain > bGain then bInfo, bSlot, bGain, bBag, bBagSlot = info, inv, gain, bag, slot end
                    elseif why then
                        if why == NOT_LOADED then waiting = true end
                        Pass(id, why, at, gain)
                    end
                end
            end
        end
        if bInfo then AG.Equip(bInfo, bSlot, bGain, ctx, bBag, bBagSlot) end
    end

    -- The player (or another addon, such as Naowh's fishing swap) changed a slot by hand: remember what came
    -- off so it is not put straight back, and forget any grudge against what went on.
    function AG.OnEquipmentChanged(slot)
        if type(slot) ~= "number" or slot < 1 or slot > 18 then return end
        local before, now = worn[slot], GetInventoryItemID("player", slot)
        worn[slot] = now
        if pending and slot == pending.slot and now == pending.id then return AG.Settle(pending) end
        if not ready or pending or GetTime() < oursUntil or before == now then return end
        displaced = {}
        local skips = Skips(true)
        if before then skips[before] = true end
        if not now then return end
        skips[now] = nil
        -- they chose this over what else in the bags fits the slot right now: those stay put as well
        local Items = ns.Score
        local level = UnitLevel("player")
        if not (Items and Items.SlotsFor) or Secret(level) or type(level) ~= "number" then return end
        level = math.max(level, levelHint)
        for bag = 0, NUM_BAG_SLOTS or 4 do
            for s = 1, C_Container.GetContainerNumSlots(bag) or 0 do
                local info = C_Container.GetContainerItemInfo(bag, s)
                local id = info and info.itemID
                local slots = id and id ~= now and Items.SlotsFor(id)
                if slots then
                    local fits = false
                    for i = 1, #slots do if slots[i] == slot then fits = true end end
                    local _, _, _, _, minLevel = ItemInfo(info.hyperlink or id)
                    if fits and minLevel and minLevel <= level then skips[id] = true end
                end
            end
        end
    end

    -- The game asks before binding an item ("Equipping this item will bind it to you"). The question is ours to
    -- answer only for an equip we started: it names our slot, or it arrives right behind our own equip call
    -- (this client does not always report the inventory slot with it).
    function AG.OnBindConfirm(event, arg)
        local p = pending
        if not p or p.answered then return end
        local mine = GetTime() - p.at <= BIND_WINDOW
        if not mine then
            local ok, same = pcall(function() return arg == p.slot end)
            mine = ok and same
        end
        if not mine then return end                    -- a dialog for something the player is equipping is theirs
        p.answered, p.bindEvent, p.bindArg = true, event, arg
        C_Timer.After(0, function() Safe(AG.AnswerBind, p) end)      -- one frame later: the default dialog is up by then
    end

    function AG.AnswerBind(p)
        if pending ~= p then return end
        local which, dialog = BindPopup()
        local data = dialog and dialog.data
        p.bindWhich, p.dialog, p.dialogData = which, dialog, data
        if type(data) == "table" then data = data.slot end
        if type(data) == "number" then p.bindArg = data end      -- what the window's own Okay button would pass
        local plain
        if p.bindEvent then plain = p.bindEvent == "EQUIP_BIND_CONFIRM" or p.bindEvent == "AUTOEQUIP_BIND_CONFIRM"
        else plain = which ~= nil and PLAIN_POPUP[which] == true end
        if plain and p.quality <= BOE_MAX_QUALITY then
            local confirm = EquipPendingItem or (C_Item and C_Item.EquipPendingItem)
            if confirm and p.bindArg ~= nil then
                p.bindHow = "api"
                confirm(p.bindArg)
                C_Timer.After(BIND_WINDOW, function() Safe(function()      -- then tidy the game's window away
                    local w, d = BindPopup()
                    if not (w and PLAIN_POPUP[w]) or d ~= p.dialog or d.data ~= p.dialogData then return end      -- only the window we answered
                    if pending == p and GetInventoryItemID("player", p.slot) ~= p.id and PressOkay(d) then
                        p.bindHow = "api+click"               -- the call did not take: the window's own Okay button
                        return
                    end
                    if StaticPopup_Hide then pcall(StaticPopup_Hide, w) end
                end) end)
                return                                 -- Settle follows from the equipment event or the timeout
            elseif which and PLAIN_POPUP[which] and PressOkay(dialog) then
                p.bindHow = "click"
                return
            end
        end
        DropBind(p)
        hinted[p.link] = true
        AG.Settle(p, plain and "it binds to you when equipped" or "it can still be traded or refunded")
    end

    -------------------------------------------------------------------------------------------------------------
    -- Quest rewards
    -------------------------------------------------------------------------------------------------------------
    local function Highlight(index)
        local buttons = QuestInfoRewardsFrame and QuestInfoRewardsFrame.RewardButtons
        if not (buttons and QuestInfoItem_OnClick) then return false end
        for _, button in ipairs(buttons) do
            if button:IsShown() and button.type == "choice" and button:GetID() == index then
                return pcall(QuestInfoItem_OnClick, button)
            end
        end
        return false
    end

    -- A verdict on the reward choices in front of the player: { quest, rows, pick, why, gain, spec }.
    -- nil = the item data has not arrived yet (ask again). No pick = left to the player, why says the reason.
    function AG.JudgeRewards()
        local n = GetNumQuestChoices() or 0
        local ctx, missing = AG.Context()
        local v = { quest = GetQuestID(), rows = {} }
        local allGear = true
        for i = 1, n do
            local link = GetQuestItemLink("choice", i)
            if not link then return nil end
            local _, _, count, _, usable, itemID = GetQuestItemInfo("choice", i)
            local id = itemID or tonumber(link:match("item:(%d+)"))
            local name, _, _, _, _, _, _, _, _, _, sell = ItemInfo(link)
            if not (id and name) then return nil end
            local row = { i = i, id = id, link = link, sell = (sell or 0) * math.max(count or 1, 1) }
            if ctx then
                if not ctx.E.SlotsFor(id) then
                    allGear = false
                else
                    local slot, gain, tooLow = AG.Score(id, link, ctx)
                    -- red in the reward window = cannot be worn; the one exception worth keeping is "not yet"
                    if slot and (tooLow or usable ~= false) then row.slot, row.gain, row.low = slot, gain, tooLow or nil end
                end
            end
            v.rows[i] = row
        end
        if not ctx then v.why = missing; return v end
        if ctx.pole then v.why = "you are holding a fishing pole, so weapons cannot be compared"; return v end
        local best, rich
        for _, row in ipairs(v.rows) do
            if row.gain and (not best or row.gain > best.gain) then best = row end
            if not rich or row.sell > rich.sell then rich = row end
        end
        if best and best.low then
            v.why = "the best one needs a higher level"
        elseif best then
            v.pick, v.why, v.gain, v.spec = best.i, "upgrade", best.gain, ctx.spec
        elseif allGear and rich then
            v.pick, v.why = rich.i, "gold"
        else
            v.why = "none is an upgrade and one of them is not gear"
        end
        return v
    end

    local lastKey, lastAt = nil, 0
    local function LogVerdict(v, mode)
        if v.logged then return end
        v.logged = true
        local key = tostring(v.quest) .. ":" .. tostring(v.pick)      -- the same window announced twice is one line
        if key == lastKey and GetTime() - lastAt < 5 then return end
        lastKey, lastAt = key, GetTime()
        local entry = { k = "reward", quest = v.quest, pick = v.pick, why = v.why, mode = mode or "off", rows = {} }
        for i, row in ipairs(v.rows) do entry.rows[i] = { id = row.id, gain = row.gain, sell = row.sell, low = row.low } end
        Log(entry)
    end

    function AG.ApplyReward(v)
        local mode = AG.RewardMode()
        LogVerdict(v, mode)
        if not mode or IsShiftKeyDown() then return end
        if (GetQuestMoneyToGet and GetQuestMoneyToGet() or 0) > 0 then return end
        local naowh = _G.NaowhForever                  -- with Naowh installed: a reward saved there (Alt-click) is the player's
        local QR = type(naowh) == "table" and naowh.QuestRewards
        if QR and QR.ItemID then
            local ok, saved = pcall(QR.ItemID, v.quest)
            if ok and saved then return end
        end
        local chosen = QuestInfoFrame and QuestInfoFrame.itemChoice
        if type(chosen) == "number" and chosen > 0 then return end      -- the player already clicked one
        if not v.pick then
            Say("quest reward is yours to pick: " .. tostring(v.why) .. ".")
            return
        end
        local row = v.rows[v.pick]
        local text = v.why == "upgrade" and ("+" .. Pct(v.gain) .. " for " .. v.spec)
            or "none is an upgrade for you; this one sells for the most"
        Highlight(v.pick)
        if mode == "select" then
            Say("quest reward: selected " .. row.link .. " (" .. text .. "). Click Complete Quest to take it.")
            return
        end
        v.auto = true
        Say("quest reward: took " .. row.link .. " (" .. text .. ")")
        GetQuestReward(v.pick)
    end

    function AG.OnQuestComplete()
        judged = nil
        questToken = questToken + 1
        if (GetNumQuestChoices() or 0) < 2 then return end
        local mode = AG.RewardMode()
        if not mode then return end                                 -- switched off: not even a log line
        local quest, token, attempt, shownAt, waits = GetQuestID(), questToken, 0, GetTime(), 0
        -- judged at once for the log, so the record is there even when something else turns the quest in first
        local ok, early = pcall(AG.JudgeRewards)
        if ok and early then judged = early; LogVerdict(early, mode) end
        local function Try()
            if token ~= questToken then return end                  -- a newer turn-in window owns the decision
            -- a reward was already taken from this window (another addon, or the player's own click): the window
            -- can still be up while the server answers, and a second pick must not follow
            if takenQuest == quest and takenAt and takenAt >= shownAt then return end
            -- gone already = another addon (or the player) turned it in; a different quest = not ours any more
            if not (QuestFrameRewardPanel and QuestFrameRewardPanel:IsShown()) or GetQuestID() ~= quest then return end
            -- talents still loading right after a loading screen: wait for them (a second at a time) instead of
            -- handing the pick over to the player
            local Spec = ns.Spec
            if waits < 16 and Spec and Spec.Pending and Spec.Key then
                local _, byHand = Spec.Key()
                if not byHand and Spec.Pending() then
                    waits = waits + 1
                    C_Timer.After(1, function() Safe(Try) end)
                    return
                end
            end
            attempt = attempt + 1
            local v = AG.JudgeRewards()
            if not v then
                if attempt < REWARD_TRIES then C_Timer.After(REWARD_WAIT, function() Safe(Try) end) end
                return
            end
            if judged and judged.logged and judged.pick == v.pick then v.logged = true end
            judged = v
            AG.ApplyReward(v)
        end
        C_Timer.After(REWARD_WAIT, function() Safe(Try) end)
    end

    -- What was actually taken (by this, another addon or the player's own click) goes in the log too.
    if hooksecurefunc and GetQuestReward then
        hooksecurefunc("GetQuestReward", function(index)
            pcall(function()
                local ours = judged      -- the frame may already be closing here, so its own numbers are not trusted
                local q = GetQuestID()
                -- a verdict kept from an earlier window is not this turn-in's (another addon can take a reward
                -- before our own look at the new window has even started)
                if ours and type(q) == "number" and q > 0 and ours.quest ~= q then ours = nil end
                takenQuest, takenAt = ours and ours.quest or q, GetTime()
                if not ours and ((GetNumQuestChoices() or 0) < 2 or not AG.RewardMode()) then return end
                Log({ k = "took", quest = ours and ours.quest or GetQuestID(), i = index, ours = ours and ours.pick,
                    by = ours and ours.auto and ours.pick == index and "auto" or "hand" })
            end)
        end)
    end

    -------------------------------------------------------------------------------------------------------------
    -- Wiring
    -------------------------------------------------------------------------------------------------------------
    -- One line about what is switched on. Said once per character, and again only when the switches or the spec
    -- changed: logins stay quiet.
    local greetTries = 0
    function AG.Greet()
        if greeted then return end
        greeted = true
        local equip, reward = AG.EquipOn(), AG.RewardMode()
        local BA = ns.BuffAsk
        local okBuff, buff = pcall(function() return BA and BA.Mode and BA.Mode() end)
        if not okBuff then buff = nil end
        local ctx, missing = AG.Context()
        -- talents or stats not readable yet: say it a little later, with the spec in it
        if not ctx and missing ~= NO_ENGINE and greetTries < 3 then
            greetTries = greetTries + 1
            greeted = false
            C_Timer.After(8, function() Safe(AG.Greet) end)
            return
        end
        local other = AG.EquipYields() or AG.RewardYields() or (BA and BA.Yields and BA.Yields())
        local switches = "auto-equip " .. (equip and "ON" or "off") .. ", quest rewards "
            .. (reward == "complete" and "ON" or reward == "select" and "SELECT ONLY" or "off")
            .. ", buff asker " .. (buff == "on" and "ON" or buff == "preview" and "PREVIEW" or "off")
            .. (other and " (WoWUI Tweaks is doing its own copy of what shows off here)" or "")
        local text = switches .. (ctx and (". Stat weights: " .. ctx.spec) or "") .. ". Options: /faio"
        local d, who = DB(), Who()
        if type(d.saidGear) ~= "table" then d.saidGear = {} end
        local said = d.saidGear[who]
        if said == text then return end
        -- still nothing to judge by: the switches alone are news only when they changed
        if not ctx and type(said) == "string" and said:sub(1, #switches) == switches then return end
        d.saidGear[who] = text
        Say(text)
    end

    local function Listing()
        local ctx, missing = AG.Context()
        if not ctx then return Say("cannot judge your gear right now: " .. tostring(missing) .. ".") end
        local skip, n = Skips(), 0
        Say("gear in your bags by " .. ctx.spec .. " weights (auto-equip is " .. (AG.EquipOn() and "ON" or "off") .. "):")
        for bag = 0, NUM_BAG_SLOTS or 4 do
            for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
                local info = C_Container.GetContainerItemInfo(bag, slot)
                if n < 15 and info and info.itemID and info.hyperlink and ctx.E.SlotsFor(info.itemID) then
                    n = n + 1
                    local inv, gain, why = AG.Verdict(info, ctx, skip, bag, slot)
                    local pct = gain and string.format("%+.1f%%", gain)
                    print("  " .. info.hyperlink .. ": " .. (inv and ("upgrade " .. pct) or ((why or "busy right now") .. (pct and (" (" .. pct .. ")") or ""))))
                end
            end
        end
        if n == 0 then print("  nothing to wear in there.") end
    end

    -- /faio equip on|off|reset, /faio reward on|select|off, /faio gear
    function AG.Slash(cmd, arg)
        local d = DB()
        arg = tostring(arg or ""):lower():match("^%s*(%S*)")
        if cmd == "equip" then
            if arg == "reset" then
                if type(d.gearSkip) == "table" then d.gearSkip[Who()] = nil end
                tries, hinted, polls = {}, {}, 0
                Say("forgot the items you took off on this character; they can be auto-equipped again.")
                return AG.Queue(0.2)
            end
            if arg == "on" then d.autoEquip = true; tries, hinted, polls = {}, {}, 0; AG.Queue(0.2)
            elseif arg == "off" then d.autoEquip = false end
            if AG.EquipYields() and d.autoEquip ~= false then
                Say("auto-equip stands back here: WoWUI Tweaks' own auto-equip is on (/wowui autoequip off hands it to Forever AIO).")
            else
                Say("auto-equip upgrades is " .. (AG.EquipOn() and "ON" or "off") .. ". /faio equip on | off | reset")
            end
        elseif cmd == "gear" then
            Listing()
        elseif cmd == "reward" then
            if arg == "on" then d.autoReward = true elseif arg == "select" then d.autoReward = "select" elseif arg == "off" then d.autoReward = false end
            if AG.RewardYields() and d.autoReward ~= false then
                Say("quest rewards stand back here: WoWUI Tweaks' own reward picker is on (/wowui autoreward off hands it to Forever AIO).")
            else
                local m = AG.RewardMode()
                Say("auto quest reward is " .. (m == "complete" and "ON (picks and completes)" or m == "select" and "SELECT ONLY (you click Complete Quest)" or "off")
                    .. ". /faio reward on | select | off")
            end
        end
    end
    ns.commands.equip = function(rest) AG.Slash("equip", rest) end
    ns.commands.autoequip = ns.commands.equip
    ns.commands.reward = function(rest) AG.Slash("reward", rest) end
    ns.commands.rewards = ns.commands.reward
    ns.commands.autoreward = ns.commands.reward
    ns.commands.gear = function(rest) AG.Slash("gear", rest) end
    ns.status[#ns.status + 1] = function()
        local m = AG.RewardMode()
        return "auto-equip " .. (AG.EquipYields() and "stands back (WoWUI Tweaks does it here)" or AG.EquipOn() and "ON" or "off")
            .. "; quest rewards " .. (AG.RewardYields() and "stand back (WoWUI Tweaks does it here)"
                or m == "complete" and "ON (picks and completes)" or m == "select" and "SELECT ONLY" or "off")
    end
    -- a spec picked by hand (/faio spec): look at the bags again with the new weights
    if ns.Spec then ns.Spec.OnChanged = function() polls = 0; AG.Queue(0.5) end end

    local frame = CreateFrame("Frame")
    for _, event in ipairs({ "PLAYER_ENTERING_WORLD", "BAG_UPDATE_DELAYED", "PLAYER_REGEN_ENABLED", "PLAYER_LEVEL_UP",
        "PLAYER_UNGHOST", "PLAYER_ALIVE", "PLAYER_EQUIPMENT_CHANGED", "QUEST_COMPLETE", "GET_ITEM_INFO_RECEIVED",
        "TRAIT_CONFIG_UPDATED", "CHARACTER_POINTS_CHANGED", "PLAYER_TALENT_UPDATE", "SKILL_LINES_CHANGED",
        "EQUIP_BIND_CONFIRM", "AUTOEQUIP_BIND_CONFIRM", "EQUIP_BIND_TRADEABLE_CONFIRM", "EQUIP_BIND_REFUNDABLE_CONFIRM" }) do
        pcall(frame.RegisterEvent, frame, event)       -- an event this client does not know must not stop the rest
    end
    frame:SetScript("OnEvent", function(_, event, a1, a2)
        if event == "PLAYER_EQUIPMENT_CHANGED" then
            Safe(AG.OnEquipmentChanged, a1)
        elseif event == "QUEST_COMPLETE" then
            Safe(AG.OnQuestComplete)
        elseif event == "GET_ITEM_INFO_RECEIVED" then
            if waiting then waiting = false; AG.Queue(0.5) end       -- an item the last look could not read
        elseif event:find("BIND_", 1, true) then
            Safe(AG.OnBindConfirm, event, a1)
        else
            if event == "PLAYER_ENTERING_WORLD" then
                Safe(AG.Snapshot)
                ready, oursUntil = true, math.max(oursUntil, GetTime() + 3)      -- gear events of a loading screen are not the player's
                if a1 or a2 then C_Timer.After(8, function() Safe(AG.Greet) end) end
            elseif event == "PLAYER_LEVEL_UP" then
                levelHint, tries = tonumber(a1) or 0, {}
            end
            polls, blind = 0, 0
            AG.Queue(event == "PLAYER_ENTERING_WORLD" and 5 or 0.8)
        end
    end)
end

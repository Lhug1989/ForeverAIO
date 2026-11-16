-- BuffAsk.lua: the buff asker (ns.BuffAsk).
-------------------------------------------------------------------------------------------------------------------
-- Whispers players near me, politely, for the buff their class gives, and thanks them when it lands.
-- Switch: ForeverAIODB.buffAsk (/faio buffask on|preview|off; preview = the whisper is only shown in my own chat
-- frame, nothing is sent). Unset = ON, for every character. Rules:
--   * who is "near": the game has no list of nearby players. Looked at four times a second: target, mouseover, party,
--     raid and every shown nameplate (friendly player nameplates must be on to see strangers). Kept: a player of
--     a buff class that I can assist, online, alive, not in combat, not AFK/DND, with class, name and level
--     readable, who is not me (by name, never by UnitIsUnit alone: Forever can refuse that comparison).
--   * how near: 28 yards (buff spells reach 30, and people need a moment to read and cast). The game gives no
--     distance, only yes/no questions: "are they in following distance" (CheckInteractDistance 4, 28 yards).
--     /faio buffask range 15 asks "would a bandage reach them" (C_Item.IsItemInRange, 15 yards, the item need
--     not be owned) or "are they in trading distance" (CheckInteractDistance 2, shorter) instead, and those two
--     also stand in when the 28-yard question gets no answer. A yes = near; no yes and at least one no = too
--     far; no answer at all = hidden = nobody asked. The questions are only allowed out of combat.
--   * what is asked: every buff of their class that I do not have OR that has less than 50% of its time left
--     (/faio buffask refresh <0-90>), that they are high enough to know (levels from Forever's trainer data),
--     that is switched on and that is useful to me. All in ONE whisper. "Have" goes by aura NAME, so every rank
--     and the group versions count. A buff whose time the game hides counts as fine.
--   * useful to me: Arcane Intellect, Divine Spirit and Blessing of Wisdom only with a mana bar; Thorns only for
--     warrior, rogue, paladin, shaman, druid; Blessing of Might for those and hunters; never a buff my own
--     class gives once I am high enough to cast it myself. Unending Breath and Water Breathing are one buff.
--   * paladins: one paladin keeps ONE blessing on me, so each paladin is asked for one: the first useful
--     blessing they know that I miss (or that is under half) in my class's order (mage/priest/warlock: Wisdom,
--     Kings; warrior/rogue: Might, Kings; others: Kings, Might, Wisdom; /faio buffask prefer <blessing> puts
--     one first). The next paladin is asked for the next one. A paladin whose blessing is on me is only ever
--     asked to renew that same blessing. While the game hides a blessing no paladin is asked.
--   * NO COOLDOWN (user 16 Nov: nothing is to stop it asking everyone in range, "as many buffs as possible"):
--     everyone near who can give a missing buff is asked right away, half a second apart, cities included
--     (/faio buffask city off keeps quiet there). The one limit, picked by the user ("once per buff"): the same
--     person is whispered ONCE for a buff I am missing. They are asked for it again only after it has been on
--     me (from anybody) and run low again, after a real login, or after 12 hours. Only a blessing just asked
--     for waits 15 s, so that the next paladin is asked for the next blessing.
--   * wording: no names, short buff words: "could I please get kings?", "can I please get fort and spirit?";
--     the thank-you is a plain "thanks". Own lines: ForeverAIODB.buffAskText.{ask,thank}.
--   * when not: no whisper of any kind (asks and thank-yous) while I am dead, in an instance, AFK or the game
--     locks addon chat; no asks on a flight. Thank-yous go out in a fight. Asks cannot: the game answers no
--     distance question while InCombatLockdown(), so they go out when the fight ends.
--   * thanks: when a buff I did not have appears, or one I had is renewed, and its caster is another player:
--     one whisper 5 s later (buffs landing together share it), once per person per 5 minutes, also for people
--     who were not asked. When the game does not name the caster: thanked is the ONE person asked for that
--     buff in the last two minutes; with nobody or several asked, nobody is thanked (never guessed). Nothing is
--     said while NaowhForever's own "Buff Thank You Message" is on, if that addon is installed. Buffs that
--     "appear" right after a loading screen, after my buffs were hidden for over 30 s, or more than three at
--     once are a re-read, not a cast: nobody is thanked.
--   * Forever hides (secret) values: a hidden reading is never guessed and never compared, the asker just stays
--     silent. Three refused whispers in a row stop it (/faio buffask on tries again).
--   * log: ForeverAIODB.buffAskLog (last 400 rows { t, kind, to, text, buffs }): kind "ask"/"thank" (really
--     whispered), "preview ask"/"preview thank", "got" (a buff arrived), "error", "start". /faio buffask log
--     sums it up in game; /faio buffask check prints what the game answers for my target.
--   * WoWUI Tweaks has an older copy of this. Where that copy is switched on, this one stays silent.
-------------------------------------------------------------------------------------------------------------------
local _, ns = ...
do
    local BA = { version = 3 }
    ns.BuffAsk = BA
    local TAG = ns.TAG
    local THANK_GAP = 301                   -- seconds before the same person is thanked again: 5 minutes + 1, because
                                            -- the clock here counts whole seconds (300 could be 299.x real seconds)
    local FORGET = 12 * 3600                -- an ask nobody answered is forgotten after this long (and at a login)
    local SEND_GAP = 0.5                    -- seconds between any two whispers (user 13 Nov: a group run past got one ask)
    local STALE = 30                        -- my buffs unreadable for longer: what is there afterwards did not "arrive"
    local HOLD = 5                          -- ... and nothing "arrives" for this long after a loading screen
    local TOGETHER = 3                      -- more buffs than this appearing in one look are a re-read, not casts
    local BLESS_WAIT = 15                   -- a BLESSING just asked for is not asked from the next paladin for this long:
                                            -- they get the next blessing instead. Other buffs: no wait (user 13 Nov)
    local THANK_WAIT = 5                    -- a thank-you goes out this long after the (last) buff from that person
    local THANK_DROP = 30                   -- a thank-you that could not go out for this long is dropped
    local CREDIT = 120                      -- hidden caster: the one person asked for the buff within this long
    local REFRESH = 50                      -- ask again when less than this percent of the buff's time is left
    local RENEWED = 2                       -- an end time this many seconds later = the buff was cast again
    local TRADE, FOLLOW = 2, 4              -- CheckInteractDistance: trading distance / 28 yards
    local RANGE_ITEMS = { 1251, 2581, 3530, 6450, 14529 }   -- bandages: reach 15 yards on a friendly player
    local TEXT_MAX = 255                    -- longest chat line the game takes
    local TICK, LOG_MAX, MAX_ERRORS, NAME_TRIES = 0.25, 400, 3, 20
    local MANA = 0

    local MELEE = { WARRIOR = true, ROGUE = true, PALADIN = true, SHAMAN = true, DRUID = true }
    local MIGHT = { WARRIOR = true, ROGUE = true, PALADIN = true, SHAMAN = true, DRUID = true, HUNTER = true }
    -- key, giving class, level they learn it at, the word used in the whisper, spells = { id, English name } of
    -- rank 1 of the single and the group version (every rank shares the name). group = buffs that replace each
    -- other for me; mana = only useful with a mana bar; only = only useful to these classes.
    local BUFFS = {
        { key = "fort",   class = "PRIEST",  level = 1,  say = "fort", spells = { { 1243, "Power Word: Fortitude" }, { 21562, "Prayer of Fortitude" } } },
        { key = "spirit", class = "PRIEST",  level = 30, say = "spirit", spells = { { 14752, "Divine Spirit" }, { 27681, "Prayer of Spirit" } }, mana = true },
        { key = "shadow", class = "PRIEST",  level = 30, say = "shadow prot", spells = { { 976, "Shadow Protection" }, { 27683, "Prayer of Shadow Protection" } } },
        { key = "motw",   class = "DRUID",   level = 1,  say = "motw", spells = { { 1126, "Mark of the Wild" }, { 21849, "Gift of the Wild" } } },
        { key = "thorns", class = "DRUID",   level = 6,  say = "thorns", spells = { { 467, "Thorns" } }, only = MELEE },
        { key = "ai",     class = "MAGE",    level = 1,  say = "int", spells = { { 1459, "Arcane Intellect" }, { 23028, "Arcane Brilliance" } }, mana = true },
        { key = "wisdom", class = "PALADIN", level = 14, say = "wisdom", spells = { { 19742, "Blessing of Wisdom" }, { 25894, "Greater Blessing of Wisdom" } }, group = "blessing", mana = true },
        { key = "might",  class = "PALADIN", level = 4,  say = "might", spells = { { 19740, "Blessing of Might" }, { 25782, "Greater Blessing of Might" } }, group = "blessing", only = MIGHT },
        { key = "kings",  class = "PALADIN", level = 20, say = "kings", spells = { { 20217, "Blessing of Kings" }, { 25898, "Greater Blessing of Kings" } }, group = "blessing" },
        { key = "breath", class = "WARLOCK", level = 16, say = "unending breath", spells = { { 5697, "Unending Breath" } }, group = "breath" },
        { key = "water",  class = "SHAMAN",  level = 22, say = "water breathing", spells = { { 131, "Water Breathing" } }, group = "breath" },
    }
    -- which blessing I ask a paladin for, best first, by MY class (the useless ones drop out by mana/only)
    local BLESSING = {
        MAGE = { "wisdom", "kings" }, PRIEST = { "wisdom", "kings" }, WARLOCK = { "wisdom", "kings" },
        WARRIOR = { "might", "kings" }, ROGUE = { "might", "kings" },
        other = { "kings", "might", "wisdom" },
    }
    local TEXT = {
        -- user 13 Nov: no names, short buff words ("could I please get kings?"), "a simple thanks"
        ask = {
            "could I please get {buff}?",
            "can I please get {buff}?",
        },
        thank = {
            "thanks",
        },
    }
    local BY_KEY, GIVES, SWITCH = {}, {}, { blessing = true }
    for _, b in ipairs(BUFFS) do BY_KEY[b.key] = b; GIVES[b.class] = true; SWITCH[b.key] = true end
    local UNITS = { "target", "mouseover" }
    for i = 1, 4 do UNITS[#UNITS + 1] = "party" .. i end
    for i = 1, 40 do UNITS[#UNITS + 1] = "raid" .. i end
    for i = 1, 40 do UNITS[#UNITS + 1] = "nameplate" .. i end
    BA.TEXT, BA.BUFFS = TEXT, BUFFS

    local function DB() return ns.DB() end
    -- a hidden (secret) value may only be stored or passed on: never compared, not even with nil
    local function Plain(v) return not (issecretvalue and issecretvalue(v)) end
    -- one game answer: the first value when the game gives a usable one, nil when it is hidden, missing or the
    -- call fails
    local function Ask(fn, ...)
        if type(fn) ~= "function" then return nil end
        local ok, v = pcall(fn, ...)
        if ok and Plain(v) then return v end
        return nil
    end
    local function Sub(key)
        local d = DB()
        if type(d[key]) ~= "table" then d[key] = {} end
        return d[key]
    end

    -- My own switch: "on" (whispers), "preview" (my own chat frame only) or nil (off). Unset = on.
    function BA.Own()
        local m = DB().buffAsk
        if m == nil or m == true then return "on" end
        if m == "preview" then return "preview" end
        return nil
    end
    -- WoWUI Tweaks carries the older copy of the buff asker. Where that one is switched on, this one stays silent:
    -- two askers would whisper everybody twice.
    function BA.Yields()
        local other = _G.WoWUI_BuffAsk
        if type(other) ~= "table" or other == BA or type(other.Mode) ~= "function" then return false end
        local ok, mode = pcall(other.Mode)
        return ok and mode ~= nil
    end
    -- What is in force right now: my own switch, or nil while the older copy is at work.
    function BA.Mode()
        if BA.Yields() then return nil end
        return BA.Own()
    end

    local function Class(unit)
        local ok, _, class = pcall(UnitClass, unit)
        if ok and Plain(class) and type(class) == "string" then return class end
        return nil
    end

    -- short name for the text and the whisper address ("Name" or "Name-Realm"), or nil when hidden
    local function Person(unit)
        local ok, name, realm = pcall(UnitName, unit)
        if not ok or not Plain(name) or not Plain(realm) then return nil end
        if type(name) ~= "string" or name == "" or name == UNKNOWNOBJECT then return nil end
        if type(realm) == "string" and realm ~= "" then return name, name .. "-" .. realm end
        return name, name
    end

    -- Is this unit (whose whisper address is full) me? Forever can refuse UnitIsUnit (nil) or hide its answer, so
    -- the name decides; my own name unreadable = treated as me (silence).
    local function IsMe(unit, full)
        if unit == "player" or Ask(UnitIsUnit, unit, "player") == true then return true end
        local _, mine = Person("player")
        return mine == nil or mine == full
    end

    local function Names(b)
        if b.names then return b.names end
        local set, list, complete = {}, {}, true
        local function add(n) if type(n) == "string" and n ~= "" and not set[n] then set[n] = true; list[#list + 1] = n end end
        for _, s in ipairs(b.spells) do
            local n = C_Spell and Ask(C_Spell.GetSpellName, s[1])
            if type(n) ~= "string" or n == "" then complete = false end
            add(n); add(s[2])
        end
        b.tries = (b.tries or 0) + 1
        if complete or b.tries >= NAME_TRIES then b.names = list end     -- a name the game did not give yet is asked again
        return list
    end

    -- true and the aura / false, or nil when the game hides this buff
    local function Have(b)
        local get = C_UnitAuras and C_UnitAuras.GetAuraDataBySpellName
        if type(get) ~= "function" then return nil end
        local hides = C_Secrets and C_Secrets.ShouldSpellAuraBeSecret
        if hides then
            -- rank 1 of the single spell is a trainer-checked id: no usable answer = hidden. The group versions
            -- may not exist in this client: only a clear "yes, secret" hides the buff.
            for i, s in ipairs(b.spells) do
                local secret = Ask(hides, s[1])
                if secret == true or (i == 1 and secret ~= false) then return nil end
            end
        end
        for _, n in ipairs(Names(b)) do
            local ok, aura = pcall(get, "player", n, "HELPFUL")
            if not ok or not Plain(aura) then return nil end
            if type(aura) == "table" then return true, aura end
            if aura ~= nil then return nil end
        end
        return false
    end

    local function Percent()
        local p = DB().buffAskRefresh
        if type(p) ~= "number" or p < 0 or p > 90 then return REFRESH end
        return p
    end

    -- st[key] = { hidden = true } or { have = true/false, low = less than Percent() of its time left, exp = when it
    -- ends (nil when not readable), aura }. nil when the game hides auras altogether.
    local function Read(now)
        if C_Secrets and C_Secrets.ShouldAurasBeSecret and Ask(C_Secrets.ShouldAurasBeSecret) ~= false then return nil end
        local part = Percent() / 100
        local st = {}
        for _, b in ipairs(BUFFS) do
            local have, aura = Have(b)
            local s
            if have == nil then
                s = { hidden = true }
            else
                s = { have = have, low = false, aura = aura }
                if have then
                    local dur, exp = aura.duration, aura.expirationTime
                    if Plain(dur) and Plain(exp) and type(dur) == "number" and type(exp) == "number" and dur > 0 and exp > 0 then
                        s.exp = exp
                        s.low = exp - now < dur * part
                    end
                end
            end
            st[b.key] = s
        end
        return st
    end

    local function Log(text, to, kind, buffs)
        local log = Sub("buffAskLog")
        log[#log + 1] = { t = time and time() or 0, text = text, to = to, kind = kind, buffs = buffs }
        while #log > LOG_MAX do table.remove(log, 1) end
    end

    local function Texts(kind)
        local own = DB().buffAskText
        local list = type(own) == "table" and own[kind]
        if type(list) == "table" and type(list[1]) == "string" then return list end
        return TEXT[kind]
    end
    local function Fill(kind, name, buff)
        local list = Texts(kind)
        local line = list[math.random(#list)]
        if type(line) ~= "string" then line = list[1] end
        local function word(k)
            k = k:lower()
            return (k == "name" and name) or ((k == "buff" or k == "buffs") and buff) or ""
        end
        -- "|" starts an escape code in chat: a line with a stray one is refused, so none goes out
        local out = line:gsub("{(%a+)}", word):gsub("|", "")
        if not out:find("%S") then out = TEXT[kind][1]:gsub("{(%a+)}", word) end
        return out
    end
    local function Join(list)
        local n = #list
        if n <= 1 then return list[1] or "" end
        return table.concat(list, ", ", 1, n - 1) .. " and " .. list[n]
    end
    -- the game refuses a chat line over 255 bytes: cut it, never in the middle of a letter
    local function Clip(text)
        if #text <= TEXT_MAX then return text end
        local n = TEXT_MAX
        while n > 0 do
            local c = text:byte(n + 1)
            if not c or c < 128 or c >= 192 then break end
            n = n - 1
        end
        return text:sub(1, n)
    end

    local prev, prevAt = nil, 0                -- the last readable st (nil until the first reading) and when it was read
    local holdUntil = 0                        -- no buff "arrives" before this (loading screens)
    local lastSend, sendErrors = -1e9, 0
    local asks = {}                            -- { full, name, keys = { buff key = true }, groups, at } of the last CREDIT seconds
    local buffWait = {}                        -- Slot(buff) -> time until which nobody else is asked for it
    local giver = {}                           -- blessing key -> { full, exp }: whose blessing of that kind is on me (when known)
    local maybe = {}                           -- blessing key -> { exp, who = { address = true } }: a blessing nobody could
                                               -- be credited for; each of these paladins may be the one keeping it on me
    local thanks = {}                          -- waiting thank-yous (array)
    local look = {}                            -- what the last look found (for the status line)
    local myClass, myLevel
    local ticker
    local tickErrors = 0
    local function Stop() if ticker then ticker:Cancel(); ticker = nil end end

    -- The books, kept across /reload with wall-clock times.
    --   asked[address][buff key] = when that person was asked for that buff, as long as it has not arrived since.
    --     ONE whisper per person per buff I am missing (user 16 Nov: no cooldown, "as many buffs as possible";
    --     picked "once per buff"). The mark goes when the buff is on me again with enough time left (from
    --     anybody: the wish is over, and when it runs low again everybody may be asked anew), at a real login,
    --     after FORGET, or with /faio buffask reset. Kept per character of mine.
    --   thanked[address] = when last thanked.
    -- Preview keeps its own set: a whisper that was only shown must not count for or against the real ones.
    local function Books(mode)
        local d = DB()
        if mode ~= "on" then d = Sub("buffAskPreview") end
        if type(d.buffAsked) ~= "table" then d.buffAsked = {} end
        if type(d.buffAskThanked) ~= "table" then d.buffAskThanked = {} end
        local _, me = Person("player")
        me = me or "?"
        if type(d.buffAsked[me]) ~= "table" then d.buffAsked[me] = {} end
        return d.buffAsked[me], d.buffAskThanked
    end
    -- seconds since book[full], or nil. A clock that went backwards counts from now (never "long ago").
    local function Since(book, full, epoch)
        local at = book[full]
        if type(at) ~= "number" then return nil end
        if epoch < at then book[full] = epoch; return 0 end
        return epoch - at
    end
    local function Stamp(book, full, epoch, keep)
        for who, was in pairs(book) do
            if type(was) ~= "number" or epoch - was >= keep then book[who] = nil
            elseif epoch < was then book[who] = epoch end
        end
        book[full] = epoch
    end

    -- One whisper out. false = not now: the caller simply tries again on a later look.
    local function Send(mode, full, text, kind, now, buffs)
        text = Clip(text)
        if mode == "preview" then
            print(TAG .. "[preview] to " .. full .. ": " .. text)
            Log(text, full, "preview " .. kind, buffs)
        else
            local lock = C_ChatInfo and C_ChatInfo.InChatMessagingLockdown
            if lock and Ask(lock) ~= false then return false end
            local say = (C_ChatInfo and C_ChatInfo.SendChatMessage) or SendChatMessage
            local ok, err = pcall(say, text, "WHISPER", nil, full)
            if not ok then
                lastSend = now
                sendErrors = sendErrors + 1
                Log(text .. ": " .. tostring(err), full, "error")
                if sendErrors >= MAX_ERRORS then
                    BA.broken = true
                    Stop()
                    print(TAG .. "buff asker stopped: the game refused the whisper three times (/faio buffask on tries again)")
                end
                return false
            end
            sendErrors = 0
            Log(text, full, kind, buffs)
        end
        lastSend = now
        return true
    end

    local function Enabled(b)
        local off = DB().buffAskOff
        if type(off) ~= "table" then return true end
        return not (off[b.key] or (b.group and off[b.group]))
    end
    -- what shares one "just asked" wait: Unending Breath / Water Breathing are one wish, every blessing its own
    local function Slot(b) return b.group ~= "blessing" and b.group or b.key end
    -- a buff of the same group is on me with enough time left (or hidden, which counts as fine). Blessings do
    -- not replace each other when they come from different paladins: each one is wanted on its own.
    local function GroupOk(b, st)
        if not b.group or b.group == "blessing" then return false end
        for _, o in ipairs(BUFFS) do
            if o.group == b.group then
                local s = st[o.key]
                if s.hidden or (s.have and not s.low) then return true end
            end
        end
        return false
    end
    local function HasMana()
        local max = Ask(UnitPowerMax, "player", MANA)
        return type(max) == "number" and max > 0
    end
    local function Useful(b, mana)
        if not myClass then return false end
        if b.only and not b.only[myClass] then return false end
        if b.mana and not mana then return false end
        if b.class == myClass then return type(myLevel) == "number" and myLevel < b.level end   -- my own spell
        return true
    end

    -- why no whisper of any kind goes out right now, or nil. Every hidden answer counts as "not now".
    local function Busy()
        if Ask(UnitIsDeadOrGhost, "player") ~= false then return "you are dead (or the game hides it)" end
        if Ask(IsInInstance) ~= false then return "you are in an instance" end
        if Ask(UnitIsAFK, "player") ~= false then return "you are AFK" end
        local lock = C_ChatInfo and C_ChatInfo.InChatMessagingLockdown
        if lock and Ask(lock) ~= false then return "the game locks addon chat here" end
        return nil
    end
    -- why I am not asking anybody right now, or nil (busy = what Busy() said this look). Cities and inns are
    -- fine (user 16 Nov: nothing is to stop it asking everyone in range); /faio buffask city off keeps quiet there.
    local function Idle(busy)
        if busy then return busy end
        -- the distance questions are refused in a fight: asks wait for its end (thank-yous do not)
        if Ask(InCombatLockdown) ~= false or Ask(UnitAffectingCombat, "player") ~= false then
            return "you are in combat: the game answers no distance question then (thank-yous still go out)"
        end
        if DB().buffAskCity == false and Ask(IsResting) ~= false then return "you are in a city or inn and asking there is switched off (/faio buffask city on allows it)" end
        if Ask(UnitOnTaxi, "player") ~= false then return "you are on a flight" end
        return nil
    end

    local function Yes(v) return v == true or v == 1 end       -- older clients answered 1 / nil
    -- true / false, or nil when the game gives no usable answer. Only called out of combat (Idle).
    local function Near15(unit)
        local trade = Ask(CheckInteractDistance, unit, TRADE)
        if Yes(trade) then return true end
        local far = trade == false
        local reach = C_Item and C_Item.IsItemInRange
        if reach then
            for _, id in ipairs(RANGE_ITEMS) do
                local r = Ask(reach, id, unit)
                if r == true then return true end
                if r == false then far = true end
            end
        end
        if far then return false end
        return nil
    end
    local function Near(unit)
        if DB().buffAskRange ~= 15 then
            local follow = Ask(CheckInteractDistance, unit, FOLLOW)
            if Yes(follow) then return true end
            if follow == false then return false end
        end
        return Near15(unit)
    end

    -- { name, full, class, level } for a unit worth asking, or nil and why not (no reason = not a player, or me)
    local function Candidate(unit)
        if Ask(UnitExists, unit) ~= true or Ask(UnitIsPlayer, unit) ~= true then return nil end
        -- no C_Secrets.ShouldUnitIdentityBeSecret gate: a hidden class or name arrives as a secret value and
        -- drops out below; what the game hands over plainly may be used (the check command still shows the flag)
        local class = Class(unit)
        if not class then return nil, "class hidden" end
        if not GIVES[class] then return nil, "class without a buff" end
        local name, full = Person(unit)
        if not name then return nil, "name hidden" end
        if IsMe(unit, full) then return nil end
        if Ask(UnitCanAssist, "player", unit) ~= true then return nil, "not on your side" end
        if Ask(UnitIsConnected, unit) ~= true then return nil, "offline" end
        if Ask(UnitIsDeadOrGhost, unit) ~= false then return nil, "dead" end
        if Ask(UnitAffectingCombat, unit) ~= false then return nil, "in combat" end
        if Ask(UnitIsAFK, unit) ~= false or Ask(UnitIsDND, unit) ~= false then return nil, "AFK or busy" end
        if Ask(UnitOnTaxi, unit) == true then return nil, "on a flight" end
        local level = Ask(UnitLevel, unit)
        if type(level) ~= "number" or level < 1 then return nil, "level hidden" end
        return { name = name, full = full, class = class, level = level }
    end

    local function Order()
        local list = BLESSING[myClass or ""] or BLESSING.other
        local first = DB().buffAskPrefer
        if not (type(first) == "string" and BY_KEY[first] and BY_KEY[first].group == "blessing") then return list end
        local out = { first }
        for _, key in ipairs(list) do if key ~= first then out[#out + 1] = key end end
        return out
    end

    -- The blessing this paladin has on me (its key), or nil; second value true = a blessing is hidden, so it
    -- cannot be known. One paladin keeps ONE blessing on a player: a second one from them replaces the first.
    -- Known from who was credited when it landed (same end time since) or from the caster the aura names.
    -- An end time the game hides for a moment is still the same aura: unreadable on either side counts as equal.
    local function Same(a, b) return a == nil or b == nil or a == b or math.abs(a - b) < RENEWED end
    local function Holds(p, st)
        for _, b in ipairs(BUFFS) do
            if b.group == "blessing" and st[b.key].hidden then return nil, true end
        end
        -- Over every blessing, in order of certainty: 1 the caster the aura itself names; 2 who was credited
        -- when it landed (the one person asked: a good guess, void when the aura names somebody else);
        -- 3 who may have given a blessing nobody could be credited for.
        for pass = 1, 3 do
            for _, b in ipairs(BUFFS) do
                local s = st[b.key]
                if b.group == "blessing" and s.have then
                    local named
                    local src = type(s.aura) == "table" and s.aura.sourceUnit
                    if Plain(src) and type(src) == "string" then
                        local _, full = Person(src)
                        named = full
                    end
                    if pass == 1 then
                        if named ~= nil and named == p.full then return b.key end
                    elseif named == nil then               -- the aura names nobody: the books decide
                        if pass == 2 then
                            local g = giver[b.key]
                            if g and g.full == p.full and Same(g.exp, s.exp) then return b.key end
                        else
                            local m = maybe[b.key]
                            if m and m.who[p.full] and Same(m.exp, s.exp) then return b.key end
                        end
                    end
                end
            end
        end
        return nil
    end

    -- the buffs to ask this person for, in the order they are named. marks = { buff key = when asked }: what this
    -- person was already asked for, and has not arrived since, is not asked from them again.
    local function Wanted(p, want, marks, st)
        local function ok(b)
            return want[b.key] and p.level >= b.level and marks[b.key] == nil
        end
        local list = {}
        for _, b in ipairs(BUFFS) do
            if b.class == p.class and b.group ~= "blessing" and ok(b) then list[#list + 1] = b end
        end
        if p.class == "PALADIN" then
            local held, blind = Holds(p, st)
            if blind then                                   -- not guessed: no blessing asked
            elseif held then                                -- theirs is on me: only ever a renewal of that one
                if ok(BY_KEY[held]) then list[#list + 1] = BY_KEY[held] end
            else
                -- one open blessing wish per paladin (they can keep only one on me): while a blessing they were
                -- asked for is still missing, they are not asked for another
                for _, b in ipairs(BUFFS) do
                    if b.group == "blessing" and marks[b.key] ~= nil then return list end
                end
                for _, key in ipairs(Order()) do
                    if ok(BY_KEY[key]) then list[#list + 1] = BY_KEY[key]; break end
                end
            end
        end
        return list
    end

    local function Skip(why) look.skip[why] = (look.skip[why] or 0) + 1 end
    local NOTHING = {}

    -- Marks that are done with: the buff is on me again with enough time left (or another buff of its group is),
    -- or the ask is older than FORGET. Runs on every look, so that a buff that came and later runs low is a new
    -- wish for everybody. A clock that went backwards counts from now (never "long ago": no second whisper).
    -- A wish that ended goes into the log once ("have"), so the summary can tell a new wish from a repeat.
    -- Is the wish for buff b over? Only on real evidence, never on a hidden reading: the buff (or another of
    -- its group) is on me with a readable time that is not low; or, when the game hides its time, it arrived
    -- in this very look (came). A buff that is on me but low is still a wish.
    local function Granted(b, st, came)
        local function ok(o)
            local s = st[o.key]
            if s == nil or s.hidden or s.have ~= true then return false end
            if s.exp ~= nil then return not s.low end
            return came ~= nil and came[o.key] == true
        end
        if ok(b) then return true end
        if b.group and b.group ~= "blessing" then
            for _, o in ipairs(BUFFS) do
                if o ~= b and o.group == b.group and ok(o) then return true end
            end
        end
        return false
    end
    local function Tidy(asked, st, epoch, mode, came)
        local over
        for who, marks in pairs(asked) do
            if type(marks) ~= "table" then
                asked[who] = nil
            else
                for key, at in pairs(marks) do
                    local b, s = BY_KEY[key], st[key]
                    if not b or not s or type(at) ~= "number" or epoch - at >= FORGET then
                        marks[key] = nil
                    elseif Granted(b, st, came) then
                        marks[key] = nil
                        over = over or {}
                        over[key] = true
                    elseif epoch < at then
                        marks[key] = epoch
                    end
                end
                if next(marks) == nil then asked[who] = nil end
            end
        end
        if over then
            for key in pairs(over) do Log("on you again: everyone may be asked anew when it runs low", nil, mode == "on" and "have" or "preview have", key) end
        end
    end

    -- At most one whisper per look.
    local function Asks(mode, st, now, busy)
        look = { players = 0, skip = {} }
        look.idle = Idle(busy)
        if look.idle then return end
        local mana = HasMana()
        local want, any = {}, false
        for _, b in ipairs(BUFFS) do
            local s, wait = st[b.key], buffWait[Slot(b)]
            if not s.hidden and (not s.have or s.low) and not GroupOk(b, st) and Enabled(b) and Useful(b, mana)
                and not (wait and now < wait) then
                want[b.key] = true; any = true
            end
        end
        if not any then look.idle = "nothing to ask for (you have the buffs, or one was just asked for)"; return end
        if now - lastSend < SEND_GAP then look.idle = "next whisper in a moment"; return end
        local asked = Books(mode)
        local epoch = time()
        local seen = {}
        for _, unit in ipairs(UNITS) do
            local p, why = Candidate(unit)
            if why then Skip(why) end
            if p and not seen[p.full] then
                seen[p.full] = true
                look.players = look.players + 1
                local marks = asked[p.full]
                if type(marks) ~= "table" then marks = NOTHING end
                local list = Wanted(p, want, marks, st)
                if #list == 0 then
                    Skip(next(marks) ~= nil and "already asked, waiting for the buff" or "nothing to ask them")
                else
                    local near = Near(unit)
                    if near == nil then Skip("range hidden")
                    elseif near ~= true then Skip("too far")
                    else
                        local words, keys, groups, said = {}, {}, {}, {}
                        for i, b in ipairs(list) do
                            words[i] = b.say; keys[b.key] = true; said[i] = b.key
                            if b.group then groups[b.group] = true end
                        end
                        if not Send(mode, p.full, Fill("ask", p.name, Join(words)), "ask", now, table.concat(said, ",")) then return end
                        if type(asked[p.full]) ~= "table" then asked[p.full] = {} end
                        for _, b in ipairs(list) do asked[p.full][b.key] = epoch end
                        asks[#asks + 1] = { full = p.full, name = p.name, keys = keys, groups = groups, at = now }
                        for _, b in ipairs(list) do if b.group == "blessing" then buffWait[Slot(b)] = now + BLESS_WAIT end end
                        return
                    end
                end
            end
        end
    end

    -- NaowhForever's own thank-you whisper is switched on: mine stays quiet
    local function NaowhThanks()
        local n = _G.NaowhForever
        local s = type(n) == "table" and n.QoLSettings
        if type(s) ~= "table" or type(s.Get) ~= "function" then return false end
        local ok1, all = pcall(s.Get, "enabled")
        local ok2, on = pcall(s.Get, "buffThanks")
        return ok1 and ok2 and all == true and on == true
    end

    -- A buff landed on me (new, or cast again): find who to thank. Every arrival is a "got" row in the log.
    -- st = this look's reading of my buffs (for the "one blessing per paladin" cross-check).
    local function Arrived(mode, b, aura, now, exp, st)
        buffWait[Slot(b)] = nil
        if b.group == "blessing" then giver[b.key], maybe[b.key] = nil, nil end      -- a new cast: whose it is starts unknown
        local function got(what, who) Log(what, who, "got", b.key) end
        local src, byPlayer = aura.sourceUnit, aura.isFromPlayerOrPlayerPet
        if Plain(byPlayer) and byPlayer == false then return got("from an NPC") end
        if not Plain(src) then src = nil end
        local name, full
        -- how sure the credit is: 3 = the aura names the caster, 2 = the one person asked for exactly this buff,
        -- 1 = the one person asked for another buff of its group
        local sure = 3
        if type(src) == "string" then
            if Ask(UnitIsPlayer, src) ~= true then return got("caster is not a readable player") end
            name, full = Person(src)
            if not name then return got("caster's name hidden") end
            if IsMe(src, full) then return got("my own cast") end
        else
            -- could be my own cast: not guessed
            if b.class == myClass and not (type(myLevel) == "number" and myLevel < b.level) then
                return got("caster hidden, could be my own cast")
            end
            -- the ONE person asked for exactly this buff; nobody was: the one person asked for a buff of its
            -- group (a paladin may answer with another blessing). Several = not guessed.
            local function asked(field, k)
                local n, f
                for _, a in ipairs(asks) do
                    if now - a.at <= CREDIT and a[field][k] then
                        if f and f ~= a.full then return nil, nil, true end
                        n, f = a.name, a.full
                    end
                end
                return n, f
            end
            local several, field, fk = nil, "keys", b.key
            name, full, several = asked("keys", b.key)
            sure = 2
            if not name and not several and b.group then
                field, fk = "groups", b.group
                name, full, several = asked("groups", b.group)
                sure = 1
            end
            if several then
                -- a blessing nobody can be credited for: every paladin asked for a blessing in that time may be
                -- the one keeping it on me, so none of them is asked for a different one while it lasts
                if b.group == "blessing" then
                    local who = {}
                    for _, a in ipairs(asks) do
                        if now - a.at <= CREDIT and a[field][fk] then who[a.full] = true end
                    end
                    maybe[b.key] = { exp = exp, who = who }
                end
                return got("caster hidden, several people asked")
            end
            if not name then return got("caster hidden, nobody asked") end
        end
        if b.group == "blessing" then
            -- One paladin keeps ONE blessing on me. Another blessing credited to the same paladin that is still
            -- on me means one of the two credits is wrong: the surer one stands. (Had they really cast this
            -- one, their other blessing would be gone.)
            if st then
                local drop = {}
                for _, o in ipairs(BUFFS) do
                    if o.group == "blessing" and o ~= b then
                        local g, theirs = giver[o.key], st[o.key]
                        if g and g.full == full and theirs and not theirs.hidden and theirs.have and Same(g.exp, theirs.exp) then
                            -- live = both end times readable (and equal): the old blessing is surely still the
                            -- one that was credited. With a hidden end time it may have been cast anew by
                            -- somebody else since, so on a tie the newer credit stands.
                            local live = g.exp ~= nil and theirs.exp ~= nil
                            local old = g.sure or 2
                            if sure == 3 or sure > old or (not live and sure == old) then
                                drop[#drop + 1] = o.key
                            else
                                return got("caster hidden, their other blessing is still on me")
                            end
                        end
                    end
                end
                for _, key in ipairs(drop) do giver[key] = nil end     -- only once the new credit stands
            end
            giver[b.key] = { full = full, exp = exp, sure = sure }
            for _, o in ipairs(BUFFS) do                       -- and they are no "maybe" for any other blessing
                if o.group == "blessing" and o ~= b then
                    local m = maybe[o.key]
                    if m and m.who[full] then m.who[full] = nil end
                end
            end
            -- their blessing wish is answered, whichever blessing they were asked for: their older blessing marks
            -- go (else a paladin who answered Might with Kings would never be asked again once it ran out)
            local theirs = (Books(mode))[full]
            if type(theirs) == "table" then
                for _, o in ipairs(BUFFS) do
                    if o.group == "blessing" and o ~= b then theirs[o.key] = nil end
                end
            end
        end
        local _, thanked = Books(mode)
        local epoch = time()
        local since = Since(thanked, full, epoch)
        if DB().buffAskThanks == false then return got("thank-yous are off", full) end
        if NaowhThanks() then return got("Naowh's thank-you is on", full) end
        if since and since < THANK_GAP then return got("thanked in the last 5 minutes", full) end
        got("thanking", full)
        local t
        for _, w in ipairs(thanks) do if w.full == full then t = w end end
        if not t then t = { name = name, full = full, buffs = {}, keys = {}, first = now }; thanks[#thanks + 1] = t end
        t.due = now + THANK_WAIT
        for _, said in ipairs(t.buffs) do if said == b.say then return end end
        t.buffs[#t.buffs + 1] = b.say
        t.keys[#t.keys + 1] = b.key
    end

    local function Thanks(mode, now)
        for i = #thanks, 1, -1 do
            if now - thanks[i].first > THANK_DROP then table.remove(thanks, i) end
        end
        -- switched off (or handed to Naowh) while one was waiting: it does not go out
        if DB().buffAskThanks == false or NaowhThanks() then thanks = {}; return end
        if now - lastSend < SEND_GAP then return end
        for i, t in ipairs(thanks) do
            if now >= t.due then
                if Send(mode, t.full, Fill("thank", t.name, Join(t.buffs)), "thank", now, table.concat(t.keys, ",")) then
                    local _, thanked = Books(mode)
                    Stamp(thanked, t.full, time(), THANK_GAP)
                    table.remove(thanks, i)
                end
                return
            end
        end
    end

    function BA.Tick(now)
        local mode = BA.Mode()
        if not mode or BA.broken then return end
        myClass = myClass or Class("player")
        myLevel = Ask(UnitLevel, "player")
        for i = #asks, 1, -1 do if now - asks[i].at > CREDIT then table.remove(asks, i) end end
        local st = Read(now)
        if not st then look = { idle = "the game hides your buffs right now" }; return end
        for key in pairs(giver) do                         -- a blessing that is gone has no giver any more
            if not st[key].hidden and not st[key].have then giver[key] = nil end
        end
        for key in pairs(maybe) do
            if not st[key].hidden and not st[key].have then maybe[key] = nil end
        end
        local came, cameKeys
        if prev and now >= holdUntil and now - prevAt <= STALE then
            came, cameKeys = {}, {}
            for _, b in ipairs(BUFFS) do
                local was, is = prev[b.key], st[b.key]
                if is.have and not was.hidden
                    and (not was.have or (was.exp and is.exp and is.exp > was.exp + RENEWED)) then
                    came[#came + 1] = b
                    cameKeys[b.key] = true
                end
            end
        end
        Tidy((Books(mode)), st, time(), mode, cameKeys)
        if came then
            if #came > TOGETHER then
                Log(#came .. " buffs appeared in one look: read as a re-read, nobody thanked", nil, "got")
                for _, b in ipairs(came) do                    -- whose blessings these are is unknown again
                    if b.group == "blessing" then giver[b.key], maybe[b.key] = nil, nil end
                end
            else
                for _, b in ipairs(came) do Arrived(mode, b, st[b.key].aura, now, st[b.key].exp, st) end
            end
        end
        prev, prevAt = st, now
        local busy = Busy()
        if not busy then Thanks(mode, now) end
        Asks(mode, st, now, busy)
    end

    -- The ticker runs whenever my own switch is on; each look then asks BA.Mode() whether it is my turn (it is
    -- not while WoWUI Tweaks' copy is at work).
    function BA.Refresh()
        if not BA.Own() or BA.broken then Stop(); prev = nil; thanks = {}; return end
        if ticker then return end
        for _, id in ipairs(RANGE_ITEMS) do Ask(C_Item and C_Item.RequestLoadItemDataByID, id) end
        Log(BA.Own(), nil, "start")
        ticker = C_Timer.NewTicker(TICK, function()
            local ok, err = pcall(BA.Tick, GetTime())
            if ok then tickErrors = 0; return end
            tickErrors = tickErrors + 1
            if tickErrors >= MAX_ERRORS then
                BA.broken = true
                Stop()
                Log(tostring(err), nil, "error")
                print(TAG .. "buff asker stopped after an error (/faio buffask on tries again)")
            end
        end)
    end

    function BA.Status()
        local mode = BA.Mode()
        local line = "buff asker is " .. (mode == "on" and "ON (whispering)" or mode == "preview" and "on PREVIEW (shown only to you, nothing is sent)" or "OFF")
        if BA.Own() and BA.Yields() then
            line = "buff asker stands back here: WoWUI Tweaks' own buff asker is on (/wowui buffask off hands it to Forever AIO)"
        end
        if BA.broken then line = line .. ", stopped after errors" end
        local off = {}
        for _, b in ipairs(BUFFS) do if not Enabled(b) then off[#off + 1] = b.key end end
        line = line .. (#off > 0 and ("; not asking for: " .. table.concat(off, ", ")) or "; asking for every buff")
        line = line .. "; reach " .. (DB().buffAskRange == 15 and 15 or 28) .. " yards; asks again under " .. Percent() .. "% left"
            .. "; everyone in reach is asked once per missing buff, no cooldown"
        if DB().buffAskCity == false then line = line .. "; not in cities" end
        if DB().buffAskThanks == false then line = line .. "; thank-yous off"
        elseif NaowhThanks() then line = line .. "; thank-yous left to Naowh's Buff Thank You Message" end
        if Ask(GetCVar, "nameplateShowFriendlyPlayers") == "0" then
            line = line .. "; friendly player nameplates are OFF: only your target, mouse-over and group are seen"
        end
        if mode and look.idle then
            line = line .. "; waiting: " .. look.idle
        elseif mode and look.skip then
            local parts = {}
            for why, n in pairs(look.skip) do parts[#parts + 1] = n .. " " .. why end
            table.sort(parts)
            line = line .. "; last look: " .. (look.players or 0) .. " player(s) of a buff class"
                .. (#parts > 0 and (", passed over: " .. table.concat(parts, ", ")) or "")
        end
        return line
    end

    -- /faio buffask check: what the game answers right now, for me and my target (or mouse-over). Only reads.
    function BA.Check()
        if Ask(InCombatLockdown) ~= false then
            print(TAG .. "buff asker check: not in combat, try again after the fight")
            return nil
        end
        local unit = Ask(UnitExists, "target") == true and "target" or "mouseover"
        local me, them, buffs = {}, {}, {}
        local function row(list, label, fn, ...)
            local s
            if type(fn) ~= "function" then
                s = "MISSING"
            else
                local ok, v = pcall(fn, ...)
                s = (not ok and "ERROR") or (not Plain(v) and "HIDDEN") or tostring(v)
            end
            list[#list + 1] = label .. "=" .. s
        end
        local S, CI, IT = C_Secrets or {}, C_ChatInfo or {}, C_Item or {}
        row(me, "instance", IsInInstance); row(me, "resting", IsResting); row(me, "flight", UnitOnTaxi, "player")
        row(me, "afk", UnitIsAFK, "player"); row(me, "chatLock", CI.InChatMessagingLockdown)
        row(me, "aurasHidden", S.ShouldAurasBeSecret); row(me, "restrictions", S.HasSecretRestrictions)
        row(me, "friendPlates", GetCVar, "nameplateShowFriendlyPlayers"); row(me, "mana", UnitPowerMax, "player", MANA)
        row(me, "level", UnitLevel, "player")
        me[#me + 1] = "class=" .. (Class("player") or "HIDDEN")
        row(them, "exists", UnitExists, unit); row(them, "player", UnitIsPlayer, unit)
        row(them, "identityHidden", S.ShouldUnitIdentityBeSecret, unit); row(them, "isMe", UnitIsUnit, unit, "player")
        local _, full = Person(unit)
        them[#them + 1] = "name=" .. (full or "HIDDEN")
        them[#them + 1] = "class=" .. (Class(unit) or "HIDDEN")
        row(them, "assist", UnitCanAssist, "player", unit); row(them, "online", UnitIsConnected, unit)
        row(them, "dead", UnitIsDeadOrGhost, unit); row(them, "combat", UnitAffectingCombat, unit)
        row(them, "afk", UnitIsAFK, unit); row(them, "dnd", UnitIsDND, unit); row(them, "level", UnitLevel, unit)
        if Ask(IsInInstance) ~= false then
            them[#them + 1] = "range=not asked in an instance"       -- the range questions are refused there
        else
            row(them, "trade", CheckInteractDistance, unit, TRADE); row(them, "follow", CheckInteractDistance, unit, FOLLOW)
            for _, id in ipairs(RANGE_ITEMS) do row(them, "item" .. id, IT.IsItemInRange, id, unit) end
            them[#them + 1] = "near=" .. tostring(Near(unit))
        end
        local st = Read(GetTime())
        if not st then
            buffs[1] = "all HIDDEN"
        else
            for _, b in ipairs(BUFFS) do
                local s = st[b.key]
                if s.hidden then
                    buffs[#buffs + 1] = b.key .. "=HIDDEN"
                elseif s.have then
                    local src = s.aura.sourceUnit
                    buffs[#buffs + 1] = b.key .. "=" .. (s.low and "low" or "have") .. (s.exp and "" or ",time hidden")
                        .. ",from " .. (not Plain(src) and "HIDDEN" or tostring(src))
                end
            end
            if #buffs == 0 then buffs[1] = "none of the asked buffs on you" end
        end
        DB().buffAskCheck = { t = time and time() or 0, unit = unit, me = me, them = them, buffs = buffs }
        print(TAG .. "buff asker check, you: " .. table.concat(me, " "))
        print(TAG .. unit .. ": " .. table.concat(them, " "))
        print(TAG .. "your buffs: " .. table.concat(buffs, " "))
        return DB().buffAskCheck
    end

    -- /faio buffask log [rows]: what the saved log says. Returns the counts and the printed lines. "twice" counts
    -- a person asked again for a buff that had not arrived in between (and with no login or reset, which forget
    -- the asks: "forget" rows; a /reload does not): the one thing the asker must never do.
    function BA.Report(rows)
        local log = DB().buffAskLog
        if type(log) ~= "table" then log = {} end
        local n = { ask = 0, thank = 0, previewAsk = 0, previewThank = 0, got = 0, known = 0, error = 0, twice = 0, people = 0 }
        local open, who = {}, {}                           -- open[mark] = { buff key, when asked }
        local function Over(key)                           -- that buff arrived: its wish is over for everybody
            for mark, was in pairs(open) do
                if was[1] == key then open[mark] = nil end
            end
        end
        for _, r in ipairs(log) do
            if type(r) == "table" then
                local k, to = r.kind, r.to
                local t = type(r.t) == "number" and r.t or 0
                if k == "ask" or k == "preview ask" or k == "thank" or k == "preview thank" then
                    local field = (k == "ask" and "ask") or (k == "thank" and "thank") or (k == "preview ask" and "previewAsk") or "previewThank"
                    n[field] = n[field] + 1
                    if (k == "ask" or k == "preview ask") and type(to) == "string" then
                        if not who[to:lower()] then who[to:lower()] = true; n.people = n.people + 1 end
                        for key in tostring(r.buffs or ""):gmatch("[^,]+") do
                            local mark = k .. ":" .. to:lower() .. ":" .. key
                            local was = open[mark]
                            if was and t - was[2] < FORGET and t >= was[2] then n.twice = n.twice + 1 end
                            open[mark] = { key, t }
                        end
                    end
                elseif k == "got" then
                    n.got = n.got + 1
                    if type(to) == "string" then n.known = n.known + 1 end
                    Over(r.buffs)
                elseif k == "have" or k == "preview have" then
                    Over(r.buffs)
                elseif k == "forget" then                  -- a login or a reset: everybody may be asked anew
                    open = {}
                elseif k == "error" then
                    n.error = n.error + 1
                end
            end
        end
        local lines = {}
        lines[1] = "buff asker log: " .. n.ask .. " asks sent (" .. n.previewAsk .. " more only previewed) to " .. n.people
            .. " people; " .. n.got .. " buffs arrived, " .. n.known .. " from someone known; " .. n.thank .. " thank-yous sent ("
            .. n.previewThank .. " previewed); " .. n.error .. " errors; same person asked twice for a buff that had not come: "
            .. (n.twice == 0 and "never" or (n.twice .. " TIMES")) .. "."
        rows = math.min(math.max(tonumber(rows) or 8, 0), 40)
        for i = math.max(1, #log - rows + 1), #log do
            local r = log[i]
            if type(r) == "table" then
                local okAt, at = pcall(function() return type(r.t) == "number" and date and date("%H:%M:%S", r.t) or "?" end)
                if not okAt or type(at) ~= "string" then at = "?" end
                lines[#lines + 1] = at .. " " .. tostring(r.kind) .. " " .. tostring(r.to or "-")
                    .. (r.buffs and (" [" .. tostring(r.buffs) .. "]") or "") .. ": " .. tostring(r.text or "")
            end
        end
        for _, l in ipairs(lines) do print(TAG .. l) end
        return n, lines
    end

    function BA.Slash(arg)
        local d = DB()
        local a, b = tostring(arg or ""):lower():match("^%s*(%S*)%s*(%S*)")
        local before, again = BA.Own(), false
        if a == "check" then BA.Check(); return end
        if a == "log" then BA.Report(b); return end
        if a == "on" then d.buffAsk = true; again = true
        elseif a == "preview" or a == "test" then d.buffAsk = "preview"; again = true
        elseif a == "off" then d.buffAsk = false
        elseif a == "reset" then again = true
        elseif a == "city" and b == "on" then d.buffAskCity = nil
        elseif a == "city" and b == "off" then d.buffAskCity = false
        elseif a == "thanks" and b == "on" then d.buffAskThanks = nil
        elseif a == "thanks" and b == "off" then d.buffAskThanks = false
        elseif a == "range" and (b == "15" or b == "28") then d.buffAskRange = b == "15" and 15 or nil
        elseif a == "refresh" and tonumber(b) and tonumber(b) >= 0 and tonumber(b) <= 90 then
            d.buffAskRefresh = tonumber(b) ~= REFRESH and tonumber(b) or nil
        elseif a == "prefer" and (b == "wisdom" or b == "might" or b == "kings") then d.buffAskPrefer = b
        elseif a == "prefer" and (b == "auto" or b == "off") then d.buffAskPrefer = nil
        elseif SWITCH[a] and (b == "on" or b == "off") then Sub("buffAskOff")[a] = b == "off" or nil
        end
        if again then BA.broken = nil; sendErrors, tickErrors = 0, 0 end
        -- who was asked is forgotten only by "reset": never by off/on or by repeating "on". The preview keeps
        -- its own books under the same rules (they never count for the real whispers).
        local mode = BA.Own()
        if a == "reset" then
            d.buffAsked, d.buffAskThanked, d.buffAskPreview = {}, {}, nil
            Log("reset", nil, "forget")
        end
        if a == "reset" or mode ~= before then
            asks, buffWait, thanks = {}, {}, {}
        end
        BA.Refresh()
        print(TAG .. BA.Status() .. "  (/faio buffask on|preview|off|reset|check|log | city on|off | thanks on|off | range 15|28 | refresh <0-90> | prefer wisdom|might|kings|auto | <buff> on|off: fort spirit shadow motw thorns ai blessing wisdom might kings breath water)")
    end

    local frame = CreateFrame("Frame")
    pcall(frame.RegisterEvent, frame, "PLAYER_ENTERING_WORLD")
    -- every loading screen: what is on me afterwards did not "arrive". A real login (not a /reload) also forgets
    -- who was asked on this character: everybody may be asked anew.
    frame:SetScript("OnEvent", function(_, _, isLogin)
        local ok, err = pcall(function()
            if Plain(isLogin) and isLogin == true then
                local d = DB()
                local _, me = Person("player")
                if me and type(d.buffAsked) == "table" then d.buffAsked[me] = nil end
                if me and type(d.buffAskPreview) == "table" and type(d.buffAskPreview.buffAsked) == "table" then
                    d.buffAskPreview.buffAsked[me] = nil
                end
                Log("login", nil, "forget")
            end
            prev, holdUntil = nil, (Ask(GetTime) or 0) + HOLD
            BA.Refresh()
        end)
        if not ok then pcall(Log, tostring(err), nil, "error") end
    end)
    ns.commands.buffask = BA.Slash
    ns.commands.buffs = BA.Slash
    ns.commands.buff = BA.Slash
    ns.status[#ns.status + 1] = BA.Status
end

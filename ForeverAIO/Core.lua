-- Forever AIO: auto-equip, quest reward picker and buff asker for WoW Forever.
-- Stands alone: it needs no other addon, and works on any character of any account (everything is on by default).
-- Core.lua: the shared table, the saved settings, chat output and the /faio command.
local ADDON, ns = ...
ns.name = ADDON or "ForeverAIO"
ns.version = "1.0.0"
ns.commands = {}                      -- /faio <word> ...: the other files add theirs
ns.status = {}                        -- functions that each return one status line for a bare /faio

local TAG = "|cff33ccffForever AIO|r: "
ns.TAG = TAG
_G.ForeverAIO = ns                    -- for /run and for other addons that want to look

-- The saved settings (ForeverAIODB, one per account; per-character things sit under the character's name).
function ns.DB()
    if type(ForeverAIODB) ~= "table" then ForeverAIODB = {} end
    return ForeverAIODB
end

function ns.Print(text) print(TAG .. tostring(text)) end

-- "Name-Realm" of the logged-in character: the key for everything kept per character
function ns.Who() return (UnitName("player") or "?") .. "-" .. (GetRealmName() or "?") end

-- Forever hands addons hidden ("secret") values at times: they may be stored and passed on, never compared
function ns.Secret(v) return issecretvalue ~= nil and issecretvalue(v) end

local HELP = {
    "/faio equip on | off | reset   - auto-equip upgrades from your bags (reset forgets what you took off)",
    "/faio reward on | select | off - quest rewards: pick and complete / only highlight / hands off",
    "/faio gear                     - how each piece of gear in your bags rates right now",
    "/faio spec [name | auto]       - which spec's stat weights are used",
    "/faio buffask on | preview | off | ... - the buff asker (/faio buffask alone shows all its options)",
}

local function Status()
    ns.Print("version " .. ns.version .. ". Stat weights: Forever Leveling BiS "
        .. tostring(ns.WeightData and ns.WeightData.version or "?") .. " (built in).")
    for _, fn in ipairs(ns.status) do
        local ok, line = pcall(fn)
        if ok and type(line) == "string" and line ~= "" then ns.Print(line) end
    end
    for _, line in ipairs(HELP) do print("  " .. line) end
end

SLASH_FOREVERAIO1, SLASH_FOREVERAIO2 = "/faio", "/foreveraio"
SlashCmdList["FOREVERAIO"] = function(msg)
    local cmd, rest = tostring(msg or ""):match("^%s*(%S*)%s*(.-)%s*$")
    cmd = (cmd or ""):lower()
    local fn = ns.commands[cmd]
    if not fn then return Status() end
    local ok, err = pcall(fn, rest or "")
    if not ok then ns.Print("that command hit an error: " .. tostring(err)) end
end

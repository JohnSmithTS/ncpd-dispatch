-- NCPD Dispatch: an NCPD career for V.
-- v0.2: dispatch calls arrive by phone (ring, caller-ID panel, dispatcher
-- lines); on-duty toggle and settings remembered; generated "crime in progress" calls built
-- from the game's own gang NPC records, map marker, payout, reputation, ranks.
-- v0.4: surprise heavies, gang wars between two factions, NCPD backup.
-- Needs Cyber Engine Tweaks + Codeware (DynamicEntitySystem).

local NCPD = {
    version = "0.7.1",
    tag = "NCPDDispatch",
    overlayOpen = false,
    timer = 0,
    now = 0,                    -- game-time seconds, advanced in onUpdate
    call = nil,                 -- the active call
    ring = nil,                 -- an incoming dispatch call that is ringing
    dialog = nil,               -- dispatcher lines being shown
    panel = nil,                -- HUD widgets for the phone panel
    pools = {},                 -- faction name -> list of record id strings
    bossPools = {},             -- faction name -> tougher (Elite/Officer) records
    copPool = {},               -- NCPD officer records for backup
    civPool = {},               -- civilian records used as victims
    recent = {},                -- last few call destinations (avoid repeats)
    poolsBuilt = false,
    lastLog = "",
    save = {
        rep = 0, calls = 0, earned = 0, nonlethal = 0,
        -- settings (kept between sessions, so CET is only needed to change them)
        onDuty = false,
        autoDispatch = true,
        autoAnswer = true,
        dispatchEvery = 240,    -- seconds between calls while on duty
        bossEnabled = true,     -- surprise heavy can join an ordinary call
        bossChance = 15,        -- percent per eligible call
        gangWarEnabled = true,  -- two rival gangs fighting each other
        backupEnabled = true,   -- friendly NCPD officers on big calls
        victimsEnabled = true,  -- civilians at the scene that suspects go after
        policeCover = true,     -- NCPD doesn't put a wanted level on V during a call
        phoneTexts = true,      -- real texts from the NCPD Dispatcher contact
        gpsQuest = true,        -- tracked NCPD objective: GPS route to the call
        ncpdIcon = true,        -- show the call pin with the NCPD icon
    },
}

local RING_AUTO_ANSWER = 4      -- seconds of ringing before auto-answer
local RING_TIMEOUT = 20         -- seconds before an unanswered call is missed
local MISSED_RETRY = 90         -- seconds until dispatch tries again
local OFFER_TIMEOUT = 45        -- seconds to confirm or deny a call before it goes to another unit
local BOSS_MIN_REP = 30         -- rep needed before heavies can show up
local BACKUP_MIN_REP = 150      -- Sergeant and up get NCPD backup
local BOSS_PAY, BOSS_REP = 2500, 20
local BOSS_GRACE = 180          -- seconds of no progress before a heavy "flees"
local WAR_EARLY_BONUS = 0.25    -- extra pay for reaching a gang war mid-fight

local SAVE_FILE = "ncpd_save.json"

local FACTIONS = {
    { name = "Maelstrom",   id = "Factions.Maelstrom" },
    { name = "Tyger Claws", id = "Factions.TygerClaws" },
    { name = "Valentinos",  id = "Factions.Valentinos" },
    { name = "6th Street",  id = "Factions.SixthStreet" },
    { name = "Animals",     id = "Factions.Animals" },
    { name = "Scavengers",  id = "Factions.Scavengers" },
    { name = "Voodoo Boys", id = "Factions.VoodooBoys" },
    { name = "Wraiths",     id = "Factions.Wraiths" },
}

local OK_RARITY = {
    ["NPCRarity.Trash"] = true, ["NPCRarity.Weak"] = true,
    ["NPCRarity.Normal"] = true, ["NPCRarity.Rare"] = true,
}
local BOSS_RARITY = {
    ["NPCRarity.Elite"] = true, ["NPCRarity.Officer"] = true, ["NPCRarity.Boss"] = true,
}
local NCPD_FACTION_IDS = { ["Factions.NCPD"] = true }
local CIV_FACTION_IDS = { ["Factions.Civilian"] = true, ["Factions.Civilians"] = true }
local VICTIM_SAVE_PAY, VICTIM_SAVE_REP = 250, 3
local RECENT_KEEP, RECENT_RADIUS = 6, 60

local CALL_TYPES = {
    { key = "robbery", title = "Armed robbery in progress", min = 2, max = 3, pay = 1200, rep = 10 },
    { key = "assault", title = "Gang assault in progress",  min = 3, max = 4, pay = 1800, rep = 15 },
    { key = "shots", title = "Shots fired, multiple suspects", min = 4, max = 6, pay = 2600, rep = 25, minRep = 60 },
    -- min/max are per side; pay is a base plus perSuspect for each one down
    { key = "war", title = "Gang war in progress", war = true, min = 3, max = 4, pay = 1500, perSuspect = 350, rep = 30, minRep = 100 },
}

local RANKS = {
    { rep = 0,   name = "Patrol Officer" },
    { rep = 60,  name = "Senior Officer" },
    { rep = 150, name = "Sergeant" },
    { rep = 300, name = "Detective" },
    { rep = 600, name = "Lieutenant" },
}

---------------------------------------------------------------- helpers

local function log(msg)
    NCPD.lastLog = msg
    print("[NCPD] " .. msg)
    spdlog.info("[NCPD] " .. msg)
end

local function idStr(tdbid)
    local ok, s = pcall(TDBID.ToStringDEBUG, tdbid)
    return ok and s or ""
end

local function rankName()
    local r = RANKS[1].name
    for _, k in ipairs(RANKS) do if NCPD.save.rep >= k.rep then r = k.name end end
    return r
end

local function notify(text, seconds)
    local ok, err = pcall(function()
        local msg = SimpleScreenMessage.new()
        msg.message = text
        msg.isShown = true
        msg.duration = seconds or 6
        local defs = GetAllBlackboardDefs()
        local bb = Game.GetBlackboardSystem():Get(defs.UI_Notifications)
        bb:SetVariant(defs.UI_Notifications.OnscreenMessage, ToVariant(msg), true)
    end)
    if not ok then log("notify failed: " .. tostring(err)) end
end

local function loadSave()
    local f = io.open(SAVE_FILE, "r")
    if not f then return end
    local ok, data = pcall(json.decode, f:read("*a"))
    f:close()
    if ok and type(data) == "table" then
        for k, v in pairs(data) do NCPD.save[k] = v end
    end
end

local function writeSave()
    local f = io.open(SAVE_FILE, "w")
    if f then f:write(json.encode(NCPD.save)); f:close() end
end

local function giveMoney(amount)
    local ok, err = pcall(function()
        Game.GetTransactionSystem():GiveItem(Game.GetPlayer(), ItemID.FromTDBID(TweakDBID.new("Items.money")), amount)
    end)
    if not ok then log("payout failed: " .. tostring(err)) end
end

---------------------------------------------------------------- phone

local function sound(name)
    pcall(function() GameObject.PlaySoundEvent(Game.GetPlayer(), CName.new(name)) end)
end

local function stopSound(name)
    pcall(function() GameObject.StopSoundEvent(Game.GetPlayer(), CName.new(name)) end)
end

local function gamePaused()
    local ok, paused = pcall(function()
        local h = Game.GetSystemRequestsHandler()
        return h:IsPreGame() or h:IsGamePaused()
    end)
    return ok and paused
end

local function inCombat()
    local ok, v = pcall(function()
        local p = Game.GetPlayer()
        local defs = GetAllBlackboardDefs()
        local bb = Game.GetBlackboardSystem():GetLocalInstanced(p:GetEntityID(), defs.PlayerStateMachine)
        return bb:GetInt(defs.PlayerStateMachine.Combat) == 1
    end)
    return ok and v
end

local function compass(from, to)
    local dx, dy = to.x - from.x, to.y - from.y
    local names = { "east", "north-east", "north", "north-west", "west", "south-west", "south", "south-east" }
    local a = math.atan2 and math.atan2(dy, dx) or math.atan(dy, dx)
    local i = math.floor(((a / (2 * math.pi)) * 8 + 0.5) % 8) + 1
    return names[i], math.floor(math.sqrt(dx * dx + dy * dy) / 10 + 0.5) * 10
end

local FONT = "base\\gameplay\\gui\\fonts\\raj\\raj.inkfontfamily"
local CYAN = { Red = 0.37, Green = 0.96, Blue = 1.0, Alpha = 1 }
local RED = { Red = 1.0, Green = 0.33, Blue = 0.32, Alpha = 1 }

local function hidePanel()
    if NCPD.panel then
        pcall(function() NCPD.panel.parent:RemoveChild(NCPD.panel.root) end)
        NCPD.panel = nil
    end
end

local function makeText(parent, size, color, top)
    local t = inkText.new()
    t:SetFontFamily(FONT)
    t:SetFontStyle(CName.new("Medium"))
    t:SetFontSize(size)
    t:SetTintColor(HDRColor.new(color))
    t:SetMargin(inkMargin.new({ left = 34, top = top, right = 0, bottom = 0 }))
    pcall(function() t:SetWrapping(true, 560) end)
    t:Reparent(parent, -1)
    return t
end

-- Caller-ID style panel on the right of the HUD. Returns false if the HUD
-- can't be reached (then the plain on-screen message is used instead).
local function showPanel(title, body, color)
    if NCPD.panel then
        pcall(function()
            NCPD.panel.title:SetText(title)
            NCPD.panel.body:SetText(body)
            NCPD.panel.title:SetTintColor(HDRColor.new(color or CYAN))
            NCPD.panel.title:SetOpacity(1.0)
        end)
        return true
    end
    local ok, err = pcall(function()
        local parent = Game.GetInkSystem():GetLayer(CName.new("inkHUDLayer")):GetVirtualWindow()
        local root = inkCanvas.new()
        root:SetName(CName.new("ncpd_phone_panel"))
        root:SetAnchor(inkEAnchor.TopRight)
        root:SetAnchorPoint(Vector2.new({ X = 1, Y = 0 }))
        root:SetMargin(inkMargin.new({ left = 0, top = 300, right = 70, bottom = 0 }))
        root:SetSize(Vector2.new({ X = 640, Y = 210 }))

        local bg = inkRectangle.new()
        bg:SetAnchor(inkEAnchor.Fill)
        bg:SetTintColor(HDRColor.new({ Red = 0.03, Green = 0.05, Blue = 0.09, Alpha = 1 }))
        bg:SetOpacity(0.85)
        bg:Reparent(root, -1)

        local bar = inkRectangle.new()
        bar:SetAnchor(inkEAnchor.LeftFillVerticaly)
        bar:SetSize(Vector2.new({ X = 8, Y = 210 }))
        bar:SetTintColor(HDRColor.new(CYAN))
        bar:Reparent(root, -1)

        local t = makeText(root, 44, color or CYAN, 18)
        t:SetText(title)
        local b = makeText(root, 32, { Red = 0.92, Green = 0.92, Blue = 0.92, Alpha = 1 }, 82)
        b:SetText(body)

        root:Reparent(parent, -1)
        NCPD.panel = { root = root, parent = parent, title = t, body = b }
    end)
    if not ok then
        log("HUD panel unavailable: " .. tostring(err))
        NCPD.panel = nil
    end
    return ok
end

-- Real phone texts: entries added to the game's ncpd_dispatcher contact by
-- ncpd_dispatch.archive (ArchiveXL journal merge). A message is (re)sent by
-- switching it to Inactive and back to Active with a notification.
local TEXT_CONTACT = "contacts/ncpd_dispatcher"
local TEXT_CONV = TEXT_CONTACT .. "/ncpd_dispatch_calls"

function NCPD.sendText(msgId)
    local jm = Game.GetJournalManager()
    local path = TEXT_CONV .. "/" .. msgId
    local steps = {
        { TEXT_CONTACT, "gameJournalContact", gameJournalEntryState.Active, JournalNotifyOption.DoNotNotify },
        { TEXT_CONV, "gameJournalPhoneConversation", gameJournalEntryState.Active, JournalNotifyOption.DoNotNotify },
        { path, "gameJournalPhoneMessage", gameJournalEntryState.Inactive, JournalNotifyOption.DoNotNotify },
        { path, "gameJournalPhoneMessage", gameJournalEntryState.Active, JournalNotifyOption.Notify },
    }
    local results = {}
    for i, st in ipairs(steps) do
        local ok, r = pcall(function() return jm:ChangeEntryState(st[1], st[2], st[3], st[4]) end)
        results[i] = ok and tostring(r) or ("error " .. tostring(r))
    end
    local found = pcall(function() return jm:GetEntryByString(path, "gameJournalPhoneMessage") end)
    log(("text %s: contact %s, conversation %s, reset %s, send %s (entry lookup %s)"):format(
        msgId, results[1], results[2], results[3], results[4], found and "ok" or "failed"))
end

-- Message ids in phone/messages.json use these gang slugs.
local GANG_SLUG = {
    ["Maelstrom"] = "maelstrom", ["Tyger Claws"] = "tyger_claws", ["Valentinos"] = "valentinos",
    ["6th Street"] = "sixth_street", ["Animals"] = "animals", ["Scavengers"] = "scavengers",
    ["Voodoo Boys"] = "voodoo_boys", ["Wraiths"] = "wraiths",
}

local function text(id)
    if NCPD.save.phoneTexts then pcall(NCPD.sendText, id) end
end

-- Reply options under the dispatch text. Picking one in the phone sets it
-- Succeeded and the other Inactive (MessengerDialogViewController.ActivateReply);
-- the mod polls those states.
local REPLY_GROUP = TEXT_CONV .. "/reply"
local REPLY_CLASS = "gameJournalPhoneChoiceEntry"
local REPLIES = { "accept", "decline" }

local function jset(path, cls, state, notify)
    local ok, r = pcall(function()
        return Game.GetJournalManager():ChangeEntryState(path, cls, state, notify or JournalNotifyOption.DoNotNotify)
    end)
    return ok and r
end

local function repliesOff()
    for _, r in ipairs(REPLIES) do jset(REPLY_GROUP .. "/" .. r, REPLY_CLASS, gameJournalEntryState.Inactive) end
    jset(REPLY_GROUP, "gameJournalPhoneChoiceGroup", gameJournalEntryState.Inactive)
end

local function repliesOn()
    repliesOff()
    local jm = Game.GetJournalManager()
    for _, r in ipairs(REPLIES) do
        pcall(function() jm:SetEntryVisited(jm:GetEntryByString(REPLY_GROUP .. "/" .. r, REPLY_CLASS), false) end)
    end
    local g = jset(REPLY_GROUP, "gameJournalPhoneChoiceGroup", gameJournalEntryState.Active)
    local a = jset(REPLY_GROUP .. "/accept", REPLY_CLASS, gameJournalEntryState.Active)
    local d = jset(REPLY_GROUP .. "/decline", REPLY_CLASS, gameJournalEntryState.Active)
    log(("replies on: group %s, accept %s, decline %s"):format(tostring(g), tostring(a), tostring(d)))
end

-- "accept", "decline" or nil while the player hasn't replied in the phone.
local function pickedReply()
    local jm = Game.GetJournalManager()
    for _, r in ipairs(REPLIES) do
        local ok, done = pcall(function()
            local st = jm:GetEntryState(jm:GetEntryByString(REPLY_GROUP .. "/" .. r, REPLY_CLASS))
            return EnumInt(st) == EnumInt(gameJournalEntryState.Succeeded)
        end)
        if ok and done then return r end
    end
end

-- A reply made with a hotkey or the overlay shows in the phone thread too.
local function markReply(r)
    for _, x in ipairs(REPLIES) do
        if x ~= r then jset(REPLY_GROUP .. "/" .. x, REPLY_CLASS, gameJournalEntryState.Inactive) end
    end
    jset(REPLY_GROUP .. "/" .. r, REPLY_CLASS, gameJournalEntryState.Succeeded)
end

local function rankSlug(name) return (name:lower():gsub(" ", "_")) end

-- Show a line in the panel, or as an on-screen message if the panel failed.
local function say(title, body, seconds, color)
    if not showPanel(title, body, color) then notify(title .. ": " .. body, seconds) end
end

---------------------------------------------------------------- NPC pools

-- Build per-gang pools from TweakDB instead of hard-coding record names, so
-- calls use whatever regular gang members the game actually has.
local function buildPools()
    NCPD.pools, NCPD.bossPools, NCPD.copPool, NCPD.civPool = {}, {}, {}, {}
    local want = {}
    for _, f in ipairs(FACTIONS) do want[f.id] = f.name; NCPD.pools[f.name] = {}; NCPD.bossPools[f.name] = {} end

    local records = TweakDB:GetRecords("gamedataCharacter_Record") or {}
    local total = 0
    for _, rec in ipairs(records) do
        pcall(function()
            local id = idStr(rec:GetID())
            if id == "" or not id:find("^Character%.") then return end
            -- skip quest / unique characters
            local low = id:lower()
            if low:find("^character%.[ms]?q%d") or low:find("quest")
                or low:find("unique") or low:find("dummy") or low:find("test") then return end
            local aff = rec:Affiliation()
            if not aff then return end
            local affId = idStr(aff:GetID())
            local rar = rec:Rarity()
            local rarId = rar and idStr(rar:GetID()) or ""
            if CIV_FACTION_IDS[affId] then
                if OK_RARITY[rarId] and not low:find("boss") then table.insert(NCPD.civPool, id) end
                return
            end
            if NCPD_FACTION_IDS[affId] then
                if (OK_RARITY[rarId] or rarId == "NPCRarity.Officer") and not low:find("boss")
                    and not low:find("maxtac") then
                    table.insert(NCPD.copPool, id)
                end
                return
            end
            local faction = want[affId]
            if not faction then return end
            if BOSS_RARITY[rarId] then
                table.insert(NCPD.bossPools[faction], id)
                return
            end
            if low:find("boss") or not OK_RARITY[rarId] then return end
            table.insert(NCPD.pools[faction], id)
            total = total + 1
        end)
    end
    local parts = {}
    for _, f in ipairs(FACTIONS) do table.insert(parts, f.name .. "=" .. #NCPD.pools[f.name]) end
    log(("NPC pools built from %d records: %d usable (%s)"):format(#records, total, table.concat(parts, ", ")))
    local bparts = {}
    for _, f in ipairs(FACTIONS) do table.insert(bparts, f.name .. "=" .. #NCPD.bossPools[f.name]) end
    log(("heavy pools (Elite/Officer/Boss): %s; NCPD officers: %d; civilians: %d"):format(table.concat(bparts, ", "), #NCPD.copPool, #NCPD.civPool))
    NCPD.poolsBuilt = total > 0
end

local function pickFaction()
    local usable = {}
    for _, f in ipairs(FACTIONS) do
        if #NCPD.pools[f.name] > 0 then table.insert(usable, f.name) end
    end
    if #usable == 0 then return nil end
    return usable[math.random(#usable)]
end

---------------------------------------------------------------- locations

-- Pick a point 60-120 m from the player and snap it to the human navmesh,
-- so suspects stand on walkable ground. Falls back to a closer raw offset.
local function pickScene()
    local player = Game.GetPlayer()
    local origin = player:GetWorldPosition()
    local systems = {}
    pcall(function() table.insert(systems, { "AINav", Game.GetAINavigationSystem() }) end)
    pcall(function() table.insert(systems, { "Nav", Game.GetNavigationSystem() }) end)
    local why = {}
    for try = 1, 16 do
        local ang = math.random() * math.pi * 2
        local dist = 60 + math.random() * 60
        if try > 8 then dist = 30 + math.random() * 30 end   -- closer if far points fail
        local p = Vector4.new(origin.x + math.cos(ang) * dist, origin.y + math.sin(ang) * dist, origin.z + 4, 1)
        for _, s in ipairs(systems) do
            local ok, snapped = pcall(function()
                return s[2]:GetNearestNavmeshPointBelowOnlyHumanNavmesh(p, 3.0, 8)
            end)
            if ok and snapped and (snapped.x ~= 0 or snapped.y ~= 0)
                and math.abs(snapped.z - origin.z) < 6 then   -- same level as V, not an upper floor
                NCPD.nav = s[2]
                return snapped, "navmesh/" .. s[1]
            end
            why[s[1]] = ok and ("returned " .. (snapped and ("%.0f %.0f %.0f"):format(snapped.x, snapped.y, snapped.z) or "nil"))
                or ("error " .. tostring(snapped))
        end
    end
    for k, v in pairs(why) do log("navmesh " .. k .. ": " .. v) end
    local fwd = player:GetWorldForward()
    return Vector4.new(origin.x + fwd.x * 30, origin.y + fwd.y * 30, origin.z, 1), "fallback"
end

-- Snap one suspect's spot to the same walkable floor as the scene centre.
-- Rejects points that moved far (other side of a wall) or changed level
-- (an interior floor); those suspects stand at the centre instead.
local function suspectSpot(center, x, y)
    if NCPD.nav then
        local ok, p = pcall(function()
            return NCPD.nav:GetNearestNavmeshPointBelowOnlyHumanNavmesh(Vector4.new(x, y, center.z + 1.5, 1), 1.0, 3)
        end)
        if ok and p and (p.x ~= 0 or p.y ~= 0) and math.abs(p.z - center.z) < 1.2 then
            local dx, dy = p.x - x, p.y - y
            if dx * dx + dy * dy < 1.0 then return p, true end
        end
    end
    return Vector4.new(center.x, center.y, center.z, 1), false
end

---------------------------------------------------------------- learned spots

-- Walkable street spots V has been near, one per 50 m cell, kept between
-- sessions. Calls are sent to these so a far-away scene is on real ground
-- (the navmesh only exists near V, so distant points can't be checked).
local SPOTS_FILE = "ncpd_spots.json"
NCPD.spots, NCPD.spotCells, NCPD.spotsDirty, NCPD.sampleIn = {}, {}, 0, 5

local function cellKey(x, y) return math.floor(x / 50) .. ":" .. math.floor(y / 50) end

local function writeSpots()
    if NCPD.spotsDirty == 0 then return end
    local f = io.open(SPOTS_FILE, "w")
    if f then f:write(json.encode(NCPD.spots)); f:close(); NCPD.spotsDirty = 0 end
end

local BANNED_FILE = "ncpd_spots_banned.json"
NCPD.banned = NCPD.banned or {}   -- cellKey -> true: spots that turned out unreachable

local function addSpot(p)
    local k = cellKey(p.x, p.y)
    if NCPD.spotCells[k] or NCPD.banned[k] then return false end
    NCPD.spotCells[k] = true
    table.insert(NCPD.spots, { x = math.floor(p.x * 10) / 10, y = math.floor(p.y * 10) / 10, z = math.floor(p.z * 10) / 10 })
    NCPD.spotsDirty = NCPD.spotsDirty + 1
    if NCPD.spotsDirty >= 10 then writeSpots() end
    return true
end

-- Forget a spot V couldn't get to, and never learn its 50 m cell again.
local function banSpot(p, why)
    local k = cellKey(p.x, p.y)
    NCPD.banned[k] = true
    local kept, removed = {}, 0
    for _, s in ipairs(NCPD.spots) do
        if cellKey(s.x, s.y) == k then removed = removed + 1 else table.insert(kept, s) end
    end
    NCPD.spots = kept
    NCPD.spotCells[k] = nil
    local keys = {}
    for b in pairs(NCPD.banned) do table.insert(keys, b) end
    local f = io.open(BANNED_FILE, "w")
    if f then f:write(json.encode(keys)); f:close() end
    NCPD.spotsDirty = NCPD.spotsDirty + 1
    writeSpots()
    log(("spot %.0f %.0f banned (%s), %d removed, %d spots left"):format(p.x, p.y, why, removed, #NCPD.spots))
end

local function loadSpots()
    local bf = io.open(BANNED_FILE, "r")
    if bf then
        local ok, keys = pcall(json.decode, bf:read("*a"))
        bf:close()
        if ok and type(keys) == "table" then for _, k in ipairs(keys) do NCPD.banned[k] = true end end
    end
    local f = io.open(SPOTS_FILE, "r")
    if not f then return end
    local ok, data = pcall(json.decode, f:read("*a"))
    f:close()
    if ok and type(data) == "table" then
        for _, p in ipairs(data) do
            local k = p.x and p.y and cellKey(p.x, p.y)
            if k and p.z and not NCPD.spotCells[k] and not NCPD.banned[k] then
                NCPD.spotCells[k] = true
                table.insert(NCPD.spots, p)
            end
        end
    end
end

local function navSystem()
    if not NCPD.nav then pcall(function() NCPD.nav = Game.GetNavigationSystem() end) end
    return NCPD.nav
end

-- Record the walkable floor right under V (street, sidewalk, plaza).
local function sampleSpot()
    local nav = navSystem()
    if not nav then return end
    local o = Game.GetPlayer():GetWorldPosition()
    local ok, p = pcall(function()
        return nav:GetNearestNavmeshPointBelowOnlyHumanNavmesh(Vector4.new(o.x, o.y, o.z + 1.5, 1), 1.0, 3)
    end)
    if ok and p and (p.x ~= 0 or p.y ~= 0) and math.abs(p.z - o.z) < 3 then
        local dx, dy = p.x - o.x, p.y - o.y
        if dx * dx + dy * dy < 16 then addSpot(p) end
    end
end

local function inVehicle()
    local ok, v = pcall(function() return Game.GetMountedVehicle(Game.GetPlayer()) end)
    return ok and v ~= nil
end

-- Where to send V: a learned spot at a sensible distance, or a rough point
-- that gets snapped to real ground once V is close.
local function pickTarget()
    local o = Game.GetPlayer():GetWorldPosition()
    local veh = inVehicle()
    local lo, hi = 150, 400
    if veh then lo, hi = 400, 1200 end
    local cands = {}
    for _, p in ipairs(NCPD.spots) do
        local dx, dy = p.x - o.x, p.y - o.y
        local d = math.sqrt(dx * dx + dy * dy)
        if d >= lo and d <= hi and math.abs(p.z - o.z) < 40 then table.insert(cands, p) end
    end
    -- prefer spots away from the last few destinations
    local fresh = {}
    for _, p in ipairs(cands) do
        local near = false
        for _, r in ipairs(NCPD.recent) do
            local dx, dy = p.x - r.x, p.y - r.y
            if dx * dx + dy * dy < RECENT_RADIUS * RECENT_RADIUS then near = true; break end
        end
        if not near then table.insert(fresh, p) end
    end
    if #fresh > 0 then cands = fresh end
    if #cands > 0 then
        local p = cands[math.random(#cands)]
        return Vector4.new(p.x, p.y, p.z, 1), (#fresh > 0) and "learned" or "learned, repeat", veh
    end
    local a = math.random() * math.pi * 2
    local d = lo + math.random() * (hi - lo)
    return Vector4.new(o.x + math.cos(a) * d, o.y + math.sin(a) * d, o.z, 1), "rough", veh
end

---------------------------------------------------------------- GPS objective

-- A Contract quest "NCPD Dispatch" with one objective and a GPS map pin is
-- merged into the journal by ncpd_dispatch.archive. During a call the mod
-- activates and tracks the objective (so the game draws the GPS route) and
-- moves its pin to the call. Without it, a plain map pin is used instead.
local QUEST = "quests/minor_activities/ncpd_dispatch_call"
local PHASE = QUEST .. "/call"
local OBJ_CLASS = "gameJournalQuestObjective"

local function jstate(path, cls, state, notify)
    local ok, r = pcall(function()
        return Game.GetJournalManager():ChangeEntryState(path, cls, state, notify)
    end)
    return ok and r
end

-- The archive has one objective per call type and gang (gang wars per gang
-- pair) so the objective line names the call: respond_<type>_<gang>[_<rival>].
local function objPath(c)
    local id = "respond_" .. c.type.key .. "_" .. (GANG_SLUG[c.faction] or "")
    if c.faction2 then id = id .. "_" .. (GANG_SLUG[c.faction2] or "") end
    return PHASE .. "/" .. id
end

-- Turns the quest off. With no call, every objective is switched off (after
-- a load we don't know which one a saved game left active).
local function questOff(c)
    local Q = JournalNotifyOption.DoNotNotify
    if c and c.obj then
        jstate(c.obj .. "/call_mappin", "gameJournalQuestMapPin", gameJournalEntryState.Inactive, Q)
        jstate(c.obj, OBJ_CLASS, gameJournalEntryState.Inactive, Q)
    else
        for _, t in ipairs(CALL_TYPES) do
            for _, a in pairs(GANG_SLUG) do
                if t.war then
                    for _, b in pairs(GANG_SLUG) do
                        if a ~= b then jstate(PHASE .. "/respond_war_" .. a .. "_" .. b, OBJ_CLASS, gameJournalEntryState.Inactive, Q) end
                    end
                else
                    jstate(PHASE .. "/respond_" .. t.key .. "_" .. a, OBJ_CLASS, gameJournalEntryState.Inactive, Q)
                end
            end
        end
    end
    jstate(PHASE, "gameJournalQuestPhase", gameJournalEntryState.Inactive, Q)
    jstate(QUEST, "gameJournalQuest", gameJournalEntryState.Inactive, Q)
end

local function questStart(c)
    if not NCPD.save.gpsQuest then return end
    c.obj = objPath(c)
    questOff(c)
    local Q = JournalNotifyOption.DoNotNotify
    local okQ = jstate(QUEST, "gameJournalQuest", gameJournalEntryState.Active, Q)
    local okP = jstate(PHASE, "gameJournalQuestPhase", gameJournalEntryState.Active, Q)
    local okO = jstate(c.obj, OBJ_CLASS, gameJournalEntryState.Active, JournalNotifyOption.Notify)
    -- the pin is its own journal entry; an Inactive pin is never spawned
    local okM = jstate(c.obj .. "/call_mappin", "gameJournalQuestMapPin", gameJournalEntryState.Active, Q)
    local tracked = pcall(function()
        local jm = Game.GetJournalManager()
        jm:TrackEntry(jm:GetEntryByString(c.obj, OBJ_CLASS))
    end)
    c.questOn = true
    c.pinTries = 0
    log(("GPS objective %s: quest %s, phase %s, objective %s, pin %s, tracked %s"):format(
        c.obj:match("[^/]+$"), tostring(okQ), tostring(okP), tostring(okO), tostring(okM), tostring(tracked)))
end

-- Find the objective's map pin (it registers a moment after activation)
-- and keep it on the call's current position.
local function questPin(c)
    if not c.questOn or c.pinFailed then return end
    if not c.questPin then
        c.pinTries = c.pinTries + 1
        pcall(function()
            local jm = Game.GetJournalManager()
            local ph = jm:GetEntryByString(PHASE, "gameJournalQuestPhase")
            local ob = jm:GetEntryByString(c.obj, OBJ_CLASS)
            local m = Game.GetMappinSystem():GetMappinFromObjective(ph, ob)
            if m then c.questPin = m:GetNewMappinID() end
        end)
        if not c.questPin then
            if c.pinTries >= 40 then   -- ~10 s at 4 checks a second
                c.pinFailed = true
                log("GPS objective pin not found; using a plain map pin")
            end
            return
        end
        log(("GPS objective pin found after %d checks"):format(c.pinTries))
        if NCPD.save.ncpdIcon then
            local ok = pcall(function()
                Game.GetMappinSystem():ChangeMappinVariant(c.questPin, gamedataMappinVariant.Zzz06_NCPDGigVariant)
            end)
            log("NCPD icon " .. (ok and "set" or "failed"))
        end
        -- the plain pin is no longer needed
        if c.mappin then
            pcall(function() Game.GetMappinSystem():UnregisterMappin(c.mappin) end)
            c.mappin = nil
        end
    end
    if c.markPos and c.pinAt ~= c.markPos then
        local ok = pcall(function() Game.GetMappinSystem():SetMappinPosition(c.questPin, c.markPos) end)
        c.pinAt = c.markPos
        if not ok then log("could not move GPS pin") end
    end
end

local function questEnd(c, outcome)
    if not c or not c.questOn then return end
    local Q = JournalNotifyOption.DoNotNotify
    jstate(c.obj, OBJ_CLASS,
        outcome == "cleared" and gameJournalEntryState.Succeeded or gameJournalEntryState.Failed, Q)
    pcall(function() Game.GetJournalManager():UntrackEntry() end)
    -- switching the objective off leaves its registered pin on the map, so
    -- take the pin off directly
    if c.questPin then
        local ok = pcall(function() Game.GetMappinSystem():UnregisterMappin(c.questPin) end)
        log("GPS pin removed (" .. outcome .. ")" .. (ok and "" or ": unregister failed"))
        c.questPin = nil
    end
    questOff(c)
    c.questOn = false
end

---------------------------------------------------------------- calls

local function clearMappin()
    if NCPD.call and NCPD.call.mappin then
        pcall(function() Game.GetMappinSystem():UnregisterMappin(NCPD.call.mappin) end)
        NCPD.call.mappin = nil
    end
end

-- Police cover: while V works a scene, the prevention (wanted) system is
-- switched off under our own source name, the way quests do it; when the call
-- ends it's switched back on and any heat V picked up is cleared.
local POLICE_SOURCE = "NCPDDispatch"

local function preventionRequest(make)
    return pcall(function()
        local sys = Game.GetScriptableSystemsContainer():Get(CName.new("PreventionSystem"))
        sys:QueueRequest(make())
    end)
end

local function setPoliceActive(active)
    local ok, err = preventionRequest(function()
        local r = TogglePreventionSystem.new()
        r.isActive = active
        r.sourceName = CName.new(POLICE_SOURCE)
        return r
    end)
    if not ok then log("police toggle failed: " .. tostring(err)) end
    NCPD.policeOff = (not active) and ok
    return ok
end

local function clearHeat()
    local ok, err = preventionRequest(function() return PreventionForceDeescalateRequest.new() end)
    if not ok then log("clearing wanted level failed: " .. tostring(err)) end
    return ok
end

local function restorePolice(why)
    if NCPD.policeOff then
        setPoliceActive(true)
        clearHeat()
        log("police cover ended (" .. why .. "), wanted level cleared")
    end
end

local function despawnAll()
    pcall(function() Game.GetDynamicEntitySystem():DeleteTagged(NCPD.tag) end)
end

local function isDown(npc)
    local dead, defeated = false, false
    pcall(function() dead = npc:IsDead() end)
    pcall(function() defeated = ScriptedPuppet.IsDefeated(npc) end)
    return dead or defeated, dead
end

local function endCall(outcome)
    local c = NCPD.call
    if not c then return end
    clearMappin()
    if outcome == "cleared" then
        local caught = #c.suspects - c.fled
        local pay = c.type.pay + (c.type.perSuspect or 300) * caught
        local rep = c.type.rep
        local notes = {}
        if c.warEarly then
            pay = math.floor(pay * (1 + WAR_EARLY_BONUS)); rep = rep + 10
            table.insert(notes, " Caught them mid-fight.")
        end
        local saved = 0
        for _, v in ipairs(c.victims or {}) do
            local ve = Game.GetDynamicEntitySystem():GetEntity(v.id)
            if ve and not isDown(ve) then saved = saved + 1 end
        end
        if saved > 0 then
            pay = pay + VICTIM_SAVE_PAY * saved; rep = rep + VICTIM_SAVE_REP * saved
            table.insert(notes, (" %d civilian%s saved."):format(saved, saved > 1 and "s" or ""))
        end
        c.saved = saved
        local unseen = 0
        for _, v in ipairs(c.victims or {}) do if not v.seen then unseen = unseen + 1 end end
        if unseen > 0 then log(("%d victim(s) never streamed in"):format(unseen)) end
        if c.bossDown then
            pay = pay + BOSS_PAY; rep = rep + BOSS_REP
            table.insert(notes, " Heavy neutralized.")
        end
        if c.fled > 0 then pay = math.floor(pay * 0.75); rep = math.floor(rep / 2) end
        local allAlive = c.fled == 0 and c.nonlethal == #c.suspects
        if allAlive then
            pay = math.floor(pay * 1.5); rep = rep * 2
            NCPD.save.nonlethal = NCPD.save.nonlethal + 1
        end
        if c.civDead then rep = -rep end
        local before = rankName()
        giveMoney(pay)
        NCPD.save.rep = math.max(0, NCPD.save.rep + rep)
        NCPD.save.calls = NCPD.save.calls + 1
        NCPD.save.earned = NCPD.save.earned + pay
        writeSave()
        local extra = allAlive and " All suspects taken alive: bonus." or ""
        if c.fled > 0 then extra = (" %d suspect%s got away."):format(c.fled, c.fled > 1 and "s" or "") end
        extra = table.concat(notes) .. extra
        notify(("NCPD: Scene clear. %d eddies, %+d rep.%s"):format(pay, rep, extra), 7)
        if rankName() ~= before then notify("NCPD: Promoted to " .. rankName() .. "!", 8) end
        if c.fled > 0 then text("result_fled")
        elseif allAlive then text("result_clear_alive")
        else text("result_clear") end
        if saved > 0 then text("result_civilians_saved") end
        if rankName() ~= before then text("promo_" .. rankSlug(rankName())) end
        log(("call cleared: pay %d rep %+d (nonlethal %d/%d, fled %d, heavy down %s, war early %s, civilians saved %d/%d)"):format(
            pay, rep, c.nonlethal, #c.suspects, c.fled, tostring(c.bossDown or false), tostring(c.warEarly or false), c.saved or 0, #(c.victims or {})))
    elseif outcome == "late" then
        NCPD.save.rep = math.max(0, NCPD.save.rep - 2)
        writeSave()
        notify("NCPD: Too slow, another unit took the call. -2 rep.", 6)
        text("result_late")
        log("call missed: did not arrive in time")
    else
        NCPD.save.rep = math.max(0, NCPD.save.rep - 5)
        writeSave()
        notify("NCPD: Call abandoned. Dispatch is not impressed. -5 rep.", 6)
        text("result_abandoned")
        log("call abandoned")
    end
    -- learn spots from scenes that worked; forget targets V gave up on
    if outcome == "cleared" and c.pos then addSpot(c.pos)
    elseif (outcome == "abandoned" or outcome == "late") and (c.targetHow or ""):match("^learned") then
        banSpot(c.target, outcome)
    end
    restorePolice(outcome)
    questEnd(c, outcome)
    NCPD.call = nil
    NCPD.timer = 0
    -- leave bodies for a bit, then clean up
    NCPD.cleanupAt = NCPD.now + 60
end

-- Choose what the call is about and where, without spawning anything yet.
local function prepareCall()
    if not NCPD.poolsBuilt then buildPools() end
    local faction = pickFaction()
    if not faction then log("no usable gang NPC records found; cannot dispatch"); return nil end
    local s = NCPD.save
    -- a rival gang for gang wars
    local rivals = {}
    for _, f in ipairs(FACTIONS) do
        if f.name ~= faction and #NCPD.pools[f.name] > 0 then table.insert(rivals, f.name) end
    end
    local choices = {}
    for _, t in ipairs(CALL_TYPES) do
        local ok = s.rep >= (t.minRep or 0)
        if t.war and (not s.gangWarEnabled or #rivals == 0) then ok = false end
        if ok then table.insert(choices, t) end
    end
    local ctype = choices[math.random(#choices)]
    local prep = { type = ctype, faction = faction, count = math.random(ctype.min, ctype.max) }
    if ctype.war then
        prep.faction2 = rivals[math.random(#rivals)]
        prep.count2 = math.random(ctype.min, ctype.max)
    elseif s.bossEnabled and s.rep >= BOSS_MIN_REP and #(NCPD.bossPools[faction] or {}) > 0
        and math.random(100) <= s.bossChance then
        prep.boss = true    -- kept secret until it happens
    end
    if not ctype.war and s.victimsEnabled and #NCPD.civPool > 0 then
        prep.victims = math.random(1, 2)
    end
    local total = prep.count + (prep.count2 or 0)
    if s.backupEnabled and s.rep >= BACKUP_MIN_REP and #NCPD.copPool > 0 and (ctype.war or total >= 4) then
        prep.backup = (total >= 6) and 3 or 2
    end
    return prep
end

local function setMappin(c, pos)
    c.markPos = pos
    if c.questPin then questPin(c); return end
    if c.mappin then pcall(function() Game.GetMappinSystem():UnregisterMappin(c.mappin) end) end
    c.mappin = nil
    pcall(function()
        local data = MappinData.new()
        data.mappinType = TweakDBID.new("Mappins.DefaultStaticMappin")
        data.variant = NCPD.save.ncpdIcon and gamedataMappinVariant.Zzz06_NCPDGigVariant
            or gamedataMappinVariant.CustomPositionVariant
        data.visibleThroughWalls = true
        c.mappin = Game.GetMappinSystem():RegisterMappin(data, pos)
    end)
end

-- Answering a call only sets a destination; suspects spawn when V is close.
local function dispatchCall(prep)
    local target, how, veh = pickTarget()
    local dist = Vector4.Distance(Game.GetPlayer():GetWorldPosition(), target)
    local c = {
        type = prep.type, faction = prep.faction, count = prep.count,
        faction2 = prep.faction2, count2 = prep.count2, boss = prep.boss, backup = prep.backup,
        allies = {}, victims = {}, victimCount = prep.victims or 0,
        state = "enroute", target = target, targetHow = how, pos = target,
        suspects = {}, nonlethal = 0, fled = 0, civDead = false,
        started = NCPD.now, deadline = NCPD.now + 120 + dist / 6,
    }
    setMappin(c, target)
    questStart(c)
    NCPD.call = c
    table.insert(NCPD.recent, { x = target.x, y = target.y })
    while #NCPD.recent > RECENT_KEEP do table.remove(NCPD.recent, 1) end
    log(("call dispatched: %s, %s x%d%s, %.0f m away (%s target, %s)%s%s"):format(
        c.type.title, c.faction, c.count,
        c.faction2 and (" vs " .. c.faction2 .. " x" .. c.count2) or "",
        dist, how, veh and "in vehicle" or "on foot",
        c.boss and " [heavy planned]" or "", c.backup and (" [backup x" .. c.backup .. "]") or ""))
    return target
end

-- Find walkable ground at the destination now that its navmesh is loaded.
-- Walking route check. Only meaningful near V, where the navmesh is
-- streamed in (the scene is placed at 150 m). Returns true / false, or nil
-- when the query itself isn't available (then nothing is rejected).
local PATH_DETOUR = 2.5   -- a route this many times the straight line (+60 m) counts as no way in

local function navStart()
    local nav = navSystem()
    if not nav then return nil end
    local o = Game.GetPlayer():GetWorldPosition()
    local ok, p = pcall(function()
        return nav:GetNearestNavmeshPointBelowOnlyHumanNavmesh(Vector4.new(o.x, o.y, o.z + 1.5, 1), 2.0, 4)
    end)
    if ok and p and (p.x ~= 0 or p.y ~= 0) and Vector4.Distance(p, o) < 6 then return p end
end

local function walkPath(from, to)
    local ok, path = pcall(function()
        return navSystem():CalculatePathOnlyHumanNavmesh(from, to, NavGenAgentSize.Human, 2.0)
    end)
    if not ok then return nil, "error " .. tostring(path) end
    local pts = path and path.path
    if not pts or #pts == 0 then return false, "no path" end
    if Vector4.Distance(pts[#pts], to) > 4 then return false, "path ends short" end
    local len = 0
    for i = 2, #pts do len = len + Vector4.Distance(pts[i - 1], pts[i]) end
    local straight = Vector4.Distance(from, to)
    if len > straight * PATH_DETOUR + 60 then
        return false, ("detour %.0f m for %.0f m"):format(len, straight)
    end
    return true, ("path %.0f m"):format(len)
end

-- Find walkable ground at the destination now that its navmesh is loaded,
-- that V can actually walk to. Falls back to a learned spot near the target,
-- then to a spot near V; an unreachable learned target is banned.
local function sceneCentre(c)
    local nav = navSystem()
    local ref = (c.targetHow or ""):match("^learned") and c.target.z or Game.GetPlayer():GetWorldPosition().z
    local start = nav and navStart()
    local reasons, checked = {}, start ~= nil
    if nav and not start then log("path check skipped: no navmesh under V") end
    local function reachable(sp)
        if not start then return true end
        local ok, info = walkPath(start, sp)
        if ok == nil then
            log("path check unavailable: " .. info); start = nil; checked = false
            return true
        end
        if not ok and #reasons < 4 then table.insert(reasons, info) end
        c.pathInfo = info
        return ok
    end
    if nav then
        for try = 1, 14 do
            local r = (try <= 3) and 0 or ((try <= 8) and 20 or 45)
            local ang = math.random() * math.pi * 2
            local p = Vector4.new(c.target.x + math.cos(ang) * r, c.target.y + math.sin(ang) * r, ref + 4, 1)
            local ok, sp = pcall(function() return nav:GetNearestNavmeshPointBelowOnlyHumanNavmesh(p, 3.0, 8) end)
            if ok and sp and (sp.x ~= 0 or sp.y ~= 0) and math.abs(sp.z - ref) < 6 and reachable(sp) then
                return sp, "at target" .. (checked and (", " .. c.pathInfo) or "")
            end
        end
        if checked then
            -- the nearest learned spots around the target that V can walk to
            local near = {}
            for _, p in ipairs(NCPD.spots) do
                local d = math.sqrt((p.x - c.target.x) ^ 2 + (p.y - c.target.y) ^ 2)
                if d > 5 and d < 120 then table.insert(near, { d = d, p = p }) end
            end
            table.sort(near, function(a, b) return a.d < b.d end)
            for i = 1, math.min(#near, 6) do
                local q = near[i].p
                local ok, sp = pcall(function()
                    return nav:GetNearestNavmeshPointBelowOnlyHumanNavmesh(Vector4.new(q.x, q.y, q.z + 2, 1), 2.0, 4)
                end)
                if ok and sp and (sp.x ~= 0 or sp.y ~= 0) and reachable(sp) then
                    log(("target unreachable (%s); moved %.0f m to a learned spot"):format(table.concat(reasons, "; "), near[i].d))
                    if (c.targetHow or ""):match("^learned") then banSpot(c.target, "no walking route") end
                    return sp, "nearby spot, " .. c.pathInfo
                end
            end
        end
    end
    if checked then
        log("target unreachable: " .. table.concat(reasons, "; "))
        if (c.targetHow or ""):match("^learned") then banSpot(c.target, "no walking route") end
    end
    local p, how = pickScene()   -- last resort: a spot near V
    return p, "near V (" .. how .. ")"
end

local function angleTo(from, to)
    local dy, dx = to.y - from.y, to.x - from.x
    return math.atan2 and math.atan2(dy, dx) or math.atan(dy, dx)
end

-- A second walkable spot `dist` metres from `pos` on the same level, for a
-- rival group, a heavy or backup. `toward` (optional) biases the direction.
local function offsetCentre(pos, dist, toward)
    local nav = navSystem()
    local base = toward and angleTo(pos, toward) or (math.random() * math.pi * 2)
    if nav then
        for try = 0, 7 do
            local step = math.floor((try + 1) / 2) * (math.pi / 6)
            local ang = base + ((try % 2 == 0) and step or -step)
            local p = Vector4.new(pos.x + math.cos(ang) * dist, pos.y + math.sin(ang) * dist, pos.z + 2, 1)
            local ok, sp = pcall(function() return nav:GetNearestNavmeshPointBelowOnlyHumanNavmesh(p, 2.0, 4) end)
            if ok and sp and (sp.x ~= 0 or sp.y ~= 0) and math.abs(sp.z - pos.z) < 2.5 then
                return sp, true
            end
        end
    end
    return Vector4.new(pos.x, pos.y, pos.z, 1), false
end

-- Spawn `count` NPCs from `pool` in a ring around `pos` into `list`.
-- Returns how many spawned and how many had to stand at the centre.
local function spawnGroup(list, pool, pos, count, fields)
    local des = Game.GetDynamicEntitySystem()
    local added, centred = 0, 0
    if not pool or #pool == 0 then return 0, 0 end
    for i = 1, count do
        local rec = pool[math.random(#pool)]
        local ok, id = pcall(function()
            local spec = DynamicEntitySpec.new()
            spec.recordID = TweakDBID.new(rec)
            local a = (i / count) * math.pi * 2
            local spot, snapped = suspectSpot(pos, pos.x + math.cos(a) * 2.5, pos.y + math.sin(a) * 2.5)
            if not snapped then centred = centred + 1 end
            spec.position = spot
            spec.persistState = false
            spec.persistSpawn = false
            spec.alwaysSpawned = true
            spec.tags = { NCPD.tag }
            return des:CreateEntity(spec)
        end)
        if ok and id then
            local e = { id = id, record = rec, hostile = false, done = false }
            for k, v in pairs(fields or {}) do e[k] = v end
            table.insert(list, e)
            added = added + 1
        else
            log("spawn failed for " .. rec .. ": " .. tostring(id))
        end
    end
    return added, centred
end

local function spawnScene(c)
    local pos, how = sceneCentre(c)
    local _, centred = spawnGroup(c.suspects, NCPD.pools[c.faction], pos, c.count, { side = 1 })
    local extra = ""
    if c.faction2 then
        local pos2, ok2 = offsetCentre(pos, 15)
        local n2, cen2 = spawnGroup(c.suspects, NCPD.pools[c.faction2], pos2, c.count2, { side = 2 })
        centred = centred + cen2
        extra = (", rival %s x%d %s"):format(c.faction2, n2, ok2 and "15 m away" or "at centre (no ground found)")
    end
    if #c.suspects == 0 then return false end
    c.pos = pos
    c.state = "active"
    if NCPD.save.policeCover then
        clearHeat()   -- anything from the drive over is forgiven too
        if setPoliceActive(false) then log("police cover on: NCPD stands down for this scene") end
    end
    c.arrivedAt = NCPD.now
    c.lastProgress = NCPD.now
    setMappin(c, pos)
    log(("scene spawned: %s x%d at %.0f %.0f %.0f (%s, %d of %d at centre%s)"):format(
        c.faction, c.count, pos.x, pos.y, pos.z, how, centred, #c.suspects, extra))
    if c.victimCount > 0 then
        local vpos = offsetCentre(pos, 5)
        local nv = spawnGroup(c.victims, NCPD.civPool, vpos, c.victimCount, { victim = true })
        log(("victims: %d civilian(s) at the scene"):format(nv))
    end
    if c.backup then
        local bpos, okb = offsetCentre(pos, 22, Game.GetPlayer():GetWorldPosition())
        local nb = spawnGroup(c.allies, NCPD.copPool, bpos, c.backup, { ally = true })
        log(("NCPD backup: %d officer(s) %s"):format(nb, okb and "22 m from scene" or "at scene centre"))
        if nb > 0 then notify("NCPD: Backup units on scene.", 4) end
    end
    return true
end

-- The heavy arrives once the first wave is mostly down.
local function spawnBoss(c)
    local pos = offsetCentre(c.pos, 12)
    local n = spawnGroup(c.suspects, NCPD.bossPools[c.faction], pos, 1, { side = 1, boss = true })
    c.bossSpawned = true
    c.lastProgress = NCPD.now
    if n > 0 then
        log(("heavy spawned: %s at %.0f %.0f %.0f"):format(c.suspects[#c.suspects].record, pos.x, pos.y, pos.z))
    else
        log("heavy spawn failed; call continues without it")
        c.boss = false
    end
end

-- The phone rings; the call is answered automatically or with the hotkey.
local function startCall()
    if NCPD.call or NCPD.ring or NCPD.dialog or NCPD.offer then log("a call is already active or ringing"); return end
    local prep = prepareCall()
    if not prep then return end
    NCPD.ring = { prep = prep, t = 0 }
    sound("ui_phone_incoming_call")
    local hint = NCPD.save.autoAnswer and "Connecting..." or "Answer with your NCPD answer key"
    say("INCOMING CALL", "NCPD Dispatch\n" .. hint, 6)
    log("phone ringing: " .. prep.type.title .. " / " .. prep.faction)
end

-- Answering the call offers it: the dispatch text arrives with two replies.
-- Nothing is put on the map until the player confirms.
local function answerCall()
    local r = NCPD.ring
    if not r then return end
    NCPD.ring = nil
    stopSound("ui_phone_incoming_call")
    sound("ui_phone_incoming_call_stop")
    sound("ui_phone_incoming_call_positive")
    local prep = r.prep
    NCPD.offer = { prep = prep, t = 0, poll = 0 }
    local slug = GANG_SLUG[prep.faction]
    local phone = NCPD.save.phoneTexts and slug and prep.type.key
    if phone then
        pcall(repliesOn)
        text(prep.type.key .. "_" .. slug)
    end
    local what = prep.faction2 and (prep.faction .. " vs " .. prep.faction2) or prep.faction
    say("NCPD DISPATCH", ("%s, %s.\nCan you take it? %s"):format(prep.type.title, what,
        phone and "Reply by text or use your NCPD keys." or "Use your NCPD answer / decline keys."), OFFER_TIMEOUT)
    log("call offered: " .. prep.type.title .. " / " .. what)
end

-- how: "phone" (reply picked in the phone), "key" (hotkey or overlay), "timeout"
local function resolveOffer(accept, how)
    local o = NCPD.offer
    if not o then return end
    NCPD.offer = nil
    if NCPD.save.phoneTexts then
        if how == "timeout" then pcall(repliesOff)
        elseif how == "key" then pcall(markReply, accept and "accept" or "decline") end
    end
    if not accept then
        if how == "timeout" then
            text("offer_timeout")
            say("NO REPLY", "NCPD Dispatch\nThe call went to another unit.", 5, RED)
            NCPD.timer = math.max(0, NCPD.save.dispatchEvery - MISSED_RETRY)
            log("call not confirmed in time")
        else
            text("deny_ack")
            say("CALL DECLINED", "NCPD Dispatch\nPassed to another unit.", 4, RED)
            NCPD.timer = 0
            log("call declined (" .. how .. ")")
        end
        NCPD.dialog = { lines = {}, t = 0, i = 0, hold = 4 }
        return
    end
    log("call confirmed (" .. how .. ")")
    local pos = dispatchCall(o.prep)
    if not pos then
        say("NCPD DISPATCH", "Disregard, unit. Situation resolved.", 5)
        NCPD.dialog = { lines = { }, t = 0, i = 0, hold = 4 }
        return
    end
    text("confirm_ack")
    local dir, dist = compass(Game.GetPlayer():GetWorldPosition(), pos)
    local c = NCPD.call
    NCPD.dialog = {
        t = 0, i = 0,
        lines = {
            ("Copy that, %s V. You're the closest unit."):format(rankName()),
            ("We have a %s about %d meters %s of you."):format(c.type.title:lower(), dist, dir),
            c.faction2 and ("%s and %s are shooting it out, %d on %d. Let them thin each other out if you like."):format(
                c.faction, c.faction2, c.count, c.count2)
                or ("Witnesses report %d %s%s. Approach with caution."):format(c.count, c.faction,
                    c.victimCount > 0 and ", civilians caught in it" or ""),
            "Location's on your map. Dispatch out.",
        },
    }
end

local function declineCall(missed)
    if not NCPD.ring then return end
    NCPD.ring = nil
    stopSound("ui_phone_incoming_call")
    sound("ui_phone_incoming_call_stop")
    if missed then
        say("MISSED CALL", "NCPD Dispatch\nThey'll try again shortly.", 5, RED)
        text("missed_call")
        NCPD.timer = math.max(0, NCPD.save.dispatchEvery - MISSED_RETRY)
        log("call missed")
    else
        say("CALL DECLINED", "NCPD Dispatch", 4, RED)
        NCPD.timer = 0
        log("call declined")
    end
    NCPD.dialog = { lines = {}, t = 0, i = 0, hold = 4 }
end

local function updateOffer(dt)
    local o = NCPD.offer
    o.t = o.t + dt
    o.poll = o.poll + dt
    if o.poll < 0.25 then return end
    o.poll = 0
    if NCPD.save.phoneTexts then
        local r = pickedReply()
        if r then resolveOffer(r == "accept", "phone"); return end
    end
    if o.t >= OFFER_TIMEOUT then resolveOffer(false, "timeout") end
end

local function updateRing(dt)
    local r = NCPD.ring
    r.t = r.t + dt
    if NCPD.panel then
        pcall(function() NCPD.panel.title:SetOpacity((math.floor(r.t * 2) % 2 == 0) and 1.0 or 0.45) end)
    end
    if NCPD.save.autoAnswer and r.t >= RING_AUTO_ANSWER then
        answerCall()
    elseif r.t >= RING_TIMEOUT then
        declineCall(true)
    end
end

-- Steps through dispatcher lines (3.5 s each), then hides the panel.
-- A dialog with no lines just keeps the current panel up for `hold` seconds.
local function updateDialog(dt)
    local d = NCPD.dialog
    d.t = d.t + dt
    if d.i == 0 then
        d.i, d.t = 1, 0
        if d.lines[1] then say("NCPD DISPATCH", d.lines[1], 4) end
        return
    end
    local stay = d.lines[d.i] and 3.5 or (d.hold or 0)
    if d.t < stay then return end
    d.i, d.t = d.i + 1, 0
    if d.lines[d.i] then
        say("NCPD DISPATCH", d.lines[d.i], 4)
    else
        if d.lines[1] then sound("ui_phone_sms") end
        hidePanel()
        NCPD.dialog = nil
    end
end

local function makeHostile(npc)
    return pcall(function()
        local agent = npc:GetAttitudeAgent()
        agent:SetAttitudeGroup(CName.new("hostile"))
        agent:SetAttitudeTowards(Game.GetPlayer():GetAttitudeAgent(), EAIAttitude.AIA_Hostile)
    end)
end

-- Gang-war fighters keep their own gang's attitude group (so each side
-- stays friendly to itself) and are made hostile to V and to every member
-- of the other side, agent to agent. Allies are friendly to V and hostile
-- to every suspect.
local function setAttitude(a, b, att)
    return pcall(function()
        a:GetAttitudeAgent():SetAttitudeTowards(b:GetAttitudeAgent(), att)
    end)
end

local function makeWarFighter(npc)
    return setAttitude(npc, Game.GetPlayer(), EAIAttitude.AIA_Hostile)
end

local function makeAlly(npc)
    return setAttitude(npc, Game.GetPlayer(), EAIAttitude.AIA_Friendly)
end

-- Make `npc` actively go after `target` (instead of idling until it notices).
local function injectThreat(c, npc, target)
    local ok = pcall(function() TargetTrackingExtension.InjectThreat(npc, target) end)
    if not ok then
        ok = pcall(function() TargetTrackingExtension.InjectThreat(npc, target, 1.0, -1.0) end)
    end
    if not ok and not c.threatFailLogged then
        c.threatFailLogged = true
        log("InjectThreat failed; NPCs will only fight what they notice")
    end
    if ok then c.threats = (c.threats or 0) + 1 end
    return ok
end

-- Link entities that have streamed in. Each pair is linked once, both ways.
local function linkAttitudes(c, des)
    c.linked = c.linked or {}
    local live = {}
    for idx, s in ipairs(c.suspects) do
        if not s.done then
            local e = des:GetEntity(s.id)
            if e then table.insert(live, { s = s, e = e, idx = idx }) end
        end
    end
    local made, failed = 0, 0
    -- hostile both ways; `x` is also pushed to attack `y` straight away
    local function link(x, y, key)
        if c.linked[key] then return end
        local ok1 = setAttitude(x, y, EAIAttitude.AIA_Hostile)
        local ok2 = setAttitude(y, x, EAIAttitude.AIA_Hostile)
        c.linked[key] = true
        if ok1 and ok2 then made = made + 1 else failed = failed + 1 end
        injectThreat(c, x, y)
    end
    -- civilians: suspects go after them, so the crime is actually happening
    for vi, v in ipairs(c.victims) do
        local ve = des:GetEntity(v.id)
        if ve then
            v.seen = true
            for _, l in ipairs(live) do link(l.e, ve, "v" .. vi .. ":" .. l.idx) end
        end
    end
    if c.faction2 then
        for i = 1, #live do
            for j = i + 1, #live do
                if live[i].s.side ~= live[j].s.side then
                    link(live[i].e, live[j].e, "s" .. live[i].idx .. ":" .. live[j].idx)
                    injectThreat(c, live[j].e, live[i].e)
                end
            end
        end
    end
    for ai, a in ipairs(c.allies) do
        local ae = des:GetEntity(a.id)
        if ae then
            if not a.hostile then
                a.hostile = makeAlly(ae)
                if not a.hostile then log("could not make officer friendly: " .. a.record) end
            end
            for _, l in ipairs(live) do link(ae, l.e, "a" .. ai .. ":" .. l.idx) end
        end
    end
    if made + failed > 0 then
        c.linkCount = (c.linkCount or 0) + made
        log(("attitude links: %d set, %d failed (total %d, threats %d)"):format(made, failed, c.linkCount, c.threats or 0))
    end
end

local function updateCall()
    local c = NCPD.call
    questPin(c)
    if c.state == "enroute" then
        local d = Vector4.Distance(Game.GetPlayer():GetWorldPosition(), c.target)
        if d < 150 then
            if not spawnScene(c) then
                log("no suspects spawned; call cancelled")
                clearMappin(); questEnd(c, "cancelled"); NCPD.call = nil; NCPD.timer = 0
            end
        elseif NCPD.now > c.deadline then
            endCall("late")
        end
        return
    end
    local des = Game.GetDynamicEntitySystem()
    local remaining = 0
    for _, s in ipairs(c.suspects) do
        if not s.done then
            local npc = des:GetEntity(s.id)
            if npc then
                if not s.hostile then
                    if c.faction2 then s.hostile = makeWarFighter(npc) else s.hostile = makeHostile(npc) end
                    if not s.hostile then log("could not set hostility on " .. s.record) end
                end
                local down, dead = isDown(npc)
                if down then
                    s.done = true
                    c.lastProgress = NCPD.now
                    if s.boss then c.bossDown = true; log("heavy down") end
                    if not dead then c.nonlethal = c.nonlethal + 1 end
                else
                    remaining = remaining + 1
                end
            else
                remaining = remaining + 1   -- not streamed in yet
            end
        end
    end
    -- attitude links for gang wars / backup, every 30 frames for a while,
    -- so entities that stream in late (or a heavy) get linked too
    if c.faction2 or #c.allies > 0 or #c.victims > 0 then
        c.linkTick = (c.linkTick or 0) + 1
        if c.linkTick % 4 == 1 then   -- about once a second
            local ok, err = pcall(linkAttitudes, c, des)
            if not ok then log("attitude link error: " .. tostring(err)) end
        end
    end

    -- when V closes in, every suspect turns on V
    if not c.engagedV and Vector4.Distance(Game.GetPlayer():GetWorldPosition(), c.pos) < 35 then
        c.engagedV = true
        local n = 0
        for _, s in ipairs(c.suspects) do
            if not s.done then
                local e = des:GetEntity(s.id)
                if e and injectThreat(c, e, Game.GetPlayer()) then n = n + 1 end
            end
        end
        log(("V on scene: %d suspect(s) engaging"):format(n))
    end

    -- gang war: bonus if V shows up while both sides are still standing
    if c.faction2 and not c.arrivalChecked
        and Vector4.Distance(Game.GetPlayer():GetWorldPosition(), c.pos) < 40 then
        c.arrivalChecked = true
        local alive = { 0, 0 }
        for _, s in ipairs(c.suspects) do
            local side = s.side or 1
            if not s.done then alive[side] = alive[side] + 1 end
        end
        c.warEarly = alive[1] > 0 and alive[2] > 0
        log(("gang war: V on scene, alive %d vs %d"):format(alive[1], alive[2]))
        if c.warEarly then notify("NCPD: They're still at it. Shut it down!", 4) end
    end

    -- surprise heavy: once the first wave is mostly down
    if c.boss and not c.bossSpawned then
        local down = #c.suspects - remaining
        if not c.bossAt and (remaining == 0 or down >= math.ceil(#c.suspects * 0.6)) then
            c.bossAt = NCPD.now + 6
            NCPD.dialog = { t = 0, i = 0, lines = {
                "V, heads up! Heavy incoming, " .. c.faction .. " sent a hitter.",
                "Watch yourself. Dispatch out.",
            } }
            sound("ui_phone_incoming_call_positive")
            log("heavy warning radioed")
            text("heavy_warning")
        end
        if c.bossAt and NCPD.now >= c.bossAt then spawnBoss(c) end
        if c.boss and not c.bossSpawned then return end   -- don't finish before the heavy shows
    end

    if remaining == 0 then endCall("cleared"); return end

    -- Suspects V can't reach (stuck in geometry) shouldn't block the call:
    -- if V is at the scene, someone is already down, and nothing has
    -- changed for a minute, the rest "flee" and the call wraps up.
    local here = Vector4.Distance(Game.GetPlayer():GetWorldPosition(), c.pos) < 60
    local grace = 60
    for _, s in ipairs(c.suspects) do if s.boss and not s.done then grace = BOSS_GRACE end end
    if here and remaining < #c.suspects and NCPD.now - c.lastProgress > grace then
        for _, s in ipairs(c.suspects) do
            if not s.done then
                s.done = true
                c.fled = c.fled + 1
                pcall(function() des:DeleteEntity(s.id) end)
            end
        end
        log(("%d suspect(s) unreachable for %d s; counted as fled"):format(c.fled, grace))
        endCall("cleared")
        return
    end

    -- abandoned if V leaves the scene once it's under way
    local d = Vector4.Distance(Game.GetPlayer():GetWorldPosition(), c.pos)
    if d > 400 and NCPD.now - c.arrivedAt > 30 then endCall("abandoned") end
end

---------------------------------------------------------------- events

registerForEvent("onInit", function()
    math.randomseed(os.time())
    loadSave()
    loadSpots()
    log(("%d learned street spots."):format(#NCPD.spots))
    log(("v%s loaded. Rank %s, rep %d, on duty: %s."):format(NCPD.version, rankName(), NCPD.save.rep, tostring(NCPD.save.onDuty)))
end)

registerForEvent("onShutdown", function()
    if NCPD.offer then pcall(repliesOff) end
    restorePolice("shutdown")
    if NCPD.call then pcall(questEnd, NCPD.call, "cancelled") end
    stopSound("ui_phone_incoming_call")
    hidePanel()
    clearMappin()
    despawnAll()
    writeSpots()
end)

registerForEvent("onOverlayOpen", function() NCPD.overlayOpen = true end)
registerForEvent("onOverlayClose", function()
    NCPD.overlayOpen = false
    writeSave()   -- keep any settings changed in the window
end)

registerHotkey("ncpd_duty", "Toggle NCPD duty", function()
    NCPD.save.onDuty = not NCPD.save.onDuty
    NCPD.timer = 0
    writeSave()
    notify(NCPD.save.onDuty and ("NCPD: On duty. " .. rankName() .. ", stand by for calls.") or "NCPD: Off duty.", 5)
    if NCPD.save.onDuty then text("on_duty") end
end)

registerHotkey("ncpd_call", "Request NCPD call now", function() startCall() end)
registerHotkey("ncpd_answer", "Answer / confirm NCPD call", function()
    if NCPD.offer then resolveOffer(true, "key") else answerCall() end
end)
registerHotkey("ncpd_decline", "Decline NCPD call", function()
    if NCPD.offer then resolveOffer(false, "key") else declineCall(false) end
end)

registerForEvent("onUpdate", function(dt)
    NCPD.now = NCPD.now + dt
    if not Game.GetPlayer() or gamePaused() then return end

    -- after a load (or a crash mid-call) make sure our police switch is on
    if not NCPD.policeChecked then
        NCPD.policeChecked = true
        if not NCPD.call then setPoliceActive(true); questOff(); pcall(repliesOff) end
    end

    -- say hello once per session if duty was left on
    if NCPD.save.onDuty and not NCPD.greeted then
        NCPD.greetIn = (NCPD.greetIn or 15) - dt
        if NCPD.greetIn <= 0 then
            NCPD.greeted = true
            notify(("NCPD: %s V on duty. Stand by for calls."):format(rankName()), 6)
        end
    end

    NCPD.sampleIn = NCPD.sampleIn - dt
    if NCPD.sampleIn <= 0 then
        NCPD.sampleIn = 20
        pcall(sampleSpot)
    end

    if NCPD.cleanupAt and NCPD.now > NCPD.cleanupAt and not NCPD.call then
        despawnAll(); NCPD.cleanupAt = nil
    end

    if NCPD.ring then
        local ok, err = pcall(updateRing, dt)
        if not ok then log("ring error: " .. tostring(err)); NCPD.ring = nil end
    end
    if NCPD.offer then
        local ok, err = pcall(updateOffer, dt)
        if not ok then log("offer error: " .. tostring(err)); NCPD.offer = nil; hidePanel() end
    end
    if NCPD.dialog then
        local ok, err = pcall(updateDialog, dt)
        if not ok then log("dialog error: " .. tostring(err)); NCPD.dialog = nil; hidePanel() end
    end

    if NCPD.call then
        -- 4 checks a second is plenty; every frame just costs CPU in big fights
        NCPD.callTick = (NCPD.callTick or 0) + dt
        if NCPD.callTick >= 0.25 then
            NCPD.callTick = 0
            local ok, err = pcall(updateCall)
            if not ok then log("update error: " .. tostring(err)) end
        end
    elseif NCPD.save.onDuty and NCPD.save.autoDispatch and not NCPD.ring and not NCPD.dialog and not NCPD.offer then
        NCPD.timer = NCPD.timer + dt
        if NCPD.timer >= NCPD.save.dispatchEvery then
            if inCombat() then
                NCPD.timer = NCPD.save.dispatchEvery - 30   -- busy; try again soon
            else
                NCPD.timer = 0
                startCall()
            end
        end
    end
end)

registerForEvent("onDraw", function()
    if not NCPD.overlayOpen then return end
    ImGui.SetNextWindowPos(80, 300, ImGuiCond.FirstUseEver)
    ImGui.SetNextWindowSize(420, 300, ImGuiCond.FirstUseEver)
    if ImGui.Begin("NCPD Dispatch") then
        local s = NCPD.save
        ImGui.Text(("Rank: %s   Rep: %d"):format(rankName(), s.rep))
        ImGui.Text(("Calls cleared: %d   Taken alive: %d   Earned: %d"):format(s.calls, s.nonlethal, s.earned))
        ImGui.Separator()
        s.onDuty = ImGui.Checkbox("On duty (remembered)", s.onDuty)
        s.autoDispatch = ImGui.Checkbox("Automatic calls", s.autoDispatch)
        s.autoAnswer = ImGui.Checkbox("Auto-answer dispatch calls", s.autoAnswer)
        s.dispatchEvery = ImGui.SliderInt("Seconds between calls", s.dispatchEvery, 60, 900)
        if ImGui.CollapsingHeader("Call types") then
            s.bossEnabled = ImGui.Checkbox(("Surprise heavies (rep %d+)"):format(BOSS_MIN_REP), s.bossEnabled)
            if s.bossEnabled then
                s.bossChance = ImGui.SliderInt("Heavy chance %", s.bossChance, 0, 100)
            end
            s.gangWarEnabled = ImGui.Checkbox("Gang wars (rep 100+)", s.gangWarEnabled)
            s.policeCover = ImGui.Checkbox("Police don't react during calls", s.policeCover)
            s.victimsEnabled = ImGui.Checkbox("Civilians at robbery/assault scenes", s.victimsEnabled)
            s.backupEnabled = ImGui.Checkbox(("NCPD backup on big calls (rep %d+)"):format(BACKUP_MIN_REP), s.backupEnabled)
            local nb = 0
            for _, p in pairs(NCPD.bossPools) do nb = nb + #p end
            ImGui.Text(("Heavy records: %d   NCPD officers: %d"):format(nb, #NCPD.copPool))
        end
        if s.onDuty and not NCPD.call and s.autoDispatch then
            ImGui.Text(("Next call in %d s"):format(math.max(0, s.dispatchEvery - math.floor(NCPD.timer))))
        end
        ImGui.Separator()
        if NCPD.ring then
            ImGui.Text("Phone ringing: NCPD Dispatch")
            if ImGui.Button("Answer") then answerCall() end
            ImGui.SameLine()
            if ImGui.Button("Decline") then declineCall(false) end
        elseif NCPD.offer then
            local p = NCPD.offer.prep
            ImGui.Text(("Call offered: %s (%s), %d s to reply"):format(p.type.title, p.faction,
                math.max(0, math.floor(OFFER_TIMEOUT - NCPD.offer.t))))
            if ImGui.Button("Confirm") then resolveOffer(true, "key") end
            ImGui.SameLine()
            if ImGui.Button("Deny") then resolveOffer(false, "key") end
        elseif NCPD.call then
            local c, left = NCPD.call, 0
            for _, x in ipairs(c.suspects) do if not x.done then left = left + 1 end end
            ImGui.Text(("Active: %s (%s)"):format(c.type.title, c.faction))
            if c.state == "enroute" then
                local d = Vector4.Distance(Game.GetPlayer():GetWorldPosition(), c.target)
                ImGui.Text(("En route: %.0f m, %d s left"):format(d, math.max(0, math.floor(c.deadline - NCPD.now))))
            else
                ImGui.Text(("Suspects left: %d / %d"):format(left, #c.suspects))
            end
            if ImGui.Button("Abandon call") then endCall("abandoned") end
        else
            if ImGui.Button("Request call now") then startCall() end
        end
        ImGui.SameLine()
        if ImGui.Button("Rebuild NPC pools") then buildPools() end
        ImGui.Separator()
        s.gpsQuest = ImGui.Checkbox("GPS route to calls (NCPD objective)", s.gpsQuest)
        s.ncpdIcon = ImGui.Checkbox("NCPD icon on the call marker", s.ncpdIcon)
        s.phoneTexts = ImGui.Checkbox("Texts from NCPD Dispatcher", s.phoneTexts)
        ImGui.SameLine()
        if ImGui.Button("Radio check") then NCPD.sendText("radio_check") end
        ImGui.Text(("Learned street spots: %d"):format(#NCPD.spots))
        ImGui.TextWrapped("Last: " .. NCPD.lastLog)
    end
    ImGui.End()
end)

return NCPD

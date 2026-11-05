-- NCPD Dispatch: an NCPD career for V.
-- v0.2: dispatch calls arrive by phone (ring, caller-ID panel, dispatcher
-- lines); on-duty toggle and settings remembered; generated "crime in progress" calls built
-- from the game's own gang NPC records, map marker, payout, reputation, ranks.
-- Needs Cyber Engine Tweaks + Codeware (DynamicEntitySystem).

local NCPD = {
    version = "0.3.0",
    tag = "NCPDDispatch",
    overlayOpen = false,
    timer = 0,
    now = 0,                    -- game-time seconds, advanced in onUpdate
    call = nil,                 -- the active call
    ring = nil,                 -- an incoming dispatch call that is ringing
    dialog = nil,               -- dispatcher lines being shown
    panel = nil,                -- HUD widgets for the phone panel
    pools = {},                 -- faction name -> list of record id strings
    poolsBuilt = false,
    lastLog = "",
    save = {
        rep = 0, calls = 0, earned = 0, nonlethal = 0,
        -- settings (kept between sessions, so CET is only needed to change them)
        onDuty = false,
        autoDispatch = true,
        autoAnswer = true,
        dispatchEvery = 240,    -- seconds between calls while on duty
    },
}

local RING_AUTO_ANSWER = 4      -- seconds of ringing before auto-answer
local RING_TIMEOUT = 20         -- seconds before an unanswered call is missed
local MISSED_RETRY = 90         -- seconds until dispatch tries again

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

local CALL_TYPES = {
    { title = "Armed robbery in progress", min = 2, max = 3, pay = 1200, rep = 10 },
    { title = "Gang assault in progress",  min = 3, max = 4, pay = 1800, rep = 15 },
    { title = "Shots fired, multiple suspects", min = 4, max = 6, pay = 2600, rep = 25, minRep = 60 },
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

-- Show a line in the panel, or as an on-screen message if the panel failed.
local function say(title, body, seconds, color)
    if not showPanel(title, body, color) then notify(title .. ": " .. body, seconds) end
end

---------------------------------------------------------------- NPC pools

-- Build per-gang pools from TweakDB instead of hard-coding record names, so
-- calls use whatever regular gang members the game actually has.
local function buildPools()
    NCPD.pools = {}
    local want = {}
    for _, f in ipairs(FACTIONS) do want[f.id] = f.name; NCPD.pools[f.name] = {} end

    local records = TweakDB:GetRecords("gamedataCharacter_Record") or {}
    local total = 0
    for _, rec in ipairs(records) do
        pcall(function()
            local id = idStr(rec:GetID())
            if id == "" or not id:find("^Character%.") then return end
            -- skip quest / unique characters
            local low = id:lower()
            if low:find("^character%.[ms]?q%d") or low:find("quest") or low:find("boss")
                or low:find("unique") or low:find("dummy") or low:find("test") then return end
            local aff = rec:Affiliation()
            if not aff then return end
            local faction = want[idStr(aff:GetID())]
            if not faction then return end
            local rar = rec:Rarity()
            if not rar or not OK_RARITY[idStr(rar:GetID())] then return end
            table.insert(NCPD.pools[faction], id)
            total = total + 1
        end)
    end
    local parts = {}
    for _, f in ipairs(FACTIONS) do table.insert(parts, f.name .. "=" .. #NCPD.pools[f.name]) end
    log(("NPC pools built from %d records: %d usable (%s)"):format(#records, total, table.concat(parts, ", ")))
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

local function addSpot(p)
    local k = cellKey(p.x, p.y)
    if NCPD.spotCells[k] then return false end
    NCPD.spotCells[k] = true
    table.insert(NCPD.spots, { x = math.floor(p.x * 10) / 10, y = math.floor(p.y * 10) / 10, z = math.floor(p.z * 10) / 10 })
    NCPD.spotsDirty = NCPD.spotsDirty + 1
    if NCPD.spotsDirty >= 10 then writeSpots() end
    return true
end

local function loadSpots()
    local f = io.open(SPOTS_FILE, "r")
    if not f then return end
    local ok, data = pcall(json.decode, f:read("*a"))
    f:close()
    if ok and type(data) == "table" then
        for _, p in ipairs(data) do
            if p.x and p.y and p.z and not NCPD.spotCells[cellKey(p.x, p.y)] then
                NCPD.spotCells[cellKey(p.x, p.y)] = true
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
    if #cands > 0 then
        local p = cands[math.random(#cands)]
        return Vector4.new(p.x, p.y, p.z, 1), "learned", veh
    end
    local a = math.random() * math.pi * 2
    local d = lo + math.random() * (hi - lo)
    return Vector4.new(o.x + math.cos(a) * d, o.y + math.sin(a) * d, o.z, 1), "rough", veh
end

---------------------------------------------------------------- calls

local function clearMappin()
    if NCPD.call and NCPD.call.mappin then
        pcall(function() Game.GetMappinSystem():UnregisterMappin(NCPD.call.mappin) end)
        NCPD.call.mappin = nil
    end
end

local function despawnAll()
    pcall(function() Game.GetDynamicEntitySystem():DeleteTagged(NCPD.tag) end)
end

local function endCall(outcome)
    local c = NCPD.call
    if not c then return end
    clearMappin()
    if outcome == "cleared" then
        local caught = #c.suspects - c.fled
        local pay = c.type.pay + 300 * caught
        local rep = c.type.rep
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
        notify(("NCPD: Scene clear. %d eddies, %+d rep.%s"):format(pay, rep, extra), 7)
        if rankName() ~= before then notify("NCPD: Promoted to " .. rankName() .. "!", 8) end
        log(("call cleared: pay %d rep %+d (nonlethal %d/%d, fled %d)"):format(pay, rep, c.nonlethal, #c.suspects, c.fled))
    elseif outcome == "late" then
        NCPD.save.rep = math.max(0, NCPD.save.rep - 2)
        writeSave()
        notify("NCPD: Too slow, another unit took the call. -2 rep.", 6)
        log("call missed: did not arrive in time")
    else
        NCPD.save.rep = math.max(0, NCPD.save.rep - 5)
        writeSave()
        notify("NCPD: Call abandoned. Dispatch is not impressed. -5 rep.", 6)
        log("call abandoned")
    end
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
    local choices = {}
    for _, t in ipairs(CALL_TYPES) do
        if NCPD.save.rep >= (t.minRep or 0) then table.insert(choices, t) end
    end
    local ctype = choices[math.random(#choices)]
    return { type = ctype, faction = faction, count = math.random(ctype.min, ctype.max) }
end

local function setMappin(c, pos)
    if c.mappin then pcall(function() Game.GetMappinSystem():UnregisterMappin(c.mappin) end) end
    c.mappin = nil
    pcall(function()
        local data = MappinData.new()
        data.mappinType = TweakDBID.new("Mappins.DefaultStaticMappin")
        data.variant = gamedataMappinVariant.CustomPositionVariant
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
        state = "enroute", target = target, targetHow = how, pos = target,
        suspects = {}, nonlethal = 0, fled = 0, civDead = false,
        started = NCPD.now, deadline = NCPD.now + 120 + dist / 6,
    }
    setMappin(c, target)
    NCPD.call = c
    log(("call dispatched: %s, %s x%d, %.0f m away (%s target, %s)"):format(
        c.type.title, c.faction, c.count, dist, how, veh and "in vehicle" or "on foot"))
    return target
end

-- Find walkable ground at the destination now that its navmesh is loaded.
local function sceneCentre(c)
    local nav = navSystem()
    local ref = (c.targetHow == "learned") and c.target.z or Game.GetPlayer():GetWorldPosition().z
    if nav then
        for try = 1, 14 do
            local r = (try <= 3) and 0 or ((try <= 8) and 20 or 45)
            local ang = math.random() * math.pi * 2
            local p = Vector4.new(c.target.x + math.cos(ang) * r, c.target.y + math.sin(ang) * r, ref + 4, 1)
            local ok, sp = pcall(function() return nav:GetNearestNavmeshPointBelowOnlyHumanNavmesh(p, 3.0, 8) end)
            if ok and sp and (sp.x ~= 0 or sp.y ~= 0) and math.abs(sp.z - ref) < 6 then
                return sp, "at target"
            end
        end
    end
    local p, how = pickScene()   -- last resort: a spot near V
    return p, "near V (" .. how .. ")"
end

local function spawnScene(c)
    local pos, how = sceneCentre(c)
    local des = Game.GetDynamicEntitySystem()
    local pool = NCPD.pools[c.faction]
    local centred = 0
    for i = 1, c.count do
        local rec = pool[math.random(#pool)]
        local ok, id = pcall(function()
            local spec = DynamicEntitySpec.new()
            spec.recordID = TweakDBID.new(rec)
            local a = (i / c.count) * math.pi * 2
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
            table.insert(c.suspects, { id = id, record = rec, hostile = false, done = false })
        else
            log("spawn failed for " .. rec .. ": " .. tostring(id))
        end
    end
    if #c.suspects == 0 then return false end
    c.pos = pos
    c.state = "active"
    c.arrivedAt = NCPD.now
    c.lastProgress = NCPD.now
    setMappin(c, pos)
    addSpot(pos)
    log(("scene spawned: %s x%d at %.0f %.0f %.0f (%s, %d of %d at centre)"):format(
        c.faction, #c.suspects, pos.x, pos.y, pos.z, how, centred, #c.suspects))
    return true
end

-- The phone rings; the call is answered automatically or with the hotkey.
local function startCall()
    if NCPD.call or NCPD.ring or NCPD.dialog then log("a call is already active or ringing"); return end
    local prep = prepareCall()
    if not prep then return end
    NCPD.ring = { prep = prep, t = 0 }
    sound("ui_phone_incoming_call")
    local hint = NCPD.save.autoAnswer and "Connecting..." or "Answer with your NCPD answer key"
    say("INCOMING CALL", "NCPD Dispatch\n" .. hint, 6)
    log("phone ringing: " .. prep.type.title .. " / " .. prep.faction)
end

local function answerCall()
    local r = NCPD.ring
    if not r then return end
    NCPD.ring = nil
    stopSound("ui_phone_incoming_call")
    sound("ui_phone_incoming_call_stop")
    sound("ui_phone_incoming_call_positive")
    local pos = dispatchCall(r.prep)
    if not pos then
        say("NCPD DISPATCH", "Disregard, unit. Situation resolved.", 5)
        NCPD.dialog = { lines = { }, t = 0, i = 0, hold = 4 }
        return
    end
    local dir, dist = compass(Game.GetPlayer():GetWorldPosition(), pos)
    local c = NCPD.call
    NCPD.dialog = {
        t = 0, i = 0,
        lines = {
            ("%s V, this is NCPD Dispatch. You're the closest unit."):format(rankName()),
            ("We have a %s about %d meters %s of you."):format(c.type.title:lower(), dist, dir),
            ("Witnesses report %d %s. Approach with caution."):format(c.count, c.faction),
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
        NCPD.timer = math.max(0, NCPD.save.dispatchEvery - MISSED_RETRY)
        log("call missed")
    else
        say("CALL DECLINED", "NCPD Dispatch", 4, RED)
        NCPD.timer = 0
        log("call declined")
    end
    NCPD.dialog = { lines = {}, t = 0, i = 0, hold = 4 }
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

local function isDown(npc)
    local dead, defeated = false, false
    pcall(function() dead = npc:IsDead() end)
    pcall(function() defeated = ScriptedPuppet.IsDefeated(npc) end)
    return dead or defeated, dead
end

local function makeHostile(npc)
    return pcall(function()
        local agent = npc:GetAttitudeAgent()
        agent:SetAttitudeGroup(CName.new("hostile"))
        agent:SetAttitudeTowards(Game.GetPlayer():GetAttitudeAgent(), EAIAttitude.AIA_Hostile)
    end)
end

local function updateCall()
    local c = NCPD.call
    if c.state == "enroute" then
        local d = Vector4.Distance(Game.GetPlayer():GetWorldPosition(), c.target)
        if d < 150 then
            if not spawnScene(c) then
                log("no suspects spawned; call cancelled")
                clearMappin(); NCPD.call = nil; NCPD.timer = 0
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
                    s.hostile = makeHostile(npc)
                    if not s.hostile then log("could not set hostility on " .. s.record) end
                end
                local down, dead = isDown(npc)
                if down then
                    s.done = true
                    c.lastProgress = NCPD.now
                    if not dead then c.nonlethal = c.nonlethal + 1 end
                else
                    remaining = remaining + 1
                end
            else
                remaining = remaining + 1   -- not streamed in yet
            end
        end
    end
    if remaining == 0 then endCall("cleared"); return end

    -- Suspects V can't reach (stuck in geometry) shouldn't block the call:
    -- if V is at the scene, someone is already down, and nothing has
    -- changed for a minute, the rest "flee" and the call wraps up.
    local here = Vector4.Distance(Game.GetPlayer():GetWorldPosition(), c.pos) < 60
    if here and remaining < #c.suspects and NCPD.now - c.lastProgress > 60 then
        for _, s in ipairs(c.suspects) do
            if not s.done then
                s.done = true
                c.fled = c.fled + 1
                pcall(function() des:DeleteEntity(s.id) end)
            end
        end
        log(("%d suspect(s) unreachable for 60 s; counted as fled"):format(c.fled))
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
end)

registerHotkey("ncpd_call", "Request NCPD call now", function() startCall() end)
registerHotkey("ncpd_answer", "Answer NCPD call", function() answerCall() end)
registerHotkey("ncpd_decline", "Decline NCPD call", function() declineCall(false) end)

registerForEvent("onUpdate", function(dt)
    NCPD.now = NCPD.now + dt
    if not Game.GetPlayer() or gamePaused() then return end

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
    if NCPD.dialog then
        local ok, err = pcall(updateDialog, dt)
        if not ok then log("dialog error: " .. tostring(err)); NCPD.dialog = nil; hidePanel() end
    end

    if NCPD.call then
        local ok, err = pcall(updateCall)
        if not ok then log("update error: " .. tostring(err)) end
    elseif NCPD.save.onDuty and NCPD.save.autoDispatch and not NCPD.ring and not NCPD.dialog then
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
        if s.onDuty and not NCPD.call and s.autoDispatch then
            ImGui.Text(("Next call in %d s"):format(math.max(0, s.dispatchEvery - math.floor(NCPD.timer))))
        end
        ImGui.Separator()
        if NCPD.ring then
            ImGui.Text("Phone ringing: NCPD Dispatch")
            if ImGui.Button("Answer") then answerCall() end
            ImGui.SameLine()
            if ImGui.Button("Decline") then declineCall(false) end
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
        ImGui.Text(("Learned street spots: %d"):format(#NCPD.spots))
        ImGui.TextWrapped("Last: " .. NCPD.lastLog)
    end
    ImGui.End()
end)

return NCPD

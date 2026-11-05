-- NCPD Dispatch: an NCPD career for V.
-- Prototype v0.1: on-duty toggle, generated "crime in progress" calls built
-- from the game's own gang NPC records, map marker, payout, reputation, ranks.
-- Needs Cyber Engine Tweaks + Codeware (DynamicEntitySystem).

local NCPD = {
    version = "0.1.0",
    tag = "NCPDDispatch",
    overlayOpen = false,
    onDuty = false,
    autoDispatch = true,
    dispatchEvery = 240,        -- seconds between calls while on duty
    timer = 0,
    now = 0,                    -- game-time seconds, advanced in onUpdate
    call = nil,                 -- the active call
    pools = {},                 -- faction name -> list of record id strings
    poolsBuilt = false,
    lastLog = "",
    save = { rep = 0, calls = 0, earned = 0, nonlethal = 0 },
}

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
                and math.abs(snapped.z - origin.z) < 15 then
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
        local pay = c.type.pay + 300 * #c.suspects
        local rep = c.type.rep
        if c.nonlethal == #c.suspects then
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
        local extra = (c.nonlethal == #c.suspects) and " All suspects taken alive: bonus." or ""
        notify(("NCPD: Scene clear. %d eddies, %+d rep.%s"):format(pay, rep, extra), 7)
        if rankName() ~= before then notify("NCPD: Promoted to " .. rankName() .. "!", 8) end
        log(("call cleared: pay %d rep %+d (nonlethal %d/%d)"):format(pay, rep, c.nonlethal, #c.suspects))
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

local function startCall()
    if NCPD.call then log("a call is already active"); return end
    if not NCPD.poolsBuilt then buildPools() end
    local faction = pickFaction()
    if not faction then log("no usable gang NPC records found; cannot dispatch"); return end

    local choices = {}
    for _, t in ipairs(CALL_TYPES) do
        if NCPD.save.rep >= (t.minRep or 0) then table.insert(choices, t) end
    end
    local ctype = choices[math.random(#choices)]
    local pos, how = pickScene()

    local des = Game.GetDynamicEntitySystem()
    local pool = NCPD.pools[faction]
    local suspects = {}
    for i = 1, math.random(ctype.min, ctype.max) do
        local rec = pool[math.random(#pool)]
        local ok, id = pcall(function()
            local spec = DynamicEntitySpec.new()
            spec.recordID = TweakDBID.new(rec)
            local a = (i / ctype.max) * math.pi * 2
            spec.position = Vector4.new(pos.x + math.cos(a) * 2.5, pos.y + math.sin(a) * 2.5, pos.z, 1)
            spec.persistState = false
            spec.persistSpawn = false
            spec.alwaysSpawned = true
            spec.tags = { NCPD.tag }
            return des:CreateEntity(spec)
        end)
        if ok and id then
            table.insert(suspects, { id = id, record = rec, hostile = false, done = false })
        else
            log("spawn failed for " .. rec .. ": " .. tostring(id))
        end
    end
    if #suspects == 0 then log("no suspects spawned; call cancelled"); return end

    local mappin
    pcall(function()
        local data = MappinData.new()
        data.mappinType = TweakDBID.new("Mappins.DefaultStaticMappin")
        data.variant = gamedataMappinVariant.CustomPositionVariant
        data.visibleThroughWalls = true
        mappin = Game.GetMappinSystem():RegisterMappin(data, pos)
    end)

    NCPD.call = {
        type = ctype, faction = faction, pos = pos, suspects = suspects,
        mappin = mappin, nonlethal = 0, started = NCPD.now, civDead = false,
    }
    notify(("NCPD DISPATCH: %s. %s suspects, %d reported. Marker set."):format(ctype.title, faction, #suspects), 8)
    log(("call started: %s, %s x%d at %.0f %.0f %.0f (%s)"):format(ctype.title, faction, #suspects, pos.x, pos.y, pos.z, how))
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

    -- abandoned if V wanders far away after a few minutes
    local d = Vector4.Distance(Game.GetPlayer():GetWorldPosition(), c.pos)
    if d > 400 and NCPD.now - c.started > 120 then endCall("abandoned") end
end

---------------------------------------------------------------- events

registerForEvent("onInit", function()
    math.randomseed(os.time())
    loadSave()
    log(("v%s loaded. Rank %s, rep %d."):format(NCPD.version, rankName(), NCPD.save.rep))
end)

registerForEvent("onShutdown", function()
    clearMappin()
    despawnAll()
end)

registerForEvent("onOverlayOpen", function() NCPD.overlayOpen = true end)
registerForEvent("onOverlayClose", function() NCPD.overlayOpen = false end)

registerHotkey("ncpd_duty", "Toggle NCPD duty", function()
    NCPD.onDuty = not NCPD.onDuty
    NCPD.timer = 0
    notify(NCPD.onDuty and ("NCPD: On duty. " .. rankName() .. ", stand by for calls.") or "NCPD: Off duty.", 5)
end)

registerHotkey("ncpd_call", "Request NCPD call now", function() startCall() end)

registerForEvent("onUpdate", function(dt)
    NCPD.now = NCPD.now + dt
    if not Game.GetPlayer() then return end
    if NCPD.cleanupAt and NCPD.now > NCPD.cleanupAt and not NCPD.call then
        despawnAll(); NCPD.cleanupAt = nil
    end
    if NCPD.call then
        local ok, err = pcall(updateCall)
        if not ok then log("update error: " .. tostring(err)) end
    elseif NCPD.onDuty and NCPD.autoDispatch then
        NCPD.timer = NCPD.timer + dt
        if NCPD.timer >= NCPD.dispatchEvery then NCPD.timer = 0; startCall() end
    end
end)

registerForEvent("onDraw", function()
    if not NCPD.overlayOpen then return end
    ImGui.SetNextWindowPos(80, 300, ImGuiCond.FirstUseEver)
    ImGui.SetNextWindowSize(420, 260, ImGuiCond.FirstUseEver)
    if ImGui.Begin("NCPD Dispatch") then
        ImGui.Text(("Rank: %s   Rep: %d"):format(rankName(), NCPD.save.rep))
        ImGui.Text(("Calls cleared: %d   Taken alive: %d   Earned: %d"):format(NCPD.save.calls, NCPD.save.nonlethal, NCPD.save.earned))
        ImGui.Separator()
        NCPD.onDuty = ImGui.Checkbox("On duty", NCPD.onDuty)
        NCPD.autoDispatch = ImGui.Checkbox("Automatic calls", NCPD.autoDispatch)
        NCPD.dispatchEvery = ImGui.SliderInt("Seconds between calls", NCPD.dispatchEvery, 60, 900)
        if NCPD.onDuty and not NCPD.call and NCPD.autoDispatch then
            ImGui.Text(("Next call in %d s"):format(math.max(0, NCPD.dispatchEvery - math.floor(NCPD.timer))))
        end
        ImGui.Separator()
        if NCPD.call then
            local c, left = NCPD.call, 0
            for _, s in ipairs(c.suspects) do if not s.done then left = left + 1 end end
            ImGui.Text(("Active: %s (%s)"):format(c.type.title, c.faction))
            ImGui.Text(("Suspects left: %d / %d"):format(left, #c.suspects))
            if ImGui.Button("Abandon call") then endCall("abandoned") end
        else
            if ImGui.Button("Request call now") then startCall() end
        end
        ImGui.SameLine()
        if ImGui.Button("Rebuild NPC pools") then buildPools() end
        ImGui.Separator()
        ImGui.TextWrapped("Last: " .. NCPD.lastLog)
    end
    ImGui.End()
end)

return NCPD

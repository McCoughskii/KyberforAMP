-- Co-Op 24/7: every human on one team, bots on the other, maps loop forever.
local cfg = require("config")

local Coop = {
    loaded = false,        -- a level is running
    sinceLoad = 0,
    sinceTick = 0,
    rotationSet = false,
    nextBotId = 1,
    level = "",
    mode = "",
}

local function log(msg) print(msg) end

local function shortMap(level)
    return (level or ""):match("([^/]+)$") or level or "?"
end

local function safe(fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then log("error: " .. tostring(err)) end
    return ok, err
end

-- Count players into humans/bots per team.
local function census()
    local c = { humans = {}, bots = { [cfg.humanTeam] = {}, [cfg.botTeam] = {} }, humanCount = 0 }
    for _, p in ipairs(PlayerManager.GetPlayers() or {}) do
        if p.isBot then
            local list = c.bots[p.team]
            if list then list[#list + 1] = p end
        else
            c.humans[#c.humans + 1] = p
            c.humanCount = c.humanCount + 1
        end
    end
    return c
end

local function botName()
    local name
    repeat
        name = string.format("%s%04d", cfg.botNamePrefix, Coop.nextBotId)
        Coop.nextBotId = Coop.nextBotId + 1
    until PlayerManager.GetPlayer(name) == nil
    return name
end

local function addBot(team)
    local bot = PlayerManager.CreatePlayer(botName())
    if bot then bot:SetTeam(team) end
end

-- Bring one team's bot count to `want`, changing at most `budget` bots.
local function adjust(list, team, want, budget)
    local have = #list
    while have < want and budget > 0 do
        addBot(team); have = have + 1; budget = budget - 1
    end
    while have > want and budget > 0 do
        list[have]:Kick("Co-Op rebalance"); list[have] = nil
        have = have - 1; budget = budget - 1
    end
    return budget
end

function Coop:Balance()
    local c = census()

    -- Keep people on the human side. Only move dead players so nobody is killed by a team swap.
    for _, p in ipairs(c.humans) do
        if p.team ~= cfg.humanTeam and not p.isAlive then
            p:SetTeam(cfg.humanTeam)
            p:SendChatMessage(cfg.chatPrefix .. "Moved you to the player team.")
        end
    end

    local humans = c.humanCount
    local wantEnemy, wantAllies = cfg.playersPerTeam, 0
    if cfg.fillHumanTeam then wantAllies = math.max(0, cfg.playersPerTeam - humans) end
    if humans == 0 and not cfg.keepBotsWhenEmpty then wantEnemy, wantAllies = 0, 0 end

    local budget = cfg.botsPerTick
    budget = adjust(c.bots[cfg.botTeam], cfg.botTeam, wantEnemy, budget)
    adjust(c.bots[cfg.humanTeam], cfg.humanTeam, wantAllies, budget)
end

function Coop:ApplyRotation()
    if self.rotationSet or not cfg.overrideRotation or #cfg.maps == 0 then return end
    local maps = {}
    for i, m in ipairs(cfg.maps) do maps[i] = m end
    if cfg.shuffle then
        for i = #maps, 2, -1 do
            local j = math.random(i); maps[i], maps[j] = maps[j], maps[i]
        end
    end
    -- Don't replay the map that is running now straight away.
    if #maps > 1 and maps[1] == self.level then maps[1], maps[#maps] = maps[#maps], maps[1] end
    MapRotation.Clear(maps[1], cfg.mode)
    for i = 2, #maps do MapRotation.AddMap(maps[i], cfg.mode) end
    self.rotationSet = true
    log(string.format("rotation set: %d maps, mode %s", #maps, cfg.mode))
end

function Coop:NextMapText()
    local ok, nxt = pcall(MapRotation.GetNextMap)
    if ok and nxt then return shortMap(nxt.level) .. " (" .. nxt.mode .. ")" end
    return "unknown"
end

function Coop:Status()
    local c = census()
    return string.format("map %s | humans %d | bots %d vs %d | next %s",
        shortMap(self.level), c.humanCount, #c.bots[cfg.humanTeam], #c.bots[cfg.botTeam], self:NextMapText())
end

-- Events ---------------------------------------------------------------

EventManager.Listen("Server:Init", function()
    -- Stop the game's auto-balance from pushing humans onto the bot team.
    safe(function()
        local k = Console.GetSettings("Kyber")
        if k then k.DisableTeamBalancing = true end
    end)
    log("loaded: " .. cfg.playersPerTeam .. " per team, mode " .. cfg.mode)
end)

EventManager.Listen("Level:Loaded", function(level, mode)
    Coop.level, Coop.mode = level, mode
    Coop.loaded, Coop.sinceLoad, Coop.sinceTick = true, 0, 0
    safe(Coop.ApplyRotation, Coop)
    if mode ~= cfg.mode then
        log("warning: level loaded in mode " .. tostring(mode) .. ", expected " .. cfg.mode)
    end
end)

EventManager.Listen("Level:Complete", function()
    Coop.loaded = false
end)

EventManager.Listen("Server:UpdatePre", function(dt)
    if not Coop.loaded then return end
    Coop.sinceLoad = Coop.sinceLoad + dt
    if Coop.sinceLoad < cfg.startDelay then return end
    Coop.sinceTick = Coop.sinceTick + dt
    if Coop.sinceTick < cfg.tickInterval then return end
    Coop.sinceTick = 0
    safe(Coop.Balance, Coop)
end)

EventManager.Listen("ServerPlayer:Joined", function(p)
    if p.isBot then return end
    safe(function()
        p:SetTeam(cfg.humanTeam)
        p:SendChatMessage(cfg.chatPrefix .. cfg.welcome)
    end)
end)

EventManager.Listen("ServerPlayer:SendMessage", function(p, msg)
    local cmd = (msg or ""):lower():match("^%s*(!%a+)")
    if cmd == "!coop" then
        p:SendChatMessage(cfg.chatPrefix .. Coop:Status())
        EventManager.SetCancelled(true)
    elseif cmd == "!next" then
        p:SendChatMessage(cfg.chatPrefix .. "Next map: " .. Coop:NextMapText())
        EventManager.SetCancelled(true)
    end
end)

-- Server console commands (AMP console): Coop.Status, Coop.PerTeam <n>, Coop.Fill <on|off>
Console.Register("Coop", "Status", "Show Co-Op bot/team status", Coop, function(self)
    return self:Status()
end)

Console.Register("Coop", "PerTeam", "Set players per team (bots fill the rest)", Coop, function(self, args)
    local n = tonumber(args)
    if not n or n < 0 or n > 32 then return "usage: Coop.PerTeam <0-32>" end
    cfg.playersPerTeam = math.floor(n)
    return "players per team = " .. cfg.playersPerTeam
end)

Console.Register("Coop", "Fill", "Fill the human team with bots (on/off)", Coop, function(self, args)
    local v = (args or ""):lower()
    if v ~= "on" and v ~= "off" then return "usage: Coop.Fill on|off" end
    cfg.fillHumanTeam = (v == "on")
    return "fill human team = " .. v
end)

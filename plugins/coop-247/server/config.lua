-- Co-Op 24/7 settings. Edit, re-zip, drop the .kbplugin in the server's plugins/ folder.
return {
    -- Game mode for every map. PlanetaryBattles = Galactic Assault.
    mode = "PlanetaryBattles",

    -- true: the plugin replaces the AMP Map Rotation setting with the list below.
    -- false: keep whatever rotation the server was started with.
    overrideRotation = true,
    shuffle = true,
    maps = {
        "S5_1/Levels/MP/Geonosis_01/Geonosis_01",
        "Levels/MP/Kamino_01/Kamino_01",
        "Levels/MP/Naboo_01/Naboo_01",
        "Levels/MP/Kashyyyk_01/Kashyyyk_01",
        "Levels/MP/Tatooine_01/Tatooine_01",
        "Levels/MP/Yavin_01/Yavin_01",
        "Levels/MP/Hoth_01/Hoth_01",
        "Levels/MP/Endor_01/Endor_01",
        "Levels/MP/DeathStar02_01/DeathStar02_01",
        "Levels/MP/Jakku_01/Jakku_01",
        "Levels/MP/Takodana_01/Takodana_01",
        "Levels/MP/StarKiller_01/StarKiller_01",
        "S1/Levels/Crait_01/Crait_01",
    },

    -- Humans all play on humanTeam; bots fill both sides up to playersPerTeam.
    humanTeam = 1,
    botTeam = 2,
    playersPerTeam = 20,
    fillHumanTeam = true,     -- top up the human side with bots when few people are on
    keepBotsWhenEmpty = true, -- false: remove all bots while no humans are online

    -- Timing (seconds).
    startDelay = 15,          -- wait after a level loads before adding bots
    tickInterval = 5,         -- how often teams are checked
    botsPerTick = 4,          -- add/remove at most this many bots per check

    botNamePrefix = "CT-",
    chatPrefix = "[Co-Op] ",
    welcome = "Welcome! Everyone plays together against the AI. Type !coop for info.",
}

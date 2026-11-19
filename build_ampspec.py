"""Generates kyber.ampspec (AMP3 template) next to this file.

Run:  python build_ampspec.py
The repo layout this expects (and AMP3 reads):
    kyber.ampspec
    scripts/kyber/kyber-install.sh
    scripts/kyber/kyber-run.sh
"""
import json
import pathlib

HERE = pathlib.Path(__file__).parent
REPO_RAW = "https://raw.githubusercontent.com/McCoughskii/KyberforAMP/main"
CONFIG_VERSION = "1"

CAT = "category.kyber:rocket_launch"
SUB = {
    "accounts": ("category.accounts:key:1", "Accounts"),
    "server": ("category.server:dns:2", "Server"),
    "rotation": ("category.rotation:map:3", "Map Rotation"),
    "mods": ("category.mods:extension:4", "Mods & Plugins"),
    "game": ("category.game:download:5", "Game Files"),
    "advanced": ("category.advanced:tune:6", "Advanced"),
}

locale = {
    "meta.name": "KYBER (Star Wars Battlefront II)",
    "meta.description": "KYBER dedicated server for Star Wars Battlefront II (2017). Peer to peer - no ports to open.",
    "category.kyber": "Kyber",
}
for key, (cat, label) in SUB.items():
    locale[cat.split(":")[0]] = label

settings = []
env = {}


def setting(field, sub, name, desc, itype="text", default="", env_name=None, enum=None, keywords="", **extra):
    s = {
        "FieldName": field,
        "ParamFieldName": field,
        "DefaultValue": default,
        "Category": CAT,
        "Subcategory": SUB[sub][0],
        "DisplayName": f"setting.{field}.name",
        "Description": f"setting.{field}.desc",
        "Keywords": keywords,
        "InputType": itype,
    }
    locale[f"setting.{field}.name"] = name
    locale[f"setting.{field}.desc"] = desc
    if enum:
        s["EnumValues"] = {}
        for value, label in enum.items():
            k = f"setting.{field}.value.{value}"
            s["EnumValues"][value] = k
            locale[k] = label
    s.update(extra)
    settings.append(s)
    if env_name:
        env[env_name] = "{{" + field + "}}"


BOOL = {"False": "Disabled", "True": "Enabled"}

setting("EAEmail", "accounts", "EA Account Email",
        "Email of an EA account that owns Star Wars Battlefront II. Maxima uses it to validate the game licence.",
        env_name="AMP_KYBER_EA_EMAIL", keywords="ea,email,maxima,login,account", Placeholder="you@example.com")
setting("EAPassword", "accounts", "EA Account Password", "Password for the EA account above.",
        itype="Password", env_name="AMP_KYBER_EA_PASSWORD", keywords="ea,password,maxima")
setting("KyberToken", "accounts", "KYBER Token",
        "Your KYBER API token. Create it once with `kyber_cli get_token` (KYBER launcher or CLI on any PC). It does not expire.",
        itype="Password", env_name="AMP_KYBER_TOKEN", keywords="kyber,token,api,auth")

setting("ServerName", "server", "Server Name", "Name shown in the KYBER server browser. Maximum 24 characters.",
        default="AMP KYBER Server", env_name="AMP_KYBER_SERVER_NAME", keywords="name,title,hostname")
setting("ServerDescription", "server", "Server Description",
        "Longer description for rules, Discord links and so on. Maximum 256 characters.",
        itype="Textarea", env_name="AMP_KYBER_SERVER_DESCRIPTION", keywords="description,motd,rules")
setting("ServerPassword", "server", "Server Password", "Password players must enter to join. Leave blank for a public server.",
        itype="Password", env_name="AMP_KYBER_SERVER_PASSWORD", keywords="password,private")
setting("MaxPlayers", "server", "Max Players", "Maximum number of players (1-64).",
        itype="number", default="40", env_name="AMP_KYBER_MAX_PLAYERS", keywords="players,slots,max",
        MinValue=1, MaxValue=64)

setting("MapRotation", "rotation", "Map Rotation",
        "Paste the base64 string from the KYBER launcher (Host tab > NEW > add maps > Export). "
        "A raw JSON array, or a plain list of entries (one per line or comma separated) also works and is encoded for you.",
        itype="Textarea", default="WyJzdXBfZ2Vvbm9zaXMiLCJzdXBfY2FzY2FkZSJd", env_name="AMP_KYBER_MAP_ROTATION",
        keywords="map,rotation,mode,level")

setting("UseMods", "mods", "Load Mod Collection",
        "Loads the mod collection extracted into the `mods` folder. In the KYBER launcher: Mods > Create New Collection > "
        "Play dropdown > Export Collection (tar), then upload and extract the tar into `mods` with the File Manager.",
        itype="checkbox", default="false", enum=BOOL, env_name="AMP_KYBER_USE_MODS", keywords="mods,collection")
setting("UsePlugins", "mods", "Enable Plugins Folder",
        "Uses the `plugins` folder as the KYBER plugins path. Plugins are experimental and unsupported by KYBER.",
        itype="checkbox", default="false", enum=BOOL, env_name="AMP_KYBER_USE_PLUGINS", keywords="plugins")

setting("EAToken", "game", "EA Token (game download)",
        "Needed only to download or verify the game (about 90 GB). Create one with `kyber_cli get_ea_token`, paste it here "
        "and press Update. EA tokens expire quickly; clear it after the download.",
        itype="Password", keywords="ea,token,download,install")
setting("GameDir", "game", "Game Directory",
        "Folder holding starwarsbattlefrontii.exe, as seen inside the shard. Leave blank for the `battlefront` folder of this server.",
        env_name="AMP_KYBER_GAME_DIR", keywords="game,path,directory,install")

setting("ModuleChannel", "advanced", "KYBER Module Channel", "Release channel of the KYBER module the server loads.",
        itype="enum", default="default", env_name="AMP_KYBER_MODULE_CHANNEL", keywords="module,channel,beta,version",
        enum={"default": "Default", "stable": "stable", "custom": "Custom (set below)"})
setting("ModuleChannelCustom", "advanced", "Custom Module Channel", "Used when the channel above is Custom, e.g. `ver/beta10`.",
        env_name="AMP_KYBER_MODULE_CHANNEL_CUSTOM", keywords="module,channel,version", Placeholder="ver/beta10")
setting("LogLevel", "advanced", "Log Level", "KYBER log verbosity.",
        itype="enum", default="info", env_name="AMP_KYBER_LOG_LEVEL", keywords="log,debug,trace",
        enum={"info": "info", "debug": "debug", "trace": "trace"})
setting("MaximaDebug", "advanced", "Maxima Debug Output", "Adds --debug to kyber_cli for troubleshooting EA login problems.",
        itype="checkbox", default="false", enum=BOOL, env_name="AMP_KYBER_MAXIMA_DEBUG", keywords="debug,maxima")
setting("KyberImage", "advanced", "KYBER Image (runtime source)",
        "The KYBER files (kyber_cli, maxima, module) are taken from this image on every Update.",
        default="ghcr.io/armchairdevelopers/kyber-server:latest", keywords="image,docker,runtime,version")
setting("WineUrl", "advanced", "Wine Build URL", "Wine build used to run the server. Default is the GE-Proton8-26 build KYBER ships.",
        default="https://github.com/GloriousEggroll/wine-ge-custom/releases/download/GE-Proton8-26/wine-lutris-GE-Proton8-26-x86_64.tar.xz",
        keywords="wine,proton,ge")
setting("$MaxUsers", "server", "Maximum Users (AMP)", "Player limit AMP uses for its own statistics.",
        itype="number", default="64", keywords="max,users", Hidden=True)


def fetch(name):
    return {
        "UpdateSource": "FetchURL",
        "UpdateStageName": f"Download {name}",
        "UpdateSourcePlatform": "Linux",
        "UpdateSourceData": f"{REPO_RAW}/scripts/kyber/{name}",
        "UpdateSourceArgs": name,
        "UpdateSourceTarget": "{{$FullRootDir}}scripts",
        "OverwriteExistingFiles": True,
    }


install_cmd = (
    "-c \"chmod +x '{{$FullRootDir}}scripts/'*.sh; "
    "KYBER_IMAGE='{{KyberImage}}' KYBER_WINE_URL='{{WineUrl}}' KYBER_GAME_DIR='{{GameDir}}' KYBER_EA_TOKEN='{{EAToken}}' "
    "'{{$FullRootDir}}scripts/kyber-install.sh' '{{$FullBaseDir}}'\""
)

spec = {
    "Id": "6b1f0c52-3e7a-4d8b-9a41-2f5c7e9d0b13",
    "TemplateSlug": "kyber",
    "Lifecycle": {
        "RootDir": "./kyber/",
        "BaseDirectory": "./kyber/",
        "ExecutableWin": "",
        "ExecutableLinux": "/bin/bash",
        "WorkingDir": "",
        "LinuxCommandLineArgs": "",
        "CommandLineArgs": "\"{{$FullRootDir}}scripts/kyber-run.sh\" \"{{$FullBaseDir}}\"",
        "CommandLineParameterFormat": "",
        "CommandLineParameterDelimiter": "",
        "ApplicationReadyMode": "Immediate",
        "ExitMethod": "OS_CLOSE",
        "ExitTimeout": "30",
        "ExitString": "",
        "ExitFile": "",
    },
    "Management": {
        "MaxUsers": 64,
        "HasReadableConsole": True,
        "HasWriteableConsole": True,
        "AdminMethod": "STDIO",
        "RCONHeartbeatCommand": "",
        "EnvironmentVariables": env,
    },
    "Metadata": {
        "DisplayName": "meta.name",
        "Description": "meta.description",
        "Author": "Serabus",
        "URL": "https://kyber.gg/",
        "DisplayImageSource": "steam:1237950",
        "EndpointURIFormat": "",
        "SpecificDockerImage": "cubecoders/amp3base:wine-devel",
        "OS": "Linux",
        "AarchSupport": "NotSupported",
        "ExtraSetupStepsURI": "https://docs.kyber.gg/g/hosting/dedicated-servers/config",
        "ConfigVersion": CONFIG_VERSION,
        "MinAMPVersion": "2.6.0.0",
    },
    "Console": {
        "AppReadyRegex": "^$",
        "UserJoinRegex": "^$",
        "UserLeaveRegex": "^$",
        "UserChatRegex": "^$",
        "UpdateAvailableRegex": "^$",
    },
    "PortReferences": {
        "AdminPortRef": "0",
        "PrimaryApplicationPortRef": "0",
        "UniversalSleepApplicationUDPPortRef": "0",
        "UniversalSleepSteamQueryPortRef": "0",
    },
    "UpdateStages": [
        {
            "UpdateSource": "CreateDirectory",
            "UpdateStageName": "Create scripts folder",
            "UpdateSourcePlatform": "Linux",
            "UpdateSourceArgs": "{{$FullRootDir}}scripts",
        },
        fetch("kyber-install.sh"),
        fetch("kyber-run.sh"),
        {
            "UpdateSource": "Executable",
            "UpdateStageName": "Install KYBER runtime, Wine and game files",
            "UpdateSourcePlatform": "Linux",
            "UpdateSourceData": "/bin/bash",
            "UpdateSourceArgs": install_cmd,
        },
    ],
    "PortRequirements": [],
    "Settings": settings,
    "ConfigFileMappings": [],
    "Locale": {"en": locale},
}

out = HERE / "kyber.ampspec"
out.write_text(json.dumps(spec, indent=2, ensure_ascii=False) + "\n", encoding="utf-8", newline="\n")
print("Wrote", out, "-", len(settings), "settings,", len(env), "env vars")

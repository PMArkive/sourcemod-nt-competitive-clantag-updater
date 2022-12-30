#include <sourcemod>
#include <neotokyo>

#pragma semicolon 1
#pragma newdecls required


#define PLUGIN_VERSION "0.4.0"

#define NEO_MAX_PLAYERS 32

// Max team name length. This is different from the team's clantag.
#define MAX_CLAN_NAME_LEN 64 + 1
#define MIN_CLAN_NAME_LEN 1
// Max clantag length, without any bracket decorators.
// Settled with Steam's max group clantag length as a reasonable value here.
#define MAX_CLAN_TAG_LEN 12 + 1
#define MIN_CLAN_TAG_LEN 2

#define CLANTAGS_CFG_VERSION 1
#define CMD_LIST_CLANS "sm_list_clantags"

#define DEBUG false

// TODO: if bot -> try get client cvar "name" -> try get clientinfo

native bool Competitive_IsLive();

public Plugin myinfo = {
	name = "NT Competitive Clantag Updater",
	description = "Update tournament team/clan names automatically.",
	author = "Rain",
	version = PLUGIN_VERSION,
	url = "https://github.com/Rainyan/sourcemod-nt-competitive-clantag-updater"
};

char g_sTag[] = "[TEAM]";
// Using dynamic array for this so we can have arbitrary amount of config-defined teams.
ArrayList g_rClans = null;

ConVar g_hCvar_JinraiName = null, g_hCvar_NsfName = null;
ConVar g_hCvar_ClantagUpdateMode = null;
ConVar g_hCvar_ConfigPath = null;

enum struct Clan {
	char name[MAX_CLAN_NAME_LEN];
	char tag[MAX_CLAN_TAG_LEN];
	// For avoiding false positives with clantags that clash with common player
	// names; for example tag "JAM" would match with a player named "Jam Lover",
	// unless case specificity is enabled. Note however that tags must be
	// whitespace-separated, so "James" would not trigger this false positive.
	bool case_sensitive;

	// For a given valid client index, returns whether the client's name
	// matches this clan's clantag pattern.
	// The clantag text is allowed to be offset from the name start
	// by max_decorator_offset chars, at most. Eg: "<(CLAN)>" would require
	// an offset of at least two for the "CLAN" part to be detected.
	bool IsMember(int client, int max_decorator_offset = 2)
	{
		char client_name[MAX_NAME_LENGTH + 1];
		if (!GetClientName(client, client_name, sizeof(client_name)))
		{
			return false;
		}

		// Clantag must be in the beginning(ish) of the name.
		int pos = StrContains(client_name, this.tag, this.case_sensitive);
		if (!NumInRange(pos, 0, max_decorator_offset))
		{
			return false;
		}

		// Name must include characters other than just the clantag,
		// because otherwise a player whose name exactly matches
		// some team's clantag will trigger a false positive.
		char name_sans_clantag[MAX_NAME_LENGTH];
		strcopy(name_sans_clantag, sizeof(name_sans_clantag),
			client_name[pos + strlen(this.tag)]);
		TrimString(name_sans_clantag);
		if (strlen(name_sans_clantag) == 0)
		{
			return false;
		}

		// Can't form decorative surrounding elements from alphanumerics,
		// because it leads to too many false positives.
		// For example, player name "asd" would match
		// the clantag "sd" otherwise.
		for (int i = 0; i < pos; ++i)
		{
			if (IsCharAlpha(client_name[i]) ||
				IsCharNumeric(client_name[i]))
			{
				return false;
			}
		}

		return true;
	}
}

// These enums are checked as ranges in the code,
// please check for side effects before reordering.
enum {
	CLANTAG_MODE_DISABLED = 0,
	CLANTAG_MODE_ONLY_MANUAL,
	CLANTAG_MODE_ONLY_AUTOMATIC,
	CLANTAG_MODE_BOTH,

	NUM_CLANTAG_MODES,
	LARGEST_CLANTAG_MODE = (NUM_CLANTAG_MODES - 1)
};

public void OnPluginStart()
{
	CreateConVar("sm_competitive_clantag_updater_version", PLUGIN_VERSION,
		"NT Competitive Clantag Updater plugin version.", FCVAR_DONTRECORD);

	g_hCvar_ClantagUpdateMode = CreateConVar("sm_competitive_clantag_mode", "3",
		"Operation mode. 0: disabled, 1: only manual \"sm_team\" clantag setting, 2: only automatic clantag setting, 3: allow both manual and automatic clantag setting.",
		_, true, CLANTAG_MODE_DISABLED * 1.0, true, LARGEST_CLANTAG_MODE * 1.0);

	g_hCvar_ConfigPath = CreateConVar("sm_competitive_clantag_cfg_file", "clantags.cfg",
		"Clantags config file name. Relative to SourceMod's \"configs\" folder. Must exist. Changing this value will force a clantags config reload.");
	g_hCvar_ConfigPath.AddChangeHook(CvarChanged_ConfigPath);

	RegConsoleCmd("sm_team", Cmd_SetTeamName);

	RegAdminCmd("sm_reload_clantags", Cmd_ReloadClantags, ADMFLAG_GENERIC,
		"Reload the clantags config from disk.");
	RegAdminCmd(CMD_LIST_CLANS, Cmd_ListClantags, ADMFLAG_GENERIC,
		"List current clantag bindings for confirming correctness.");

	if (!HookEventEx("player_team", Event_PlayerTeam, EventHookMode_Post)) {
		SetFailState("Failed to hook event \"player_team\"");
	}
	else if (!HookEventEx("player_changename", Event_PlayerChangeName, EventHookMode_Post)) {
		SetFailState("Failed to hook event \"player_changename\"");
	}

	AutoExecConfig();
	ReadClanConfig();
}

public void OnAllConfigsExecuted()
{
	// OnAllConfigsExecuted implies OnAllPluginsLoaded, so this is safe to call here.
	UpdateTeamNames(true);
}

public void OnAllPluginsLoaded()
{
	g_hCvar_JinraiName = FindConVar("sm_competitive_jinrai_name");
	g_hCvar_NsfName = FindConVar("sm_competitive_nsf_name");
	if (g_hCvar_JinraiName == null || g_hCvar_NsfName == null) {
		SetFailState("Failed to find the competitive NT plugin cvars required. Is competitive plugin enabled?");
	}
}

public void OnClientDisconnect(int client)
{
	if (IsPlayerTeam(GetClientTeam(client)))
	{
		// Too early to reliably have the new name set at this point, so delay with a timer.
		CreateTimer(1.0, Timer_DelayedUpdateTeamNames);
	}
}

public void CvarChanged_ConfigPath(ConVar convar, const char[] oldValue, const char[] newValue)
{
	ReadClanConfig();
	UpdateTeamNames(true);
}

public Action Cmd_SetTeamName(int client, int argc)
{
	if (client == 0) {
		ReplyToCommand(client, "%s This command cannot be executed by the server.", g_sTag);
		return Plugin_Handled;
	}
	else if (g_hCvar_ClantagUpdateMode.IntValue == CLANTAG_MODE_DISABLED ||
		g_hCvar_ClantagUpdateMode.IntValue == CLANTAG_MODE_ONLY_AUTOMATIC)
	{
		ReplyToCommand(client, "%s Manual clan tag changing is currently disabled.", g_sTag);
		return Plugin_Handled;
	}
	else if (argc != 1) {
		char cmd_name[32];
		GetCmdArg(0, cmd_name, sizeof(cmd_name));
		ReplyToCommand(client, "%s Usage: %s \"Team Name In Quotes\"", g_sTag, cmd_name);
		return Plugin_Handled;
	}

	int team = GetClientTeam(client);
	if (team != TEAM_JINRAI && team != TEAM_NSF) {
		ReplyToCommand(client, "%s This command can only be used by the playing teams.", g_sTag);
		return Plugin_Handled;
	}

	char team_name_before[MAX_CLAN_NAME_LEN];
	GetConVarString((team == TEAM_JINRAI) ? g_hCvar_JinraiName : g_hCvar_NsfName,
		team_name_before, sizeof(team_name_before));

	char team_name[MAX_CLAN_NAME_LEN];
	if (GetCmdArg(1, team_name, sizeof(team_name)) < 1) {
		ReplyToCommand(client, "%s Failed to parse the team name provided.", g_sTag);
		return Plugin_Handled;
	}

	if (StrEqual(team_name, ((team == TEAM_JINRAI) ? "NSF" : "Jinrai"), false)) {
		ReplyToCommand(client, "%s %s can't use %s as their name.",
			g_sTag,
			(team == TEAM_JINRAI) ? "Jinrai" : "NSF",
			(team == TEAM_JINRAI) ? "NSF" : "Jinrai");
		return Plugin_Handled;
	}

	SetConVarString((team == TEAM_JINRAI) ? g_hCvar_JinraiName : g_hCvar_NsfName, team_name);

	char client_name[MAX_NAME_LENGTH];
	GetClientName(client, client_name, sizeof(client_name));

	// Competitive plugin may forbid the team cvar name change,
	// usually if trying to set team name identical to the opponent's team name.
	// Checking for that case here to avoid confusion.
	GetConVarString((team == TEAM_JINRAI) ? g_hCvar_JinraiName : g_hCvar_NsfName,
		team_name, sizeof(team_name));
	if (StrEqual(team_name_before, team_name)) {
		ReplyToCommand(client, "%s Team name was not changed from previous value.", g_sTag);
		ReplyToCommand(client, "%s Are you trying to set your name to same value as the other team, or was your team name already set?", g_sTag);
		return Plugin_Handled;
	}

	PrintToChatAll("%s Player %s has set %s team name to: %s",
		g_sTag,
		client_name,
		(team == TEAM_JINRAI) ? "Jinrai" : "NSF",
		team_name);

	return Plugin_Handled;
}

public Action Cmd_ReloadClantags(int client, int argc)
{
	int num_clans_read = ReadClanConfig();
	ReplyToCommand(client, "%s Read %d clans from config.", g_sTag, num_clans_read);
	ReplyToCommand(client, "You can use %s to verify all teams were loaded correctly.", CMD_LIST_CLANS);

	UpdateTeamNames(true);

	return Plugin_Handled;
}

public Action Cmd_ListClantags(int client, int argc)
{
#if DEBUG
	PrintToServer("[DEBUG] Len: %d, BlockSize: %d", g_rClans.Length, g_rClans.BlockSize);
#endif
	PrintToConsole(client, "\n%s Clan names, and their detection patterns:", g_sTag);
	Clan clan;
	for (int i = 0; i < g_rClans.Length; ++i)
	{
		g_rClans.GetArray(i, clan, sizeof(clan));
		PrintToConsole(client, "%s Team \"%s\" == \"%s\"",
			g_sTag, clan.name, clan.tag);
	}
	PrintToConsole(client, "");

	ReplyToCommand(client, "%s Clan tags have been listed in your console.", g_sTag);

	return Plugin_Handled;
}

bool IsPlayerTeam(int team)
{
	return team == TEAM_JINRAI || team == TEAM_NSF;
}

public void Event_PlayerTeam(Event event, const char[] name, bool dontBroadcast)
{
	PrintToServer("Event_PlayerTeam: %d, %d",
		event.GetInt("team"),
		event.GetInt("oldteam"));
	// Only trigger when someone joins a playable team.
	if (IsPlayerTeam(event.GetInt("team")) || IsPlayerTeam(event.GetInt("oldteam")))
	{
		// Too early to reliably have the new name set at this point, so delay with a timer.
		CreateTimer(1.0, Timer_DelayedUpdateTeamNames);
	}
}

public void Event_PlayerChangeName(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	// Only need to update teams if this name changer is a Jinrai or NSF player.
	if (client != 0 && GetClientTeam(client) > TEAM_SPECTATOR) {
		// Too early to reliably have the new name set at this point, so delay with a timer.
		CreateTimer(1.0, Timer_DelayedUpdateTeamNames);
	}
}

// Whenever you need to delay the name change check for whatever reason.
public Action Timer_DelayedUpdateTeamNames(Handle timer)
{
	UpdateTeamNames();
	return Plugin_Stop;
}

void InitializeClan(Clan out_clan, const char name[MAX_CLAN_NAME_LEN],
    const char tag[MAX_CLAN_TAG_LEN], bool case_sensitive = false)
{
    strcopy(out_clan.name, sizeof(out_clan.name), name);
    strcopy(out_clan.tag, sizeof(out_clan.tag), tag);
    out_clan.case_sensitive = case_sensitive;
}

// Reads clan info from config file.
// Returns the number of valid team entries found in the config.
int ReadClanConfig()
{
	char filename[PLATFORM_MAX_PATH];
	g_hCvar_ConfigPath.GetString(filename, sizeof(filename));
	char path[PLATFORM_MAX_PATH];
	if (BuildPath(Path_SM, path, sizeof(path), "configs/%s", filename) <= 0)
	{
		ThrowError("Failed to build path");
	}
	else if (!FileExists(path))
	{
		ThrowError("Config file doesn't exist: \"%s\"", path);
	}

	KeyValues kv = new KeyValues("cfg_clantags");
	if (!kv.ImportFromFile(path))
	{
		delete kv;
		ThrowError("Failed to import cfg to keyvalues: \"%s\"", path);
	}

	int version = kv.GetNum("version");
	if (version == 0)
	{
		delete kv;
		ThrowError("Invalid config version or no version found");
	}
	else if (version != CLANTAGS_CFG_VERSION)
	{
		delete kv;
		ThrowError("Unsupported config version %d (expected version %d)",
			version, CLANTAGS_CFG_VERSION);
	}

	if (g_rClans == null)
	{
		// Estimate 16 teams max initially.
		// Since this is a dynamic array, it'll grow to accomodate as needed.
		g_rClans = new ArrayList(sizeof(Clan), 16);
	}
	g_rClans.Clear();
	int num_clans = 0;
	if (kv.JumpToKey("team"))
	{
		char name[MAX_CLAN_NAME_LEN];
		char tag[MAX_CLAN_TAG_LEN];
		Clan c;
		do {
			kv.GetString("name", name, sizeof(name));
			kv.GetString("tag", tag, sizeof(tag));
			TrimString(name);
			TrimString(tag);
			if (strlen(name) < MIN_CLAN_NAME_LEN ||
				strlen(tag) < MIN_CLAN_TAG_LEN)
			{
				LogError("Team name must be at least %d characters long \
and team tag must be at least %d characters long \
(name was \"%s\", tag was \"%s\")",
					MIN_CLAN_NAME_LEN, MIN_CLAN_TAG_LEN, name, tag);
				continue;
			}

			bool case_sensitive = (kv.GetNum("case_sensitive") == 0) ? false : true;

			InitializeClan(c, name, tag, case_sensitive);
			g_rClans.PushArray(c, sizeof(c));

			++num_clans;
		} while (kv.GotoNextKey());
	}

	delete kv;
	return num_clans;
}

// Looks for clan tags from both teams' player names, and tries to detect which teams they represent.
// If clans were found, updates the nt_competitive plugin cvar clan tags accordingly.
// If the optional "force" boolean is set, will process the update no matter what.
void UpdateTeamNames(bool force = false)
{
	if (!force)
	{
		if (g_hCvar_ClantagUpdateMode.IntValue <= CLANTAG_MODE_ONLY_MANUAL)
		{
			return;
		}
		// Because we're using relatively heavy dynamic array based structures,
		// this name parsing is not super fast. So only do it when there isn't
		// a competitive game live to minimize the changes of introducing a lagspike.
		if (Competitive_IsLive())
		{
			return;
		}
	}

	char ignore_clan[MAX_CLAN_TAG_LEN];
	char previous_team_name_jinrai[MAX_CLAN_NAME_LEN];
	char previous_team_name_nsf[MAX_CLAN_NAME_LEN];
	g_hCvar_JinraiName.GetString(previous_team_name_jinrai, sizeof(previous_team_name_jinrai));
	g_hCvar_NsfName.GetString(previous_team_name_nsf, sizeof(previous_team_name_nsf));

	g_hCvar_JinraiName.RestoreDefault();
	g_hCvar_NsfName.RestoreDefault();

	Clan clan;
	for (int team = TEAM_JINRAI; team <= TEAM_NSF; ++team)
	{
		DataPack filters = new DataPack();
		filters.WriteCell(team);
		filters.WriteString(ignore_clan);
		SortADTArrayCustom(g_rClans, SortClans, filters);
		filters.Reset();
		filters.ReadCell();
		char dummy[1];
		filters.ReadString(dummy, sizeof(dummy));
		int num_members = filters.ReadCell();
		delete filters;

		ConVar team_cvar = (team == TEAM_NSF) ? g_hCvar_NsfName : g_hCvar_JinraiName;

		if (num_members == 0)
		{
			continue;
		}

		g_rClans.GetArray(0, clan, sizeof(clan));
		strcopy(ignore_clan, sizeof(ignore_clan), clan.tag);
		// Only announce new team name if it was actually changed.
		if (!StrEqual(((team == TEAM_NSF) ? previous_team_name_nsf : previous_team_name_jinrai), clan.name))
		{
			team_cvar.SetString(clan.name);
			PrintToChatAll("%s Detected a team in %s. Setting the team name as: %s",
				g_sTag,
				(team == TEAM_NSF) ? "NSF" : "Jinrai",
				clan.name
			);
		}
	}
}

// Sort comparison function for ADT Array elements of the Clans array.
// We sort by amount of clients hailing each clans' clantag.
//
// Filters must contain a DataPack with structure:
//     <int> team index,
//     <char[]> clantag block filter,
//
// The team index filter only processes clients of that team.
// The clantag filter will ignore the clan using that clantag.
// If you don't want to filter by clantag, pass in an empty string for it.
//
// Returns: qsort return value
int SortClans(int index1, int index2, Handle array, Handle filters)
{
	int team_index_pass_filter;
	char clantag_block_filter[MAX_CLAN_TAG_LEN];

	view_as<DataPack>(filters).Reset();
	team_index_pass_filter = view_as<DataPack>(filters).ReadCell();
	view_as<DataPack>(filters).ReadString(clantag_block_filter, sizeof(clantag_block_filter));

	Clan clan1, clan2;
	g_rClans.GetArray(index1, clan1, sizeof(clan1));
	g_rClans.GetArray(index2, clan2, sizeof(clan2));

	int team1_members, team2_members;
	for (int client = 1; client < MaxClients; ++client)
	{
		// Can't detect bot names with GetClientName reliably,
		// so filtering fake clients entirely here to avoid debug confusion.
		if (!IsClientInGame(client) || IsFakeClient(client))
		{
			continue;
		}

		int team = GetClientTeam(client);
		if (filters != INVALID_HANDLE)
		{
			if (team != team_index_pass_filter)
			{
				continue;
			}
		}
		else if (team <= TEAM_SPECTATOR)
		{
			continue;
		}

		if (clan1.IsMember(client) &&
			!StrEqual(clantag_block_filter, clan1.tag, clan1.case_sensitive))
		{
			++team1_members;
		}
		else if (clan2.IsMember(client) &&
			!StrEqual(clantag_block_filter, clan2.tag, clan2.case_sensitive))
		{
			++team2_members;
		}
	}

	if (team1_members == team2_members)
	{
		view_as<DataPack>(filters).WriteCell(0);
		return 0;
	}

	if (team1_members > team2_members)
	{
		view_as<DataPack>(filters).WriteCell(team1_members);
		return -1;
	}

	view_as<DataPack>(filters).WriteCell(team2_members);
	return 1;
}

// For number num, returns whether it is bound inside the range (inclusive).
bool NumInRange(int num, int min, int max)
{
	return num >= min && num <= max;
}
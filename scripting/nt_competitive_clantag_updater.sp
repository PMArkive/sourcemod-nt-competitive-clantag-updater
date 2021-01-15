#pragma semicolon 1

#include <sourcemod>

#include <neotokyo>

#pragma newdecls required

#define PLUGIN_VERSION "0.1.1"

public Plugin myinfo = {
	name = "NT Competitive Clantag Updater",
	description = "Update tournament team/clan names automatically.",
	author = "Rain",
	version = PLUGIN_VERSION,
	url = "https://github.com/Rainyan/sourcemod-nt-competitive-clantag-updater"
};

char g_sTag[] = "[TEAM]";

// Based on the WW2021 registered teams.
#define NUM_TEAMS 12

// Whether clan tag detection should be case sensitive.
// Clan tags are only detected at the beginning of names,
// so false positives are rare, but this can be toggled if they occur.
#define CLAN_TAGS_COMPARE_IS_CASE_SENSITIVE false

// TODO: move the teams data into a config file

// These are the name tags used to detect a clan player.
// They need to be in the same order as team_names below.
char team_tags[NUM_TEAMS][] = {
	"AHNS",
	"BONK",
	"PIGA",
	"幽霊団",
	"NaT",
	"RENRAKU",
	"RENRUKA",
	"dF",
	"OP",
	"NTST",
	"PR1SM",
	"NX"
};
// Note that any names longer than TEAM_NAME_MAX_LEN (nt_competitive base define,
// value 64) will get truncated by the comp plugin.
#define LONGEST_CLAN_NAME_LEN (40 + 1) // be sure to update this if changing the names below
char team_names[NUM_TEAMS][LONGEST_CLAN_NAME_LEN] = {
	"All Hammer, No Sickle",
	"Bonkurazu",
	"Pwyllgor Imperialaeth Gwrth-Americanaidd",
	"Ghost Brigade",
	"NaT°",
	"RENRAKU",
	"RENRUKA",
	"Road To Deepfrog",
	"Sweaty Tryhard Operation Phoenix",
	"Near The Spinning Tree",
	"PR1SM",
	"NoXp"
};

ConVar g_hCvar_JinraiName = null, g_hCvar_NsfName = null;
ConVar g_hCvar_ClantagUpdateMode = null;

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
	
	RegConsoleCmd("sm_team", Cmd_SetTeamName);
	
	RegAdminCmd("sm_list_clantags", Cmd_ListClantags, ADMFLAG_GENERIC,
		"List current clantag bindings for confirming correctness.");
	
	if (!HookEventEx("player_team", Event_PlayerTeam, EventHookMode_Post)) {
		SetFailState("Failed to hook event \"player_team\"");
	}
	else if (!HookEventEx("player_changename", Event_PlayerChangeName, EventHookMode_Post)) {
		SetFailState("Failed to hook event \"player_changename\"");
	}
	
	AutoExecConfig();
}

public void OnAllConfigsExecuted()
{
	// OnAllConfigsExecuted implies OnAllPluginsLoaded, so this is safe to call here.
	UpdateTeamNames();
}

public void OnAllPluginsLoaded()
{
	g_hCvar_JinraiName = FindConVar("sm_competitive_jinrai_name");
	g_hCvar_NsfName = FindConVar("sm_competitive_nsf_name");
	if (g_hCvar_JinraiName == null || g_hCvar_NsfName == null) {
		SetFailState("Failed to find the competitive NT plugin cvars required. Is competitive plugin enabled?");
	}
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
	
	char team_name_before[LONGEST_CLAN_NAME_LEN];
	GetConVarString((team == TEAM_JINRAI) ? g_hCvar_JinraiName : g_hCvar_NsfName,
		team_name_before, sizeof(team_name_before));
	
	char team_name[LONGEST_CLAN_NAME_LEN];
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

public Action Cmd_ListClantags(int client, int argc)
{
	PrintToConsole(client, "\n%s Clan names, and their detection patterns:", g_sTag);
#if CLAN_TAGS_COMPARE_IS_CASE_SENSITIVE
	PrintToConsole(client, "Detection patterns are case sensitive: yes.\n");
#else
	PrintToConsole(client, "Detection patterns are case sensitive: no.\n");
#endif

	for (int team = 0; team < NUM_TEAMS; ++team) {
		PrintToConsole(client, "%s Team \"%s\" == \"%s\"",
			g_sTag, team_names[team], team_tags[team]);
	}
	PrintToConsole(client, " ");
	
	ReplyToCommand(client, "%s Clan tags have been listed in your console.", g_sTag);
	
	return Plugin_Handled;
}

public void Event_PlayerTeam(Event event, const char[] name, bool dontBroadcast)
{
	// Only need to update teams if Jinrai or NSF had a player change.
	// This will also detect relevant player disconnects.
	if (event.GetInt("team") > TEAM_SPECTATOR || event.GetInt("oldteam") > TEAM_SPECTATOR) {
		UpdateTeamNames();
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

// Look for clan tags from both teams' player names, and try to detect which teams they represent.
// If clans were found, update the nt_comp plugin clan tags accordingly.
void UpdateTeamNames()
{
	if (g_hCvar_ClantagUpdateMode.IntValue <= CLANTAG_MODE_ONLY_MANUAL) {
		return;
	}
	
#define INDEX_JINRAI 0
#define INDEX_NSF 1
#define NUM_TEAM_INDICES 2
	int num_clan_players_in_team[NUM_TEAM_INDICES][NUM_TEAMS];
	char client_name[MAX_NAME_LENGTH];
	
	for (int team = 0; team < NUM_TEAM_INDICES; ++team) {
		for (int client = 1; client <= MaxClients; ++client) {
			// Can't detect bot names with GetClientName reliably, so filtering fake clients entirely here to avoid debug confusion.
			if (!IsClientInGame(client) || IsFakeClient(client) || TeamIndexToTeamArrIndex(GetClientTeam(client)) != team) {
				continue;
			}
			
			GetClientName(client, client_name, sizeof(client_name));
			
			int num_tags_contained_in_name = 0;
			int tag_index_contained_in_name;
			for (int team_index = 0; team_index < sizeof(team_tags); ++team_index) {
				int contains_pos = StrContains(client_name, team_tags[team_index], CLAN_TAGS_COMPARE_IS_CASE_SENSITIVE);
				// Checking for charpos 1, because some clans use a "[TAG]" style or similar, where the 0th char is a stylized character like '[' etc.
				if (contains_pos == 0 || contains_pos == 1) {
					++num_tags_contained_in_name;
					tag_index_contained_in_name = team_index;
				}
			}
			
			// Either no tag was recognized, or multiple tags were.
			// In any case, can't figure out which team tag this player actually hails.
			if (num_tags_contained_in_name != 1) {
				continue;
			}
			
			++num_clan_players_in_team[team][tag_index_contained_in_name];
		}
	}
	
	int plurality_team_indices[NUM_TEAM_INDICES];
	for (int team = 0; team < NUM_TEAM_INDICES; ++team) {
		plurality_team_indices[team] = GetPluralityOfArray(
			num_clan_players_in_team[team], sizeof(num_clan_players_in_team[]));
	}
	
	// Teams had equal representation of clan players, or nobody is hailing a clan tag.
	// Can't detect team names in this case, so silently reset both teams to default name.
	if (plurality_team_indices[INDEX_JINRAI] == plurality_team_indices[INDEX_NSF]) {
		g_hCvar_JinraiName.SetString("Jinrai");
		g_hCvar_NsfName.SetString("NSF");
		return;
	}
	
	char previous_team_name[LONGEST_CLAN_NAME_LEN];
	// Actually set the clan name for Jinrai if there was plurality.
	if (plurality_team_indices[INDEX_JINRAI] != -1) {
		g_hCvar_JinraiName.GetString(previous_team_name, sizeof(previous_team_name));
		// Only announce new team name if it was actually changed.
		if (!StrEqual(previous_team_name, team_names[plurality_team_indices[INDEX_JINRAI]])) {
			g_hCvar_JinraiName.SetString(team_names[plurality_team_indices[INDEX_JINRAI]]);
			PrintToChatAll("%s Detected a team in Jinrai. Setting team name as: %s", g_sTag, team_names[plurality_team_indices[INDEX_JINRAI]]);
		}
	}
	// Can't determine Jinrai clan, silently restore name to default.
	else {
		g_hCvar_JinraiName.SetString("Jinrai");
	}
	
	// Actually updates the name for Jinrai if there was plurality.
	if (plurality_team_indices[INDEX_NSF] != -1) {
		g_hCvar_NsfName.GetString(previous_team_name, sizeof(previous_team_name));
		// Only announce new team name if it was actually changed.
		if (!StrEqual(previous_team_name, team_names[plurality_team_indices[INDEX_NSF]])) {
			g_hCvar_NsfName.SetString(team_names[plurality_team_indices[INDEX_NSF]]);
			PrintToChatAll("%s Detected a team in NSF. Setting team name as: %s", g_sTag, team_names[plurality_team_indices[INDEX_NSF]]);
		}
	}
	// Can't determine NSF clan, silently restore name to default.
	else {
		g_hCvar_NsfName.SetString("NSF");
	}
}

// Helper function to convert game team indices to the 0-1 array indices used specifically in UpdateTeamNames()
static int TeamIndexToTeamArrIndex(int team)
{
	if (team != TEAM_JINRAI && team != TEAM_NSF) {
		ThrowError("Unexpected team index: %d", team);
	}
	return team == TEAM_JINRAI ? INDEX_JINRAI : INDEX_NSF;
}

//	Returns the array index containing the largest positive value in an integer array,
//	or returns -1 if:
//		- The array has less than 1 elements
//		- The array has any elements with a negative value
//		- The array has multiple elements with the largest value (ie. couldn't determine a single plurality)
int GetPluralityOfArray(const int[] array, const int num_elements)
{
	int largest_index;
	int num_with_largest_index;
	
	for (int i = 0; i < num_elements; ++i) {
		if (array[i] < 0) {
			return -1;
		}
		else if (array[i] == 0) {
			continue;
		}
		else if (array[i] == largest_index) {
			++num_with_largest_index;
		}
		else if (array[i] > largest_index) {
			largest_index = i;
			num_with_largest_index = 1;
		}
	}
	
	return num_with_largest_index == 1 ? largest_index : -1;
}

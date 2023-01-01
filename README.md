# sourcemod-nt-competitive-clantag-updater
A complementary SM plugin for the Neotokyo competitive plugin. Sets competitive team names automatically based on clantags.

The team names are updated on:
* Player name change
* Player disconnect
* Player join (Jinrai/NSF)

The names will only be updated when a nt_competitive match is not live.

# Requirements

## Building
* SourceMod 1.10 or newer
* [Neotokyo include](https://github.com/softashell/sourcemod-nt-include/blob/master/scripting/include/neotokyo.inc)

## Plugins
* Server must be running the [nt_competitive](https://github.com/Rainyan/sourcemod-nt-competitive) plugin

# Installation
* Place the compiled plugin .smx binary in the `addons/sourcemod/plugins` directory.
* Place the config file in the `addons/sourcemod/configs` directory.

# Configuration

## Cvars
* `sm_competitive_clantag_mode`: Operation mode. 0: disabled, 1: only manual "sm_team" clantag setting, 2: only automatic clantag setting, 3: allow both manual and automatic clantag setting. Default: `3`
* `sm_competitive_clantag_cfg_file`: Clantags config file name. Relative to SourceMod's "configs" folder. Must exist. Changing this value will force a clantags config reload. Useful to modify if you're running multiple competitions with unique clantag configs for each. Default: `clantags.cfg`

## User commands:
* `sm_team`: If "sm_competitive_clantag_mode" allows manual team setting, this can be used to manually set your team's name.

## Admin commands:
* `sm_reload_clantags`: Reload the clantags config from disk.
* `sm_list_clantags`: List current clantag bindings for confirming correctness.

## Config file format
The config uses the Valve KeyValues format.

Root key name: `"cfg_clantags"`

Team entry syntax:
```c
"team"
{
	// Full name of the team. Clamped at 64 chars. Must be longer than 0 chars.
	"name"	"Oxygen Enjoyers"

	// The clantag, without any surrounding character art.
	// Maximum clantag length is 12 chars.
	// Minimum clantag length is 2 chars.
	// Maximum of 2 leading "vanity chars" supported;
	// eg. this would also match "<{OXY}>",
	// but not "<{(OXY)}>".
	"tag"	"OXY"

	// Optional, for setting whether the clantag is case sensitive.
	// Default is off ("0") if this is not specified.
	// To enable for a specific team's tag, use the value ("1").
	// Used for avoiding false positives with clantags that clash with common player
	// names; for example tag "JAM" would match with a player named "Jam Lover",
	// unless case specificity is enabled. Note however that tags must be
	// whitespace-separated, so "James" would not trigger this false positive.
	"case_sensitive" "0"
}
```

# sourcemod-nt-competitive-clantag-updater
A complementary SM plugin for the Neotokyo competitive plugin. Sets competitive team names automatically based on clantags.

# Building
## Requirements
* SourceMod 1.10 or newer
* [Neotokyo include](https://github.com/softashell/sourcemod-nt-include/blob/master/scripting/include/neotokyo.inc)

# Installation
* Place the compiled plugin .smx binary in the `sourcemod/addons/plugins` directory.
* Place the config file in the `sourcemod/configs` directory.

# Config format
The config uses the Valve KeyValues format.

Team entry syntax:
```c
"team"
{
	// Full name of the team. Clamped at 64 chars.
	"name"	"Oxygen Enjoyers"

	// The clantag, without any surrounding character art.
	// Maximum clantag length is 12 chars.
	// Maximum of 2 leading "vanity chars" supported;
	// eg. this would also match "<{OXY}>",
	// but not "<{(OXY)}>".
	"tag"	"OXY"

	// Optional, for setting whether the clantag is case sensitive.
	// Default is off if this is not specified.
	// Used for avoiding false positives with clantags that clash with common player
	// names; for example tag "JAM" would match with a player named "Jam Lover",
	// unless case specificity is enabled. Note however that tags must be
	// whitespace-separated, so "James" would not trigger this false positive.
	"case_sensitive" "0"
}
```

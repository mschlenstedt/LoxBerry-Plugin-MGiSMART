#!/bin/sh

# Runs as loxberry after an upgrade, once the new plugin files are in place.
# Moves back what preupgrade.sh set aside before purge_installation() wiped the
# plugin's config and data directories.
#
# postroot.sh runs after this one and takes care of permissions, of reinstalling
# the gateway should the restore have failed, and of starting it again.
#
# We add 5 arguments when executing the script:
# command <TEMPFOLDER> <NAME> <FOLDER> <VERSION> <BASEFOLDER>

ARGV3=$3
ARGV5=$5

CONFIGDIR="$ARGV5/config/plugins/$ARGV3"
DATADIR="$ARGV5/data/plugins/$ARGV3"
CONFIG_STASH="$ARGV5/config/plugins/.$ARGV3.upgrade"
DATA_STASH="$ARGV5/data/plugins/.$ARGV3.upgrade"

# Moves every entry back, overwriting whatever the archive shipped under the
# same name - the user's own configuration wins over a packaged default. Entries
# are moved one by one rather than the directory as a whole, because the core
# has already recreated the target and may have copied files into it.
#
# The globs cover dotfiles too: the generated .env lives in the config directory.
restore_stash()
{
	stash="$1"
	target="$2"
	label="$3"

	[ -d "$stash" ] || return 0

	echo "<INFO> Restoring $label"
	mkdir -p "$target"

	for entry in "$stash"/* "$stash"/.[!.]* "$stash"/..?*; do
		[ -e "$entry" ] || continue
		name=$(basename "$entry")
		rm -rf "$target/$name"
		mv "$entry" "$target/$name" || echo "<WARNING> Could not restore $name"
	done

	rmdir "$stash" 2>/dev/null || rm -rf "$stash"
	return 0
}

restore_stash "$CONFIG_STASH" "$CONFIGDIR" "the configuration"
restore_stash "$DATA_STASH" "$DATADIR" "the gateway installation"

exit 0

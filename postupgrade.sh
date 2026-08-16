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

# Whether the user had the gateway stopped, decided BEFORE the stash is consumed.
#
# The archive ships config/gateway_stopped.cfg so a fresh installation does not
# start an unconfigured gateway. On an upgrade the core copies that file in as
# well, which would stop a gateway that was happily running. The stash is the
# authority on what the user actually wanted, so the flag is reconciled against
# it below rather than being left to whichever copy landed last.
if [ -d "$CONFIG_STASH" ]; then
	HAD_STASH=1
	[ -e "$CONFIG_STASH/gateway_stopped.cfg" ] && WAS_STOPPED=1 || WAS_STOPPED=0
else
	HAD_STASH=0
	WAS_STOPPED=0
fi

restore_stash "$CONFIG_STASH" "$CONFIGDIR" "the configuration"
restore_stash "$DATA_STASH" "$DATADIR" "the gateway installation"

if [ "$HAD_STASH" = "1" ] && [ "$WAS_STOPPED" = "0" ]; then
	if [ -e "$CONFIGDIR/gateway_stopped.cfg" ]; then
		echo "<INFO> The gateway was running before the upgrade - clearing the packaged stop flag"
		rm -f "$CONFIGDIR/gateway_stopped.cfg"
	fi
fi

exit 0

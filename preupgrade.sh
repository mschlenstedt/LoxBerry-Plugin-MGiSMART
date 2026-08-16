#!/bin/sh

# Runs as loxberry before an upgrade, right after preroot.
#
# Immediately after this script, plugininstall.pl calls purge_installation(),
# which deletes config/, bin/, data/, templates/ and webfrontend/ of this plugin
# before the new files are copied in. For this plugin that would take out the
# whole gateway installation: the unpacked release, the venv, and possibly a
# private CPython of over 100 MB - all of which would then have to be downloaded
# and rebuilt on every single plugin upgrade.
#
# So config/ and data/ are moved aside here and moved back by postupgrade.sh.
#
# MOVED, not copied. purge_installation() removes exactly
# "<...>/plugins/<folder>/", so a sibling directory next to it survives
# untouched. A rename within the same filesystem is instant and costs nothing,
# whereas copying into /tmp would be both slow and dangerous - /tmp is a tmpfs
# on LoxBerry, and the gateway data would have to fit into RAM.
#
# log/ is not saved: purge_installation() only deletes the log folder when
# called with "all", which happens on uninstall, not on upgrade.
#
# We add 5 arguments when executing the script:
# command <TEMPFOLDER> <NAME> <FOLDER> <VERSION> <BASEFOLDER>

ARGV3=$3
ARGV5=$5

WATCHDOG="$ARGV5/bin/plugins/$ARGV3/watchdog.pl"

CONFIGDIR="$ARGV5/config/plugins/$ARGV3"
DATADIR="$ARGV5/data/plugins/$ARGV3"
# A leading dot keeps these out of the way of plugin folder names, which are
# always plain lowercase.
CONFIG_STASH="$ARGV5/config/plugins/.$ARGV3.upgrade"
DATA_STASH="$ARGV5/data/plugins/.$ARGV3.upgrade"

if [ -x "$WATCHDOG" ]; then
	echo "<INFO> Stopping the gateway for the upgrade"
	# Ended through the watchdog's own probe rather than --action=stop, which
	# would set the manual stop marker and make the upgrade look like a
	# deliberate stop afterwards.
	PID=$("$WATCHDOG" --action=pid 2>/dev/null | tr -dc '0-9')
	if [ -n "$PID" ]; then
		kill -TERM "$PID" 2>/dev/null
		i=0
		while [ "$i" -lt 20 ] && [ -d "/proc/$PID" ]; do
			sleep 0.25
			i=$((i + 1))
		done
		[ -d "/proc/$PID" ] && kill -KILL "$PID" 2>/dev/null
	fi
fi

# Leftovers from an upgrade that did not finish would otherwise shadow this run.
rm -rf "$CONFIG_STASH" "$DATA_STASH"

if [ -d "$CONFIGDIR" ]; then
	echo "<INFO> Setting the configuration aside"
	mv "$CONFIGDIR" "$CONFIG_STASH" || echo "<WARNING> Could not set the configuration aside"
fi

if [ -d "$DATADIR" ]; then
	echo "<INFO> Setting the gateway installation aside"
	mv "$DATADIR" "$DATA_STASH" || echo "<WARNING> Could not set the gateway installation aside"
fi

exit 0

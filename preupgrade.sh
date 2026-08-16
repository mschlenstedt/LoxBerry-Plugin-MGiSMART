#!/bin/sh

# Runs as loxberry before an upgrade, right after preroot and before the plugin
# files are replaced.
#
# Saves config and log, which postupgrade.sh restores.
#
# This is insurance, not a necessity today. plugininstall.pl does not delete
# config/ or data/: it creates the directory and then copies over only what the
# archive itself ships (see the "Copy Config files" and "Copy Data files"
# blocks). This plugin ships neither, so both survive an upgrade untouched. The
# backup exists so that stays true if a later version starts shipping config
# defaults.
#
# data/ is deliberately NOT backed up. It holds the gateway, the venv and
# possibly a private Python - together well over 100 MB - and /tmp on LoxBerry
# is a tmpfs, so copying that would eat RAM on small machines to protect
# against something the core does not do anyway.
#
# The gateway itself is stopped so it does not keep running against files that
# are about to be replaced; postroot.sh starts it again at the end.
#
# We add 5 arguments when executing the script:
# command <TEMPFOLDER> <NAME> <FOLDER> <VERSION> <BASEFOLDER>

ARGV1=$1
ARGV3=$3
ARGV5=$5

WATCHDOG="$ARGV5/bin/plugins/$ARGV3/watchdog.pl"
BACKUP="/tmp/${ARGV1}_upgrade"

if [ -x "$WATCHDOG" ]; then
	echo "<INFO> Stopping the gateway for the upgrade"
	# --action=restart stops without setting the manual stop marker, so an
	# upgrade does not look like a deliberate stop afterwards. There is no
	# separate "stop without marker" action, so the process is ended through the
	# watchdog's own probe.
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

echo "<INFO> Creating temporary folders for upgrading"
mkdir -p "$BACKUP/config"
mkdir -p "$BACKUP/log"

echo "<INFO> Backing up existing config files"
cp -r "$ARGV5/config/plugins/$ARGV3/" "$BACKUP/config" 2>/dev/null \
	|| echo "<INFO> No existing configuration to back up"

echo "<INFO> Backing up existing log files"
cp -r "$ARGV5/log/plugins/$ARGV3/" "$BACKUP/log" 2>/dev/null \
	|| echo "<INFO> No existing log files to back up"

exit 0

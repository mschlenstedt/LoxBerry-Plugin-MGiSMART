#!/bin/sh

# Runs as loxberry after an upgrade, once the new plugin files are in place.
# Restores what preupgrade.sh saved. postroot.sh runs after this one and takes
# care of permissions, of reinstalling the gateway if it went missing, and of
# starting it again.
#
# We add 5 arguments when executing the script:
# command <TEMPFOLDER> <NAME> <FOLDER> <VERSION> <BASEFOLDER>

ARGV1=$1
ARGV3=$3
ARGV5=$5

BACKUP="/tmp/${ARGV1}_upgrade"
CONFIGDIR="$ARGV5/config/plugins/$ARGV3"
LOGDIR="$ARGV5/log/plugins/$ARGV3"

echo "<INFO> Copy back existing config files"
if [ -d "$BACKUP/config/$ARGV3" ]; then
	mkdir -p "$CONFIGDIR"
	# The dot makes cp copy the hidden files too - the generated .env among them.
	cp -r "$BACKUP/config/$ARGV3/." "$CONFIGDIR/" \
		|| echo "<WARNING> Could not restore the configuration"
else
	echo "<INFO> No configuration backup found"
fi

echo "<INFO> Copy back existing log files"
if [ -d "$BACKUP/log/$ARGV3" ]; then
	mkdir -p "$LOGDIR"
	for logfile in "$BACKUP/log/$ARGV3"/*; do
		[ -e "$logfile" ] || continue
		target="$LOGDIR/$(basename "$logfile")"
		rm -rf "$target"
		cp -r "$logfile" "$LOGDIR/" || echo "<WARNING> Could not restore log file $logfile"
	done
fi

echo "<INFO> Remove temporary folders"
rm -rf "$BACKUP"

exit 0

#!/bin/sh

# Runs as root, as the LAST of the lifecycle scripts - plugininstall.pl executes
# preroot, preupgrade, preinstall, then copies the files, then postinstall,
# postupgrade and finally postroot. So this is also the right place to bring the
# gateway back up after an upgrade.
#
# Prepares the directories and makes sure python3-venv is available, then hands
# the installation of saic-python-mqtt-gateway to bin/gateway_pkg.sh, which runs
# as loxberry: everything it touches lives below the plugin's data directory, so
# it needs neither root nor a sudoers entry.
#
# We add 5 arguments when executing the script:
# command <TEMPFOLDER> <NAME> <FOLDER> <VERSION> <BASEFOLDER>

ARGV3=$3
ARGV5=$5

BINDIR="$ARGV5/bin/plugins/$ARGV3"
DATADIR="$ARGV5/data/plugins/$ARGV3"
CONFIGDIR="$ARGV5/config/plugins/$ARGV3"
LOGDIR="$ARGV5/log/plugins/$ARGV3"
RUNTIME_DIR="/var/run/shm/$ARGV3"
PKG="$BINDIR/gateway_pkg.sh"
WATCHDOG="$BINDIR/watchdog.pl"

if [ "$(id -u)" != "0" ]; then
	echo "<ERROR> postroot.sh must run as root."
	exit 2
fi

# Executable bits. bin/healthcheck in particular: the core finds plugin health
# checks by walking bin/ for an *executable* file of that name, so without this
# the check is silently ignored.
for file in gateway_pkg.sh watchdog.pl healthcheck; do
	[ -e "$BINDIR/$file" ] && chmod +x "$BINDIR/$file"
done
[ -e "$ARGV5/webfrontend/htmlauth/plugins/$ARGV3/ajax.cgi" ] && \
	chmod +x "$ARGV5/webfrontend/htmlauth/plugins/$ARGV3/ajax.cgi"

mkdir -p "$DATADIR" "$CONFIGDIR" "$LOGDIR" "$RUNTIME_DIR"
chown -R loxberry:loxberry "$DATADIR" "$CONFIGDIR" "$LOGDIR" "$RUNTIME_DIR"
chmod 0750 "$RUNTIME_DIR"

# The gateway needs its own venv; on a minimal system the module is missing.
if ! python3 -c "import venv" >/dev/null 2>&1; then
	echo "<INFO> Installing python3-venv"
	DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends python3-venv \
		|| echo "<WARNING> Could not install python3-venv. The gateway installation will fail."
fi

# An upgrade that died between preupgrade.sh and postupgrade.sh leaves the old
# installation sitting in the stash. Recover it rather than throwing away a
# working gateway and 100+ MB of interpreter; if the live directory is fine
# already, the stash is stale and goes.
DATA_STASH="$ARGV5/data/plugins/.$ARGV3.upgrade"
if [ -d "$DATA_STASH" ]; then
	if su loxberry -c "$PKG installed" 2>/dev/null; then
		echo "<INFO> Discarding a stale upgrade backup."
		rm -rf "$DATA_STASH"
	else
		echo "<INFO> Recovering the gateway installation from an interrupted upgrade."
		mkdir -p "$DATADIR"
		for entry in "$DATA_STASH"/* "$DATA_STASH"/.[!.]*; do
			[ -e "$entry" ] || continue
			rm -rf "$DATADIR/$(basename "$entry")"
			mv "$entry" "$DATADIR/" || true
		done
		rm -rf "$DATA_STASH"
		chown -R loxberry:loxberry "$DATADIR"
	fi
fi

# The gateway installation happens LAST, and that placement is deliberate.
#
# plugininstall.pl runs preroot, preupgrade, then purge_installation() which
# deletes config/, bin/, data/, templates/ and webfrontend/ of this plugin, then
# preinstall, copies the files, postinstall, postupgrade and finally postroot.
# preupgrade.sh moves config and data out of the purge's way and postupgrade.sh
# moves them back, so anything installed earlier than this point would either be
# purged or overwritten by that restore.
#
# Only install when there is nothing usable. Thanks to the stash the previous
# installation normally survives an upgrade, so this does not re-download the
# release and rebuild the venv every time. Updating the gateway is a separate,
# deliberate action on the Update tab.
#
# "installed" is not a mere file check: it runs the venv's interpreter and
# verifies it still satisfies the gateway's requires-python. A venv whose base
# interpreter disappeared, or one left behind by an OS downgrade, therefore
# ends up being rebuilt instead of being reported as fine.
if [ -x "$PKG" ]; then
	if su loxberry -c "$PKG installed"; then
		echo "<INFO> saic-python-mqtt-gateway is already installed and usable - keeping it."
		# Tidy up interpreters no longer referenced by the venv, e.g. left over
		# from an earlier gateway release that needed a different Python.
		su loxberry -c "$PKG prune" || true
	else
		echo "<INFO> Installing saic-python-mqtt-gateway. This takes a few minutes."
		if su loxberry -c "$PKG install"; then
			echo "<OK> saic-python-mqtt-gateway installed."
		else
			echo "<WARNING> Could not install saic-python-mqtt-gateway. Use the Update tab on the plugin page to retry."
		fi
	fi
else
	echo "<ERROR> Package helper is missing: $PKG"
fi

# Start the gateway again, but only when there is something to start with: on a
# fresh installation there is no configuration yet and no credentials to log in
# with, so the user does that on the Settings tab and starts it themselves. A
# manual stop is remembered in the config directory and survives the upgrade.
if [ -x "$WATCHDOG" ] && [ -f "$CONFIGDIR/pluginconfig.json" ]; then
	if [ -e "$CONFIGDIR/gateway_stopped.cfg" ]; then
		echo "<INFO> The gateway was stopped manually - not starting it."
	else
		su loxberry -c "$WATCHDOG --action=restart" >/dev/null 2>&1 \
			&& echo "<INFO> Gateway started." \
			|| echo "<INFO> The gateway was not started. See the plugin log for the reason."
	fi
fi

exit 0

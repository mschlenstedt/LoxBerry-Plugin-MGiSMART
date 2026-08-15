#!/bin/bash

# Installs and updates saic-python-mqtt-gateway, and reports versions for the
# web interface.
#
# Usage:
#   gateway_pkg.sh current            installed version (empty if not installed)
#   gateway_pkg.sh available [force]  newest version in the configured channel
#   gateway_pkg.sh channel            configured update channel
#   gateway_pkg.sh installed          exit 0 if gateway and venv are present
#   gateway_pkg.sh install            install (or reinstall) the gateway
#   gateway_pkg.sh upgrade            install with its own logfile, then restart
#
# Everything lives below the plugin's data directory and is owned by loxberry,
# so no action here needs root and no sudoers entry is required.
#
# The gateway source comes from a GitHub release tarball; its Python
# dependencies go into a dedicated venv. A venv rather than a system-wide pip
# install, because the gateway pins narrow version ranges of widely used
# packages (httpx, anyio, apscheduler): an update triggered from the web
# interface must never be able to break another plugin.

set -u

ACTION="${1:-}"
ARG2="${2:-}"

# Derive the plugin name and LoxBerry home from this script's own path. The
# plugin folder is dynamic - LoxBerry appends 01, 02, ... on a name collision -
# so it must never be hardcoded.
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
PLUGINNAME="$(basename "$SCRIPT_DIR")"
LBHOMEDIR="${SCRIPT_DIR%/bin/plugins/*}"

DATADIR="$LBHOMEDIR/data/plugins/$PLUGINNAME"
CONFIGDIR="$LBHOMEDIR/config/plugins/$PLUGINNAME"
RUNDIR="/var/run/shm/$PLUGINNAME"

GATEWAY_DIR="$DATADIR/gateway"
VENV_DIR="$DATADIR/venv"
VERSION_FILE="$CONFIGDIR/version.json"
PLUGIN_CONFIG="$CONFIGDIR/pluginconfig.json"
STOPPED_MARKER="$CONFIGDIR/gateway_stopped.cfg"
CACHE_FILE="$RUNDIR/release_cache.json"
WATCHDOG="$SCRIPT_DIR/watchdog.pl"

REPO="SAIC-iSmart-API/saic-python-mqtt-gateway"
API="https://api.github.com/repos/$REPO"
CACHE_TTL=21600   # 6 hours

# Modules that must import successfully before a build is activated. Without
# this check a broken dependency set would only show up as a gateway that dies
# right after every start.
IMPORT_CHECK="saic_ismart_client_ng, gmqtt, httpx, apscheduler, dotenv, inflection"

# Filled in by build_new and consumed by activate_new.
NEW_VERSION=""
NEW_TAG=""

##############################################################################
# Small helpers
##############################################################################

# The system python3 is used for JSON and TOML parsing only, so it does not have
# to satisfy the gateway's own version requirement.
json_get()
{
	# json_get <file> <dotted.path>  ->  value, or nothing
	python3 - "$1" "$2" <<'EOF' 2>/dev/null || true
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        data = json.load(fh)
except Exception:
    sys.exit(0)
for part in sys.argv[2].split("."):
    if not isinstance(data, dict) or part not in data:
        sys.exit(0)
    data = data[part]
if data is None or isinstance(data, (dict, list)):
    sys.exit(0)
print(data)
EOF
}

installed_version()
{
	[ -f "$VERSION_FILE" ] || return 0
	json_get "$VERSION_FILE" "version"
}

update_channel()
{
	local channel
	channel="$(json_get "$PLUGIN_CONFIG" "MAIN.update_channel")"
	case "$channel" in
		prerelease) echo "prerelease" ;;
		*)          echo "release" ;;
	esac
}

##############################################################################
# Release lookup
##############################################################################

# Prints "<version>|<tag>|<tarball_url>" for the newest release in the given
# channel, or nothing when GitHub could not be asked.
fetch_release()
{
	local channel url body rc
	channel="$1"
	if [ "$channel" = "prerelease" ]; then
		url="$API/releases?per_page=20"
	else
		url="$API/releases/latest"
	fi

	# The response goes through a file rather than a pipe: the parser below is
	# fed to python on stdin, which would otherwise swallow the piped body.
	body="$(mktemp "${TMPDIR:-/tmp}/gwrel-XXXXXX.json")" || return 1
	if ! curl -fsSL --max-time 20 \
		-H 'Accept: application/vnd.github+json' \
		-H "User-Agent: LoxBerry-Plugin-$PLUGINNAME" \
		"$url" -o "$body" 2>/dev/null
	then
		rm -f "$body"
		return 1
	fi

	python3 - "$body" <<'EOF' 2>/dev/null
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        data = json.load(fh)
except Exception:
    sys.exit(1)
# /releases/latest answers with an object, /releases with a list that is
# already newest first. Drafts never count.
if isinstance(data, dict):
    data = [data]
if not isinstance(data, list):
    sys.exit(1)
for rel in data:
    if not isinstance(rel, dict) or rel.get("draft"):
        continue
    tag = rel.get("tag_name") or ""
    tarball = rel.get("tarball_url") or ""
    if not tag or not tarball:
        continue
    version = tag[1:] if tag[:1] in ("v", "V") else tag
    print(f"{version}|{tag}|{tarball}")
    break
EOF
	rc=$?
	rm -f "$body"
	return $rc
}

read_cache()
{
	[ -f "$CACHE_FILE" ] || return 1
	python3 - "$CACHE_FILE" "$1" "$CACHE_TTL" <<'EOF' 2>/dev/null
import json, sys, time
try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        c = json.load(fh)
except Exception:
    sys.exit(1)
if c.get("channel") != sys.argv[2]:
    sys.exit(1)
if time.time() - float(c.get("ts", 0)) > float(sys.argv[3]):
    sys.exit(1)
print("{}|{}|{}".format(c.get("version", ""), c.get("tag", ""), c.get("tarball", "")))
EOF
}

write_cache()
{
	mkdir -p "$RUNDIR" 2>/dev/null || true
	python3 - "$CACHE_FILE" "$1" "$2" "$3" "$4" <<'EOF' 2>/dev/null || true
import json, sys, time
path, channel, version, tag, tarball = sys.argv[1:6]
with open(path, "w", encoding="utf-8") as fh:
    json.dump({"channel": channel, "version": version, "tag": tag,
               "tarball": tarball, "ts": time.time()}, fh)
EOF
}

# Prints the newest available version. "force" bypasses the cache. Silent on
# failure: the web interface shows "unknown" rather than an error, because a
# missing internet connection is not a fault of the installation.
available_version()
{
	local force channel cached rel version tag tarball
	force="${1:-}"
	channel="$(update_channel)"

	if [ "$force" != "force" ]; then
		if cached="$(read_cache "$channel")" && [ -n "$cached" ]; then
			printf '%s\n' "${cached%%|*}"
			return 0
		fi
	fi

	rel="$(fetch_release "$channel")" || return 0
	[ -n "$rel" ] || return 0

	version="$(printf '%s' "$rel" | cut -d'|' -f1)"
	tag="$(printf '%s' "$rel" | cut -d'|' -f2)"
	tarball="$(printf '%s' "$rel" | cut -d'|' -f3)"
	write_cache "$channel" "$version" "$tag" "$tarball"
	printf '%s\n' "$version"
}

##############################################################################
# Install
##############################################################################

# Downloads and unpacks the release and builds a fresh venv, both under ".new"
# names. Nothing currently in use is touched, so a failure anywhere in here
# leaves the working installation behind - that is the whole point of building
# a new venv instead of upgrading the existing one in place.
build_new()
{
	local channel rel tarball tmptar reqs

	channel="$(update_channel)"
	echo "<INFO> Update channel: $channel"

	rel="$(fetch_release "$channel")"
	if [ -z "$rel" ]; then
		echo "<ERROR> Could not query the releases of $REPO. Is the LoxBerry online?"
		return 3
	fi
	NEW_VERSION="$(printf '%s' "$rel" | cut -d'|' -f1)"
	NEW_TAG="$(printf '%s' "$rel" | cut -d'|' -f2)"
	tarball="$(printf '%s' "$rel" | cut -d'|' -f3)"
	write_cache "$channel" "$NEW_VERSION" "$NEW_TAG" "$tarball"

	echo "<INFO> Installing saic-python-mqtt-gateway $NEW_VERSION ($NEW_TAG)"

	mkdir -p "$DATADIR" || return 4
	rm -rf "$GATEWAY_DIR.new" "$VENV_DIR.new"
	mkdir -p "$GATEWAY_DIR.new" || return 4

	tmptar="$(mktemp "${TMPDIR:-/tmp}/gateway-XXXXXX.tar.gz")" || return 4

	echo "<INFO> Downloading the release tarball"
	if ! curl -fsSL --max-time 300 \
		-H "User-Agent: LoxBerry-Plugin-$PLUGINNAME" \
		"$tarball" -o "$tmptar"
	then
		echo "<ERROR> Download failed: $tarball"
		rm -f "$tmptar"
		rm -rf "$GATEWAY_DIR.new"
		return 3
	fi

	# GitHub source tarballs wrap everything in a single <owner>-<repo>-<sha>
	# directory, which is stripped here.
	if ! tar -xzf "$tmptar" -C "$GATEWAY_DIR.new" --strip-components=1; then
		echo "<ERROR> Could not unpack the release tarball"
		rm -f "$tmptar"
		rm -rf "$GATEWAY_DIR.new"
		return 4
	fi
	rm -f "$tmptar"

	if [ ! -f "$GATEWAY_DIR.new/src/main.py" ]; then
		echo "<ERROR> The unpacked release has no src/main.py - unexpected layout"
		rm -rf "$GATEWAY_DIR.new"
		return 4
	fi

	echo "<INFO> Creating the Python environment"
	if ! python3 -m venv "$VENV_DIR.new"; then
		echo "<ERROR> Could not create the venv. Is python3-venv installed?"
		rm -rf "$GATEWAY_DIR.new" "$VENV_DIR.new"
		return 4
	fi

	# The runtime dependencies come from [project].dependencies of the release's
	# own pyproject.toml, read with tomllib from the standard library - so the
	# LoxBerry needs no Poetry, and a changed dependency list is picked up
	# automatically with the next release.
	reqs="$GATEWAY_DIR.new/requirements.plugin.txt"
	if ! "$VENV_DIR.new/bin/python" - "$GATEWAY_DIR.new/pyproject.toml" "$reqs" <<'EOF'
import sys, tomllib
with open(sys.argv[1], "rb") as fh:
    data = tomllib.load(fh)
deps = data.get("project", {}).get("dependencies", [])
if not deps:
    raise SystemExit("no [project].dependencies found")
with open(sys.argv[2], "w", encoding="utf-8") as fh:
    fh.write("\n".join(deps) + "\n")
EOF
	then
		echo "<ERROR> Could not read the dependency list from pyproject.toml"
		rm -rf "$GATEWAY_DIR.new" "$VENV_DIR.new"
		return 4
	fi

	echo "<INFO> Installing the Python dependencies (this takes a few minutes)"
	if ! "$VENV_DIR.new/bin/pip" install --no-input --disable-pip-version-check -r "$reqs"; then
		echo "<ERROR> Could not install the Python dependencies"
		rm -rf "$GATEWAY_DIR.new" "$VENV_DIR.new"
		return 4
	fi

	if ! "$VENV_DIR.new/bin/python" -c "import $IMPORT_CHECK" >/dev/null 2>&1; then
		echo "<ERROR> The installed dependencies are incomplete: import check failed"
		rm -rf "$GATEWAY_DIR.new" "$VENV_DIR.new"
		return 4
	fi

	echo "<OK> Build prepared: $NEW_VERSION"
	return 0
}

# Puts the prepared build in place. Kept separate from build_new so the caller
# can stop the gateway in between and keep the switch-over window short.
activate_new()
{
	if [ ! -d "$GATEWAY_DIR.new" ] || [ ! -d "$VENV_DIR.new" ]; then
		echo "<ERROR> No prepared build to activate"
		return 4
	fi

	rm -rf "$GATEWAY_DIR.old" "$VENV_DIR.old"
	[ -d "$GATEWAY_DIR" ] && mv "$GATEWAY_DIR" "$GATEWAY_DIR.old"
	[ -d "$VENV_DIR" ] && mv "$VENV_DIR" "$VENV_DIR.old"
	mv "$GATEWAY_DIR.new" "$GATEWAY_DIR"
	mv "$VENV_DIR.new" "$VENV_DIR"
	rm -rf "$GATEWAY_DIR.old" "$VENV_DIR.old"

	mkdir -p "$CONFIGDIR"
	python3 - "$VERSION_FILE" "$NEW_VERSION" "$NEW_TAG" <<'EOF' || true
import json, sys, time
path, version, tag = sys.argv[1:4]
with open(path, "w", encoding="utf-8") as fh:
    json.dump({"version": version, "tag": tag,
               "installed": time.strftime("%Y-%m-%d %H:%M:%S")}, fh, indent=2)
EOF

	echo "<OK> saic-python-mqtt-gateway $NEW_VERSION installed"
	return 0
}

install_gateway()
{
	build_new || return $?
	activate_new || return $?
	return 0
}

# Takes the gateway down without setting the manual stop marker - an update is
# not a decision by the user to keep it stopped.
stop_gateway()
{
	local pid i
	[ -x "$WATCHDOG" ] || return 0
	pid="$("$WATCHDOG" --action=pid 2>/dev/null | tr -dc '0-9')"
	[ -n "$pid" ] || return 0
	kill -TERM "$pid" 2>/dev/null || true
	for i in $(seq 1 20); do
		[ -d "/proc/$pid" ] || break
		sleep 0.25
	done
	if [ -d "/proc/$pid" ]; then
		kill -KILL "$pid" 2>/dev/null || true
	fi
	return 0
}

restart_gateway()
{
	[ -x "$WATCHDOG" ] || return 0
	"$WATCHDOG" --action=restart
}

# Web-triggered update: the same install, but with a registered LoxBerry logfile
# so the run shows up in the plugin's log manager, and with a restart afterwards.
run_logged_upgrade()
{
	local loglib rc
	loglib="$LBHOMEDIR/libs/bashlib/loxberry_log.sh"
	if [ ! -r "$loglib" ]; then
		install_gateway
		rc=$?
		if [ "$rc" -eq 0 ] && [ ! -e "$STOPPED_MARKER" ]; then
			restart_gateway
		fi
		return "$rc"
	fi

	# The LoxBerry bash log library reads unset variables, so nounset is off from
	# here on.
	set +u
	# shellcheck disable=SC1090
	. "$loglib"
	PACKAGE="$PLUGINNAME"
	NAME="update"
	LOGDIR="$LBHOMEDIR/log/plugins/$PLUGINNAME"
	LOGLEVEL=7
	mkdir -p "$LOGDIR"
	LOGSTART "Gateway update started"

	# Called directly rather than in a subshell: build_new sets NEW_VERSION and
	# NEW_TAG, which activate_new needs.
	build_new >>"$FILENAME" 2>&1
	rc=$?

	if [ "$rc" -eq 0 ]; then
		# Stop first. The switch-over renames two directories, and a gateway
		# restarted by the cron watchdog inside that window would find a
		# half-moved installation.
		LOGINF "Stopping the gateway for the switch-over..."
		stop_gateway >>"$FILENAME" 2>&1
		activate_new >>"$FILENAME" 2>&1
		rc=$?
	fi

	if [ "$rc" -eq 0 ]; then
		LOGOK "Gateway update finished."
		if [ -e "$STOPPED_MARKER" ]; then
			LOGINF "The gateway was stopped manually - not restarting."
		else
			LOGINF "Restarting the gateway to activate the new version..."
			restart_gateway >>"$FILENAME" 2>&1
			LOGOK "Gateway restart triggered."
		fi
	else
		LOGERR "Gateway update failed (exit code $rc). The previous installation is untouched."
	fi

	LOGEND "Gateway update ended"
	return "$rc"
}

##############################################################################
# Dispatch
##############################################################################

case "$ACTION" in
	current)
		installed_version
		;;
	available)
		available_version "$ARG2"
		;;
	channel)
		update_channel
		;;
	installed)
		[ -x "$VENV_DIR/bin/python" ] && [ -f "$GATEWAY_DIR/src/main.py" ]
		exit $?
		;;
	install)
		install_gateway
		exit $?
		;;
	upgrade)
		run_logged_upgrade
		exit $?
		;;
	*)
		echo "Usage: $0 current|available [force]|channel|installed|install|upgrade"
		exit 2
		;;
esac
exit 0

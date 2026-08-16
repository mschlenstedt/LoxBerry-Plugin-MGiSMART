#!/bin/sh

# Runs as root as the very first lifecycle script, before anything is copied.
#
# Checks up front that the gateway will be able to run at all.
#
# saic-python-mqtt-gateway uses typing.override and other 3.12 features, so on
# Debian 12 (Bookworm, Python 3.11) it installs cleanly and then dies on its
# first import - the dependencies themselves carry no such requirement, so pip
# never notices.
#
# When the system Python is too old the plugin provisions a private CPython of
# its own (see ensure_python in bin/gateway_pkg.sh), so that alone is not a
# reason to refuse. The installation is only cancelled when there is no way to
# get a suitable Python at all: no python3 whatsoever, or a machine with no
# prebuilt CPython available - 32-bit ARM in particular.
#
# Exit codes matter: plugininstall.pl treats 1 as an error that it LOGS AND
# CONTINUES past, and only > 1 as fatal. So this exits 2 to actually cancel.
#
# We add 6 arguments when executing the script:
# command <TEMPFILE> <NAME> <FOLDER> <VERSION> <BASEFOLDER> <TEMPFOLDER>

REPO="SAIC-iSmart-API/saic-python-mqtt-gateway"

# Used only when the required version cannot be looked up (no internet during
# installation). Kept as a floor so an offline install cannot slip through on a
# Python that is definitely too old.
FALLBACK_MIN="3.12"

# Reads "requires-python" from the pyproject.toml of the release that would be
# installed and returns its minimum, e.g. "3.12". Empty when it cannot be
# determined - the gateway declares this itself, so a future release raising the
# requirement is picked up without touching this script.
required_python()
{
	tag=$(curl -fsSL --max-time 10 \
		-H 'Accept: application/vnd.github+json' \
		-H "User-Agent: LoxBerry-Plugin-$2" \
		"https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null \
		| python3 -c 'import json,sys
try:
    print(json.load(sys.stdin).get("tag_name",""))
except Exception:
    pass' 2>/dev/null)

	[ -n "$tag" ] || return 0

	curl -fsSL --max-time 10 \
		-H "User-Agent: LoxBerry-Plugin-$2" \
		"https://raw.githubusercontent.com/$REPO/$tag/pyproject.toml" 2>/dev/null \
		| python3 -c 'import re,sys
m = re.search(r"""requires-python\s*=\s*["\x27]([^"\x27]+)["\x27]""", sys.stdin.read())
if m:
    g = re.search(r">=\s*(\d+\.\d+)", m.group(1))
    if g:
        print(g.group(1))' 2>/dev/null
}

if ! command -v python3 >/dev/null 2>&1; then
	echo "<FAIL> python3 was not found on this system."
	echo "<FAIL> The MG iSMART plugin cannot work without it."
	echo "<FAIL> Installation cancelled."
	exit 2
fi

HAVE=$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null)

MIN=$(required_python "$@")
if [ -z "$MIN" ]; then
	MIN="$FALLBACK_MIN"
	echo "<INFO> Could not look up the required Python version; assuming $MIN."
else
	echo "<INFO> saic-python-mqtt-gateway requires Python $MIN or newer."
fi

if python3 -c "
import sys
req = tuple(int(p) for p in '$MIN'.split('.'))
sys.exit(0 if sys.version_info[:len(req)] >= req else 1)
" 2>/dev/null
then
	echo "<OK> The system Python $HAVE satisfies the requirement (>= $MIN)."
	exit 0
fi

# Too old - but a prebuilt CPython can be installed privately for the plugin,
# provided this machine is one the builds exist for.
case "$(uname -m)" in
	x86_64|amd64|aarch64|arm64)
		echo "<INFO> The system Python is $HAVE, which is older than the required $MIN."
		echo "<INFO> The plugin will install its own Python $MIN below its data directory."
		echo "<INFO> The system Python is not touched, and removing the plugin removes it again."
		exit 0
		;;
esac

echo "<FAIL> This system has Python $HAVE, but saic-python-mqtt-gateway needs $MIN or newer."
echo "<FAIL> There is also no prebuilt Python available for this machine ($(uname -m)),"
echo "<FAIL> so the plugin cannot provide a suitable one itself."
echo "<FAIL>"
echo "<FAIL> Please use a LoxBerry on Debian 13 ('Trixie') or newer, which ships Python 3.13,"
echo "<FAIL> or a 64-bit machine (x86_64 or aarch64)."
echo "<FAIL>"
echo "<FAIL> Installation cancelled."
exit 2

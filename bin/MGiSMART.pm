package MGiSMART;

# Shared helpers for the MG iSMART plugin: reading the plugin configuration,
# locating the installation, and reproducing the MQTT topic the gateway
# publishes to.
#
# Used by bin/watchdog.pl, bin/healthcheck and webfrontend/htmlauth/ajax.cgi -
# all three need the same answers, and a second implementation of the topic
# rules would silently drift from the gateway's.

use strict;
use warnings;
use JSON::PP;
use LoxBerry::System;

use base 'Exporter';
our @EXPORT_OK = qw(
	plugin_config
	installed_version
	gateway_installed
	topic_root
	topic_prefix
	managed_env_keys
	derive_log_levels
	config_dir
	data_dir
	mg_trim
	is_true
);

# Environment variables the plugin writes into the generated .env itself.
#
# The Settings tab lets the user append arbitrary KEY=VALUE lines for options
# the plugin does not expose (ABRP, OsmAnd, OpenWB). Those lines are appended
# after the managed ones and would win, so a collision is refused at save time
# rather than silently overriding a managed value.
#
# KEEP IN SYNC with write_env_file() in bin/watchdog.pl, which produces them.
my @MANAGED_ENV_KEYS = qw(
	MQTT_URI
	MQTT_USER
	MQTT_PASSWORD
	MQTT_SERVER_CERT
	MQTT_SERVER_CERT_CHECK_HOSTNAME
	MQTT_CLIENT_ID
	MQTT_TOPIC
	MQTT_ALLOW_DOTS_IN_TOPIC
	SAIC_USER
	SAIC_PASSWORD
	SAIC_REGION
	SAIC_REST_URI
	SAIC_PHONE_COUNTRY_CODE
	SAIC_RELOGIN_DELAY
	MESSAGES_REQUEST_INTERVAL
	ACCOUNT_REFRESH_INTERVAL
	CHARGE_MIN_PERCENTAGE
	BATTERY_CAPACITY_MAPPING
	SAIC_USER_TIMEZONE
	HA_DISCOVERY_ENABLED
	LOG_LEVEL
	MQTT_LOG_LEVEL
	RELEASE_VERSION
);

sub managed_env_keys { return @MANAGED_ENV_KEYS; }

sub config_dir { return $lbpconfigdir; }
sub data_dir   { return "$lbhomedir/data/plugins/$lbpplugindir"; }

sub _read_file
{
	my ($file) = @_;
	return undef if (!-e $file);
	open(my $fh, "<", $file) or return undef;
	local $/;
	my $content = <$fh>;
	close($fh);
	return $content;
}

sub _read_json
{
	my ($file) = @_;
	my $raw = _read_file($file);
	return undef if (!defined($raw) || $raw !~ /\S/);
	my $data = eval { JSON::PP->new->relaxed->decode($raw) };
	return undef if ($@ || ref($data) ne "HASH");
	return $data;
}

# The MAIN section of pluginconfig.json, or an empty hash.
sub plugin_config
{
	my $data = _read_json(config_dir() . "/pluginconfig.json");
	return {} if (!$data || ref($data->{MAIN}) ne "HASH");
	return $data->{MAIN};
}

# The gateway version recorded by gateway_pkg.sh, or an empty string.
sub installed_version
{
	my $data = _read_json(config_dir() . "/version.json");
	return "" if (!$data);
	return $data->{version} // "";
}

sub gateway_installed
{
	my $data = data_dir();
	return (-x "$data/venv/bin/python" && -f "$data/gateway/src/main.py") ? 1 : 0;
}

# The two bases the gateway publishes under. They are NOT the same, which
# matters when reading its status back:
#
#   topic_prefix -> "<prefix>"                 e.g. <prefix>/_internal/lwt
#   topic_root   -> "<prefix>/<saic user>"     e.g. <prefix>/<user>/account/...
#
# In publisher/core.py, get_topic() prepends only the configured prefix; the
# account name is added separately by the gateway for account and vehicle
# topics. The last will (_internal/lwt) therefore sits directly below the
# prefix, without the user.
#
# Both are sanitized the way the gateway does it: [+#*$>] is always replaced by
# an underscore, and the dot as well when MQTT_ALLOW_DOTS_IN_TOPIC is off. The
# user name is usually an e-mail address, so that dot rule is what decides how
# the topics actually look.
sub topic_prefix
{
	my ($cfg) = @_;
	$cfg = plugin_config() if (!$cfg || ref($cfg) ne "HASH");

	my $prefix = mg_trim($cfg->{mqtt_topic} // "");
	$prefix = "saic" if (!length($prefix));
	return _sanitize($prefix, is_true($cfg->{mqtt_allow_dots_in_topic}));
}

# Empty when no account is configured yet - there is no meaningful root then.
sub topic_root
{
	my ($cfg) = @_;
	$cfg = plugin_config() if (!$cfg || ref($cfg) ne "HASH");

	my $user = mg_trim($cfg->{saic_user} // "");
	return "" if (!length($user));

	my $allow_dots = is_true($cfg->{mqtt_allow_dots_in_topic});
	return _sanitize(topic_prefix($cfg) . "/" . $user, $allow_dots);
}

sub _sanitize
{
	my ($topic, $allow_dots) = @_;
	if ($allow_dots) {
		$topic =~ s/[+#*\$>]/_/g;
	}
	else {
		$topic =~ s/[+#*\$>.]/_/g;
	}
	return $topic;
}

# Translates the LoxBerry log level (0-7, increasing verbosity) into the Python
# levels the gateway understands. Returns (LOG_LEVEL, MQTT_LOG_LEVEL).
#
# Level 0 is a special case: pluginloglevel() returns 0 both for "deliberately
# set to EMERGE" and for "not set at all" - its return is
# ($plugin and $plugin->{PLUGINDB_LOGLEVEL}) ? ... : 0 - and the two are
# indistinguishable. A literal translation would leave a freshly installed
# plugin with a completely silent gateway, so 0 maps to INFO.
#
# The gmqtt client is very chatty in normal operation, so its own level is
# capped at WARNING unless the plugin is set to DEBUG.
sub derive_log_levels
{
	my $level = LoxBerry::System::pluginloglevel();
	$level = 0 if (!defined($level) || $level !~ /\A\d+\z/);

	my %map = (
		0 => "INFO",       # not set / EMERGE - see above
		1 => "CRITICAL",   # Python has nothing below CRITICAL
		2 => "CRITICAL",
		3 => "ERROR",
		4 => "WARNING",
		5 => "INFO",       # Python has no equivalent of OK/NOTICE
		6 => "INFO",
		7 => "DEBUG",
	);

	return ($map{$level} // "INFO", ($level >= 7) ? "DEBUG" : "WARNING");
}

# Deliberately not called "trim": LoxBerry::System exports a trim() of its own,
# and every consumer of this module imports that too, so a same-named sub here
# would trigger "Subroutine trim redefined" on every single call. The core's
# version cannot simply be used instead - it does not guard against undef
# (`my $s = shift; $s =~ s/…/`), which the call sites here rely on.
sub mg_trim
{
	my ($value) = @_;
	return "" if (!defined($value));
	$value =~ s/\A\s+|\s+\z//g;
	return $value;
}

# Accepts the shapes a checkbox can arrive in: JSON booleans, 0/1, "true".
sub is_true
{
	my ($value) = @_;
	return 0 if (!defined($value));
	return $value ? 1 : 0 if (JSON::PP::is_bool($value));
	return 0 if (ref($value));
	return ($value && $value ne "0" && lc($value) ne "false") ? 1 : 0;
}

1;

#!/usr/bin/perl

# AJAX endpoint for the web interface. Returns JSON. Mutating actions require
# POST. Error messages are returned as keys and localized in the browser, so
# this endpoint stays language-independent.

use strict;
use warnings;
use CGI;
use JSON::PP;
use POSIX ();
use File::Path qw(make_path);
use LoxBerry::System;
# LoxBerry::System exports $lbpbindir (.../bin/plugins/<folder>), where the
# plugin's Perl modules live. It is populated at compile time by the import
# above, so the following "use lib" picks it up.
use lib $lbpbindir;
use LoxBerry::IO;
use MGiSMART qw(plugin_config installed_version gateway_installed topic_root topic_prefix managed_env_keys derive_log_levels mg_trim);

my $cgi    = CGI->new;
my $q      = $cgi->Vars;
my $action = $q->{action} || "";

my $watchdog    = "$lbpbindir/watchdog.pl";
my $pkg         = "$lbpbindir/gateway_pkg.sh";
my $config_file = "$lbpconfigdir/pluginconfig.json";

my $rundir        = "/var/run/shm/$lbpplugindir";
my $update_pid    = "$rundir/update.pid";
my $update_result = "$rundir/update.result";

# Settings the Settings tab owns. Anything else in pluginconfig.json is left
# untouched by a save.
my @CONFIG_KEYS = qw(
	saic_user
	saic_password
	saic_region
	saic_phone_country_code
	mqtt_topic
	mqtt_allow_dots_in_topic
	ha_discovery_enabled
	saic_relogin_delay
	messages_request_interval
	account_refresh_interval
	charge_min_percentage
	battery_capacity_mapping
	saic_user_timezone
	extra_env
	update_channel
);

print $cgi->header(-type => "application/json", -charset => "utf-8", -expires => "now");

my $response = { ok => JSON::PP::false };

sub is_post { return (($ENV{REQUEST_METHOD} || "") eq "POST"); }

##############################################################################
# Gateway process
##############################################################################

# Probes the running gateway through the watchdog's lightweight, unlogged "pid"
# action and returns a status hash for the service block.
sub gw_status
{
	my (undef, $out) = LoxBerry::System::execute(command => "$watchdog --action=pid 2>/dev/null");
	$out = "" if (!defined($out));
	my ($pid) = $out =~ /(\d+)/;
	return {
		ok        => JSON::PP::true,
		running   => $pid ? JSON::PP::true : JSON::PP::false,
		pid       => $pid ? int($pid) : 0,
		installed => gateway_installed() ? JSON::PP::true : JSON::PP::false,
	};
}

# Runs a mutating watchdog action, then returns the resulting status so the UI
# can update the badge in one round trip.
sub gw_action
{
	my ($what) = @_;
	LoxBerry::System::execute(command => "$watchdog --action=$what 2>&1");
	return gw_status();
}

##############################################################################
# Cloud status (retained topics published by the gateway)
##############################################################################

sub mqtt_read
{
	my ($topic) = @_;
	my $value = eval { LoxBerry::IO::mqtt_get($topic, 600) };
	return undef if ($@ || !defined($value) || $value eq "");
	return $value;
}

sub cloud_status
{
	my $cfg    = plugin_config();
	my $prefix = topic_prefix($cfg);
	my $root   = topic_root($cfg);

	return {
		ok         => JSON::PP::true,
		configured => JSON::PP::false,
		topic      => "",
	} if (!length($root));

	# The last will sits directly below the prefix, the account topics below the
	# prefix *and* the account name - see MGiSMART::topic_root.
	my $lwt   = mqtt_read("$prefix/_internal/lwt");
	my $login = mqtt_read("$root/account/lastLogin");
	my $error = mqtt_read("$root/account/lastLoginError");
	my $gwver = mqtt_read("$root/account/gatewayVersion");

	# Both timestamps are UTC ISO 8601, so a string compare orders them.
	my $failed = (defined($error) && (!defined($login) || $error gt $login)) ? 1 : 0;

	return {
		ok               => JSON::PP::true,
		configured       => JSON::PP::true,
		# What the user has to subscribe in the MQTT Gateway: everything the
		# gateway publishes lives below the prefix.
		topic            => "$prefix/#",
		topic_root       => $root,
		online           => (defined($lwt) && lc($lwt) eq "online") ? JSON::PP::true : JSON::PP::false,
		lwt              => $lwt // "",
		last_login       => $login // "",
		last_login_error => $error // "",
		login_failed     => $failed ? JSON::PP::true : JSON::PP::false,
		gateway_version  => $gwver // "",
		answered         => (defined($lwt) || defined($login) || defined($error)) ? JSON::PP::true : JSON::PP::false,
	};
}

##############################################################################
# Configuration
##############################################################################

sub config_get
{
	my $cfg = plugin_config();
	# Fill in the defaults a fresh installation has no values for, so the form
	# does not start out empty.
	$cfg->{saic_region}    = "eu"      if (!length(mg_trim($cfg->{saic_region} // "")));
	$cfg->{mqtt_topic}     = "saic"    if (!length(mg_trim($cfg->{mqtt_topic} // "")));
	$cfg->{update_channel} = "release" if (($cfg->{update_channel} // "") ne "prerelease");

	# The gateway log level is not a plugin setting - it follows the LoxBerry log
	# level of the plugin. Reported here so the Settings tab can show which level
	# the gateway will actually run at.
	my ($loglevel) = derive_log_levels();

	return { ok => JSON::PP::true, config => $cfg, log_level => $loglevel };
}

# Checks the free-form environment block: every non-empty, non-comment line has
# to be KEY=VALUE, and the key must not be one the plugin writes itself.
sub validate_extra_env
{
	my ($text) = @_;
	return (1, undef, undef) if (!defined($text) || $text !~ /\S/);

	my %managed = map { $_ => 1 } managed_env_keys();

	foreach my $line (split(/\r?\n/, $text)) {
		next if ($line !~ /\S/ || $line =~ /\A\s*#/);
		my $trimmed = mg_trim($line);
		my ($key) = $trimmed =~ /\A([A-Za-z_][A-Za-z0-9_]*)\s*=/;
		return (0, "UI_EXTRA_ENV_INVALID", $trimmed) if (!defined($key));
		return (0, "UI_EXTRA_ENV_CONFLICT", $key) if ($managed{uc($key)});
	}
	return (1, undef, undef);
}

sub config_set
{
	my ($json) = @_;
	my $payload = eval { JSON::PP->new->decode(defined($json) ? $json : "") };
	return { ok => JSON::PP::false, error_key => "UI_AJAX_FAILED" } if ($@ || ref($payload) ne "HASH");

	my ($ok, $error_key, $detail) = validate_extra_env($payload->{extra_env});
	return { ok => JSON::PP::false, error_key => $error_key, detail => $detail } if (!$ok);

	my $region = lc(mg_trim($payload->{saic_region} // "eu"));
	$region = "eu" if ($region !~ /\A(?:eu|au|tr)\z/);
	$payload->{saic_region} = $region;

	my $channel = mg_trim($payload->{update_channel} // "release");
	$payload->{update_channel} = ($channel eq "prerelease") ? "prerelease" : "release";

	# Read-modify-write, so keys outside @CONFIG_KEYS survive a save.
	my $data = read_config_file();
	$data->{MAIN} = {} if (ref($data->{MAIN}) ne "HASH");
	foreach my $key (@CONFIG_KEYS) {
		next if (!exists($payload->{$key}));
		my $value = $payload->{$key};
		# Checkboxes arrive as JSON booleans; store them as 0/1 so the file stays
		# readable from shell and Python too.
		$value = ($value ? 1 : 0) if (JSON::PP::is_bool($value));
		$data->{MAIN}{$key} = $value;
	}

	return { ok => JSON::PP::false, error_key => "UI_SAVE_FAILED" } if (!write_config_file($data));
	return { ok => JSON::PP::true };
}

sub read_config_file
{
	return {} if (!-e $config_file);
	open(my $fh, "<", $config_file) or return {};
	local $/;
	my $raw = <$fh>;
	close($fh);
	return {} if (!defined($raw) || $raw !~ /\S/);
	my $data = eval { JSON::PP->new->relaxed->decode($raw) };
	return {} if ($@ || ref($data) ne "HASH");
	return $data;
}

# Written through a temporary file, so an interrupted write cannot leave a
# truncated configuration behind.
sub write_config_file
{
	my ($data) = @_;
	my $tmp = "$config_file.tmp";
	open(my $fh, ">", $tmp) or return 0;
	print $fh JSON::PP->new->utf8->pretty->canonical->encode($data);
	close($fh);
	chmod(0640, $tmp);
	return rename($tmp, $config_file) ? 1 : 0;
}

##############################################################################
# Version and update
##############################################################################

sub version_info
{
	my ($force) = @_;
	my $current = installed_version();

	my $arg = $force ? "available force" : "available";
	my (undef, $available) = LoxBerry::System::execute(command => "$pkg $arg 2>/dev/null");
	$available = "" if (!defined($available));
	$available = mg_trim($available);

	my (undef, $channel) = LoxBerry::System::execute(command => "$pkg channel 2>/dev/null");
	$channel = mg_trim($channel // "");
	$channel = "release" if ($channel ne "prerelease");

	my $update = 0;
	if (length($current) && length($available)) {
		# dpkg orders version strings properly; a plain inequality would also
		# report a downgrade as an available update.
		$update = 1 if (system("dpkg", "--compare-versions", $available, "gt", $current) == 0);
	}
	elsif (!length($current) && length($available)) {
		# Nothing installed yet - the button offers the first installation.
		$update = 1;
	}

	return {
		ok               => JSON::PP::true,
		current          => $current,
		available        => $available,
		channel          => $channel,
		installed        => gateway_installed() ? JSON::PP::true : JSON::PP::false,
		update_available => $update ? JSON::PP::true : JSON::PP::false,
	};
}

# The update downloads a tarball and builds a venv with pip, which takes several
# minutes on a Raspberry Pi - far longer than a web request may last. So it is
# detached and the browser polls update_status() instead. The run writes its own
# registered logfile and restarts the gateway itself.
sub update_run
{
	return { ok => JSON::PP::true, started => JSON::PP::true } if (update_is_running());

	make_path($rundir) if (!-d $rundir);
	unlink($update_result);

	my $pid = fork();
	return { ok => JSON::PP::false, error_key => "UI_UPDATE_START_FAILED" } if (!defined($pid));

	if ($pid == 0) {
		# Detach from the CGI process, so the update survives the request.
		POSIX::setsid();
		open(STDIN, "<", "/dev/null");
		open(STDOUT, ">", "/dev/null");
		open(STDERR, ">&", \*STDOUT);
		my $rc = system($pkg, "upgrade");
		if (open(my $fh, ">", $update_result)) {
			print $fh(($rc == -1 ? 255 : ($rc >> 8)), "\n");
			close($fh);
		}
		POSIX::_exit(0);
	}

	if (open(my $fh, ">", $update_pid)) {
		print $fh "$pid\n";
		close($fh);
	}
	return { ok => JSON::PP::true, started => JSON::PP::true };
}

sub update_is_running
{
	return 0 if (!-e $update_pid);
	open(my $fh, "<", $update_pid) or return 0;
	my $pid = <$fh>;
	close($fh);
	$pid = "" if (!defined($pid));
	chomp($pid);
	return 0 if ($pid !~ /\A\d+\z/);
	return (-d "/proc/$pid") ? 1 : 0;
}

sub update_status
{
	my $running = update_is_running();
	my $rc;
	if (!$running && -e $update_result) {
		open(my $fh, "<", $update_result);
		if ($fh) {
			my $line = <$fh>;
			close($fh);
			chomp($line) if (defined($line));
			$rc = $line if (defined($line) && $line =~ /\A\d+\z/);
		}
	}
	return {
		ok       => JSON::PP::true,
		running  => $running ? JSON::PP::true : JSON::PP::false,
		finished => (!$running && defined($rc)) ? JSON::PP::true : JSON::PP::false,
		success  => (defined($rc) && $rc == 0) ? JSON::PP::true : JSON::PP::false,
	};
}

##############################################################################
# Dispatch
##############################################################################

if ($action eq "gw-status") {
	$response = gw_status();
}
elsif ($action eq "gw-start") {
	$response = is_post() ? gw_action("start") : { ok => JSON::PP::false, error_key => "UI_POST_REQUIRED" };
}
elsif ($action eq "gw-stop") {
	$response = is_post() ? gw_action("stop") : { ok => JSON::PP::false, error_key => "UI_POST_REQUIRED" };
}
elsif ($action eq "gw-restart") {
	$response = is_post() ? gw_action("restart") : { ok => JSON::PP::false, error_key => "UI_POST_REQUIRED" };
}
elsif ($action eq "cloud-status") {
	$response = cloud_status();
}
elsif ($action eq "config-get") {
	$response = config_get();
}
elsif ($action eq "config-set") {
	$response = is_post() ? config_set($q->{config}) : { ok => JSON::PP::false, error_key => "UI_POST_REQUIRED" };
}
elsif ($action eq "version-info") {
	$response = version_info(0);
}
elsif ($action eq "version-refresh") {
	$response = is_post() ? version_info(1) : { ok => JSON::PP::false, error_key => "UI_POST_REQUIRED" };
}
elsif ($action eq "update-run") {
	$response = is_post() ? update_run() : { ok => JSON::PP::false, error_key => "UI_POST_REQUIRED" };
}
elsif ($action eq "update-status") {
	$response = update_status();
}
else {
	$response = { ok => JSON::PP::false, error_key => "UI_UNKNOWN_ACTION" };
}

print JSON::PP->new->utf8->canonical->encode($response);
exit;

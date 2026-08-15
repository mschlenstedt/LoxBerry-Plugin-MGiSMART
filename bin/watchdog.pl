#!/usr/bin/perl

# Starts, stops and supervises the saic-python-mqtt-gateway process.
#
# The gateway is not a systemd service; this script owns its lifecycle, so the
# process runs as "loxberry" - the same user as the web interface - and its
# output lands in a registered LoxBerry logfile.
#
# Usage: watchdog.pl --action=start|stop|restart|check|status|pid [--verbose]
#
#   pid      print the running PID (empty line if not running) and exit; a
#            lightweight probe for the web interface, without log session or lock
#   start    start the gateway unless it is already running
#   stop     stop the gateway and remember that this was intentional
#   restart  stop (without the marker), then start
#   check    restart the gateway if it died unexpectedly (called from cron)
#   status   exit 0 if the gateway is running, 1 otherwise
#
# The manual-stop marker lives in the config directory, so a deliberate stop
# survives both a reboot and a plugin upgrade.

use strict;
use warnings;
use Getopt::Long;
use File::Path qw(make_path);
use POSIX qw(setsid);
use FindBin;
use lib $FindBin::Bin;
use LoxBerry::System;
use LoxBerry::Log;
use LoxBerry::IO;
use MGiSMART qw(plugin_config installed_version gateway_installed derive_log_levels trim is_true);

my $psubfolder  = $lbpplugindir;
my $config_dir  = $lbpconfigdir;
my $data_dir    = "$lbhomedir/data/plugins/$psubfolder";

my $gateway_dir = "$data_dir/gateway";
my $gateway_py  = "$gateway_dir/src/main.py";
my $venv_python = "$data_dir/venv/bin/python";

my $env_file       = "$config_dir/.env";
my $stopped_marker = "$config_dir/gateway_stopped.cfg";

my $runtime_dir  = "/var/run/shm/$psubfolder";
my $pid_file     = "$runtime_dir/gateway.pid";
my $failure_file = "$runtime_dir/gateway_failures";
my $max_failures = 5;

# Endpoints of the SAIC API. Region and URI belong together, so the UI offers
# the region and the URI is derived here.
my %REST_URI = (
	eu => "https://gateway-mg-eu.soimt.com/api.app/v1/",
	au => "https://gateway-mg-au.soimt.com/api.app/v1/",
	tr => "https://gateway-mg-tr.soimt.com/api.app/v1/",
);

my ($verbose, $action);
GetOptions("verbose=s" => \$verbose, "action=s" => \$action);
$action = "" if (!defined($action));

# Unlogged status probe for the web interface, which polls it every few seconds.
if ($action eq "pid") {
	my $pid = gateway_running() ? (read_pid() || find_gateway_pid() || "") : "";
	print "$pid\n";
	exit 0;
}

my $log = LoxBerry::Log->new(name => "watchdog", package => $psubfolder);
if ($verbose) {
	$log->stdout(1);
	$log->loglevel(7);
}
LOGSTART("watchdog action=$action");

make_path($runtime_dir) if (!-d $runtime_dir);

# Serialize against a parallel run, for example cron firing while the web
# interface triggers a restart.
my $lockstate = LoxBerry::System::lock(lockfile => "$psubfolder-watchdog", wait => 120);
if ($lockstate) {
	LOGWARN("Another watchdog run is active: $lockstate");
	print "$lockstate currently running - Quitting.\n";
	LOGEND();
	exit 1;
}

my $exit = 0;
if    ($action eq "start")   { $exit = do_start(); }
elsif ($action eq "stop")    { $exit = do_stop(1); }
elsif ($action eq "restart") { $exit = do_restart(); }
elsif ($action eq "check")   { $exit = do_check(); }
elsif ($action eq "status")  { $exit = gateway_running() ? 0 : 1; }
else {
	LOGERR("No valid action. --action=start|stop|restart|check|status|pid is required.");
	print "No valid action specified. --action=start|stop|restart|check|status|pid is required.\n";
	$exit = 2;
}

LoxBerry::System::unlock(lockfile => "$psubfolder-watchdog");
LOGEND();
exit $exit;

##############################################################################
# Actions
##############################################################################

sub do_start
{
	# A manual or boot start clears the marker.
	unlink($stopped_marker) if (-e $stopped_marker);

	if (gateway_running()) {
		LOGOK("The gateway is already running.");
		print "The gateway is already running.\n";
		return 0;
	}
	if (!gateway_installed()) {
		LOGERR("The gateway is not installed. Install it from the Update tab.");
		print "The gateway is not installed.\n";
		return 1;
	}

	my $cfg = plugin_config();
	if (!length(trim($cfg->{saic_user} // "")) || !length($cfg->{saic_password} // "")) {
		LOGERR("No iSMART credentials configured. Enter them on the Settings tab.");
		print "No iSMART credentials configured.\n";
		return 1;
	}

	my $mqtt = eval { LoxBerry::IO::mqtt_connectiondetails() } || {};
	if (!$mqtt->{brokerhost}) {
		LOGWARN("No MQTT broker details available from LoxBerry. Starting without a broker connection.");
	}

	my $env_extra = write_env_file($cfg, $mqtt);
	if (!$env_extra) {
		LOGERR("Could not write $env_file.");
		print "Could not write the gateway configuration.\n";
		return 1;
	}

	my ($loglevel, $mqtt_loglevel) = derive_log_levels();
	my $release = installed_version();

	my $logfile = gateway_logfile();
	LOGINF("Starting the gateway ($venv_python $gateway_py), log level $loglevel.");

	my $pid = fork();
	if (!defined($pid)) {
		LOGERR("Could not fork: $!");
		return 1;
	}
	if ($pid == 0) {
		# Detach, so the gateway survives the watchdog and its caller.
		setsid();
		open(STDIN, "<", "/dev/null");
		open(STDOUT, ">>", $logfile) or open(STDOUT, ">", "/dev/null");
		open(STDERR, ">&", \*STDOUT);

		# Passwords and any value the .env cannot represent safely - see
		# write_env_file. os.environ wins over the .env, so these are what the
		# gateway actually uses.
		$ENV{$_} = $env_extra->{$_} foreach (keys %$env_extra);

		# log_config.py reads these with os.getenv(), so they bypass the merged
		# .env dictionary entirely and have to be real environment variables.
		$ENV{LOG_LEVEL}       = $loglevel;
		$ENV{MQTT_LOG_LEVEL}  = $mqtt_loglevel;
		$ENV{RELEASE_VERSION} = $release if ($release);

		# The working directory decides where the gateway looks for its
		# configuration: argparse_extensions.py calls dotenv_values(".env"),
		# a relative path resolved against the CWD with no search upwards.
		chdir($config_dir);
		exec($venv_python, $gateway_py);
		exit 1;
	}

	write_pid($pid);
	# Give it a moment, so an immediate failure is reported instead of a success
	# that is already over.
	sleep 3;
	if (!gateway_running()) {
		LOGERR("The gateway exited right after the start. See the gateway log.");
		print "The gateway did not stay running. Check the gateway log.\n";
		return 1;
	}
	reset_failures();
	LOGOK("Gateway started (PID $pid).");
	print "Started the gateway (PID $pid).\n";
	return 0;
}

sub do_stop
{
	my ($manual) = @_;

	if ($manual) {
		# Written even when nothing was running, so the state is unambiguous:
		# the user asked for it to stay down.
		write_marker($stopped_marker);
	}

	my $pid = read_pid();
	if (!$pid || !process_is_gateway($pid)) {
		$pid = find_gateway_pid();
	}
	if (!$pid) {
		LOGOK("The gateway is not running.");
		print "The gateway is not running.\n";
		unlink($pid_file);
		return 0;
	}

	LOGINF("Stopping the gateway (PID $pid).");
	kill("TERM", $pid);
	for (1 .. 20) {
		last if (!process_is_gateway($pid));
		select(undef, undef, undef, 0.25);
	}
	if (process_is_gateway($pid)) {
		LOGWARN("The gateway did not stop on TERM, sending KILL.");
		kill("KILL", $pid);
		select(undef, undef, undef, 0.5);
	}
	unlink($pid_file);

	if (process_is_gateway($pid)) {
		LOGERR("Could not stop the gateway (PID $pid).");
		print "Could not stop the gateway.\n";
		return 1;
	}
	LOGOK("Gateway stopped.");
	print "Stopped the gateway.\n";
	return 0;
}

sub do_restart
{
	my $rc = do_stop(0);
	return $rc if ($rc != 0);
	sleep 1;
	return do_start();
}

# Called every five minutes from cron. Restarts the gateway only if it should be
# running and was not stopped on purpose, and gives up after repeated failures
# so a broken configuration is not restarted forever.
sub do_check
{
	if (-e $stopped_marker) {
		LOGOK("The gateway was stopped manually. Nothing to do.");
		return 0;
	}
	if (!gateway_installed()) {
		LOGOK("The gateway is not installed. Nothing to do.");
		return 0;
	}
	if (gateway_running()) {
		reset_failures();
		LOGOK("The gateway is running.");
		return 0;
	}

	my $failures = read_failures() + 1;
	write_failures($failures);
	if ($failures > $max_failures) {
		LOGERR("The gateway failed $failures times in a row. Not restarting again until it is started manually.");
		return 1;
	}
	LOGWARN("The gateway is not running (failure $failures of $max_failures). Restarting.");
	return do_start();
}

##############################################################################
# Configuration
##############################################################################

# Collects every setting the gateway needs, as an ordered list of
# [key, value, secret] triples. Secrets never reach the .env; see write_env_file.
sub gateway_settings
{
	my ($cfg, $mqtt) = @_;
	my @pairs;

	# --- MQTT broker: always taken fresh from LoxBerry ---------------------
	if ($mqtt->{brokerhost}) {
		my $port = $mqtt->{brokerport} || 1883;
		my $scheme = $mqtt->{tls} ? "tls" : "tcp";
		$port = $mqtt->{tls_brokerport} if ($mqtt->{tls} && $mqtt->{tls_brokerport});
		push @pairs, ["MQTT_URI", "$scheme://$mqtt->{brokerhost}:$port", 0];
		push @pairs, ["MQTT_USER", $mqtt->{brokeruser}, 0]
			if (defined($mqtt->{brokeruser}) && $mqtt->{brokeruser} ne "");
		push @pairs, ["MQTT_PASSWORD", $mqtt->{brokerpass}, 1]
			if (defined($mqtt->{brokerpass}) && $mqtt->{brokerpass} ne "");
		if ($mqtt->{tls} && $mqtt->{tls_cafile}) {
			push @pairs, ["MQTT_SERVER_CERT", $mqtt->{tls_cafile}, 0];
			push @pairs, ["MQTT_SERVER_CERT_CHECK_HOSTNAME", $mqtt->{tls_verify} ? "True" : "False", 0];
		}
	}
	push @pairs, ["MQTT_CLIENT_ID", "loxberry-$psubfolder", 0];

	# Only the prefix: the gateway appends the account name itself and applies
	# its own character rules to the result.
	my $prefix = trim($cfg->{mqtt_topic} // "");
	$prefix = "saic" if (!length($prefix));
	push @pairs, ["MQTT_TOPIC", $prefix, 0];
	push @pairs, ["MQTT_ALLOW_DOTS_IN_TOPIC", is_true($cfg->{mqtt_allow_dots_in_topic}) ? "True" : "False", 0];

	# --- SAIC account ------------------------------------------------------
	push @pairs, ["SAIC_USER", $cfg->{saic_user} // "", 0];
	push @pairs, ["SAIC_PASSWORD", $cfg->{saic_password} // "", 1];

	my $region = lc(trim($cfg->{saic_region} // "eu"));
	$region = "eu" if (!exists($REST_URI{$region}));
	push @pairs, ["SAIC_REGION", $region, 0];
	push @pairs, ["SAIC_REST_URI", $REST_URI{$region}, 0];

	push @pairs, ["SAIC_PHONE_COUNTRY_CODE", trim($cfg->{saic_phone_country_code}), 0]
		if (length(trim($cfg->{saic_phone_country_code} // "")));

	# --- Optional tuning ---------------------------------------------------
	my @optional = (
		[saic_relogin_delay        => "SAIC_RELOGIN_DELAY"],
		[messages_request_interval => "MESSAGES_REQUEST_INTERVAL"],
		[account_refresh_interval  => "ACCOUNT_REFRESH_INTERVAL"],
		[charge_min_percentage     => "CHARGE_MIN_PERCENTAGE"],
		[battery_capacity_mapping  => "BATTERY_CAPACITY_MAPPING"],
		[saic_user_timezone        => "SAIC_USER_TIMEZONE"],
	);
	foreach my $entry (@optional) {
		my $value = trim($cfg->{$entry->[0]} // "");
		push @pairs, [$entry->[1], $value, 0] if (length($value));
	}

	# --- Integrations ------------------------------------------------------
	push @pairs, ["HA_DISCOVERY_ENABLED", is_true($cfg->{ha_discovery_enabled}) ? "True" : "False", 0];

	return \@pairs;
}

# Writes the gateway configuration. Regenerated on every start, so changed
# settings and - just as important - changed LoxBerry broker credentials are
# picked up without any extra step.
#
# Returns the settings that must be handed over as real environment variables
# instead, which the caller applies to the child before exec. Two reasons a
# value takes that route:
#
#   - It is a secret. Passwords then exist only in the process environment,
#     readable by the owner and root, and not in a second file on disk.
#   - The .env cannot represent it faithfully. Values are written single-quoted,
#     which is the form python-dotenv does not unescape - double quotes would
#     turn a \t inside a value into a tab. Two things still bite, both verified
#     against python-dotenv rather than assumed:
#       * a single quote has no escape inside single quotes; a value containing
#         one makes the parser drop the whole line with an error
#       * "${...}" is expanded from the environment even inside single quotes,
#         so a value containing it would silently come out different
#     Values like that, and any containing a newline, take the environment route.
#
# This is safe because os.environ wins over the .env - argparse_extensions.py
# builds {**dotenv_values(".env"), **os.environ}.
sub write_env_file
{
	my ($cfg, $mqtt) = @_;

	my @lines;
	push @lines, "# Generated by the LoxBerry MG iSMART plugin on every gateway start.";
	push @lines, "# Do not edit - your changes are overwritten. Use the plugin's";
	push @lines, "# Settings tab instead.";
	push @lines, "#";
	push @lines, "# Passwords are deliberately not in here; they are handed to the";
	push @lines, "# process through its environment.";
	push @lines, "";

	my %env;
	foreach my $pair (@{gateway_settings($cfg, $mqtt)}) {
		my ($key, $value, $secret) = @$pair;
		$value = "" if (!defined($value));

		if ($secret || $value =~ /['\n]/ || $value =~ /\$\{/) {
			$env{$key} = $value;
			push @lines, "# $key is passed through the environment";
			next;
		}
		push @lines, "$key='$value'";
	}

	# --- User-supplied extras ----------------------------------------------
	# Appended last, but the web interface refuses lines that collide with a
	# managed key, so this cannot silently override anything above.
	my $extra = $cfg->{extra_env} // "";
	if (length(trim($extra))) {
		push @lines, "";
		push @lines, "# Additional environment variables from the Settings tab";
		foreach my $line (split(/\r?\n/, $extra)) {
			next if ($line !~ /\S/ || $line =~ /\A\s*#/);
			push @lines, trim($line);
		}
	}

	my $tmp = "$env_file.tmp";
	open(my $fh, ">", $tmp) or return undef;
	binmode($fh, ":encoding(UTF-8)");
	print $fh join("\n", @lines), "\n";
	close($fh);
	chmod(0600, $tmp);
	return undef if (!rename($tmp, $env_file));
	return \%env;
}

##############################################################################
# Process handling
##############################################################################

sub gateway_logfile
{
	my $dir = "$lbhomedir/log/plugins/$psubfolder";
	make_path($dir) if (!-d $dir);
	# A LoxBerry log session gives the file a timestamped name and registers it
	# in the log manager; the gateway writes into it through its stdout.
	my $gwlog = LoxBerry::Log->new(name => "gateway", package => $psubfolder);
	$gwlog->LOGSTART("Gateway process log");
	return $gwlog->filename();
}

sub gateway_running
{
	my $pid = read_pid();
	return 1 if ($pid && process_is_gateway($pid));
	my $found = find_gateway_pid();
	write_pid($found) if ($found);
	return $found ? 1 : 0;
}

# Only our own instance counts. The command line has to contain the path of the
# main.py this plugin installed, so a foreign Python process is never mistaken
# for the gateway and a stale PID file is harmless.
sub process_is_gateway
{
	my ($pid) = @_;
	return 0 if (!$pid || $pid !~ /\A\d+\z/ || !-d "/proc/$pid");
	open(my $fh, "<", "/proc/$pid/cmdline") or return 0;
	local $/;
	my $cmdline = <$fh> || "";
	close($fh);
	my @args = grep { defined($_) && $_ ne "" } split(/\0/, $cmdline);
	return 0 if (!@args);
	return 0 if ($args[0] !~ m{(?:\A|/)python[\d.]*\z});
	return (grep { $_ eq $gateway_py } @args) ? 1 : 0;
}

sub find_gateway_pid
{
	opendir(my $proc, "/proc") or return undef;
	my @pids = sort { $a <=> $b } grep { /\A\d+\z/ } readdir($proc);
	closedir($proc);
	foreach my $pid (@pids) {
		return $pid if (process_is_gateway($pid));
	}
	return undef;
}

##############################################################################
# Small file helpers
##############################################################################

sub read_whole_file
{
	my ($file) = @_;
	return undef if (!-e $file);
	open(my $fh, "<", $file) or return undef;
	local $/;
	my $content = <$fh>;
	close($fh);
	return $content;
}

sub read_pid
{
	my $pid = read_whole_file($pid_file);
	return undef if (!defined($pid));
	chomp($pid);
	return ($pid =~ /\A\d+\z/) ? $pid : undef;
}

sub write_pid
{
	my ($pid) = @_;
	open(my $fh, ">", $pid_file) or return;
	print $fh "$pid\n";
	close($fh);
}

sub read_failures
{
	my $count = read_whole_file($failure_file);
	return 0 if (!defined($count));
	chomp($count);
	return ($count =~ /\A\d+\z/) ? $count : 0;
}

sub write_failures
{
	my ($count) = @_;
	open(my $fh, ">", $failure_file) or return;
	print $fh "$count\n";
	close($fh);
}

sub reset_failures { unlink($failure_file) if (-e $failure_file); }

sub write_marker
{
	my ($file) = @_;
	my $fh;
	if (open($fh, ">", $file)) { print $fh "1\n"; close($fh); }
}

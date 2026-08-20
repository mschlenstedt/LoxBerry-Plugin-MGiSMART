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
use JSON::PP;
use File::Path qw(make_path);
use POSIX qw(setsid);
use FindBin;
use lib $FindBin::Bin;
use LoxBerry::System;
use LoxBerry::Log;
use LoxBerry::IO;
use MGiSMART qw(plugin_config installed_version gateway_installed topic_root derive_log_levels mqtt_read mqtt_vins mg_trim is_true);

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

# How often the gateway asks the car for its state.
#
# The gateway accepts these ONLY as retained MQTT messages - there is no
# environment variable and no command line option for them, so the generated
# .env cannot carry them. The topics are per VIN, and the VIN is not known
# until the gateway has logged in and published it. Both together are why this
# runs from the five minute check instead of from do_start(): the check sees a
# gateway that is already up, and publishing is idempotent, so an interval that
# is already correct costs nothing.
#
# The gateway's own default for the inactive interval is 86400 - once a day, to
# spare the 12V battery. That is too coarse for a car that charges overnight on
# a timer: the state that arrives in the morning is still the one from the
# evening before. The plugin therefore defaults to an hour and lets the ladder
# below back off again when the car really is standing still.
my @REFRESH_PERIODS = (
	{ key => "refresh_period_active",         topic => "active",        default => 30   },
	{ key => "refresh_period_inactive",       topic => "inActive",      default => 3600 },
	{ key => "refresh_period_after_shutdown", topic => "afterShutdown", default => 120  },
	{ key => "refresh_period_inactive_grace", topic => "inActiveGrace", default => 600  },
);

# The values that decide whether anything happened to the car.
#
# Deliberately a short, hand picked list. A hash over everything the gateway
# publishes would never hold still: interior and exterior temperature, the 12V
# voltage and the GPS position all drift by themselves, and the back off below
# would never trigger. What is left is what only changes when someone or
# something actually acts on the car.
my @FINGERPRINT_TOPICS = (
	"drivetrain/soc",                # charging and driving
	"drivetrain/mileage",            # driving
	"drivetrain/chargerConnected",   # plugged in, before charging even starts
	"drivetrain/socTarget",          # charge target changed in the app
	"doors/locked",                  # someone was at the car
);

# How far the inactive interval may climb while nothing happens, as
# [quiet seconds, interval]. Applied on top of the configured interval: a
# larger user value always wins, so the ladder can only ever make the polling
# gentler, never more aggressive.
my @REFRESH_LADDER = (
	[ 24 * 3600, 12 * 3600 ],
	[ 48 * 3600, 24 * 3600 ],
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

# The log session is created on first use, never up front.
#
# cron runs "check" every five minutes, and each LoxBerry::Log session means a
# new timestamped file plus a database entry - roughly 288 logfiles a day on a
# RAM disk, almost all of them stating that everything is fine. A run with
# nothing to report now writes nothing at all, while every run that actually
# does something (start, stop, restart, or a check that has to restart the
# gateway) still gets its own logfile.
my $log;

sub logsession
{
	return $log if ($log);
	# One logfile that every run appends to, instead of one file per run.
	#
	# "nosession" is what LoxBerry::Log offers for a continuously written
	# log: it forces append mode, suppresses the LOGSTART/LOGEND separator
	# blocks, and resolves the database entry through the FILENAME instead
	# of opening a new session - creating that entry on first use and
	# reusing it ever after (log_db_get_session_by_filename). The filename
	# therefore has to be a fixed one; the default carries a timestamp and
	# would produce a new file, and a new log manager entry, every run.
	#
	# That is what this used to do, and with cron calling "check" every five
	# minutes it would scatter the refresh policy history below over
	# hundreds of unrelated files. Keeping the file from growing without
	# bound is not this script's business - log_maint.pl does that.
	$log = LoxBerry::Log->new(
		name      => "watchdog",
		package   => $psubfolder,
		filename  => "$lbplogdir/watchdog.log",
		nosession => 1,
		# A file that spans days needs the time on every single line; with
		# one file per run the session header used to carry it.
		addtime   => 1,
	);
	if ($verbose) {
		$log->stdout(1);
		$log->loglevel(7);
	}
	# Claim the exported LOG* functions explicitly. new() only takes that role
	# when no object holds it yet, and do_start() opens the gateway's own log
	# session - without this, whichever happened to be created first would
	# decide where these messages end up.
	$log->default();
	LOGSTART("watchdog action=$action");
	return $log;
}

sub wlog_inf  { logsession(); LOGINF(@_);  }
sub wlog_ok   { logsession(); LOGOK(@_);   }
sub wlog_warn { logsession(); LOGWARN(@_); }
sub wlog_err  { logsession(); LOGERR(@_);  }

# Written regardless of the configured loglevel.
#
# LoxBerry::Log drops anything whose severity is above the plugin loglevel, so
# at loglevel 3 (ERROR) a perfectly normal stop or restart left a logfile
# containing nothing but the header. Starting and stopping the gateway is
# precisely what one opens this log for, so those lines have to survive any
# loglevel - without pretending to be errors, which would colour a routine stop
# red in the log manager.
#
# The mechanism is the one the core uses for its own header lines: write()
# never filters a negative severity, and it then adds no tag of its own, so the
# tag travels inside the text and the viewer still colours the line.
sub wlog_event
{
	my ($tag, $message) = @_;
	logsession();
	$log->write(-1, "<$tag> $message");
	$log->close();
	return;
}

# An explicit --verbose run is always meant to be watched, so it opens the
# session even when the outcome turns out to be "nothing to do".
logsession() if ($verbose);

make_path($runtime_dir) if (!-d $runtime_dir);

# Serialize against a parallel run, for example cron firing while the web
# interface triggers a restart.
my $lockstate = LoxBerry::System::lock(lockfile => "$psubfolder-watchdog", wait => 120);
if ($lockstate) {
	wlog_warn("Another watchdog run is active: $lockstate");
	print "$lockstate currently running - Quitting.\n";
	LOGEND() if ($log);
	exit 1;
}

my $exit = 0;
if    ($action eq "start")   { $exit = do_start(); }
elsif ($action eq "stop")    { $exit = do_stop(1); }
elsif ($action eq "restart") { $exit = do_restart(); }
elsif ($action eq "check")   { $exit = do_check(); }
elsif ($action eq "status")  { $exit = gateway_running() ? 0 : 1; }
else {
	wlog_err("No valid action. --action=start|stop|restart|check|status|pid is required.");
	print "No valid action specified. --action=start|stop|restart|check|status|pid is required.\n";
	$exit = 2;
}

LoxBerry::System::unlock(lockfile => "$psubfolder-watchdog");
LOGEND() if ($log);
exit $exit;

##############################################################################
# Actions
##############################################################################

sub do_start
{
	# A manual or boot start clears the marker.
	unlink($stopped_marker) if (-e $stopped_marker);

	if (gateway_running()) {
		wlog_event("OK", "The gateway is already running.");
		print "The gateway is already running.\n";
		return 0;
	}
	if (!gateway_installed()) {
		wlog_err("The gateway is not installed. Install it from the Update tab.");
		print "The gateway is not installed.\n";
		return 1;
	}

	my ($have_py, $need_py) = python_requirement_unmet();
	if ($have_py) {
		wlog_err("The environment runs Python $have_py, but the gateway needs $need_py or newer. Reinstall it from the Update tab, which provides a suitable Python.");
		print "Python $have_py is too old; the gateway needs $need_py or newer.\n";
		return 1;
	}

	my $cfg = plugin_config();
	if (!length(mg_trim($cfg->{saic_user} // "")) || !length($cfg->{saic_password} // "")) {
		wlog_err("No iSMART credentials configured. Enter them on the Settings tab.");
		print "No iSMART credentials configured.\n";
		return 1;
	}

	my $mqtt = eval { LoxBerry::IO::mqtt_connectiondetails() } || {};
	if (!$mqtt->{brokerhost}) {
		wlog_warn("No MQTT broker details available from LoxBerry. Starting without a broker connection.");
	}

	my $env_extra = write_env_file($cfg, $mqtt);
	if (!$env_extra) {
		wlog_err("Could not write $env_file.");
		print "Could not write the gateway configuration.\n";
		return 1;
	}

	my ($loglevel, $mqtt_loglevel) = derive_log_levels();
	my $release = installed_version();

	my $logfile = gateway_logfile();
	wlog_inf("Starting the gateway ($venv_python $gateway_py), log level $loglevel.");

	my $pid = fork();
	if (!defined($pid)) {
		wlog_err("Could not fork: $!");
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
		wlog_err("The gateway exited right after the start. See the gateway log.");
		print "The gateway did not stay running. Check the gateway log.\n";
		return 1;
	}
	reset_failures();
	wlog_event("OK", "Gateway started (PID $pid).");
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
		wlog_event("OK", "The gateway is not running.");
		print "The gateway is not running.\n";
		unlink($pid_file);
		return 0;
	}

	wlog_event("INFO", "Stopping the gateway (PID $pid).");
	kill("TERM", $pid);
	for (1 .. 20) {
		last if (!process_is_gateway($pid));
		select(undef, undef, undef, 0.25);
	}
	if (process_is_gateway($pid)) {
		wlog_warn("The gateway did not stop on TERM, sending KILL.");
		kill("KILL", $pid);
		select(undef, undef, undef, 0.5);
	}
	unlink($pid_file);

	if (process_is_gateway($pid)) {
		wlog_err("Could not stop the gateway (PID $pid).");
		print "Could not stop the gateway.\n";
		return 1;
	}
	wlog_event("OK", "Gateway stopped.");
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
	# Every path that concludes "nothing to do" returns SILENTLY - no log call,
	# so no log session and no logfile. This runs from cron every five minutes;
	# a line saying that all is well, written 288 times a day onto a RAM disk,
	# buries the runs that actually matter. Only acting is worth recording.
	#
	# An explicit --verbose run still logs, because logsession() is opened up
	# front for it.

	return 0 if (-e $stopped_marker);
	return 0 if (!gateway_installed());

	# Nothing to supervise before the plugin has been set up. Without this the
	# cron check would fail a start every five minutes on a freshly installed
	# plugin and fill the log with errors about missing credentials.
	my $cfg = plugin_config();
	if (!length(mg_trim($cfg->{saic_user} // "")) || !length($cfg->{saic_password} // "")) {
		return 0;
	}

	if (gateway_running()) {
		reset_failures();
		apply_refresh_policy($cfg);
		return 0;
	}

	my $failures = read_failures() + 1;
	write_failures($failures);
	if ($failures > $max_failures) {
		wlog_err("The gateway failed $failures times in a row. Not restarting again until it is started manually.");
		return 1;
	}
	wlog_event("WARNING", "The gateway is not running (failure $failures of $max_failures). Restarting.");
	return do_start();
}

##############################################################################
# Refresh periods
##############################################################################

# The tables this section works with - @REFRESH_PERIODS, @FINGERPRINT_TOPICS
# and @REFRESH_LADDER - are declared at the top of the file. A file scoped
# "my" is only assigned once execution reaches it, and the action dispatch
# runs above this point, so declaring them here would leave them empty.

sub policy_state_file { return "$runtime_dir/refresh_policy.json"; }

# Brings every vehicle's refresh periods in line with the settings and the
# back off ladder. Silent unless something actually changes.
sub apply_refresh_policy
{
	my ($cfg) = @_;

	my $root = topic_root($cfg);
	return if (!length($root));

	# No answer means no gateway topics on the broker yet, or no broker at all.
	# Neither is this run's problem - do_check() has already established that
	# the process is alive.
	my @vins = mqtt_vins($root);
	return if (!@vins);

	my $previous = read_policy_state();
	my $now      = time();
	my %state;

	foreach my $vin (@vins) {
		$state{$vin} = refresh_policy_for_vehicle($cfg, $root, $vin, $previous->{$vin}, $now);
	}

	# Vehicles that disappeared from the account are dropped with the rewrite.
	write_policy_state(\%state);
	return;
}

sub refresh_policy_for_vehicle
{
	my ($cfg, $root, $vin, $previous, $now) = @_;
	$previous = {} if (ref($previous) ne "HASH");

	my $base = "$root/vehicles/$vin";

	# A read that times out must not look like a change. Without this a
	# moment of broker latency would read the value as empty, count as
	# activity, reset the ladder and write a line about a value that never
	# moved - so the last known value is kept instead.
	my $before = (ref($previous->{values}) eq "HASH") ? $previous->{values} : {};
	my %values;
	foreach my $topic (@FINGERPRINT_TOPICS) {
		my $value = mqtt_read("$base/$topic", 500);
		$value = $before->{$topic} if (!defined($value));
		$values{$topic} = $value // "";
	}
	my $phase    = mqtt_read("$base/refresh/pollingPhase", 500) // "";
	my $activity = mqtt_read("$base/refresh/lastActivity", 500) // $previous->{activity} // "";
	my $cable    = is_true($values{"drivetrain/chargerConnected"});

	# On the first sighting there is nothing to compare against, so the quiet
	# clock simply starts now - without claiming that anything changed.
	my $first  = (ref($previous->{values}) eq "HASH") ? 0 : 1;
	my $reason = $first ? undef : refresh_activity_reason($previous, \%values, $phase, $activity);

	my $since = $previous->{since};
	$since = $now if ($first || defined($reason) || !$since || $since > $now);
	my $quiet = $now - $since;

	my $step = 0;
	foreach my $rung (@REFRESH_LADDER) {
		$step = $rung->[1] if ($quiet >= $rung->[0]);
	}

	# A car on the cable can start charging at any moment without anyone
	# touching it - a timer in the car, the wallbox, the tariff. Letting the
	# interval climb here is exactly how a scheduled night charge stays
	# invisible until the next day, which is the case this mechanism exists
	# for. Unplugged, the car really is dormant and may back off.
	my $hold = ($step > 0 && $cable) ? 1 : 0;
	$step = 0 if ($hold);

	my %wanted = refresh_period_targets($cfg);
	$wanted{inActive} = $step if ($step > $wanted{inActive});

	# Why the inactive interval is what it is - the one line worth reading in
	# this log a week later.
	my $why = "";
	if    ($hold)                               { $why = "charging cable connected"; }
	elsif ($step > ($previous->{step} // 0))    { $why = "no change seen for " . human_span($quiet); }
	elsif (defined($reason) && length($reason)) { $why = $reason; }

	# Bring every period in line, and keep track of what was published: a
	# value the gateway never picks up would otherwise produce the same line
	# every five minutes forever - a car removed from the account whose
	# retained topics linger is exactly that case.
	my %published = (ref($previous->{published}) eq "HASH") ? %{$previous->{published}} : ();
	foreach my $period (@REFRESH_PERIODS) {
		my $topic = $period->{topic};
		my $want  = $wanted{$topic};

		my $have  = mqtt_read("$base/refresh/period/$topic", 500);
		my $known = (defined($have) && $have =~ /\A\d+\z/) ? int($have) : undef;
		if (defined($known) && $known == $want) {
			$published{$topic} = $want;
			next;
		}

		# Retained, because the gateway replays these on every start
		# (is_replayable_when_retained) - that is how the setting survives a
		# gateway restart and a reboot.
		LoxBerry::IO::mqtt_retain("$base/refresh/period/$topic/set", $want);

		my $repeat = (defined($published{$topic}) && $published{$topic} == $want) ? 1 : 0;
		$published{$topic} = $want;
		next if ($repeat);

		my $message = mask_vin($vin) . ": $topic query interval ";
		$message .= defined($known) ? human_period($known) . " -> " . human_period($want)
		                            : "set to " . human_period($want);
		$message .= " ($why)" if ($topic eq "inActive" && length($why));
		wlog_event("INFO", $message);
	}

	# The hold produces no value change, so without its own line it would be
	# invisible - and "why did it never back off?" is exactly the question
	# someone will ask.
	if ($hold && !$previous->{hold}) {
		wlog_event("INFO", mask_vin($vin) . ": inActive query interval held at "
			. human_period($wanted{inActive}) . " (charging cable connected)");
	}

	return {
		values    => \%values,
		activity  => $activity,
		since     => $since,
		step      => $step,
		hold      => $hold,
		published => \%published,
	};
}

# What happened to the car since the last run, as text - or undef for "nothing".
sub refresh_activity_reason
{
	my ($previous, $values, $phase, $activity) = @_;

	my @changed;
	foreach my $topic (@FINGERPRINT_TOPICS) {
		my $was = $previous->{values}{$topic} // "";
		my $is  = $values->{$topic} // "";
		next if ($was eq $is);
		my ($name) = $topic =~ m{([^/]+)\z};
		push @changed, length($was) ? "$name $was -> $is" : "$name $is";
	}
	return join(", ", @changed) if (@changed);

	# The gateway decides the phase itself; anything but "inactive" means it
	# has already seen the car doing something.
	return "polling phase $phase" if (length($phase) && lc($phase) ne "inactive");

	# A message from the car - the gateway's own wake up path.
	my $before = $previous->{activity} // "";
	return "vehicle message received" if (length($activity) && length($before) && $activity ne $before);

	return undef;
}

# The configured periods, falling back to the defaults for empty fields.
sub refresh_period_targets
{
	my ($cfg) = @_;

	my %want;
	foreach my $period (@REFRESH_PERIODS) {
		my $value = mg_trim($cfg->{$period->{key}} // "");
		$want{$period->{topic}} = ($value =~ /\A\d+\z/ && $value > 0) ? int($value) : $period->{default};
	}
	return %want;
}

sub read_policy_state
{
	my $raw = read_whole_file(policy_state_file());
	return {} if (!defined($raw) || $raw !~ /\S/);
	my $data = eval { JSON::PP->new->relaxed->decode($raw) };
	return {} if ($@ || ref($data) ne "HASH");
	return $data;
}

# Lives on the RAM disk on purpose: after a reboot the ladder starts at the
# bottom again, which polls a dormant car a little more often than necessary
# for a day - the harmless direction of being wrong.
sub write_policy_state
{
	my ($state) = @_;

	my $json = eval { JSON::PP->new->canonical->pretty->encode($state) };
	return if ($@ || !defined($json));
	open(my $fh, ">", policy_state_file()) or return;
	print $fh $json;
	close($fh);
	return;
}

# VINs identify a car and its owner, and logs get pasted into forum posts.
sub mask_vin
{
	my ($vin) = @_;
	return $vin if (length($vin) < 8);
	return substr($vin, 0, 3) . "..." . substr($vin, -4);
}

sub human_period
{
	my ($seconds) = @_;

	return "${seconds}s"              if ($seconds < 60);
	return int($seconds / 60) . "m"   if ($seconds < 3600);

	my $hours   = int($seconds / 3600);
	my $minutes = int(($seconds % 3600) / 60);
	return ($minutes ? "${hours}h${minutes}m" : "${hours}h") if ($seconds < 86400);

	my $days = int($seconds / 86400);
	$hours   = int(($seconds % 86400) / 3600);
	return $hours ? "${days}d${hours}h" : "${days}d";
}

sub human_span
{
	my ($seconds) = @_;
	my $hours   = int($seconds / 3600);
	my $minutes = int(($seconds % 3600) / 60);
	return sprintf("%dh%02dm", $hours, $minutes);
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
	my $prefix = mg_trim($cfg->{mqtt_topic} // "");
	$prefix = "saic" if (!length($prefix));
	push @pairs, ["MQTT_TOPIC", $prefix, 0];
	push @pairs, ["MQTT_ALLOW_DOTS_IN_TOPIC", is_true($cfg->{mqtt_allow_dots_in_topic}) ? "True" : "False", 0];

	# --- SAIC account ------------------------------------------------------
	push @pairs, ["SAIC_USER", $cfg->{saic_user} // "", 0];
	push @pairs, ["SAIC_PASSWORD", $cfg->{saic_password} // "", 1];

	my $region = lc(mg_trim($cfg->{saic_region} // "eu"));
	$region = "eu" if (!exists($REST_URI{$region}));
	push @pairs, ["SAIC_REGION", $region, 0];
	push @pairs, ["SAIC_REST_URI", $REST_URI{$region}, 0];

	push @pairs, ["SAIC_PHONE_COUNTRY_CODE", mg_trim($cfg->{saic_phone_country_code}), 0]
		if (length(mg_trim($cfg->{saic_phone_country_code} // "")));

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
		my $value = mg_trim($cfg->{$entry->[0]} // "");
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
	if (length(mg_trim($extra))) {
		push @lines, "";
		push @lines, "# Additional environment variables from the Settings tab";
		foreach my $line (split(/\r?\n/, $extra)) {
			next if ($line !~ /\S/ || $line =~ /\A\s*#/);
			push @lines, mg_trim($line);
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

# The gateway declares a minimum Python version in its pyproject.toml. Checking
# it before the start turns an unreadable ImportError traceback in the gateway
# log into one clear line. gateway_pkg.sh builds the venv with an interpreter
# that satisfies the requirement, so this should never fire - it catches the
# venv having been built against an interpreter that later disappeared or was
# replaced, for instance by an OS upgrade.
#
# Returns (have, need) when the requirement is not met, and nothing otherwise -
# including when either version cannot be determined, because a failed check
# must never be a reason not to start.
sub python_requirement_unmet
{
	open(my $fh, "<", "$gateway_dir/pyproject.toml") or return;
	local $/;
	my $raw = <$fh>;
	close($fh);

	my ($spec) = ($raw // "") =~ /requires-python\s*=\s*["']([^"']+)["']/;
	return if (!$spec);
	my ($need) = $spec =~ />=\s*(\d+\.\d+)/;
	return if (!$need);

	my $have = `$venv_python -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null`;
	$have = "" if (!defined($have));
	chomp($have);
	return if ($have !~ /\A\d+\.\d+\z/);

	my ($hmaj, $hmin) = split(/\./, $have);
	my ($nmaj, $nmin) = split(/\./, $need);
	return ($have, $need) if ($hmaj < $nmaj || ($hmaj == $nmaj && $hmin < $nmin));
	return;
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

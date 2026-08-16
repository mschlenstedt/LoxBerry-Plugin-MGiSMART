#!/usr/bin/perl

# MG iSMART web interface.
#
# Uses the LoxBerry Design System (lb-* classes), not jQuery Mobile: the fourth
# argument to lbheader() is "nojqm". The page is a set of tabs, one template per
# tab, selected through the ?form= parameter and rendered as a navbar. All data
# is fetched from ajax.cgi, so a tab switch never loses state on the device.

use strict;
use warnings;
use CGI;
use LoxBerry::System;
use LoxBerry::Web;
use LoxBerry::Log;

my $cgi = CGI->new;
my $q   = $cgi->Vars;

my $version = LoxBerry::System::pluginversion();

$q->{form} = "gateway" if (!$q->{form});

my $template;
my $templateout;
my %L;

if ($q->{form} eq "settings") {
	$template = LoxBerry::System::read_file("$lbptemplatedir/tab_settings.html");
	&form_settings();
}
elsif ($q->{form} eq "update") {
	$template = LoxBerry::System::read_file("$lbptemplatedir/tab_update.html");
	&form_update();
}
elsif ($q->{form} eq "logfiles") {
	$template = LoxBerry::System::read_file("$lbptemplatedir/tab_logfiles.html");
	&form_logfiles();
}
else {
	$q->{form} = "gateway";
	$template = LoxBerry::System::read_file("$lbptemplatedir/tab_gateway.html");
	&form_gateway();
}

&printtemplate();
exit;

##########################################################################
# Tab forms
##########################################################################

sub form_gateway  { &preparetemplate(); return(); }
sub form_settings { &preparetemplate(); return(); }
sub form_update   { &preparetemplate(); return(); }

sub form_logfiles
{
	&preparetemplate();
	$templateout->param("LOGLIST", LoxBerry::Web::loglist_html());
	return();
}

##########################################################################
# Template and navbar
##########################################################################

sub preparetemplate
{
	# The shared JavaScript is appended to every tab. It runs through
	# HTML::Template too, so it can use <TMPL_VAR> for localized strings, and
	# fetches its data from ajax.cgi.
	$template .= LoxBerry::System::read_file("$lbptemplatedir/javascript.js");

	$templateout = HTML::Template->new_scalar_ref(
		\$template,
		global_vars       => 1,
		loop_context_vars => 1,
		die_on_bad_params => 0,
	);
	%L = LoxBerry::System::readlanguage($templateout, "language.ini");

	# Navbar entries. Numeric keys control the display order.
	our %navbar;

	$navbar{10}{Name}   = $L{'COMMON.TAB_GATEWAY'};
	$navbar{10}{URL}    = 'index.cgi?form=gateway';
	$navbar{10}{active} = 1 if ($q->{form} eq "gateway");

	$navbar{20}{Name}   = $L{'COMMON.TAB_SETTINGS'};
	$navbar{20}{URL}    = 'index.cgi?form=settings';
	$navbar{20}{active} = 1 if ($q->{form} eq "settings");

	$navbar{30}{Name}   = $L{'COMMON.TAB_UPDATE'};
	$navbar{30}{URL}    = 'index.cgi?form=update';
	$navbar{30}{active} = 1 if ($q->{form} eq "update");

	$navbar{40}{Name}   = $L{'COMMON.TAB_LOGFILES'};
	$navbar{40}{URL}    = 'index.cgi?form=logfiles';
	$navbar{40}{active} = 1 if ($q->{form} eq "logfiles");

	return();
}

sub printtemplate
{
	# "nojqm" selects the LoxBerry Design System instead of jQuery Mobile.
	LoxBerry::Web::lbheader($L{'COMMON.PLUGIN_TITLE'} . " V$version",
		"https://wiki.loxberry.de/plugins/mgismart", "", "nojqm");
	print LoxBerry::Log::get_notifications_html($lbpplugindir);
	print $templateout->output();
	LoxBerry::Web::lbfooter();
	return();
}

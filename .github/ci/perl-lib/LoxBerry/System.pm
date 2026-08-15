package LoxBerry::System;
use strict;
use warnings;

# Minimal CI stub for LoxBerry::System. It provides just enough of the real
# module for a "perl -c" syntax check on a plain Perl install without LoxBerry:
# the directory variables plugin code imports, and no-op versions of the
# handful of functions this plugin calls.

our $lbhomedir = '/opt/loxberry';
our $lbpplugindir = 'mgismart';
our $lbpbindir = '/opt/loxberry/bin/plugins/mgismart';
our $lbpconfigdir = '/opt/loxberry/config/plugins/mgismart';
our $lbptemplatedir = '/opt/loxberry/templates/plugins/mgismart';
our $lbplogdir = '/opt/loxberry/log/plugins/mgismart';
our $lbsconfigdir = '/opt/loxberry/config/system';

sub import {
	my $caller = caller;
	no strict 'refs';
	*{"${caller}::lbhomedir"} = \$lbhomedir;
	*{"${caller}::lbpplugindir"} = \$lbpplugindir;
	*{"${caller}::lbpbindir"} = \$lbpbindir;
	*{"${caller}::lbpconfigdir"} = \$lbpconfigdir;
	*{"${caller}::lbptemplatedir"} = \$lbptemplatedir;
	*{"${caller}::lbplogdir"} = \$lbplogdir;
	*{"${caller}::lbsconfigdir"} = \$lbsconfigdir;
}

sub pluginversion { return "0.0.0"; }
sub pluginloglevel { return 6; }
sub plugindata { return {}; }
sub lock { return undef; }
sub unlock { return 1; }
sub readlanguage { return (); }
sub execute { my (%p) = @_; my $out = `$p{command} 2>&1`; return ($? >> 8, $out); }
sub read_file { my ($f) = @_; open(my $fh, "<", $f) or return ""; local $/; my $c = <$fh>; close($fh); return $c; }

1;

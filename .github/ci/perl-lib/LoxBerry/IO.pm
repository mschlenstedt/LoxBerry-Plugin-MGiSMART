package LoxBerry::IO;
use strict;
use warnings;

# Minimal CI stub for LoxBerry::IO. Only the MQTT helpers this plugin uses are
# present, as no-ops, so a "perl -c" syntax check runs without LoxBerry and
# without a broker.
#
# Note that the real module exports mqtt_get but NOT mqtt_connectiondetails,
# which callers have to qualify - the stub mirrors that on purpose, so a missing
# qualification fails here too.

use base 'Exporter';
our @EXPORT = qw(mqtt_connect mqtt_publish mqtt_retain mqtt_set mqtt_get);

sub mqtt_connectiondetails { return {}; }
sub mqtt_connect { return undef; }
sub mqtt_publish { return undef; }
sub mqtt_retain { return undef; }
sub mqtt_set { return undef; }
sub mqtt_get { return undef; }

1;

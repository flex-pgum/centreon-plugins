#
# This file is derived from GLPI Agent (https://github.com/glpi-project/glpi-agent),
# lib/GLPI/Agent/SOAP/WsMan, which is distributed under the terms of the
# GNU General Public License version 2 (GPL-2.0).
#
# NOTE: the GPL-2.0 is not compatible with the Apache-2.0 license used by
# centreon-plugins. Licensing must be clarified with the GLPI Agent copyright
# holders before this code is distributed as part of centreon-plugins.
#

package centreon::plugins::wsman::soap::Datetime;

use strict;
use warnings;

use centreon::plugins::wsman::soap::Node;

## no critic (ProhibitMultiplePackages)
package
    Datetime;

use parent
    'Node';

use constant xmlns  => 'cim';

sub new {
    my ($class, $datetime) = @_;

    # Convert Datetime
    if ($datetime =~ /^(\d{4})-(\d{2})-(\d{2})T00:00:00Z$/) {
        $datetime = "$2/$3/$1";
    } elsif ($datetime =~ /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})/) {
        $datetime = "$1-$2-$3 $4:$5:$6";
    }

    my $self = $class->SUPER::new($datetime);

    bless $self, $class;

    return $self;
}

1;

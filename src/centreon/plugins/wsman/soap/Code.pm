#
# This file is derived from GLPI Agent (https://github.com/glpi-project/glpi-agent),
# lib/GLPI/Agent/SOAP/WsMan, which is distributed under the terms of the
# GNU General Public License version 2 (GPL-2.0).
#
# NOTE: the GPL-2.0 is not compatible with the Apache-2.0 license used by
# centreon-plugins. Licensing must be clarified with the GLPI Agent copyright
# holders before this code is distributed as part of centreon-plugins.
#

package centreon::plugins::wsman::soap::Code;

use strict;
use warnings;

use centreon::plugins::wsman::soap::Node;

## no critic (ProhibitMultiplePackages)
package
    Code;

use parent
    'Node';

sub support {
    return {
        Value   => "s:Value",
    };
}

sub xmlns {
    my ($self) = @_;

    return $self->{_signal} ? 'rsp' : 's';
}

sub signal {
    my ($class, $signal) = @_;

    my %code = (
        terminate   => "http://schemas.microsoft.com/wbem/wsman/1/windows/shell/signal/terminate",
    );

    return unless $code{$signal};

    my $new = $class->new($code{$signal});
    $new->{_signal} = 1;

    return $new;
}

1;

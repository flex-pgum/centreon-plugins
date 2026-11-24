#
# This file is derived from GLPI Agent (https://github.com/glpi-project/glpi-agent),
# lib/GLPI/Agent/SOAP/WsMan, which is distributed under the terms of the
# GNU General Public License version 2 (GPL-2.0).
#
# NOTE: the GPL-2.0 is not compatible with the Apache-2.0 license used by
# centreon-plugins. Licensing must be clarified with the GLPI Agent copyright
# holders before this code is distributed as part of centreon-plugins.
#

package centreon::plugins::wsman::soap::Fault;

use strict;
use warnings;

use centreon::plugins::wsman::soap::Node;

## no critic (ProhibitMultiplePackages)
package
    Fault;

use parent
    'Node';

use constant    xmlns   => 's';

sub support {
    return {
        Reason  => "s:Reason",
        Code    => "s:Code",
    };
}

sub reason {
    my ($self) = @_;

    my ($reason) = $self->get('Reason');

    return $reason // Reason->new();
}

sub errorCode {
    my ($self) = @_;

    my $code;

    my $detail = $self->get('Detail')
        or return 0;

    my $wmierror = $detail->get('MSFT_WmiError_Type');
    my $errorcode = $wmierror ? $wmierror->get('error_Code') : undef;
    $code = $errorcode->string if $errorcode;

    my $wsmanerror;
    $wsmanerror = $detail->get('WSManFault') unless $code;
    $code = $wsmanerror->attribute('Code') if $wsmanerror;

    return $code // 0;
}

1;

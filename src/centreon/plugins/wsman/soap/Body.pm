#
# This file is derived from GLPI Agent (https://github.com/glpi-project/glpi-agent),
# lib/GLPI/Agent/SOAP/WsMan, which is distributed under the terms of the
# GNU General Public License version 2 (GPL-2.0).
#
# NOTE: the GPL-2.0 is not compatible with the Apache-2.0 license used by
# centreon-plugins. Licensing must be clarified with the GLPI Agent copyright
# holders before this code is distributed as part of centreon-plugins.
#

package centreon::plugins::wsman::soap::Body;

use strict;
use warnings;

use centreon::plugins::wsman::soap::Node;

## no critic (ProhibitMultiplePackages)
package
    Body;

use parent
    'Node';

use constant    xmlns   => 's';

use centreon::plugins::wsman::soap::Fault;
use centreon::plugins::wsman::soap::EnumerateResponse;

sub support {
    return {
        IdentifyResponse    => "wsmid:IdentifyResponse",
        Fault               => "s:Fault",
        EnumerateResponse   => "n:EnumerateResponse",
        PullResponse        => "n:PullResponse",
        Shell               => "rsp:Shell",
        ReceiveResponse     => "rsp:ReceiveResponse",
        ResourceCreated     => "x:ResourceCreated",
        CommandResponse     => "rsp:CommandResponse",
    };
}

sub fault {
    my ($self) = @_;

    my ($fault) = $self->get('Fault');

    return $fault // Fault->new();
}

sub enumeration {
    my ($self, $ispull) = @_;

    my ($enum) = $self->get($ispull ? 'PullResponse' : 'EnumerateResponse');

    return $enum // EnumerateResponse->new();
}

1;

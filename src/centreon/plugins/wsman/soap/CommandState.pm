#
# This file is derived from GLPI Agent (https://github.com/glpi-project/glpi-agent),
# lib/GLPI/Agent/SOAP/WsMan, which is distributed under the terms of the
# GNU General Public License version 2 (GPL-2.0).
#
# NOTE: the GPL-2.0 is not compatible with the Apache-2.0 license used by
# centreon-plugins. Licensing must be clarified with the GLPI Agent copyright
# holders before this code is distributed as part of centreon-plugins.
#

package centreon::plugins::wsman::soap::CommandState;

use strict;
use warnings;

use centreon::plugins::wsman::soap::Node;

## no critic (ProhibitMultiplePackages)
package
    CommandState;

use parent
    'Node';


use constant    xmlns   => 'rsp';

sub support {
    return {
        ExitCode    => "rsp:ExitCode",
    };
}

sub done {
    my ($self, $cid) = @_;

    if ($cid) {
        my $thiscid = $self->attribute("CommandId");
        return 0 unless $thiscid && $thiscid eq $cid;
    }

    my $done_url = "http://schemas.microsoft.com/wbem/wsman/1/windows/shell/CommandState/Done";
    my $state = $self->attribute("State");

    return $state && $state eq $done_url ? 1 : 0 ;
}

sub exitcode {
    my ($self) = @_;

    my $exitcode = $self->get('ExitCode')
        or return;

    return $exitcode->string();
}

1;

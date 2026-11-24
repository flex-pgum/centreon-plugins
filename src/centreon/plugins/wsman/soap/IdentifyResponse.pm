#
# This file is derived from GLPI Agent (https://github.com/glpi-project/glpi-agent),
# lib/GLPI/Agent/SOAP/WsMan, which is distributed under the terms of the
# GNU General Public License version 2 (GPL-2.0).
#
# NOTE: the GPL-2.0 is not compatible with the Apache-2.0 license used by
# centreon-plugins. Licensing must be clarified with the GLPI Agent copyright
# holders before this code is distributed as part of centreon-plugins.
#

package centreon::plugins::wsman::soap::IdentifyResponse;

use strict;
use warnings;

use centreon::plugins::wsman::soap::Node;

## no critic (ProhibitMultiplePackages)
package
    IdentifyResponse;

use parent
    'Node';

use constant    xmlns   => 'wsmid';

use centreon::plugins::wsman::soap::Identify;

sub values {
    return [ qw(ProtocolVersion ProductVendor ProductVersion) ];
}

sub isvalid {
    my ($self) = @_;

    my ($xsd) = $self->attribute("xmlns:".xmlns);

    return $xsd eq Identify->xsd;
}

sub ProductVendor {
    my ($self) = @_;

    return $self->get('ProductVendor')->string;
}

sub ProductVersion {
    my ($self) = @_;

    return $self->get('ProductVersion')->string;
}

1;

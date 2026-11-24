#
# This file is derived from GLPI Agent (https://github.com/glpi-project/glpi-agent),
# lib/GLPI/Agent/SOAP/WsMan, which is distributed under the terms of the
# GNU General Public License version 2 (GPL-2.0).
#
# NOTE: the GPL-2.0 is not compatible with the Apache-2.0 license used by
# centreon-plugins. Licensing must be clarified with the GLPI Agent copyright
# holders before this code is distributed as part of centreon-plugins.
#

package centreon::plugins::wsman::soap::Address;

use strict;
use warnings;

use centreon::plugins::wsman::soap::Node;

## no critic (ProhibitMultiplePackages)
package
    Address;

use parent
    'Node';

use constant    xmlns   => 'a';

use centreon::plugins::wsman::soap::Attribute;

sub new {
    my ($class, $url) = @_;

    my $self = $class->SUPER::new(
        Attribute->must_understand(),
        $url,
    );

    bless $self, $class;
    return $self;
}

sub anonymous {
    my ($class) = @_;

    return $class->new("http://schemas.xmlsoap.org/ws/2004/08/addressing/role/anonymous");
}

1;

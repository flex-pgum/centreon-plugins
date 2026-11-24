#
# This file is derived from GLPI Agent (https://github.com/glpi-project/glpi-agent),
# lib/GLPI/Agent/SOAP/WsMan, which is distributed under the terms of the
# GNU General Public License version 2 (GPL-2.0).
#
# NOTE: the GPL-2.0 is not compatible with the Apache-2.0 license used by
# centreon-plugins. Licensing must be clarified with the GLPI Agent copyright
# holders before this code is distributed as part of centreon-plugins.
#

package centreon::plugins::wsman::soap::Selector;

use strict;
use warnings;

use centreon::plugins::wsman::soap::Node;

## no critic (ProhibitMultiplePackages)
package
    Selector;

use parent
    'Node';

use centreon::plugins::wsman::soap::Selector;

use constant    xmlns   => 'w';

sub new {
    my ($class, @condition) = @_;

    @condition =( Attribute->new("Name" => $1), $2 )
        if @condition == 1 && $condition[0] =~ /^(\w+)=(\w+)$/;

    my $self = $class->SUPER::new(@condition);

    bless $self, $class;
    return $self;
}

1;

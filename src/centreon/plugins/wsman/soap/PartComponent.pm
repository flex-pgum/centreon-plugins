#
# This file is derived from GLPI Agent (https://github.com/glpi-project/glpi-agent),
# lib/GLPI/Agent/SOAP/WsMan, which is distributed under the terms of the
# GNU General Public License version 2 (GPL-2.0).
#
# NOTE: the GPL-2.0 is not compatible with the Apache-2.0 license used by
# centreon-plugins. Licensing must be clarified with the GLPI Agent copyright
# holders before this code is distributed as part of centreon-plugins.
#

package centreon::plugins::wsman::soap::PartComponent;

use strict;
use warnings;

use centreon::plugins::wsman::soap::Node;

## no critic (ProhibitMultiplePackages)
package
    PartComponent;

# Required if we need to make request on Win32_SystemUsers

use parent
    'Node';

use constant    xmlns   => 'p';

use constant    dump_as_string => 1;

sub string {
    my ($self) = @_;

    my $refparams = $self->get("ReferenceParameters")
        or return;

    my $resource = $refparams->get("ResourceURI")
        or return;

    my $selectorset = $refparams->get("SelectorSet")
        or return;

    my $selector = $selectorset->get("Selector")
        or return;

    my $string = $resource->string.".";
    foreach my $node ($selector->nodes()) {
        my $name = $node->attribute("Name");
        my $text = $node->string;
        $string .= "," unless $string =~ /\.$/;
        $string .= "$name=\"$text\"";
    }

    return $string;
}

1;

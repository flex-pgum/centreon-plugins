#
# This file is derived from GLPI Agent (https://github.com/glpi-project/glpi-agent),
# lib/GLPI/Agent/SOAP/WsMan, which is distributed under the terms of the
# GNU General Public License version 2 (GPL-2.0).
#
# NOTE: the GPL-2.0 is not compatible with the Apache-2.0 license used by
# centreon-plugins. Licensing must be clarified with the GLPI Agent copyright
# holders before this code is distributed as part of centreon-plugins.
#

package centreon::plugins::wsman::soap::PullResponse;

use strict;
use warnings;

use centreon::plugins::wsman::soap::EnumerateResponse;

## no critic (ProhibitMultiplePackages)
package
    PullResponse;

use parent
    'EnumerateResponse';

sub support {
    return {
        EnumerationContext  => "n:EnumerationContext",
        Items               => "n:Items",
        EndOfSequence       => "n:EndOfSequence",
    };
}

1;

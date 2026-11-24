#
# This file is derived from GLPI Agent (https://github.com/glpi-project/glpi-agent),
# lib/GLPI/Agent/SOAP/WsMan, which is distributed under the terms of the
# GNU General Public License version 2 (GPL-2.0).
#
# NOTE: the GPL-2.0 is not compatible with the Apache-2.0 license used by
# centreon-plugins. Licensing must be clarified with the GLPI Agent copyright
# holders before this code is distributed as part of centreon-plugins.
#

package centreon::plugins::wsman::soap::SessionId;

use strict;
use warnings;

use centreon::plugins::wsman::soap::Node;

## no critic (ProhibitMultiplePackages)
package
    SessionId;

use parent
    'Node';


use constant    xmlns   => 'p';

use centreon::plugins::wsman::soap::Attribute;

sub new {
    my ($class, $sessionid) = @_;

    return $class->SUPER::new($sessionid) if $sessionid;

    my $uuid = Node::new_uuid();

    my $self = $class->SUPER::new(
        Attribute->must_understand("false"),
        "uuid:$uuid",
    );

    $self->{_uuid} = $uuid;

    bless $self, $class;
    return $self;
}

sub uuid {
    my ($self) = @_;

    my ($uuid) = $self->string =~ /^uuid:(.*)$/;

    return unless $self->{_uuid} || $uuid;

    return $self->{_uuid} if $self->{_uuid};

    return $self->{_uuid} = $uuid;
}

package
    SessionID;

use parent
    'Node';

use constant    xmlns   => 'p';

1;

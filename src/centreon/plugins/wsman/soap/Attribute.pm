#
# This file is derived from GLPI Agent (https://github.com/glpi-project/glpi-agent),
# lib/GLPI/Agent/SOAP/WsMan, which is distributed under the terms of the
# GNU General Public License version 2 (GPL-2.0).
#
# NOTE: the GPL-2.0 is not compatible with the Apache-2.0 license used by
# centreon-plugins. Licensing must be clarified with the GLPI Agent copyright
# holders before this code is distributed as part of centreon-plugins.
#

package centreon::plugins::wsman::soap::Attribute;

use strict;
use warnings;

## no critic (ProhibitMultiplePackages)
package
    Attribute;

sub new {
    my ($class, %params) = @_;

    my $self = \%params;

    bless $self, $class;
    return $self;
}

sub get {
    my ($self, $key) = @_;

    return $self->{$key} if $key;

    my @attributes;
    foreach my $key (keys(%{$self})) {
        push @attributes, "-$key", $self->{$key};
    }

    return \@attributes;
}

sub must_understand {
    my ($class, $bool) = @_;

    return $class->new("s:mustUnderstand" => $bool // "true");
}

1;

#
# This file is derived from GLPI Agent (https://github.com/glpi-project/glpi-agent),
# lib/GLPI/Agent/SOAP/WsMan, which is distributed under the terms of the
# GNU General Public License version 2 (GPL-2.0).
#
# NOTE: the GPL-2.0 is not compatible with the Apache-2.0 license used by
# centreon-plugins. Licensing must be clarified with the GLPI Agent copyright
# holders before this code is distributed as part of centreon-plugins.
#

package centreon::plugins::wsman::soap::Envelope;

use strict;
use warnings;

use centreon::plugins::wsman::soap::Node;

## no critic (ProhibitMultiplePackages)
package
    Envelope;

use parent
    'Node';

use constant    xmlns   => 's';

use centreon::plugins::wsman::soap::Attribute;
use centreon::plugins::wsman::soap::Header;
use centreon::plugins::wsman::soap::Body;

my %ns = (
    s   => "http://www.w3.org/2003/05/soap-envelope",
    a   => "http://schemas.xmlsoap.org/ws/2004/08/addressing",
    n   => "http://schemas.xmlsoap.org/ws/2004/09/enumeration",
    w   => "http://schemas.dmtf.org/wbem/wsman/1/wsman.xsd",
    p   => "http://schemas.microsoft.com/wbem/wsman/1/wsman.xsd",
    b   => "http://schemas.dmtf.org/wbem/wsman/1/cimbinding.xsd",

    wsmid   => "http://schemas.dmtf.org/wbem/wsman/identity/1/wsmanidentity.xsd"
);

sub support {
    return {
        Body    => "s:Body",
        Header  => "s:Header",
    };
}

sub new {
    my ($class, @nodes) = @_;

    my $self;

    my ($first) = @nodes;

    if (ref($first) eq 'HASH') {
        # Remote may use another prefix than 's' for SOAP envelope namespace
        my ($key) = grep { /^(?:\w+:)?Envelope$/ } keys(%{$first});
        @nodes = ($first->{$key}) if $key && $first->{$key};
    }

    $self = $class->SUPER::new(@nodes);
    bless $self, $class;

    return $self;
}

sub body {
    my ($self) = @_;

    my ($body) = $self->get('Body');

    return $body // Body->new();
}

sub header {
    my ($self) = @_;

    my ($header) = $self->get('Header');

    return $header // Header->new();
}

sub reset_namespace {
    my ($self, $namespaces) = @_;
    my @attributes;

    if (ref($namespaces) eq '') {
        my @ns = split(/,/, $namespaces);
        foreach my $ns (@ns) {
            next unless $ns{$ns};
            push @attributes, "xmlns:$ns" => $ns{$ns};
        }
    }
    $self->SUPER::reset_namespace(
        ref($namespaces) eq 'Attribute' ? $namespaces : Attribute->new(@attributes)
    );
}

1;

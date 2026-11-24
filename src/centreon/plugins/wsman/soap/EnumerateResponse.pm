#
# This file is derived from GLPI Agent (https://github.com/glpi-project/glpi-agent),
# lib/GLPI/Agent/SOAP/WsMan, which is distributed under the terms of the
# GNU General Public License version 2 (GPL-2.0).
#
# NOTE: the GPL-2.0 is not compatible with the Apache-2.0 license used by
# centreon-plugins. Licensing must be clarified with the GLPI Agent copyright
# holders before this code is distributed as part of centreon-plugins.
#

package centreon::plugins::wsman::soap::EnumerateResponse;

use strict;
use warnings;

use centreon::plugins::wsman::soap::Node;

BEGIN {
    # Needed for PullResponse class
    $INC{'EnumerateResponse.pm'} = __FILE__;
}

## no critic (ProhibitMultiplePackages)
package
    EnumerateResponse;

use parent
    'Node';

use List::Util qw(first);
use centreon::plugins::wsman::soap::EnumerationContext;
use centreon::plugins::wsman::soap::EndOfSequence;

use constant    xmlns   => 'n';

sub new {
    my ($class, @enum) = @_;

    my $self = $class->SUPER::new(@enum);

    bless $self, $class;

    $self->push( EndOfSequence->new() ) unless @enum;

    return $self;
}

sub support {
    return {
        EnumerationContext  => "n:EnumerationContext",
        Items               => "w:Items",
        EndOfSequence       => "w:EndOfSequence",
    };
}

sub items {
    my ($self) = @_;

    my @items;
    foreach my $items ($self->nodes("Items")) {
        foreach my $item ($items->nodes()) {
            push @items, _dump($item);
        }
    }

    return @items;
}

# Return items as flat hashes of property name => text value, like it was
# returned by openwsman perl binding: when a property is set more than once
# (array property), the last value is kept and a nil property value is undef.
# This works for full instances (with xsi:type) as for WQL projections returned
# as XmlFragment nodes.
sub rows {
    my ($self) = @_;

    my @rows;
    foreach my $items ($self->nodes("Items")) {
        foreach my $child ($items->nodes()) {
            my @instances = $child->nodes();
            # Many instances with the same node name are kept as array items
            # of the node named as the instance class
            @instances = ($child)
                unless @instances && !grep { !$_->{_array_item} } @instances;
            foreach my $instance (@instances) {
                my $row = {};
                foreach my $property ($instance->nodes()) {
                    my $nil = $property->attribute('xsi:nil');
                    if ($nil && $nil eq 'true') {
                        $row->{$property->name} = undef;
                        next;
                    }
                    my @values = $property->nodes();
                    if (@values && !defined($property->{_text}) && !grep { !$_->{_array_item} } @values) {
                        $row->{$property->name} = $values[-1]->string;
                    } else {
                        $row->{$property->name} = $property->string;
                    }
                }
                push @rows, $row;
            }
        }
    }

    return @rows;
}

sub end_of_sequence {
    my ($self) = @_;

    return first { ref($_) eq "EndOfSequence" } $self->nodes();
}

sub _dump {
    my ($object) = @_;

    my @dump = ();

    my $dump = {};

    foreach my $node ($object->nodes()) {
        my $key = $node->name;
        my $nil = $node->attribute('xsi:nil');
        my @nodes = $node->nodes();
        if ($nil && $nil eq 'true') {
            $dump->{$key} = undef;
        } elsif ($node->attribute('xsi:type')) {
            push @dump, _dump($node);
            undef $dump;
        } elsif (ref($node) && $node->dump_as_string()) {
            $dump->{$key} = $node->string;
        } else {
            $dump->{$key} = @nodes > 1 ? [ map { $_->string } @nodes ] : $node->string;
        }
    }
    push @dump, $dump if $dump;

    return @dump;
}

sub context {
    my ($self) = @_;

    my ($context) = $self->get('EnumerationContext');

    $context->set_namespace() if $context;

    return $context // EnumerationContext->new();
}

1;

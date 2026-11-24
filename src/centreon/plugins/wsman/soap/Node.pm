#
# This file is derived from GLPI Agent (https://github.com/glpi-project/glpi-agent),
# lib/GLPI/Agent/SOAP/WsMan, which is distributed under the terms of the
# GNU General Public License version 2 (GPL-2.0).
#
# NOTE: the GPL-2.0 is not compatible with the Apache-2.0 license used by
# centreon-plugins. Licensing must be clarified with the GLPI Agent copyright
# holders before this code is distributed as part of centreon-plugins.
#

package centreon::plugins::wsman::soap::Node;

use strict;
use warnings;

BEGIN {
    $INC{'Node.pm'} = __FILE__;
}

## no critic (ProhibitMultiplePackages)
package
    Node;

use constant    xmlns   => "";
use constant    xsd     => "";

use constant    dump_as_string => 0;

use List::Util qw(first);

# Generate a random (version 4) UUID, replaces Data::UUID usage
sub new_uuid {
    my @bytes = map { int(rand(256)) } 1..16;
    $bytes[6] = ($bytes[6] & 0x0f) | 0x40;
    $bytes[8] = ($bytes[8] & 0x3f) | 0x80;
    return uc(sprintf('%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x', @bytes));
}

# Node name as found in XML, class name may differ when a dedicated class
# has been generated to avoid a collision with an existing perl package
sub name {
    my ($self) = @_;

    return $self->{_name} // ref($self);
}

sub new {
    my ($class, @nodes) = @_;

    my $self = {};

    # List of class names supported by this node
    my $supported = $class->support() // {};

    while (@nodes) {
        my $node = shift @nodes;
        my $ref = ref($node);
        if ($ref eq 'Attribute') {
            CORE::push @{$self->{_attributes}}, $node;
        } elsif ($ref eq 'Namespace') {
            CORE::push @{$self->{_attributes}}, $node->attributes;
        } elsif (!$ref && defined($node)) {
            if ($node eq '__nodeclass__' && @nodes) {
                $class = _load_class(shift @nodes, get_namespace($self));
            } elsif (ref($self->{_text})) {
                CORE::push @{$self->{_text}}, $ref ? @{$node} : $node;
            } elsif (defined($self->{_text})) {
                $self->{_text} = [ $self->{_text}, $ref ? @{$node} : $node ];
            } elsif (defined($node)) {
                $self->{_text} = $node;
            }
        } elsif ($ref eq 'ARRAY') {
            foreach my $object (@{$node}) {
                my $this = Node->new($object);
                # Remember this node is one of a list of same named XML nodes
                $this->{_array_item} = 1;
                CORE::push @{$self->{_nodes}}, $this;
            }
        } elsif ($ref eq 'HASH') {
            foreach my $key (keys(%{$node})) {
                if ($key =~ /^-(.+)$/) {
                    CORE::push @{$self->{_attributes}}, Attribute->new( $1 => $node->{$key} );
                    $class = _load_class($1) if $1 eq 'xsi:type' && $node->{$key} =~ /^p:(.+)$/;
                } elsif ($key eq '#text') {
                    $self->{_text} = $node->{$key} if defined($node->{$key});
                    $self->{_text} = $1 if $self->{_text} && $self->{_text} =~ /^#textuuid:(.*)$/;
                } else {
                    my $support = first { $supported->{$_} eq $key } keys(%{$supported});
                    ($support) = $key =~ /^(?:\w+:)?(\w+)$/ unless $support;
                    # Try to load class if still not loaded nor known
                    my $nodeclass = _load_class($support);
                    my $object = $nodeclass->new( $node->{$key} );
                    $object->{_name} = $support
                        if $nodeclass ne $support && ref($object) eq $nodeclass;
                    CORE::push @{$self->{_nodes}}, $object;
                }
            }
        } else {
            CORE::push @{$self->{_nodes}}, $node;
        }
    }

    bless $self, $class;
    return $self;
}

sub _load_class {
    my ($class, $namespace) = @_;

    # All supported classes are preloaded by centreon::plugins::wsman::soap
    # (no lookup on filesystem, so this also works with fatpacked plugins)
    return $class if $class->isa('Node');

    # Don't alter an existing perl package not related to WsMan (like 'Config'
    # or 'IO'), but use a dedicated one. The original node name is then
    # available with name() method.
    my $target = $class;
    if (_package_exists($class)) {
        $target = 'WsManNode::' . $class;
        return $target if $target->isa('Node');
    }

    # If a class is not known just create one with Node as template
    no strict 'refs'; ## no critic (ProhibitNoStrict)
    if ($namespace) {
        *{"${target}::xmlns"} = sub () { "$namespace" };
    }
    CORE::push @{"${target}::ISA"}, 'Node';

    return $target;
}

sub _package_exists {
    my ($class) = @_;

    no strict 'refs'; ## no critic (ProhibitNoStrict)
    return %{"${class}::"} ? 1 : 0;
}

sub namespace {
    my ($self) = @_;

    return "xmlns:".$self->xmlns() => $self->xsd();
}

sub get_namespace {
    my ($self) = @_;

    my $name = first { /^xmlns:./ } map { keys(%{$_}) } @{$self->{_attributes}}
        or return;

    return $name =~ /^xmlns:(\w+)$/;
}

sub set_namespace {
    my ($self) = @_;

    return if grep { /^xmlns:/ } map { keys(%{$_}) } @{$self->{_attributes}};

    $self->push( Attribute->new($self->namespace) );
}

sub reset_namespace {
    my ($self, @attributes) = @_;

    return delete $self->{_attributes} unless @attributes;

    $self->{_attributes} = \@attributes;
}

sub support {}

sub values {}

sub get {
    my ($self, $leaf) = @_;

    if ($leaf) {
        my ($leafnode) = grep { ref($_) eq $leaf } @{$self->{_nodes}};
        return $leafnode;
    }

    my %nodes;
    foreach my $node (@{$self->{_attributes}}, @{$self->{_nodes}}) {
        my $insert = $node->get();
        if (ref($insert) eq 'HASH') {
            foreach my $key (keys(%{$insert})) {
                if ($nodes{$key}) {
                    $nodes{$key} = [ $nodes{$key} ]
                        unless ref($nodes{$key}) eq 'ARRAY';
                    CORE::push @{$nodes{$key}}, $insert->{$key};
                } else {
                    $nodes{$key} = $insert->{$key};
                }
            }
        } elsif (ref($insert) eq 'ARRAY') {
            while (@{$insert}) {
                my $key = shift @{$insert};
                my $value = shift @{$insert};
                if ($nodes{$key}) {
                    $nodes{$key} = [ $nodes{$key} ]
                        unless ref($nodes{$key}) eq 'ARRAY';
                    CORE::push @{$nodes{$key}}, $value;
                } else {
                    $nodes{$key} = $value;
                }
            }
        } elsif (ref($insert)) {
            $nodes{ref($insert)} = $insert;
        }
    }
    $nodes{'#text'} = $self->{_text} if defined($self->{_text});

    return { $self->xmlns.":".ref($self) => \%nodes };
}

sub delete {
    my ($self, $node) = @_;

    return unless $node && $self->nodes($node);

    my @nodes = grep { ref($_) ne $node } @{$self->{_nodes}};

    $self->{_nodes} = \@nodes;
}

sub nodes {
    my ($self, $filter) = @_;

    return unless defined($self->{_nodes});

    return grep { ref($_) eq $filter } @{$self->{_nodes}}
        if $filter;

    return @{$self->{_nodes}};
}

sub push {
    my ($self, @nodes) = @_;

    return unless @nodes;

    foreach my $node (@nodes) {
        if (ref($node) eq 'Attribute') {
            CORE::push @{$self->{_attributes}}, $node;
        } else {
            CORE::push @{$self->{_nodes}}, $node;
        }
    }
}

sub attribute {
    my ($self, $key) = @_;

    my ($attribute) = $self->attributes($key);

    return unless $attribute;

    return $attribute->get($key);
}

sub attributes {
    my ($self, $key) = @_;

    return unless defined($self->{_attributes});

    return grep { $_->get($key) } @{$self->{_attributes}} if $key;

    return @{$self->{_attributes}};
}

sub string {
    my ($self, $string) = @_;

    return $self->{_text} = $string
        if $string;

    my @nodes = $self->nodes();
    if (!defined($self->{_text}) && scalar(@nodes) == 1) {
        my ($substring) = $self->nodes();
        return $substring->string();
    }

    return $self->{_text} // '';
}

sub reset {
    my ($self, @nodes) = @_;

    $self->{_nodes} = [];

    $self->push(@nodes);
}

1;

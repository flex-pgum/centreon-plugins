#
# This file is derived from GLPI Agent (https://github.com/glpi-project/glpi-agent),
# lib/GLPI/Agent/XML.pm, which is distributed under the terms of the
# GNU General Public License version 2 (GPL-2.0).
#
# NOTE: the GPL-2.0 is not compatible with the Apache-2.0 license used by
# centreon-plugins. Licensing must be clarified with the GLPI Agent copyright
# holders before this code is distributed as part of centreon-plugins.
#

package centreon::plugins::wsman::xml;

# Minimal XML::LibXML wrapper converting perl hash trees to XML and back, as
# expected by the WsMan SOAP node classes. Only the features used by WsMan are
# kept from GLPI::Agent::XML (no plist, no win32 thread support).

use strict;
use warnings;

use Encode qw(decode);
use List::Util qw(any);
use XML::LibXML;

sub new {
    my ($class, %params) = @_;

    my $self = {};
    bless $self, $class;

    map { $self->{"_$_"} = $params{$_} } grep { defined($params{$_}) } qw(
        first_out
        no_xml_decl
        xml_format
    );

    $self->string($params{string});

    return $self;
}

sub _parser {
    my ($self) = @_;

    unless ($self->{_parser}) {
        $self->{_parser} = XML::LibXML->new();
        $self->{_parser}->set_options(
            load_ext_dtd => 0,
            no_network   => 1,
            no_blanks    => 1,
            # Don't report parsing error
            recover      => 2,
        );
    }

    return $self->{_parser};
}

sub _is_xml {
    my ($self) = @_;

    my $xml = $self->{_xml};

    return ref($xml) eq 'XML::LibXML::Document' && $xml->documentElement() ? 1 : 0;
}

sub string {
    my ($self, $string) = @_;

    return $self unless defined($string) && length($string);

    delete $self->{_xml};
    my $xml = eval { $self->_parser->parse_string(decode('UTF-8', $string)) };
    $self->{_xml} = $xml if $xml;
    delete $self->{_xml} unless $self->_is_xml();

    return $self;
}

sub _build_xml {
    my ($self, $hash, $node) = @_;

    my $xml = $self->{_xml};

    unless ($xml) {
        return unless ref($hash) eq 'HASH' && keys(%{$hash}) == 1;

        $xml = $self->{_xml} = XML::LibXML::Document->new('1.0', 'UTF-8');

        my ($key) = keys(%{$hash});
        my $root = $xml->createElement($key);
        $xml->setDocumentElement($root);
        if (ref($hash->{$key}) eq 'HASH') {
            $hash = $hash->{$key};
        } elsif (ref($hash->{$key})) {
            die "centreon::plugins::wsman::xml: Unsupported array ref as $key document root\n";
        } else {
            $root->appendTextNode($hash->{$key});
            return 1;
        }
        $node = $root;
    }

    my @keys;
    # Handle first_out option
    if ($self->{_first_out} && any { exists($hash->{$_}) } @{$self->{_first_out}}) {
        my @first_out = sort grep { exists($hash->{$_}) } @{$self->{_first_out}};
        push @keys, @first_out;
        push @keys, sort grep { my $k = $_ ; ! grep { $_ eq $k } @first_out } keys(%{$hash});
    } else {
        @keys = sort keys(%{$hash});
    }

    foreach my $key (@keys) {
        next unless defined($hash->{$key});
        if ($key =~ /^-(.*)$/) {
            $node->setAttribute($1, $hash->{$key});
        } elsif ($key eq '#text') {
            $node->appendChild($xml->createTextNode($hash->{$key}));
        } else {
            my $leaf = $xml->createElement($key);
            $node->appendChild($leaf);
            if (ref($hash->{$key}) eq 'HASH') {
                $self->_build_xml($hash->{$key}, $leaf);
            } elsif (ref($hash->{$key}) eq 'ARRAY') {
                foreach my $element (@{$hash->{$key}}) {
                    # Keep first one and create new ones starting from second loop
                    unless ($leaf) {
                        $leaf = $xml->createElement($key);
                        $node->appendChild($leaf);
                    }
                    if (ref($element)) {
                        $self->_build_xml($element, $leaf);
                    } else {
                        $leaf->appendChild($xml->createTextNode($element));
                    }
                    undef $leaf;
                }
            } else {
                $leaf->appendChild($xml->createTextNode($hash->{$key}));
            }
        }
    }

    return 1;
}

sub write {
    my ($self, $hash) = @_;

    if ($hash) {
        delete $self->{_xml};
        $self->_build_xml($hash);
        unless ($self->_is_xml()) {
            delete $self->{_xml};
            return;
        }
    }

    return '' unless $self->_is_xml();

    local $XML::LibXML::setTagCompression = 0;

    if ($self->{_no_xml_decl}) {
        my $string = '';
        foreach my $node ($self->{_xml}->childNodes()) {
            $string .= $node->toString($self->{_xml_format} // 1);
        }
        return $string;
    }

    return $self->{_xml}->toString($self->{_xml_format} // 1);
}

# Recursive API to dump XML::LibXML objects as a hash tree like XML::TreePP does
sub dump_as_hash {
    my ($self, $node) = @_;

    unless ($node) {
        return unless $self->_is_xml();
        $node = $self->{_xml}->documentElement()
            or return;
    }

    my $type = $node->nodeType;

    my $ret;
    if ($type == XML::LibXML::XML_ELEMENT_NODE()) {
        my $name = $node->nodeName;
        foreach my $child ($node->childNodes()) {
            my $leaf = $self->dump_as_hash($child);
            if (ref($leaf) eq 'HASH') {
                foreach my $key (keys(%{$leaf})) {
                    # Transform key in array ref is necessary
                    if (exists($ret->{$name}->{$key})) {
                        $ret->{$name}->{$key} = [ $ret->{$name}->{$key} ]
                            unless ref($ret->{$name}->{$key}) eq 'ARRAY';
                        push @{$ret->{$name}->{$key}}, $leaf->{$key};
                    } else {
                        $ret->{$name}->{$key} = $leaf->{$key};
                    }
                }
            } elsif (defined($leaf) && !ref($ret->{$name})) {
                $ret->{$name}->{'#text'} .= $leaf;
            } elsif (defined($leaf) && !ref($leaf)) {
                $ret->{$name}->{'#text'} .= $leaf;
            }
        }
        foreach my $attribute ($node->attributes()) {
            $ret->{$name}->{'-' . $attribute->nodeName()} = $attribute->getValue();
        }
        if (!defined($ret)) {
            $ret->{$name} = '';
        } elsif (defined($ret->{$name}->{'#text'}) && keys(%{$ret->{$name}}) == 1) {
            $ret->{$name} = $ret->{$name}->{'#text'};
        } elsif (!defined($ret->{$name}->{'#text'})) {
            delete $ret->{$name}->{'#text'};
        }
    } elsif ($type == XML::LibXML::XML_TEXT_NODE() || $type == XML::LibXML::XML_CDATA_SECTION_NODE()) {
        $ret = $node->textContent;
        chomp($ret);
        # Cleanup empty nodes like "<node>\n    </node>"
        $ret = '' if $ret =~ /^\n\s+$/m;
    }
    # Other node types (comments, processing instructions...) are ignored

    return $ret;
}

1;

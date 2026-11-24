#
# This file is derived from GLPI Agent (https://github.com/glpi-project/glpi-agent),
# lib/GLPI/Agent/SOAP/WsMan, which is distributed under the terms of the
# GNU General Public License version 2 (GPL-2.0).
#
# NOTE: the GPL-2.0 is not compatible with the Apache-2.0 license used by
# centreon-plugins. Licensing must be clarified with the GLPI Agent copyright
# holders before this code is distributed as part of centreon-plugins.
#

package centreon::plugins::wsman::soap::Stream;

use strict;
use warnings;

use centreon::plugins::wsman::soap::Node;

## no critic (ProhibitMultiplePackages)
package
    Stream;

use parent
    'Node';

use MIME::Base64;

use constant    xmlns   => 'rsp';

sub new {
    my ($class, $streams) = @_;

    $streams = [ $streams ] unless ref($streams) eq 'ARRAY';

    my $self = {};

    foreach my $stream (@{$streams}) {
        next unless ref($stream) eq 'HASH';
        my $cid = $stream->{'-CommandId'}
            or next;
        my $name = $stream->{'-Name'}
            or next;
        next unless $name =~ /^std(out|err)$/;
        my $text = $stream->{'#text'};
        if (defined($text) && length($text)) {
            $self->{$cid}->{$name} .= decode_base64($text);
        }
        $self->{$cid}->{"_end_$name"} = $stream->{'-End'} =~ /^true$/i if $stream->{'-End'};
    }

    bless $self, $class;
    return $self;
}

sub stdout {
    my ($self, $cid) = @_;

    return unless $self->{$cid};

    return $self->{$cid}->{stdout} // '';
}

sub stderr {
    my ($self, $cid) = @_;

    return unless $self->{$cid};

    return $self->{$cid}->{stderr} // '';
}

sub stdout_is_full {
    my ($self, $cid) = @_;

    return unless $self->{$cid};

    return $self->{$cid}->{_end_stdout} // 0;
}

sub stderr_is_full {
    my ($self, $cid) = @_;

    return unless $self->{$cid};

    return $self->{$cid}->{_end_stderr} // 0;
}

1;

#
# This file is derived from GLPI Agent (https://github.com/glpi-project/glpi-agent),
# lib/GLPI/Agent/SOAP/WsMan, which is distributed under the terms of the
# GNU General Public License version 2 (GPL-2.0).
#
# NOTE: the GPL-2.0 is not compatible with the Apache-2.0 license used by
# centreon-plugins. Licensing must be clarified with the GLPI Agent copyright
# holders before this code is distributed as part of centreon-plugins.
#

package centreon::plugins::wsman::soap::Shell;

use strict;
use warnings;

use centreon::plugins::wsman::soap::Node;

## no critic (ProhibitMultiplePackages)
package
    Shell;

use parent
    'Node';

use centreon::plugins::wsman::soap::Attribute;
use centreon::plugins::wsman::soap::InputStreams;
use centreon::plugins::wsman::soap::OutputStreams;
use centreon::plugins::wsman::soap::CommandLine;
use centreon::plugins::wsman::soap::Command;
use centreon::plugins::wsman::soap::Arguments;

use constant    xmlns   => 'rsp';
use constant    xsd     => "http://schemas.microsoft.com/wbem/wsman/1/windows/shell";

sub support {
    return {
        Selector    => "w:Selector",
    };
}

sub new {
    my ($class, @params) = @_;

    # For some reasons, remote answers with wrong case on ResourceURI when remote is done from windows
    $params[0]->{'rsp:ResourceURI'} = delete $params[0]->{'rsp:ResourceUri'}
        if $params[0] && ref($params[0]) eq 'HASH' && exists($params[0]->{'rsp:ResourceUri'});

    my $self = $class->SUPER::new(@params);

    $self->push(
        Attribute->new("xmlns:".$class->xmlns => xsd),
        InputStreams->new(),
        OutputStreams->new()
    ) unless @params;

    bless $self, $class;

    return $self;
}

sub commandline {
    my ($self, $command) = @_;

    my ($cmd, $args) = $command =~ /^\s*(\S+)\s*(.*)$/;

    my $cmdline = CommandLine->new(
        Attribute->new( $self->namespace ),
        Command->new($cmd),
    );
    $cmdline->push(Arguments->new($args))
        if defined($args) && length($args);

    return $cmdline;
}

1;

#
# Copyright 2026-Present Centreon (http://www.centreon.com/)
#
# Centreon is a full-fledged industry-strength solution that meets
# the needs in IT infrastructure and application monitoring for
# service performance.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

package centreon::plugins::wsman::client;

# WS-Management client written after the specifications:
#  - DMTF DSP0226 (WS-Management) for enumeration (WS-Enumeration)
#  - Microsoft MS-WSMV for WinRM remote shell (WinRS) operations
# SOAP messages are built with XML::LibXML DOM and responses are read with
# XPath. HTTP transport and authentication: centreon::plugins::wsman::transport

use strict;
use warnings;

use Encode qw(encode);
use MIME::Base64;
use Time::HiRes;
use XML::LibXML;
use centreon::plugins::wsman::transport;

my %NS = (
    s   => 'http://www.w3.org/2003/05/soap-envelope',
    a   => 'http://schemas.xmlsoap.org/ws/2004/08/addressing',
    n   => 'http://schemas.xmlsoap.org/ws/2004/09/enumeration',
    w   => 'http://schemas.dmtf.org/wbem/wsman/1/wsman.xsd',
    p   => 'http://schemas.microsoft.com/wbem/wsman/1/wsman.xsd',
    rsp => 'http://schemas.microsoft.com/wbem/wsman/1/windows/shell',
    xsi => 'http://www.w3.org/2001/XMLSchema-instance'
);

use constant ANONYMOUS => 'http://schemas.xmlsoap.org/ws/2004/08/addressing/role/anonymous';
use constant WQL_DIALECT => 'http://schemas.microsoft.com/wbem/wsman/1/WQL';
use constant SHELL_URI => 'http://schemas.microsoft.com/wbem/wsman/1/windows/shell/cmd';
use constant SHELL_NS => 'http://schemas.microsoft.com/wbem/wsman/1/windows/shell';
use constant MAX_ENVELOPE_SIZE => 512000;

# Fault code returned by WinRM when OperationTimeout expired without result
use constant FAULT_TIMED_OUT => '2150858793';

my %ACTIONS = (
    enumerate => 'http://schemas.xmlsoap.org/ws/2004/09/enumeration/Enumerate',
    pull      => 'http://schemas.xmlsoap.org/ws/2004/09/enumeration/Pull',
    create    => 'http://schemas.xmlsoap.org/ws/2004/09/transfer/Create',
    delete    => 'http://schemas.xmlsoap.org/ws/2004/09/transfer/Delete',
    command   => SHELL_NS . '/Command',
    receive   => SHELL_NS . '/Receive',
    signal    => SHELL_NS . '/Signal'
);
my %RESPONSES = (
    enumerate => 'http://schemas.xmlsoap.org/ws/2004/09/enumeration/EnumerateResponse',
    pull      => 'http://schemas.xmlsoap.org/ws/2004/09/enumeration/PullResponse',
    create    => 'http://schemas.xmlsoap.org/ws/2004/09/transfer/CreateResponse',
    delete    => 'http://schemas.xmlsoap.org/ws/2004/09/transfer/DeleteResponse',
    command   => SHELL_NS . '/CommandResponse',
    receive   => SHELL_NS . '/ReceiveResponse',
    signal    => SHELL_NS . '/SignalResponse'
);

sub new {
    my ($class, %options) = @_;

    my $self = bless {
        url        => $options{url},
        timeout    => $options{timeout} || 30,
        debug      => $options{debug} // 0,
        debug_raw  => $options{debug_raw} // 0,
        lasterror  => '',
        lastcode   => 0,
        fault_code => undef
    }, $class;

    # Remote side must answer before the HTTP timeout expires
    $self->{operation_timeout} = $self->{timeout} > 10 ? $self->{timeout} - 5 : $self->{timeout};

    $self->{transport} = centreon::plugins::wsman::transport->new(
        url            => $options{url},
        auth_method    => $options{auth_method},
        username       => $options{username},
        password       => $options{password},
        timeout        => $self->{timeout},
        proxy_url      => $options{proxy_url},
        proxy_username => $options{proxy_username},
        proxy_password => $options{proxy_password},
        logger         => sub { $self->log($_[0]) }
    );

    return $self;
}

sub log {
    my ($self, $message) = @_;

    print STDERR "[wsman] $message\n" if ($self->{debug});
}

sub lasterror {
    my ($self) = @_;

    return $self->{lasterror};
}

sub lastcode {
    my ($self) = @_;

    return $self->{lastcode};
}

sub _error {
    my ($self, $message) = @_;

    $self->{lasterror} = $message;
    $self->log($message);

    return undef;
}

sub _uuid {
    my @b = map { int(rand(256)) } (1..16);
    $b[6] = 0x40 | ($b[6] & 0x0f);
    $b[8] = 0x80 | ($b[8] & 0x3f);

    return 'uuid:' . uc(join('-', map { unpack('H*', pack('C*', @b[@$_])) } ([0..3], [4..5], [6..7], [8..9], [10..15])));
}

#####
# SOAP message building

sub _add {
    my ($parent, $qname, $text, %attributes) = @_;

    my ($prefix) = $qname =~ /^(\w+):/;
    my $node = $parent->ownerDocument()->createElementNS($NS{$prefix}, $qname);
    foreach my $name (sort keys %attributes) {
        my ($attr_prefix) = $name =~ /^(\w+):/;
        if (defined($attr_prefix) && $attr_prefix eq 'xml') {
            $node->setAttributeNS('http://www.w3.org/XML/1998/namespace', $name, $attributes{$name});
        } elsif (defined($attr_prefix) && defined($NS{$attr_prefix})) {
            $node->setAttributeNS($NS{$attr_prefix}, $name, $attributes{$name});
        } else {
            $node->setAttribute($name, $attributes{$name});
        }
    }
    $node->appendText($text) if (defined($text));
    $parent->appendChild($node);

    return $node;
}

# Build a SOAP envelope, return ($document, $body, $message_id)
#  action: key of %ACTIONS
#  resource_uri: targeted resource
#  selectors: hash ref of selector name => value
#  options: hash ref of option name => value
sub _envelope {
    my ($self, %options) = @_;

    my $doc = XML::LibXML::Document->new('1.0', 'UTF-8');
    my $envelope = $doc->createElementNS($NS{s}, 's:Envelope');
    $doc->setDocumentElement($envelope);
    foreach my $prefix (qw(a n w p rsp)) {
        $envelope->setNamespace($NS{$prefix}, $prefix, 0);
    }

    my $message_id = _uuid();
    my $header = _add($envelope, 's:Header');
    _add($header, 'a:To', $self->{url});
    _add($header, 'w:ResourceURI', $options{resource_uri}, 's:mustUnderstand' => 'true');
    my $reply_to = _add($header, 'a:ReplyTo');
    _add($reply_to, 'a:Address', ANONYMOUS, 's:mustUnderstand' => 'true');
    _add($header, 'a:Action', $ACTIONS{$options{action}}, 's:mustUnderstand' => 'true');
    _add($header, 'a:MessageID', $message_id);
    _add($header, 'w:MaxEnvelopeSize', MAX_ENVELOPE_SIZE, 's:mustUnderstand' => 'true');
    _add($header, 'w:Locale', undef, 'xml:lang' => 'en-US', 's:mustUnderstand' => 'false');
    _add($header, 'p:DataLocale', undef, 'xml:lang' => 'en-US', 's:mustUnderstand' => 'false');
    _add($header, 'w:OperationTimeout', sprintf('PT%d.000S', $options{timeout} // $self->{operation_timeout}));

    if ($options{selectors} && %{$options{selectors}}) {
        my $set = _add($header, 'w:SelectorSet');
        _add($set, 'w:Selector', $options{selectors}->{$_}, Name => $_) foreach (sort keys %{$options{selectors}});
    }
    if ($options{options} && %{$options{options}}) {
        my $set = _add($header, 'w:OptionSet');
        _add($set, 'w:Option', $options{options}->{$_}, Name => $_) foreach (sort keys %{$options{options}});
    }

    my $body = _add($envelope, 's:Body');

    return ($doc, $body, $message_id);
}

#####
# Exchange

# Send a message and check the answer. Returns an XPath context on the
# response document or undef (see lasterror(), lastcode())
sub _call {
    my ($self, %options) = @_;

    $self->{fault_code} = undef;

    my $content = $options{document}->documentElement()->toString();
    $content = encode('UTF-8', $content) if (utf8::is_utf8($content));

    $self->log("request:\n" . $content) if ($self->{debug_raw});
    my $start = Time::HiRes::time();
    my $response = $self->{transport}->post(content => $content);
    $self->{lastcode} = $response->code();
    $self->log(sprintf(
        '%s request to %s: HTTP %s (%d bytes in %.2fs)',
        $options{action}, $self->{url}, $response->status_line(),
        length($response->content() // ''), Time::HiRes::time() - $start
    ));
    if ($self->{debug_raw}) {
        my $dump = $response->status_line() . "\n" . $response->headers()->as_string() . "\n" . $response->decoded_content(charset => 'none');
        $self->log("response:\n" . $dump);
    }

    my $xpc;
    my $type = $response->header('Content-Type') // '';
    my $raw = $response->content();
    if (defined($raw) && $raw ne '' && $type =~ /xml/i) {
        my $doc = eval {
            XML::LibXML->load_xml(string => $raw, no_network => 1, load_ext_dtd => 0, expand_entities => 0, huge => 0);
        };
        if (defined($doc)) {
            $xpc = XML::LibXML::XPathContext->new($doc->documentElement());
            $xpc->registerNs($_, $NS{$_}) foreach (keys %NS);
        }
    }

    # SOAP fault (WinRM answers them with HTTP 500 or 400)
    if (defined($xpc) && $xpc->exists('/s:Envelope/s:Body/s:Fault')) {
        my $code = $xpc->findvalue('/s:Envelope/s:Body/s:Fault/s:Detail//*[local-name()="WSManFault"]/@Code');
        $code = $xpc->findvalue('/s:Envelope/s:Body/s:Fault/s:Detail//*[local-name()="error_Code"]') if ($code eq '');
        $self->{fault_code} = $code if ($code ne '');
        my $reason = $xpc->findvalue('/s:Envelope/s:Body/s:Fault/s:Reason/s:Text');
        $reason = $xpc->findvalue('/s:Envelope/s:Body/s:Fault/s:Detail//*[local-name()="Message"]') if ($reason eq '');
        $reason =~ s/^\s+|\s+$//g;
        $reason = encode('UTF-8', $reason) if (utf8::is_utf8($reason));
        my $subcode = $xpc->findvalue('/s:Envelope/s:Body/s:Fault/s:Code/s:Subcode/s:Value');
        $self->log("SOAP fault on $options{action} request" . ($subcode ne '' ? ", subcode $subcode" : '') . ($code ne '' ? ", code $code" : ''));
        return $self->_error($reason ne '' ? $reason : 'SOAP fault' . ($code ne '' ? " (code $code)" : ''));
    }

    if (!$response->is_success()) {
        if ($response->code() == 401) {
            return $self->_error(($self->{transport}->auth_error() // 'authentication failed') . ' (' . $response->status_line() . ')');
        }
        return $self->_error($response->status_line());
    }

    return $self->_error("Malformed $options{action} response: no SOAP envelope")
        if (!defined($xpc) || !$xpc->exists('/s:Envelope/s:Body'));

    my $action = $xpc->findvalue('/s:Envelope/s:Header/a:Action');
    return $self->_error("Unexpected answer to $options{action} request: '$action'")
        if ($action ne $RESPONSES{$options{action}});

    my $relates_to = $xpc->findvalue('/s:Envelope/s:Header/a:RelatesTo');
    return $self->_error("Answer to $options{action} request is not related to it")
        if ($relates_to ne '' && $relates_to ne $options{message_id});

    return $xpc;
}

#####
# Enumeration (WS-Enumeration with WS-Management extensions)

# Returns an array ref of instances, each one a hash ref of property name =>
# value, or undef on failure. Values are UTF-8 encoded strings, empty for nil
# values. When a property appears more than once, its last value is kept.
#  resource_uri: resource to enumerate
#  query: optional WQL filter
#  max_elements: max instances by answer (default 999)
sub enumerate {
    my ($self, %options) = @_;

    $self->{lasterror} = '';

    my $max_elements = $options{max_elements} || 999;
    $self->log('Requesting enumerate on ' . $options{resource_uri} . (defined($options{query}) ? ': ' . $options{query} : ''));

    my ($doc, $body, $message_id) = $self->_envelope(action => 'enumerate', resource_uri => $options{resource_uri});
    my $enumerate = _add($body, 'n:Enumerate');
    _add($enumerate, 'w:OptimizeEnumeration');
    _add($enumerate, 'w:MaxElements', $max_elements);
    _add($enumerate, 'w:Filter', $options{query}, Dialect => WQL_DIALECT) if (defined($options{query}));

    my $action = 'enumerate';
    my @instances;
    while (1) {
        my $xpc = $self->_call(document => $doc, message_id => $message_id, action => $action)
            or return undef;

        my ($answer) = $xpc->findnodes('/s:Envelope/s:Body/n:EnumerateResponse | /s:Envelope/s:Body/n:PullResponse');
        return $self->_error("Malformed $action response") if (!defined($answer));

        my $received = 0;
        foreach my $items ($xpc->findnodes('w:Items | n:Items', $answer)) {
            foreach (grep { $_->nodeType() == XML::LibXML::XML_ELEMENT_NODE() } $items->childNodes()) {
                push @instances, _instance($_);
                $received++;
            }
        }

        my $end = $xpc->exists('w:EndOfSequence | n:EndOfSequence', $answer);
        my $context = $xpc->findvalue('n:EnumerationContext', $answer);
        $self->log(sprintf(
            '%d instance(s) received (total: %d)%s', $received, scalar(@instances),
            $end || $context eq '' ? ', end of enumeration' : ', pulling next instances'
        ));
        last if ($end || $context eq '');

        # Pull next items: MaxElements and MaxEnvelopeSize must not change
        ($doc, $body, $message_id) = $self->_envelope(action => 'pull', resource_uri => $options{resource_uri});
        my $pull = _add($body, 'n:Pull');
        _add($pull, 'n:EnumerationContext', $context);
        _add($pull, 'n:MaxElements', $max_elements);
        $action = 'pull';
    }

    return \@instances;
}

sub _instance {
    my ($node) = @_;

    my %instance;
    foreach my $property ($node->childNodes()) {
        next if ($property->nodeType() != XML::LibXML::XML_ELEMENT_NODE());
        # Complex values (like cim:Datetime) are given as their text content.
        # Nil values (xsi:nil="true") are empty strings, as with openwsman: the
        # modes expect defined values.
        my $value = $property->textContent();
        $value = encode('UTF-8', $value) if (utf8::is_utf8($value));
        $instance{$property->localname()} = $value;
    }

    return \%instance;
}

#####
# Remote shell (MS-WSMV WinRS)

# Create a cmd shell, return a shell hash ref or undef
#  options: WinRS options (WINRS_CODEPAGE, WINRS_NOPROFILE...)
sub shell_create {
    my ($self, %options) = @_;

    $self->{lasterror} = '';

    my ($doc, $body, $message_id) = $self->_envelope(
        action => 'create',
        resource_uri => SHELL_URI,
        options => $options{options}
    );
    my $shell = _add($body, 'rsp:Shell');
    _add($shell, 'rsp:InputStreams', 'stdin');
    _add($shell, 'rsp:OutputStreams', 'stdout stderr');

    my $xpc = $self->_call(document => $doc, message_id => $message_id, action => 'create')
        or return undef;

    my $id = $xpc->findvalue('/s:Envelope/s:Body//w:SelectorSet/w:Selector[@Name="ShellId"]');
    $id = $xpc->findvalue('/s:Envelope/s:Body//rsp:ShellId') if ($id eq '');
    return $self->_error('No shell id returned') if ($id eq '');

    $self->log(
        "shell $id created on " . $self->{url} .
        ($options{options} && %{$options{options}} ?
            ' (' . join(', ', map { "$_=$options{options}->{$_}" } sort keys %{$options{options}}) . ')' : '')
    );

    return { id => $id };
}

# Start a command in the shell, return the command id or undef
#  options: WinRS options (WINRS_CONSOLEMODE_STDIN, WINRS_SKIP_CMD_SHELL...)
sub shell_command {
    my ($self, %options) = @_;

    $self->{lasterror} = '';

    $self->log("running command in shell $options{shell}->{id} on $self->{url}: $options{command}");

    my ($doc, $body, $message_id) = $self->_envelope(
        action => 'command',
        resource_uri => SHELL_URI,
        selectors => { ShellId => $options{shell}->{id} },
        options => $options{options}
    );
    my $command_line = _add($body, 'rsp:CommandLine');
    _add($command_line, 'rsp:Command', $options{command});

    my $xpc = $self->_call(document => $doc, message_id => $message_id, action => 'command')
        or return undef;

    my $command_id = $xpc->findvalue('/s:Envelope/s:Body/rsp:CommandResponse/rsp:CommandId');
    return $self->_error('No command id returned') if ($command_id eq '');
    $self->log("command id: $command_id");

    return $command_id;
}

# Read command output until it is done. Return { stdout, stderr, exitcode }
# or undef
#  timeout: max time in seconds to wait for the end of the command (default 300)
sub shell_receive {
    my ($self, %options) = @_;

    $self->{lasterror} = '';

    my $command_id = $options{command_id};
    my $limit = time() + ($options{timeout} // 300);
    my %output = (stdout => '', stderr => '');
    my $exit_code;

    while (1) {
        return $self->_error('Command too long to execute') if (time() > $limit);

        my ($doc, $body, $message_id) = $self->_envelope(
            action => 'receive',
            resource_uri => SHELL_URI,
            selectors => { ShellId => $options{shell}->{id} }
        );
        my $receive = _add($body, 'rsp:Receive');
        _add($receive, 'rsp:DesiredStream', 'stdout stderr', CommandId => $command_id);

        my $xpc = $self->_call(document => $doc, message_id => $message_id, action => 'receive');
        if (!defined($xpc)) {
            # No output during OperationTimeout: just ask again
            if (defined($self->{fault_code}) && $self->{fault_code} eq FAULT_TIMED_OUT) {
                $self->log('no output yet, command still running');
                next;
            }
            return undef;
        }

        foreach my $stream ($xpc->findnodes('/s:Envelope/s:Body/rsp:ReceiveResponse/rsp:Stream')) {
            my $name = $stream->getAttribute('Name') // '';
            next if ($name !~ /^std(?:out|err)$/);
            my $cid = $stream->getAttribute('CommandId');
            next if (defined($cid) && $cid ne $command_id);
            my $data = $stream->textContent();
            $output{$name} .= decode_base64($data) if ($data ne '');
        }

        my ($state) = $xpc->findnodes('/s:Envelope/s:Body/rsp:ReceiveResponse/rsp:CommandState');
        next if (!defined($state));

        my $cid = $state->getAttribute('CommandId');
        return $self->_error('Wrong CommandId in ReceiveResponse node') if (defined($cid) && $cid ne $command_id);

        my $code = $xpc->findvalue('rsp:ExitCode', $state);
        $exit_code = $code if ($code ne '');

        my $value = $state->getAttribute('State') // '';
        if ($value eq SHELL_NS . '/CommandState/Done') {
            return $self->_error("No exit code for 'done' command") if (!defined($exit_code));
            last;
        } elsif ($value eq SHELL_NS . '/CommandState/Pending') {
            # WinRM 1.1 ends commands in that state
            last;
        } elsif ($value ne SHELL_NS . '/CommandState/Running') {
            return $self->_error('Unknown command state: ' . $value);
        }
    }

    if ($self->{debug}) {
        $self->log(sprintf(
            'command %s exited with code %s (stdout: %d bytes, stderr: %d bytes)',
            $command_id, $exit_code // 'unknown', length($output{stdout}), length($output{stderr})
        ));
        $self->_log_output(stream => 'stderr', data => $output{stderr});
        # Output of a failed command usually explains the failure
        $self->_log_output(stream => 'stdout', data => $output{stdout})
            if (defined($exit_code) && $exit_code ne '0');
    }

    return { stdout => $output{stdout}, stderr => $output{stderr}, exitcode => $exit_code };
}

# Send a signal to a command (terminate by default)
sub shell_signal {
    my ($self, %options) = @_;

    $self->{lasterror} = '';

    my ($doc, $body, $message_id) = $self->_envelope(
        action => 'signal',
        resource_uri => SHELL_URI,
        selectors => { ShellId => $options{shell}->{id} }
    );
    my $signal = _add($body, 'rsp:Signal', undef, CommandId => $options{command_id});
    _add($signal, 'rsp:Code', SHELL_NS . '/signal/' . ($options{signal} // 'terminate'));

    $self->_call(document => $doc, message_id => $message_id, action => 'signal')
        or return undef;
    $self->log('signal ' . ($options{signal} // 'terminate') . " sent to command $options{command_id}");

    return 1;
}

# Log command output lines (limited to 4000 bytes)
sub _log_output {
    my ($self, %options) = @_;

    my $data = $options{data};
    return if (!defined($data) || $data =~ /^\s*$/);

    my $truncated = length($data) > 4000 ? 1 : 0;
    $data = substr($data, 0, 4000) if ($truncated);
    $data =~ s/\r//g;
    $self->log("$options{stream}: $_") foreach (grep { /\S/ } split(/\n/, $data));
    $self->log("$options{stream}: [output truncated]") if ($truncated);
}

sub shell_delete {
    my ($self, %options) = @_;

    $self->{lasterror} = '';

    my ($doc, $body, $message_id) = $self->_envelope(
        action => 'delete',
        resource_uri => SHELL_URI,
        selectors => { ShellId => $options{shell}->{id} }
    );

    $self->_call(document => $doc, message_id => $message_id, action => 'delete')
        or return undef;
    $self->log('shell ' . $options{shell}->{id} . ' deleted');

    return 1;
}

1;

__END__

=head1 NAME

centreon::plugins::wsman::client - WS-Management client

=head1 SYNOPSIS

    my $client = centreon::plugins::wsman::client->new(
        url         => 'https://host:5986/wsman',
        auth_method => 'basic',
        username    => 'user',
        password    => 'pass'
    );
    my $instances = $client->enumerate(
        resource_uri => 'http://schemas.microsoft.com/wbem/wsman/1/wmi/root/cimv2/*',
        query        => 'select Name from Win32_Service'
    ) or die $client->lasterror();

=cut

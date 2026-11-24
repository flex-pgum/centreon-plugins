#
# This file is derived from GLPI Agent (https://github.com/glpi-project/glpi-agent),
# lib/GLPI/Agent/SOAP/WsMan.pm and lib/GLPI/Agent/HTTP/Client.pm, which are
# distributed under the terms of the GNU General Public License version 2 (GPL-2.0).
#
# NOTE: the GPL-2.0 is not compatible with the Apache-2.0 license used by
# centreon-plugins. Licensing must be clarified with the GLPI Agent copyright
# holders before this code is distributed as part of centreon-plugins.
#

package centreon::plugins::wsman::client;

# Pure perl WS-Management client (replaces openwsman perl binding).
#
# SOAP messages are built and parsed with the WsMan node classes ported from
# GLPI Agent. HTTP transport is done with LWP::UserAgent and supports these
# authentication methods:
#  - noauth
#  - basic, digest (and 'pass' handled as basic) through LWP
#  - ntlm with Authen::NTLM
#  - gssnegotiate (kerberos) with GSSAPI, including mutual authentication and
#    TLS channel binding (RFC 5929) over https
# Message level encryption (as done by WinRM over http with negotiate
# authentication) is not supported: use https or allow unencrypted traffic.

use strict;
use warnings;

use Encode qw(encode);
use HTTP::Request;
use HTTP::Headers;
use HTTP::Response;
use LWP::UserAgent;
use MIME::Base64;
use Scalar::Util qw(weaken);
use URI;

use centreon::plugins::wsman::xml;
use centreon::plugins::wsman::soap;

use constant SHELL_CMD_URI => 'http://schemas.microsoft.com/wbem/wsman/1/windows/shell/cmd';
use constant SHELL_STATE_URI => 'http://schemas.microsoft.com/wbem/wsman/1/windows/shell/CommandState/';
use constant FULLDUPLEX_URI => 'http://schemas.microsoft.com/wbem/wsman/1/wsman/FullDuplex';

# WinRM fault codes
use constant WSMAN_ERROR_TIMEDOUT => '2150858793';
use constant WSMAN_ERROR_RESOURCE_NOT_AVAILABLE => '2150858752';

my $xml;

sub new {
    my ($class, %params) = @_;

    my $self = {
        _url            => $params{url},
        _auth_method    => $params{auth_method} // 'basic',
        _user           => $params{username} // '',
        _password       => $params{password} // '',
        _timeout        => $params{timeout} || 30,
        _proxy_url      => $params{proxy_url},
        _proxy_user     => $params{proxy_username},
        _proxy_password => $params{proxy_password},
        _logger         => $params{logger},
        _debug          => $params{debug} // 0,
        _debug_raw      => $params{debug_raw} // 0,
        _lang           => 'en-US',
        _lasterror      => '',
        _lastcode       => 0,
    };
    bless $self, $class;

    # WsMan server must answer before HTTP timeout
    $self->{_operation_timeout} = $self->{_timeout} > 10 ? $self->{_timeout} - 5 : $self->{_timeout};

    $self->{ua} = centreon::plugins::wsman::client::useragent->new(
        keep_alive => 1,
        timeout    => $self->{_timeout},
        agent      => 'centreon-plugins-wsman',
        parse_head => 0,
        requests_redirectable => [],
    );
    $self->{ua}->{_wsman_client} = $self;
    weaken($self->{ua}->{_wsman_client});

    # Previous openwsman implementation didn't verify server certificate
    $self->{ua}->ssl_opts(verify_hostname => 0, SSL_verify_mode => 0)
        if $self->{ua}->can('ssl_opts');

    if (defined($self->{_proxy_url}) && $self->{_proxy_url} ne '') {
        my $proxy = URI->new($self->{_proxy_url});
        if (defined($self->{_proxy_user}) && defined($self->{_proxy_password}) && $proxy->can('userinfo')) {
            $proxy->userinfo(_uri_escape($self->{_proxy_user}) . ':' . _uri_escape($self->{_proxy_password}));
        }
        $self->{ua}->proxy(['http', 'https'], $proxy->as_string);
    }

    # LWP chooses the authentication scheme following WWW-Authenticate headers
    # order, so only keep the one matching the requested method
    my %lwp_schemes = (basic => 'Basic', pass => 'Basic', digest => 'Digest');
    if (my $scheme = $lwp_schemes{$self->{_auth_method}}) {
        $self->{ua}->add_handler(response_done => sub {
            my ($response) = @_;
            return unless $response->code == 401;
            my @challenges = grep { /^\Q$scheme\E\b/i } map { split(/\s*,\s*(?=[A-Za-z0-9-]+(?:\s|$))/, $_) } $response->header('WWW-Authenticate');
            $response->remove_header('WWW-Authenticate');
            $response->push_header('WWW-Authenticate' => $_) foreach (@challenges);
            return;
        });
    } else {
        # Authentication is handled by this module (ntlm, gssnegotiate) or not
        # at all (noauth): hide challenges from LWP so it doesn't try another
        # scheme by itself, like Basic with given credentials
        $self->{ua}->add_handler(response_done => sub {
            my ($response) = @_;
            return unless $response->code == 401;
            my @challenges = $response->header('WWW-Authenticate');
            $response->remove_header('WWW-Authenticate');
            $response->push_header('X-WsMan-Authenticate' => $_) foreach (@challenges);
            return;
        });
    }

    $xml = centreon::plugins::wsman::xml->new(
        first_out   => [ 's:Header' ],
        no_xml_decl => 1,
        xml_format  => 0,
    ) unless $xml;

    return $self;
}

sub _uri_escape {
    my ($string) = @_;

    $string =~ s/([^A-Za-z0-9\-\._~])/sprintf('%%%02X', ord($1))/ge;
    return $string;
}

#####
# Logging

sub debug {
    my ($self, $message) = @_;

    return $self->{_debug} unless defined($message);
    $self->_log($message) if $self->{_debug};
}

sub debug2 {
    my ($self, $message) = @_;

    $self->_log($message) if $self->{_debug};
}

sub _log {
    my ($self, $message) = @_;

    if (ref($self->{_logger}) eq 'CODE') {
        $self->{_logger}->($message);
    } else {
        print STDERR "[wsman] $message\n";
    }
}

sub abort {
    my ($self, $message) = @_;

    $self->lasterror($message);
    $self->debug2($message);
    return;
}

sub lasterror {
    my ($self, $error) = @_;

    $self->{_lasterror} = $error if defined($error);

    return $self->{_lasterror} // '';
}

sub lastcode {
    my ($self) = @_;

    return $self->{_lastcode};
}

sub url {
    my ($self) = @_;

    return $self->{_url};
}

#####
# HTTP transport

sub _ua_request {
    my ($self, $request) = @_;

    my $response = eval { $self->{ua}->request($request) };
    $response = HTTP::Response->new(500, 'request failure: ' . ($@ // 'unknown error'))
        unless defined($response);

    return $response;
}

sub request {
    my ($self, $request) = @_;

    my $response = $self->_ua_request($request);

    if ($response->code == 401 && $self->{_auth_method} eq 'gssnegotiate') {
        $response = $self->_kerberos_authentication(request => $request, response => $response);
    } elsif ($response->code == 401 && $self->{_auth_method} eq 'ntlm') {
        $response = $self->_ntlm_authentication(request => $request, response => $response);
    }

    if ($response->code == 401) {
        $self->{_auth_error} //= 'authentication failed';
    }

    return $response;
}

sub _challenges {
    my ($response) = @_;

    return map { split(/\s*,\s*(?=[A-Za-z0-9-]+(?:\s|$))/, $_) }
        $response->header('WWW-Authenticate'), $response->header('X-WsMan-Authenticate');
}

sub _kerberos_authentication {
    my ($self, %params) = @_;

    my $request  = $params{request};
    my $response = $params{response};
    my $url      = $request->uri;

    # Check server supports Negotiate authentication scheme
    unless (grep { /^Negotiate\b/i } _challenges($response)) {
        $self->{_auth_error} = 'kerberos authentication not offered by server';
        return $response;
    }

    my $host = $url->host();

    require centreon::plugins::wsman::kerberos;
    my $kerberos = $self->{_kerberos}->{$host} //= centreon::plugins::wsman::kerberos->new(
        host => $host
    );

    # Bind kerberos token to the TLS channel (RFC 5929 tls-server-end-point) as
    # required by servers enforcing Extended Protection for Authentication, like
    # WinRM with CbtHardeningLevel set to Strict
    if ($url->scheme eq 'https' && !$kerberos->error()) {
        my ($der, $sigalg) = $self->_get_server_certificate($url);
        my $cbt = centreon::plugins::wsman::kerberos::tlsServerEndPoint($der, $sigalg);
        if ($cbt) {
            $self->debug2('using kerberos channel binding with server certificate' . ($sigalg ? " signed with $sigalg" : ''));
        } else {
            $self->debug2("can't get server certificate, kerberos channel binding not used");
        }
        $kerberos->channel_binding($cbt);
    }

    my $token = $kerberos->token();
    unless ($token) {
        $self->{_auth_error} = $kerberos->error() || 'kerberos token failure';
        # Reset kerberos object so next request can retry with a refreshed ticket
        delete $self->{_kerberos}->{$host};
        return $response;
    }

    $self->debug2('authentication required, trying kerberos with ' . $kerberos->service() . ' service');

    $request->header(Authorization => "Negotiate $token");
    $response = $self->_ua_request($request);
    # Don't keep authorization header in request as token can't be replayed
    $request->remove_header('Authorization');

    if ($response->code == 401) {
        $self->{_auth_error} = 'kerberos authentication refused';
        delete $self->{_kerberos}->{$host};
        return $response;
    }

    # Mutual authentication: the server must prove its identity with a token in
    # its answer. A missing token is a failure too, otherwise any server could
    # skip the check just by not providing it.
    my ($mutual) = map { /^Negotiate\s+(\S+)/i } _challenges($response);
    unless ($kerberos->verify($mutual)) {
        $self->{_auth_error} = $kerberos->error();
        delete $self->{_kerberos}->{$host};
        # Don't trust server answer
        return HTTP::Response->new(401, 'Kerberos mutual authentication failure');
    }
    $self->debug2('kerberos mutual authentication verified');

    return $response;
}

# Return DER encoded server certificate and its signature algorithm name for
# the given https url, from the kept-alive connection or from a dedicated one
sub _get_server_certificate {
    my ($self, $url) = @_;

    return unless eval { require Net::SSLeay; 1 };

    # LWP caches kept-alive connections with "host:port" as key, so peek the
    # socket by withdrawing and depositing it back
    my $key = $url->host() . ':' . $url->port();
    my $conn_cache = $self->{ua}->conn_cache();
    my $socket = $conn_cache ? $conn_cache->withdraw('https', $key) : undef;
    if ($socket) {
        $conn_cache->deposit('https', $key, $socket);
        my @cert = _certificate_info($socket);
        return @cert if @cert;
    }

    # Server may have closed the connection, like WinRM does after a 401, so
    # just open a dedicated connection to get its certificate. Server is not
    # authenticated here, but a wrong certificate only leads to a binding the
    # server refuses.
    if ($self->{ua}->proxy('https')) {
        $self->debug2("can't get server certificate via a proxy");
        return;
    }

    return unless eval { require IO::Socket::SSL; 1 };

    my $host = $url->host();
    $socket = IO::Socket::SSL->new(
        PeerHost        => $host,
        PeerPort        => $url->port(),
        Timeout         => $self->{_timeout} > 30 ? 30 : $self->{_timeout},
        SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE(),
        # Set SNI for the server to provide the expected certificate
        $host =~ /^[0-9.]+$|:/ ? () : (SSL_hostname => $host),
    );
    unless ($socket) {
        no warnings 'once';
        $self->debug2("failed to connect to $key to get server certificate: " . ($IO::Socket::SSL::SSL_ERROR || $! || 'unknown error'));
        return;
    }

    my @cert = _certificate_info($socket);
    $socket->close(SSL_fast_shutdown => 1);

    return @cert;
}

sub _certificate_info {
    my ($socket) = @_;

    return unless $socket->can('peer_certificate');

    my $cert = $socket->peer_certificate()
        or return;

    my $pem = Net::SSLeay::PEM_get_string_X509($cert)
        or return;
    $pem =~ s/-----(BEGIN|END) CERTIFICATE-----//g;
    my $der = decode_base64($pem)
        or return;

    my $sigalg;
    my $obj = Net::SSLeay::P_X509_get_signature_alg($cert);
    $sigalg = Net::SSLeay::OBJ_nid2sn(Net::SSLeay::OBJ_obj2nid($obj)) if $obj;

    return $der, $sigalg;
}

sub _ntlm_authentication {
    my ($self, %params) = @_;

    my $request  = $params{request};
    my $response = $params{response};

    my @challenges = _challenges($response);
    # WinRM only offers Negotiate scheme which also accepts NTLM tokens
    my ($scheme) = map { /^(NTLM|Negotiate)\b/i ? $1 : () } @challenges;
    unless ($scheme) {
        $self->{_auth_error} = 'ntlm authentication not offered by server';
        return $response;
    }

    unless (eval { require Authen::NTLM; 1 }) {
        $self->{_auth_error} = 'Authen::NTLM perl module is required for ntlm authentication';
        return $response;
    }

    my ($domain, $user) = ('', $self->{_user});
    if ($user =~ /^(.*?)\\(.*)$/) {
        ($domain, $user) = ($1, $2);
    } elsif ($user =~ /^(.*)\@(.*)$/) {
        ($user, $domain) = ($1, $2);
    }

    my $ntlm = Authen::NTLM->new(
        user     => $user,
        domain   => $domain,
        password => $self->{_password},
        version  => 2,
    );

    $self->debug2("authentication required, trying ntlm with $scheme scheme");

    # Type 1 message, server should answer with a type 2 challenge
    $request->header(Authorization => "$scheme " . $ntlm->challenge());
    $response = $self->_ua_request($request);

    my ($challenge) = map { /^\Q$scheme\E\s+(\S+)/i ? $1 : () } _challenges($response);
    if ($response->code == 401 && $challenge) {
        # Type 3 message on the same connection
        $request->header(Authorization => "$scheme " . $ntlm->challenge($challenge));
        $response = $self->_ua_request($request);
    }
    $request->remove_header('Authorization');

    $self->{_auth_error} = 'ntlm authentication refused'
        if $response->code == 401;

    return $response;
}

#####
# WsMan SOAP layer (ported from GLPI::Agent::SOAP::WsMan)

sub _send {
    my ($self, $envelope, $header) = @_;

    delete $self->{_fault_code};
    delete $self->{_auth_error};

    my $message = $xml->write($envelope->get());
    return $self->abort("Won't send wrong request")
        unless $message;
    $message = encode('UTF-8', $message);

    my $headers = HTTP::Headers->new(
        'Content-Type'   => 'application/soap+xml;charset=UTF-8',
        'Content-Length' => length($message),
        %{$header // {}},
    );

    my $request = HTTP::Request->new(POST => $self->url(), $headers, $message);

    $self->_log("===>\n" . $request->as_string . "===>") if $self->{_debug_raw};

    my $response = $self->request($request);
    $self->{_lastcode} = $response->code;

    $self->_log("<====\n" . $response->as_string . "<====") if $self->{_debug_raw};

    if ($response->is_success) {
        $xml->string($response->content);
        my $tree = $xml->dump_as_hash()
            or return $self->abort('Malformed response: no XML content found');
        return $tree;
    } elsif ($response->header('Content-Type') && $response->header('Content-Type') =~ m{application/soap\+xml}) {
        # In case of failure (error 500) we can analyse the reason
        $xml->string($response->content);
        my $tree = $xml->dump_as_hash();
        my $fault = $tree ? Envelope->new($tree) : undef;
        if ($fault && $fault->header->action && $fault->header->action->is('fault')) {
            my $code = $fault->body->fault->errorCode;
            $self->{_fault_code} = $code;
            return $self->abort('WMI ' . ($self->{_resource_class} ? $self->{_resource_class} . ' ' : '') . 'resource not available')
                if $code && $code eq WSMAN_ERROR_RESOURCE_NOT_AVAILABLE;
            my $text = $fault->body->fault->reason->text;
            return $self->abort($text || $response->status_line);
        }
    }

    if ($response->code == 401) {
        return $self->abort(($self->{_auth_error} // 'authentication failed') . ' (' . $response->status_line . ')');
    }

    return $self->abort($response->status_line);
}

sub _check_response {
    my ($self, %params) = @_;

    my $what = $params{what};

    my $envelope = Envelope->new($params{response})
        or return $self->abort("Malformed $what response, no 'Envelope' node found");

    my $header = $envelope->header;
    return $self->abort("Malformed $what response, no 'Header' node found")
        unless ref($header) eq 'Header';

    my $respaction = $header->action;
    return $self->abort("Malformed $what response, no 'Action' found in Header")
        unless ref($respaction) eq 'Action';
    return $self->abort("Not a $what response but " . $respaction->what)
        unless grep { $respaction->is($_) } @{$params{actions}};

    my $related = $header->get('RelatesTo');
    return $self->abort("Got message not related to our $what request")
        if (!$related || $related->string() ne $params{messageid}->string());

    # OperationID is only returned by WinRM
    if ($params{operationid}) {
        my $thisopid = $header->get('OperationID');
        return $self->abort("Got message not related to our $what operation")
            if ($thisopid && !$thisopid->equals($params{operationid}));
    }

    my $respbody = $envelope->body;
    return $self->abort("Malformed $what response, no 'Body' node found")
        unless ref($respbody) eq 'Body';

    return $envelope;
}

sub _header {
    my ($self, %params) = @_;

    return Header->new(
        To->new( $self->url ),
        ResourceURI->new( $params{resource} ),
        ReplyTo->anonymous,
        $params{action},
        $params{messageid},
        MaxEnvelopeSize->new(512000),
        Locale->new($self->{_lang}),
        DataLocale->new($self->{_lang}),
        $params{sid} // SessionId->new(),
        $params{operationid},
        SequenceId->new(),
        OperationTimeout->new($params{timeout} // $self->{_operation_timeout}),
        defined($params{selectorset}) ? $params{selectorset} : (),
        defined($params{optionset}) ? $params{optionset} : (),
    );
}

sub identify {
    my ($self) = @_;

    my $request = Envelope->new(
        Namespace->new(qw(s wsmid)),
        Header->new(),
        Body->new( Identify->new() ),
    );

    my $response = $self->_send(
        $request,
        $self->{_auth_method} eq 'noauth' ? { WSMANIDENTIFY => 'unauthenticated' } : {},
    );

    return unless $response;

    my $envelope = Envelope->new($response);
    my $body = $envelope->body;
    return $self->abort("Malformed identify response, no 'body' node found")
        unless (ref($body) eq 'Body');

    my $identify = $body->get('IdentifyResponse');
    return $self->abort('Malformed identify response, not valid')
        unless $identify && $identify->isvalid();

    $self->debug2('Identify response: ' . $identify->ProductVendor . ' - ' . $identify->ProductVersion);

    # Get remote lang as default lang for future exchanges
    my $lang = $envelope->attribute('xml:lang');
    if ($lang) {
        $self->{_lang} = $lang;
        $self->debug2('Identify response language: ' . $lang);
    }

    return $identify;
}

# Enumerate instances of a resource, optionally filtered with a WQL query.
# Returns an array ref of rows (hash of property name => value) or undef on
# failure (see lasterror()).
#  resource_uri: resource URI, like http://schemas.microsoft.com/wbem/wsman/1/wmi/root/cimv2/*
#  class/moniker: alternative to resource_uri to build a WMI resource URI
#  query: WQL query
#  max_elements: max elements by response
sub enumerate {
    my ($self, %params) = @_;

    $self->lasterror('');

    my $url = $params{resource_uri};
    unless ($url) {
        my $class = $params{query} ? '*' : $params{class};
        $self->{_resource_class} = $class unless $class eq '*';
        $url = $self->resource_url($class, $params{moniker})
            or return;
    }

    # End message is a WinRM extension
    my $winrm = $url =~ m{^https?://schemas\.microsoft\.com/} ? 1 : 0;

    my $messageid = MessageID->new();
    my $sid = SessionId->new();
    my $operationid = OperationID->new();
    my $max_elements = $params{max_elements} || 999;
    my @enumerate = (
        OptimizeEnumeration->new(),
        MaxElements->new($max_elements),
    );
    push @enumerate, Filter->new($params{query}) if $params{query};
    my $body = Body->new( Enumerate->new(@enumerate) );
    my $action = Action->new('enumerate');

    $self->debug2($params{query} ?
        "Requesting enumerate on $url: $params{query}" : "Requesting enumerate URL: $url"
    );

    my $request = Envelope->new(
        Namespace->new(qw(s a n w p b)),
        $self->_header(
            resource    => $url,
            action      => $action,
            messageid   => $messageid,
            sid         => $sid,
            operationid => $operationid,
        ),
        $body,
    );

    my @items;
    my $failed = 0;

    while ($request) {
        my $response = $self->_send($request);
        unless ($response) {
            $failed = 1;
            last;
        }

        my $envelope = $self->_check_response(
            what        => 'enumerate',
            response    => $response,
            actions     => [ 'enumerateresponse', 'pullresponse' ],
            messageid   => $messageid,
            operationid => $operationid,
        );
        unless ($envelope) {
            $failed = 1;
            last;
        }

        my $ispull = $envelope->header->action->is('pullresponse');
        my $enum = $envelope->body->enumeration($ispull);
        foreach my $row ($enum->rows()) {
            # Values are returned as UTF-8 encoded bytes, as openwsman did
            foreach (values(%$row)) {
                $_ = encode('UTF-8', $_) if defined($_) && utf8::is_utf8($_);
            }
            push @items, $row;
        }

        last if $enum->end_of_sequence;

        my $context = $enum->context;
        unless (defined($context->string) && $context->string ne '') {
            # No more context: nothing more to pull
            last;
        }

        # Fix Envelope namespaces
        $request->reset_namespace('s,a,n,w,p');

        # Update Action to Pull
        $action->set('pull');

        # Update MessageID & OperationID
        $messageid->reset_uuid();
        $operationid->reset_uuid();

        # Reset Body to make Pull request with provided EnumerationContext
        $body->reset(
            # WinRM requires same MaxElements for Pull as for Enumerate
            Pull->new( $context, MaxElements->new($max_elements, 'for_pull') )
        );
    }

    # Send End to remote
    $self->end($operationid) if $winrm;

    # Forget what resource was requested
    delete $self->{_resource_class};

    return $failed ? undef : \@items;
}

sub resource_url {
    my ($self, $class, $moniker) = @_;

    my $path = 'cimv2';

    if ($moniker) {
        $moniker =~ s/\\/\//g;
        ($path) = $moniker =~ m|root/(.*)$|i;
        return $self->abort("Wrong moniker for request: $moniker")
            unless $path;
        $path =~ s/\/*$//;
    }

    return 'http://schemas.microsoft.com/wbem/wsman/1/wmi/root/' . lc("$path/$class");
}

#####
# Remote shell (WinRS)

# Create a remote cmd shell. Returns a shell handle (hash ref) or undef.
#  options: hash ref of WinRS options (like WINRS_CODEPAGE => 437)
sub shell_create {
    my ($self, %params) = @_;

    my $messageid = MessageID->new();
    my $sid = SessionId->new();
    my $operationid = OperationID->new();
    my $resource = ResourceURI->new(SHELL_CMD_URI);

    my $options = $params{options} // { WINRS_NOPROFILE => 'TRUE', WINRS_CODEPAGE => '65001' };
    my $optionset = OptionSet->new(
        map { Option->new($_ => $options->{$_}) } sort keys(%{$options})
    );

    my $request = Envelope->new(
        Namespace->new(qw(s a w p)),
        $self->_header(
            resource    => SHELL_CMD_URI,
            action      => Action->new('create'),
            messageid   => $messageid,
            sid         => $sid,
            operationid => $operationid,
            optionset   => $optionset,
        ),
        Body->new( Shell->new() ),
    );

    my $response = $self->_send($request)
        or return;

    my $envelope = $self->_check_response(
        what        => 'create',
        response    => $response,
        actions     => [ 'createresponse' ],
        messageid   => $messageid,
        operationid => $operationid,
    ) or return;

    my $created = $envelope->body->get('ResourceCreated');
    return $self->abort("Malformed create response, no 'ResourceCreated' node found")
        unless ref($created) eq 'ResourceCreated';

    my $reference = $created->get('ReferenceParameters');
    return $self->abort("Malformed create response, no 'ReferenceParameters' returned")
        unless ref($reference) eq 'ReferenceParameters';

    my $selectorset = $reference->get('SelectorSet');
    return $self->abort("Malformed create response, no 'SelectorSet' returned")
        unless ref($selectorset) eq 'SelectorSet';

    my ($selector) = $selectorset->nodes('Selector');
    my $shell_id = $selector ? $selector->string : undef;
    return $self->abort('Malformed create response, no shell id returned')
        unless defined($shell_id) && $shell_id ne '';

    $self->debug2("Shell created: $shell_id");

    return {
        id          => $shell_id,
        sid         => $sid,
        resource    => SHELL_CMD_URI,
        selectorset => SelectorSet->new(
            Selector->new( Attribute->new( Name => 'ShellId' ), $shell_id )
        ),
    };
}

# Run a command in a remote shell. Returns command id or undef.
#  options: hash ref of WinRS options (like WINRS_SKIP_CMD_SHELL => 'FALSE')
#  split_args: send command and arguments in dedicated nodes (GLPI Agent way),
#              by default the whole command line is sent in Command node
sub shell_command {
    my ($self, %params) = @_;

    my $shell = $params{shell};
    my $command = $params{command};

    return $self->abort('No command to run')
        unless defined($command) && length($command);

    # limit log command size if too large like for powershell commands
    if ($self->debug()) {
        my $logcommand = $command;
        while (length($logcommand) > 120 && $logcommand =~ /\w\s+\w/) {
            ($logcommand) = $logcommand =~ /^(.*\w)\s+\w+/;
            $logcommand .= ' ...';
        }
        $self->debug2("Requesting '$logcommand' run to " . $self->url);
    }

    my $messageid = MessageID->new();
    my $operationid = OperationID->new();

    my $options = $params{options} // { WINRS_CONSOLEMODE_STDIN => 'TRUE' };
    my $optionset = OptionSet->new(
        map { Option->new($_ => $options->{$_}) } sort keys(%{$options})
    );

    my $cmdline;
    if ($params{split_args}) {
        $cmdline = Shell->new()->commandline($command);
    } else {
        $cmdline = CommandLine->new(
            Attribute->new( Shell->new()->namespace ),
            Command->new($command),
        );
    }

    my $request = Envelope->new(
        Namespace->new(qw(s a w p)),
        $self->_header(
            resource    => $shell->{resource},
            action      => Action->new('command'),
            messageid   => $messageid,
            sid         => $shell->{sid},
            operationid => $operationid,
            selectorset => $shell->{selectorset},
            optionset   => $optionset,
        ),
        Body->new($cmdline),
    );

    my $response = $self->_send($request)
        or return;

    my $envelope = $self->_check_response(
        what        => 'command',
        response    => $response,
        actions     => [ 'commandresponse' ],
        messageid   => $messageid,
        operationid => $operationid,
    ) or return;

    my $respcmd = $envelope->body->get('CommandResponse');
    return $self->abort("Malformed command response, no 'CommandResponse' node found")
        unless ref($respcmd) eq 'CommandResponse';

    my $commandid = $respcmd->get('CommandId');
    return $self->abort("Malformed command response, no 'CommandId' returned")
        unless ref($commandid) eq 'CommandId';

    my $cid = $commandid->string();
    return $self->abort('Malformed command response, no CommandId value found')
        unless $cid;

    return $cid;
}

# Read streams of a command until it is done. Returns a hash ref with stdout,
# stderr and exitcode keys or undef on failure.
#  timeout: global timeout in seconds to wait for command completion
sub shell_receive {
    my ($self, %params) = @_;

    my $shell = $params{shell};
    my $cid = $params{command_id};
    my $deadline = time() + ($params{timeout} // 300);

    my ($stdout, $stderr, $exitcode) = ('', '', undef);

    while (1) {
        return $self->abort('Command too long to execute')
            if time() > $deadline;

        my $messageid = MessageID->new();
        my $operationid = OperationID->new();

        my $request = Envelope->new(
            Namespace->new(qw(s a w p)),
            $self->_header(
                resource    => $shell->{resource},
                action      => Action->new('receive'),
                messageid   => $messageid,
                sid         => $shell->{sid},
                operationid => $operationid,
                selectorset => $shell->{selectorset},
            ),
            Body->new( Receive->new($cid) ),
        );

        my $response = $self->_send($request);
        unless ($response) {
            # WinRM answers with a TimedOut fault when no output is available
            # before OperationTimeout: just retry
            next if $self->{_fault_code} && $self->{_fault_code} eq WSMAN_ERROR_TIMEDOUT;
            return;
        }

        my $envelope = $self->_check_response(
            what        => 'receive',
            response    => $response,
            actions     => [ 'receiveresponse' ],
            messageid   => $messageid,
            operationid => $operationid,
        ) or return;

        my $received = $envelope->body->get('ReceiveResponse');
        return $self->abort("Malformed receive response, no 'ReceiveResponse' node found")
            unless ref($received) eq 'ReceiveResponse';

        # Handles Streams
        my $streams = $received->get('Stream');
        if (ref($streams) eq 'Stream') {
            $stdout .= $streams->stdout($cid) // '';
            $stderr .= $streams->stderr($cid) // '';
        }

        my $cmdstate = $received->get('CommandState');
        next unless ref($cmdstate) eq 'CommandState';

        my $thiscid = $cmdstate->attribute('CommandId');
        return $self->abort('Wrong CommandId in ReceiveResponse node')
            if defined($thiscid) && $thiscid ne $cid;

        my $state = $cmdstate->attribute('State') // '';
        my $code = $cmdstate->exitcode();
        $exitcode = $code if defined($code);

        if ($state eq SHELL_STATE_URI . 'Done') {
            return $self->abort("No exit code for 'done' command")
                unless defined($exitcode);
            $self->debug2("Command exited with code: $exitcode");
            last;
        } elsif ($state eq SHELL_STATE_URI . 'Pending') {
            # WinRM 1.1 sends this with ExitCode:0
            last;
        } elsif ($state ne SHELL_STATE_URI . 'Running') {
            return $self->abort('Unknown command state: ' . $state);
        }
    }

    return {
        stdout   => $stdout,
        stderr   => $stderr,
        exitcode => $exitcode,
    };
}

sub shell_signal {
    my ($self, %params) = @_;

    my $shell = $params{shell};
    my $cid = $params{command_id};

    my $messageid = MessageID->new();
    my $operationid = OperationID->new();

    my $request = Envelope->new(
        Namespace->new(qw(s a w p)),
        $self->_header(
            resource    => $shell->{resource},
            action      => Action->new('signal'),
            messageid   => $messageid,
            sid         => $shell->{sid},
            operationid => $operationid,
            selectorset => $shell->{selectorset},
        ),
        Body->new(
            Signal->new(
                Attribute->new( 'xmlns:' . Shell->xmlns => Shell->xsd ),
                Attribute->new( CommandId => $cid ),
                Code->signal($params{signal} // 'terminate'),
            ),
        ),
    );

    my $response = $self->_send($request)
        or return;

    $self->_check_response(
        what        => 'signal',
        response    => $response,
        actions     => [ 'signalresponse' ],
        messageid   => $messageid,
        operationid => $operationid,
    ) or return;

    return 1;
}

sub shell_delete {
    my ($self, %params) = @_;

    my $shell = $params{shell};

    my $messageid = MessageID->new();
    my $operationid = OperationID->new();

    my $request = Envelope->new(
        Namespace->new(qw(s a w p)),
        $self->_header(
            resource    => $shell->{resource},
            action      => Action->new('delete'),
            messageid   => $messageid,
            sid         => $shell->{sid},
            operationid => $operationid,
            selectorset => $shell->{selectorset},
        ),
        Body->new(),
    );

    my $response = $self->_send($request)
        or return;

    $self->_check_response(
        what        => 'delete',
        response    => $response,
        actions     => [ 'deleteresponse' ],
        messageid   => $messageid,
        operationid => $operationid,
    ) or return;

    # Send End to remote
    $self->end($operationid);

    return 1;
}

# Run one command in a dedicated shell (GLPI Agent API)
sub shell {
    my ($self, $command) = @_;

    return unless $command;

    my $shell = $self->shell_create()
        or return;

    my $result;
    my $cid = $self->shell_command(shell => $shell, command => $command, split_args => 1);
    if ($cid) {
        $result = $self->shell_receive(shell => $shell, command_id => $cid);
        $self->shell_signal(shell => $shell, command_id => $cid);
    }
    $self->shell_delete(shell => $shell);

    return unless $result;

    return {
        stdout   => \$result->{stdout},
        exitcode => $result->{exitcode} // 255,
    };
}

sub end {
    my ($self, $operationid) = @_;

    # Don't alter last error with End message result
    local $self->{_lasterror} = $self->{_lasterror};
    local $self->{_lastcode} = $self->{_lastcode};
    local $self->{_fault_code} = $self->{_fault_code};

    my $request = Envelope->new(
        Namespace->new(qw(s a w p)),
        Header->new(
            To->anonymous,
            ResourceURI->new(FULLDUPLEX_URI),
            Action->new('end'),
            MessageID->new(),
            $operationid,
        ),
        Body->new(),
    );
    $self->_send($request);
}

package centreon::plugins::wsman::client::useragent;

use strict;
use warnings;

use parent 'LWP::UserAgent';

# Credentials for LWP handled authentication schemes (basic & digest)
sub get_basic_credentials {
    my ($self, $realm, $uri, $isproxy) = @_;

    return if $isproxy;

    my $client = $self->{_wsman_client}
        or return;

    return unless $client->{_auth_method} =~ /^(?:basic|pass|digest)$/;

    return ($client->{_user}, $client->{_password});
}

1;

__END__

=head1 NAME

centreon::plugins::wsman::client - pure perl WS-Management client

=head1 SYNOPSIS

    my $client = centreon::plugins::wsman::client->new(
        url         => 'https://host:5986/wsman',
        auth_method => 'basic',
        username    => 'user',
        password    => 'pass',
    );
    my $rows = $client->enumerate(
        resource_uri => 'http://schemas.microsoft.com/wbem/wsman/1/wmi/root/cimv2/*',
        query        => 'select Name from Win32_Service'
    ) or die $client->lasterror();

=cut

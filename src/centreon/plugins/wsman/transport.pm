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

package centreon::plugins::wsman::transport;

# HTTP(S) transport for WS-Management SOAP messages.
#
# Supported authentication methods:
#   noauth       no Authorization header
#   basic, pass  preemptive HTTP Basic authentication
#   digest       HTTP Digest authentication (handled by LWP)
#   ntlm         NTLMv2 handshake (Authen::NTLM), with 'NTLM' or 'Negotiate' scheme
#   gssnegotiate Kerberos through SPNEGO 'Negotiate' scheme (GSSAPI), see
#                centreon::plugins::wsman::negotiate
#
# Note: these methods authenticate the HTTP connection only. WinRM message
# encryption over plain http is not implemented: use https, or allow
# unencrypted traffic on the WinRM service.

use strict;
use warnings;

use HTTP::Request;
use HTTP::Response;
use LWP::UserAgent;
use MIME::Base64;
use URI;

sub new {
    my ($class, %options) = @_;

    my $self = bless {
        url         => URI->new($options{url}),
        auth_method => $options{auth_method} // 'basic',
        username    => $options{username} // '',
        password    => $options{password} // '',
        timeout     => $options{timeout} || 30,
        logger      => $options{logger},
        auth_error  => undef
    }, $class;

    my $ua = LWP::UserAgent->new(
        keep_alive => 1,
        timeout => $self->{timeout},
        agent => 'centreon-plugins-wsman',
        parse_head => 0,
        max_redirect => 0
    );
    # Server certificate is not verified (same behaviour as with openwsman)
    $ua->ssl_opts(verify_hostname => 0, SSL_verify_mode => 0);

    if (defined($options{proxy_url}) && $options{proxy_url} ne '') {
        my $proxy = URI->new($options{proxy_url});
        if (defined($options{proxy_username}) && defined($options{proxy_password}) && $proxy->can('userinfo')) {
            $proxy->userinfo(
                join(':', map { my $v = $_; $v =~ s/([^A-Za-z0-9\-._~])/sprintf('%%%02X', ord($1))/ge; $v }
                    ($options{proxy_username}, $options{proxy_password}))
            );
        }
        $ua->proxy(['http', 'https'], $proxy->as_string());
        $self->{proxy} = 1;
    }

    if ($self->{auth_method} eq 'digest') {
        # Let LWP answer the Digest challenge, whatever the realm is
        $ua->add_handler(response_done => sub {
            my ($response, $ua_obj) = @_;
            return if ($response->code() != 401);
            my $url = $response->request()->uri();
            foreach my $realm (map { /^Digest\b.*?realm="([^"]*)"/i ? $1 : () } $response->header('WWW-Authenticate')) {
                $ua_obj->credentials($url->host_port(), $realm, $self->{username}, $self->{password});
            }
            # Only keep Digest challenges: LWP would try the first supported scheme
            my @digest = grep { /^Digest\b/i } $response->header('WWW-Authenticate');
            $response->header('WWW-Authenticate' => \@digest);
            return;
        });
    }

    $self->{ua} = $ua;

    return $self;
}

sub log {
    my ($self, $message) = @_;

    $self->{logger}->($message) if (ref($self->{logger}) eq 'CODE');
}

sub auth_error {
    my ($self) = @_;

    return $self->{auth_error};
}

# Send a SOAP message, return the HTTP::Response
sub post {
    my ($self, %options) = @_;

    $self->{auth_error} = undef;

    my $request = HTTP::Request->new(POST => $self->{url});
    $request->header('Content-Type' => 'application/soap+xml;charset=UTF-8');
    $request->header('Content-Length' => length($options{content}));
    $request->content($options{content});

    my $method = $self->{auth_method};
    if ($method eq 'basic' || $method eq 'pass') {
        $request->header(Authorization => 'Basic ' . encode_base64($self->{username} . ':' . $self->{password}, ''));
    }

    my $response;
    if ($method eq 'digest') {
        # LWP handles the challenge/response exchange
        $response = $self->_send(request => $request, follow_auth => 1);
    } else {
        $response = $self->_send(request => $request);
        if ($response->code() == 401) {
            if ($method eq 'gssnegotiate') {
                $response = $self->_kerberos(request => $request, response => $response);
            } elsif ($method eq 'ntlm') {
                $response = $self->_ntlm(request => $request, response => $response);
            }
        }
    }

    $self->{auth_error} //= 'authentication failed' if ($response->code() == 401);

    return $response;
}

sub _send {
    my ($self, %options) = @_;

    my $response = eval {
        $options{follow_auth} ?
            $self->{ua}->request($options{request}) :
            # No automatic authentication handling: we do it ourself
            $self->{ua}->simple_request($options{request});
    };
    return HTTP::Response->new(500, 'request failure: ' . ($@ || 'unknown error'))
        if (!defined($response));

    return $response;
}

# Return the list of authentication challenges: [ scheme, token ] pairs
sub _challenges {
    my ($response) = @_;

    my @challenges;
    foreach my $header ($response->header('WWW-Authenticate')) {
        foreach my $challenge (split(/\s*,\s*(?=[A-Za-z][\w-]*(?:\s|$))/, $header)) {
            my ($scheme, $data) = $challenge =~ /^\s*([\w-]+)\s*(.*)$/;
            push @challenges, [ lc($scheme), $data ] if (defined($scheme));
        }
    }

    return @challenges;
}

sub _ntlm {
    my ($self, %options) = @_;

    my $request = $options{request};
    my %offered = map { $_->[0] => 1 } _challenges($options{response});
    # WinRM only offers 'Negotiate' which also accepts raw NTLM messages
    my $scheme = $offered{ntlm} ? 'NTLM' : $offered{negotiate} ? 'Negotiate' : undef;
    if (!defined($scheme)) {
        $self->{auth_error} = 'ntlm authentication not offered by server';
        return $options{response};
    }
    if (!eval { require Authen::NTLM; 1 }) {
        $self->{auth_error} = 'Authen::NTLM perl module is required for ntlm authentication';
        return $options{response};
    }

    my ($domain, $user) = ('', $self->{username});
    if ($user =~ /^([^\\]*)\\(.*)$/) {
        ($domain, $user) = ($1, $2);
    } elsif ($user =~ /^(.*)\@([^\@]*)$/) {
        ($user, $domain) = ($1, $2);
    }

    my $ntlm = Authen::NTLM->new(user => $user, domain => $domain, password => $self->{password}, version => 2);

    $self->log("ntlm authentication with '$scheme' scheme");
    $request->header(Authorization => $scheme . ' ' . $ntlm->challenge());
    my $response = $self->_send(request => $request);

    my ($server_challenge) = map { $_->[1] } grep { $_->[0] eq lc($scheme) && $_->[1] ne '' } _challenges($response);
    if ($response->code() == 401 && defined($server_challenge)) {
        $request->header(Authorization => $scheme . ' ' . $ntlm->challenge($server_challenge));
        $response = $self->_send(request => $request);
    }
    $request->remove_header('Authorization');

    $self->{auth_error} = 'ntlm authentication refused' if ($response->code() == 401);

    return $response;
}

sub _kerberos {
    my ($self, %options) = @_;

    my $request = $options{request};
    if (!grep { $_->[0] eq 'negotiate' } _challenges($options{response})) {
        $self->{auth_error} = 'kerberos authentication (Negotiate) not offered by server';
        return $options{response};
    }

    require centreon::plugins::wsman::negotiate;
    my $url = $request->uri();
    my $negotiate = centreon::plugins::wsman::negotiate->new(host => $url->host());

    # Channel binding over https (needed when WinRM CbtHardeningLevel is Strict)
    if ($url->scheme() eq 'https') {
        if ($self->{proxy}) {
            $self->log('no kerberos channel binding through a proxy');
        } else {
            my $binding = centreon::plugins::wsman::negotiate::tls_server_end_point(
                host => $url->host(),
                port => $url->port(),
                timeout => $self->{timeout}
            );
            if (defined($binding->{data})) {
                $self->log('kerberos channel binding with server certificate hashed with ' . $binding->{digest});
                $negotiate->channel_binding($binding->{data});
            } else {
                $self->log('kerberos channel binding not used: ' . $binding->{error});
            }
        }
    }

    my $token = $negotiate->initial_token();
    if (!defined($token)) {
        $self->{auth_error} = $negotiate->error();
        return $options{response};
    }

    $self->log('kerberos authentication for service ' . $negotiate->service());
    $request->header(Authorization => 'Negotiate ' . $token);
    my $response = $self->_send(request => $request);
    # A token is valid only once
    $request->remove_header('Authorization');

    if ($response->code() == 401) {
        $self->{auth_error} = 'kerberos authentication refused by server';
        return $response;
    }

    # Mutual authentication: the server must send back a token proving its identity
    my ($server_token) = map { $_->[1] } grep { $_->[0] eq 'negotiate' && $_->[1] ne '' } _challenges($response);
    if (!$negotiate->verify_server($server_token)) {
        $self->{auth_error} = $negotiate->error();
        return HTTP::Response->new(401, 'Unauthorized (server identity not verified)');
    }
    $self->log('kerberos mutual authentication verified');

    return $response;
}

1;

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

package centreon::plugins::wsman::negotiate;

# Kerberos tokens for the HTTP 'Negotiate' authentication scheme (RFC 4559),
# using the GSSAPI perl module (MIT Kerberos or Heimdal).
#
# The plugin never handles a Kerberos password: the GSSAPI library uses the
# credentials cache (kinit, KRB5CCNAME) or a client keytab (KRB5_CLIENT_KTNAME).
# The service principal is HTTP/<host>, so the hostname must be the name known
# by the KDC (usually the FQDN).
#
# Over https, the token can be bound to the TLS channel (RFC 5929
# 'tls-server-end-point'), which Windows calls Extended Protection for
# Authentication (WinRM CbtHardeningLevel).

use strict;
use warnings;

use Digest::SHA;
use MIME::Base64;

sub new {
    my ($class, %options) = @_;

    my $self = bless { host => $options{host}, error => undef }, $class;

    # GSSAPI::Status and GSSAPI::OID are only loaded by GSSAPI->import()
    if (!eval { require GSSAPI; require GSSAPI::Status; require GSSAPI::OID; 1 }) {
        $self->{error} = 'GSSAPI perl module is required for gssnegotiate authentication';
        return $self;
    }

    my $status = GSSAPI::Name->import(
        my $target,
        'HTTP@' . $self->{host},
        GSSAPI::OID::gss_nt_hostbased_service()
    );
    if (!$status) {
        $self->{error} = 'cannot build kerberos service name for ' . $self->service() . ': ' . _gss_error($status);
        return $self;
    }
    $self->{target} = $target;

    return $self;
}

sub error {
    my ($self) = @_;

    return $self->{error};
}

sub service {
    my ($self) = @_;

    return 'HTTP/' . $self->{host};
}

sub channel_binding {
    my ($self, $data) = @_;

    $self->{binding_data} = $data;
}

# Initiate the security context, return the base64 token or undef on error
sub initial_token {
    my ($self) = @_;

    return undef if (!defined($self->{target}));

    $self->{context} = GSSAPI::Context->new();
    my ($status, $token, $flags) = $self->_init_context(input => '');

    # Mutual authentication requested: the context needs the server reply
    if ($status->major() == GSSAPI::GSS_S_CONTINUE_NEEDED()) {
        return encode_base64($token // '', '');
    }

    delete $self->{context};
    $self->{error} = $status->major() == GSSAPI::GSS_S_COMPLETE() ?
        'kerberos context completed without mutual authentication for ' . $self->service() :
        'cannot get kerberos token for ' . $self->service() . ': ' . _gss_error($status);

    return undef;
}

# Check the token sent back by the server (mutual authentication)
sub verify_server {
    my ($self, $server_token) = @_;

    my $context = $self->{context};
    if (!defined($context)) {
        $self->{error} = 'kerberos mutual authentication: no context initiated';
        return 0;
    }
    if (!defined($server_token) || $server_token eq '') {
        delete $self->{context};
        $self->{error} = 'kerberos mutual authentication failed for ' . $self->service() . ': server sent no token';
        return 0;
    }

    my ($status, $token, $flags) = $self->_init_context(input => decode_base64($server_token));
    delete $self->{context};

    if ($status->major() != GSSAPI::GSS_S_COMPLETE()) {
        $self->{error} = 'kerberos mutual authentication failed for ' . $self->service() . ': ' . _gss_error($status);
        return 0;
    }
    if (!defined($flags) || !($flags & GSSAPI::GSS_C_MUTUAL_FLAG())) {
        $self->{error} = 'kerberos mutual authentication not granted by ' . $self->service();
        return 0;
    }

    return 1;
}

sub _init_context {
    my ($self, %options) = @_;

    my $bindings = GSSAPI::GSS_C_NO_CHANNEL_BINDINGS();
    if (defined($self->{binding_data})) {
        $bindings = GSSAPI::Binding->new();
        # Windows (SSPI) only fills application data: addresses are unspecified
        $bindings->set_initiator(GSSAPI::GSS_C_AF_UNSPEC(), '');
        $bindings->set_acceptor(GSSAPI::GSS_C_AF_UNSPEC(), '');
        $bindings->set_appl_data($self->{binding_data});
    }

    # Actual mechanism and lifetime outputs are not needed: undef (not an
    # unset variable which would become an empty GSSAPI::OID object)
    my ($token, $flags);
    my $status = $self->{context}->init(
        GSSAPI::GSS_C_NO_CREDENTIAL(),
        $self->{target},
        GSSAPI::OID::gss_mech_krb5(),
        GSSAPI::GSS_C_MUTUAL_FLAG(),
        0,
        $bindings,
        $options{input},
        undef,
        $token,
        $flags,
        undef
    );

    return ($status, $token, $flags);
}

sub _gss_error {
    my ($status) = @_;

    return 'unknown error' if (!ref($status));

    my @messages = grep { defined($_) && $_ ne '' } $status->generic_message();
    if ($status->minor()) {
        push @messages, grep { defined($_) && $_ ne '' && $_ ne 'Success' } $status->specific_message();
    }

    return @messages ? join(', ', @messages) : 'unknown error';
}

# RFC 5929 'tls-server-end-point' channel binding data for host:port. The
# certificate is hashed with the hash algorithm of its signature, SHA-256 being
# used instead of MD5/SHA-1 or when the signature has no explicit hash.
# Returns { data => ..., digest => ... } or { error => ... }
sub tls_server_end_point {
    my (%options) = @_;

    if (!eval { require IO::Socket::SSL; require Net::SSLeay; 1 }) {
        return { error => 'IO::Socket::SSL and Net::SSLeay perl modules are required' };
    }

    my $socket = IO::Socket::SSL->new(
        PeerHost => $options{host},
        PeerPort => $options{port},
        Timeout => $options{timeout} && $options{timeout} < 30 ? $options{timeout} : 30,
        SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE(),
        ($options{host} =~ /^[\d.]+$|:/ ? () : (SSL_hostname => $options{host}))
    );
    if (!$socket) {
        no warnings 'once';
        return { error => 'cannot get server certificate: ' . ($IO::Socket::SSL::SSL_ERROR || $! || 'connection failure') };
    }

    # Certificate is owned (and freed) by IO::Socket::SSL
    my $x509 = $socket->peer_certificate();
    my ($der, $signature);
    if ($x509) {
        # DER encoding from the PEM export (no i2d_X509 binding in Net::SSLeay)
        my $pem = Net::SSLeay::PEM_get_string_X509($x509) // '';
        $pem =~ s/-----(?:BEGIN|END) CERTIFICATE-----|\s//g;
        $der = decode_base64($pem);
        my $nid = eval { Net::SSLeay::X509_get_signature_nid($x509) };
        $nid = eval { Net::SSLeay::OBJ_obj2nid(Net::SSLeay::P_X509_get_signature_alg($x509)) }
            if (!defined($nid));
        $signature = eval { Net::SSLeay::OBJ_nid2ln($nid) } if (defined($nid));
    }
    $socket->close(SSL_fast_shutdown => 1);

    return { error => 'no server certificate' } if (!defined($der) || $der eq '');

    my $digest = 'sha256';
    if (defined($signature) && $signature =~ /sha-?(224|384|512)(?:[-\/](224|256))?/i) {
        $digest = defined($2) ? "sha512$2" : "sha$1";
    }
    (my $algorithm = $digest) =~ s/^sha//;

    return {
        data => 'tls-server-end-point:' . Digest::SHA->new($algorithm)->add($der)->digest(),
        digest => $digest,
        signature => $signature // 'unknown'
    };
}

1;

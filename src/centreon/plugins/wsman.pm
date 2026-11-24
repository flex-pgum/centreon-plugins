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

package centreon::plugins::wsman;

use strict;
use warnings;
use MIME::Base64;
use centreon::plugins::wsman::client;

my %debug_level = (
    always => -1,
    none => 0,
    error => 1,
    critical => 2,
    warning => 3,
    message => 4,
    info => 5,
    debug => 6
);


sub new {
    my ($class, %options) = @_;
    my $self  = {};
    bless $self, $class;

    if (!defined($options{output})) {
        print "Class wsman: Need to specify 'output' argument.\n";
        exit 3;
    }
    if (!defined($options{options})) {
        $options{output}->add_option_msg(short_msg => "Class wsman: Need to specify 'options' argument.");
        $options{output}->option_exit();
    }

    $options{options}->add_options(arguments => {
        'hostname|host:s'        => { name => 'host' },
        'wsman-port:s'           => { name => 'wsman_port', default => 5985, type => 'port', not_empty => 1 },
        'wsman-path:s'           => { name => 'wsman_path', default => '/wsman' },
        'wsman-scheme:s'         => { name => 'wsman_scheme', default => 'http', type => 'protocol_http', not_empty => 1 },
        'wsman-username:s'       => { name => 'wsman_username', default => '' },
        'wsman-password:s'       => { name => 'wsman_password', default => '' },
        'wsman-timeout:s'        => { name => 'wsman_timeout', default => 30, type => 'numeric', not_empty => 1 },
        'wsman-proxy-url:s'      => { name => 'wsman_proxy_url' },
        'wsman-proxy-username:s' => { name => 'wsman_proxy_username' },
        'wsman-proxy-password:s' => { name => 'wsman_proxy_password' },
        'wsman-debug:s'          => { name => 'wsman_debug' },
        'wsman-auth-method:s'    => { name => 'wsman_auth_method', default => 'basic', not_empty => 1,
                                      is_in => [ 'noauth', 'basic', 'digest', 'pass', 'ntlm', 'gssnegotiate' ] },
        'wsman-errors-exit:s'    => { name => 'wsman_errors_exit', default => 'unknown' }
    });
    $options{options}->add_help(package => __PACKAGE__, sections => 'WSMAN OPTIONS');

    #####
    $self->{client} = undef;
    $self->{output} = $options{output};
    $self->{wsman_params} = {};

    $self->{error_msg} = undef;
    $self->{error_status} = 0;

    return $self;
}

sub connect {
    my ($self, %options) = @_;

    if (!$self->{output}->is_litteral_status(status => $self->{wsman_errors_exit})) {
        $self->{output}->add_option_msg(short_msg => "Unknown value '" . $self->{wsman_errors_exit}  . "' for --wsman-errors-exit.");
        $self->{output}->option_exit(exit_litteral => 'unknown');
    }

    my ($debug, $debug_raw) = (0, 0);
    if (defined($self->{wsman_params}->{wsman_debug})) {
        my $level = defined($debug_level{ $self->{wsman_params}->{wsman_debug} }) ?
            $debug_level{ $self->{wsman_params}->{wsman_debug} } : $debug_level{info};
        $debug = $level != 0 ? 1 : 0;
        # Also dump raw HTTP requests and responses
        $debug_raw = ($level == $debug_level{debug} || $level == $debug_level{always}) ? 1 : 0;
    }

    my $host = $self->{wsman_params}->{host};
    $host = '[' . $host . ']' if ($host =~ /:/ && $host !~ /^\[/);
    my $path = $self->{wsman_params}->{wsman_path};
    $path = '/' . $path if ($path !~ /^\//);

    $self->{client} = centreon::plugins::wsman::client->new(
        url            => $self->{wsman_params}->{wsman_scheme} . '://' . $host . ':' . $self->{wsman_params}->{wsman_port} . $path,
        auth_method    => $self->{wsman_params}->{wsman_auth_method},
        username       => $self->{wsman_params}->{wsman_username},
        password       => $self->{wsman_params}->{wsman_password},
        timeout        => $self->{wsman_params}->{wsman_timeout},
        proxy_url      => $self->{wsman_params}->{wsman_proxy_url},
        proxy_username => $self->{wsman_params}->{wsman_proxy_username},
        proxy_password => $self->{wsman_params}->{wsman_proxy_password},
        debug          => $debug,
        debug_raw      => $debug_raw
    );
    if (!defined($self->{client})) {
        $self->{output}->add_option_msg(short_msg => 'Could not create client handler');
        $self->{output}->option_exit(exit_litteral => $self->{wsman_errors_exit});
    }
}

sub execute_winshell_commands {
    my ($self, %options) = @_;
    # $options{keep_open} = integer
    # $options{commands} = ref array of hash ([{label => 'myipconfig', value => 'ipconfig /all' }])

    my ($dont_quit) = (defined($options{dont_quit}) && $options{dont_quit} == 1) ? 1 : 0;
    $self->set_error();

    my $command_result = {};

    # Init result
    foreach my $command (@{$options{commands}}) {
        $command_result->{$command->{label}} = {stdout => undef, stderr => undef, exit_code => undef};
    }

    if (!defined($self->{shell})) {
        $self->{shell_id} = undef;

        ######
        # Start Shell
        $self->{shell} = $self->{client}->shell_create(
            options => {
                WINRS_NOPROFILE => 'FALSE',
                WINRS_CODEPAGE => '437'
            }
        );
        return undef if ($self->handle_dialog_fault(result => $self->{shell}, msg => 'Create failed: ', dont_quit => $dont_quit));
        $self->{shell_id} = $self->{shell}->{id};
    }

    foreach my $command (@{$options{commands}}) {
        #######
        # Issue command
        my $command_id = $self->{client}->shell_command(
            shell => $self->{shell},
            command => $command->{value},
            options => {
                WINRS_CONSOLEMODE_STDIN => 'TRUE',
                WINRS_SKIP_CMD_SHELL => defined($options{skip_cmd}) ? 'TRUE' : 'FALSE'
            }
        );
        return undef if ($self->handle_dialog_fault(result => $command_id, msg => 'Invoke failed: ', dont_quit => $dont_quit));

        #######
        # Request stdout/stderr
        my $result = $self->{client}->shell_receive(
            shell => $self->{shell},
            command_id => $command_id
        );
        return undef if ($self->handle_dialog_fault(result => $result, msg => 'Invoke failed: ', dont_quit => $dont_quit));

        my ($current_stdout, $current_stderr) = ($result->{stdout}, $result->{stderr});
        $current_stderr =~ s/\r//mg;
        $current_stdout =~ s/\r//mg;

        $command_result->{$command->{label}}->{exit_code} = $result->{exitcode};
        $command_result->{$command->{label}}->{stderr} = $current_stderr if ($current_stderr ne '');
        $command_result->{$command->{label}}->{stdout} = $current_stdout if ($current_stdout ne '');

        #
        # terminate shell command
        #
        # not strictly needed for WinRM 2.0, but WinRM 1.1 requires this
        #
        $result = $self->{client}->shell_signal(
            shell => $self->{shell},
            command_id => $command_id,
            signal => 'terminate'
        );
        return undef if ($self->handle_dialog_fault(result => $result, msg => 'Invoke failed: ', dont_quit => $dont_quit));
    }

    # Delete Shell resource
    if (defined($self->{shell}) && !(defined($options{keep_open}) && $options{keep_open} == 1)) {
        my $shell = $self->{shell};
        $self->{shell} = undef;
        $self->{shell_id} = undef;
        my $result = $self->{client}->shell_delete(shell => $shell);
        return undef if ($self->handle_dialog_fault(result => $result, msg => 'Invoke failed: ', dont_quit => $dont_quit));
    }

    return $command_result;
}

# This function executes 'content' commands via WSMAN using exclusively PowerShell commands
# Parameters:
# $options{label}: label to identify the command ro retrieve results
# $options{content}: base64 encoded content using powershell_encoded_script function
sub execute_powershell {
    my ($self, %options) = @_;

    $options{powershell_version} ||= 5;

    # Powershell 7 is called pwsh.exe, previous versions are called powershell.exe
    # To keep compatibility we use powershell.exe by default
    my $pwsh = $options{powershell_version} >= 7 ? 'pwsh.exe' : 'powershell.exe';

    if ($options{can_trim} && !$self->{wsman_params}->{wsman_debug}) {

    }

    # Trim leading whitespaces when we are not in debug and can_trim is set
    $options{content} = encode_base64( $options{can_trim} && !$self->{wsman_params}->{wsman_debug}
                                           ? $options{content} =~s/^\s+//gmr
                                           : $options{content},
                                       '' );

    my $chunk = 8000;
    my $base = 'C:/Windows/Temp/';
    my $ps1_filename = $base . $options{label} . '-' .$$. '-'. sprintf("%08X", rand(0xFFFFFFFF)) . '.ps1';
    my $b64_filename = $ps1_filename =~ s/\.ps1$/\.b64/r;
    my $commands = [
        {
            label => 'prev1-' . $options{label},
            value => qq($pwsh -command "new-item -itemtype directory -path '$base' -force")
        }
    ];

    # To work around the 8191 character command line length limit when the data exceeds 8000 characters the string is
    # split into 8000 character chunks and reassembled using a temporary file
    my $cmd_content = 'Set-Content';
    my $i = 0;
    foreach (unpack('(A' . $chunk . ')*', $options{content})) {
        push @$commands, {
            label => 'chunk-' . ($i++) . '-' . $options{label},
            value => qq($pwsh -NoProfile -Command "$cmd_content -Path '$b64_filename' -Value '$_' -Encoding ASCII")
        };

        $cmd_content = 'Add-Content';
    }

    push @$commands, {
                         label => 'convert-' . $options{label},
                         value => qq($pwsh -NoProfile -Command "[IO.File]::WriteAllBytes('$ps1_filename',[Convert]::FromBase64String((Get-Content '$b64_filename' -Raw)))")
                     },
                     {   label => $options{label},
                         value => qq($pwsh -NoProfile -ExecutionPolicy Bypass -File "$ps1_filename")
                     },
                     {
                         label => 'del-' . $options{label},
                         value => qq($pwsh -NoProfile -Command "Remove-Item '$ps1_filename','$b64_filename' -Force")
                     };
    return $self->execute_winshell_commands(
        commands => $commands,
        keep_open => 1
    );
}

sub request {
    my ($self, %options) = @_;
    # $options{nothing_quit} = integer
    # $options{dont_quit} = integer
    # $options{uri} = string
    # $options{wql_filter} = string
    # $options{result_type} = string ('array' or 'hash' with a key)
    # $options{hash_key} = string

    my ($dont_quit) = (defined($options{dont_quit}) && $options{dont_quit} == 1) ? 1 : 0;
    my ($nothing_quit) = (defined($options{nothing_quit}) && $options{nothing_quit} == 1) ? 1 : 0;
    my ($result_type) = (defined($options{result_type}) && $options{result_type} =~ /^(array|hash)$/) ? $options{result_type} : 'array';
    $self->set_error();

    ######
    # Check options
    if (!defined($options{uri})) {
        $self->{output}->add_option_msg(short_msg => 'Need to specify uri option');
        $self->{output}->option_exit(exit_litteral => $self->{wsman_errors_exit});
    }

    ######
    # Filter/Enumerate (with pull of all the results)
    my $rows = $self->{client}->enumerate(
        resource_uri => $options{uri},
        query => $options{wql_filter}
    );
    return undef if ($self->handle_dialog_fault(result => $rows, msg => 'Could not enumerate instances: ', dont_quit => $dont_quit));

    ######
    # Fetch values
    my ($array_return, $hash_return);

    $array_return = [] if ($result_type eq 'array');
    $hash_return = {} if ($result_type eq 'hash');
    my $total = 0;

    foreach my $row_return (@$rows) {
        $total++;
        push @{$array_return}, $row_return if ($result_type eq 'array');
        $hash_return->{$row_return->{$options{hash_key}}} = $row_return if ($result_type eq 'hash');
    }

    if ($nothing_quit == 1 && $total == 0) {
        $self->{output}->add_option_msg(short_msg => "Cant get a single value.");
        $self->{output}->option_exit(exit_litteral => $self->{wsman_errors_exit});
    }

    if ($result_type eq 'array') {
        return $array_return;
    }
    return $hash_return;
}

sub check_options {
    my ($self, %options) = @_;
    # $options{option_results} = ref to options result

    $self->{wsman_errors_exit} = $options{option_results}->{wsman_errors_exit};

    if (!defined($options{option_results}->{host})) {
        $self->{output}->add_option_msg(short_msg => "Missing parameter --hostname.");
        $self->{output}->option_exit();
    }
    $self->{wsman_params}->{host} = $options{option_results}->{host};

    $self->{wsman_params}->{wsman_scheme} = $options{option_results}->{wsman_scheme};

    $self->{wsman_params}->{wsman_auth_method} = $options{option_results}->{wsman_auth_method};

    $self->{wsman_params}->{wsman_port} = $options{option_results}->{wsman_port};

    $self->{wsman_params}->{wsman_path} = $options{option_results}->{wsman_path};
    $self->{wsman_params}->{wsman_username} = $options{option_results}->{wsman_username};
    $self->{wsman_params}->{wsman_password} = $options{option_results}->{wsman_password};
    $self->{wsman_params}->{wsman_timeout} = $options{option_results}->{wsman_timeout};
    $self->{wsman_params}->{wsman_proxy_url} = $options{option_results}->{wsman_proxy_url};
    $self->{wsman_params}->{wsman_proxy_username} = $options{option_results}->{wsman_proxy_username};
    $self->{wsman_params}->{wsman_proxy_password} = $options{option_results}->{wsman_proxy_password};
    $self->{wsman_params}->{wsman_debug} = $options{option_results}->{wsman_debug};
}

sub handle_dialog_fault {
    my ($self, %options) = @_;
    my $result = $options{result};
    my $prefix = $options{msg} // 'Error: ';

    unless ($result) {
        my $error_msg;
        my $fault_string = $self->{client}->lasterror();
        if ($self->{wsman_params}->{wsman_auth_method} eq 'gssnegotiate' && $self->{client}->lastcode() == 401) {
            $error_msg = qq~Failed to authenticate using 'gssnegotiate' ($fault_string).
Please verify that:
- a valid Kerberos ticket is available on the machine running the plugin (check with the 'klist' command),
- the target host name is correct,
- the Kerberos configuration is valid.
Use the debug option for more details.
~;
        } else {
            $error_msg = $prefix . ((defined($fault_string) && $fault_string ne '') ? $fault_string : 'use the debug option for more details');
        }

        if ($options{dont_quit} == 1) {
            $self->set_error(error_status => -1, error_msg => $error_msg);
            return 1;
        }
        $self->{output}->option_exit(exit_litteral => $self->{wsman_errors_exit}, short_msg => $error_msg);
    }

    return 0;
}

sub internal_exit {
    my ($self, %options) = @_;

    $self->{output}->add_option_msg(short_msg => $options{msg});
    $self->{output}->option_exit(exit_litteral => $self->{wsman_errors_exit});
}

sub set_error {
    my ($self, %options) = @_;
    # $options{error_msg} = string error
    # $options{error_status} = integer status

    $self->{error_status} = defined($options{error_status}) ? $options{error_status} : 0;
    $self->{error_msg} = defined($options{error_msg}) ? $options{error_msg} : undef;
}

sub error_status {
    my ($self) = @_;

    return $self->{error_status};
}

sub error {
    my ($self) = @_;

    return $self->{error_msg};
}

sub get_hostname {
    my ($self) = @_;

    return $self->{wsman_params}->{host};
}

sub get_port {
    my ($self) = @_;

    return $self->{wsman_params}->{wsman_port};
}

1;

__END__

=head1 NAME

WSMAN global

=head1 SYNOPSIS

WSMAN class

=head1 WSMAN OPTIONS

Pure perl WS-Management implementation (OpenWSMAN is not required anymore).
Authentication method C<ntlm> requires the Authen::NTLM perl module and C<gssnegotiate> requires the GSSAPI perl module.

=over 8

=item B<--hostname>

Define the hostname to query (mandatory).

=item B<--wsman-port>

Define the port to connect to (default: 5985).

=item B<--wsman-path>

Define the path of the WSMAN URL if it has been customized (default: '/wsman').

=item B<--wsman-scheme>

Define the transport scheme (default: 'http').

=item B<--wsman-username>

Define the username for authentication.

=item B<--wsman-password>

Define the password associated with the user name.

=item B<--wsman-timeout>

Define the HTTP transport timeout in seconds (default: 30).

=item B<--wsman-auth-method>

Define the authentication method. Available methods: C<noauth>, C<basic> (default), C<pass> (same as C<basic>), C<digest>, C<ntlm>, C<gssnegotiate>.
With C<gssnegotiate> (Kerberos), a valid ticket must be available (see C<kinit>) and the hostname must be the FQDN of the target.

=item B<--wsman-proxy-url>

Define the URL of the HTTP proxy to use.

=item B<--wsman-proxy-username>

Define the user name to authenticate to the proxy server.

=item B<--wsman-proxy-password>

Define the password to authenticate to the proxy server.

=item B<--wsman-debug>

Define the WSMAN log level (messages are printed on standard error). Available levels: error, critical, warning, message, info (default), debug (also dumps HTTP requests and responses).

=item B<--wsman-errors-exit>

Define the expected exit code when WSMAN errors occur (default: unknown).

=back

=head1 DESCRIPTION

B<WSMAN>.

=cut

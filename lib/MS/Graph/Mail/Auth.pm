package MS::Graph::Mail::Auth;

use 5.026;
use strict;
use warnings;

use LWP::UserAgent;
use HTTP::Request::Common qw(POST);
use JSON qw(decode_json);
use URI;
use Carp qw(croak);
use Try::Tiny;

our $VERSION = '0.10';

sub new {
    my ($class, %args) = @_;

    for my $required (qw(tenant_id client_id client_secret)) {
        croak "Missing required parameter: $required" unless defined $args{$required};
    }

    my $self = bless {
        tenant_id     => $args{tenant_id},
        client_id     => $args{client_id},
        client_secret => $args{client_secret},
        scope         => $args{scope} // 'https://graph.microsoft.com/.default',
        _token        => undef,
        _token_expiry => 0,
        _ua           => $args{_ua} // LWP::UserAgent->new(
            agent   => 'MS-Graph-Mail-Perl/' . $VERSION,
            timeout => 30,
        ),
    }, $class;

    return $self;
}

sub get_token {
    my ($self) = @_;

    # Return cached token if still valid (with 5 min buffer)
    if ($self->{_token} && time() < ($self->{_token_expiry} - 300)) {
        return $self->{_token};
    }

    return $self->_refresh_token();
}

sub _refresh_token {
    my ($self) = @_;

    my $token_url = sprintf(
        'https://login.microsoftonline.com/%s/oauth2/v2.0/token',
        $self->{tenant_id}
    );

    my $request = POST($token_url, [
        client_id     => $self->{client_id},
        client_secret => $self->{client_secret},
        scope         => $self->{scope},
        grant_type    => 'client_credentials',
    ]);

    my $response = $self->{_ua}->request($request);

    unless ($response->is_success) {
        my $error_msg = "Failed to obtain access token: " . $response->status_line;
        try {
            my $error_data = decode_json($response->decoded_content);
            if ($error_data->{error_description}) {
                $error_msg .= " - " . $error_data->{error_description};
            }
        };
        croak $error_msg;
    }

    my $data = try {
        decode_json($response->decoded_content);
    } catch {
        croak "Failed to parse token response: $_";
    };

    unless ($data->{access_token}) {
        croak "No access_token in response";
    }

    $self->{_token} = $data->{access_token};
    $self->{_token_expiry} = time() + ($data->{expires_in} // 3600);

    return $self->{_token};
}

sub clear_token {
    my ($self) = @_;
    $self->{_token} = undef;
    $self->{_token_expiry} = 0;
    return 1;
}

sub is_token_valid {
    my ($self) = @_;
    return ($self->{_token} && time() < ($self->{_token_expiry} - 300));
}

1;

__END__

=head1 NAME

MS::Graph::Mail::Auth - OAuth2 Client Credentials authentication for Microsoft Graph

=head1 SYNOPSIS

    use MS::Graph::Mail::Auth;

    my $auth = MS::Graph::Mail::Auth->new(
        tenant_id     => 'your-tenant-id',
        client_id     => 'your-client-id',
        client_secret => 'your-client-secret',
    );

    my $token = $auth->get_token();

=head1 DESCRIPTION

This module handles OAuth2 Client Credentials flow authentication for Microsoft Graph API.
It automatically caches tokens and refreshes them when they expire.

=head1 METHODS

=head2 new(%args)

Creates a new Auth object. Required parameters:

=over 4

=item * tenant_id - Azure AD tenant ID

=item * client_id - Application (client) ID

=item * client_secret - Client secret

=back

Optional parameters:

=over 4

=item * scope - OAuth scope (default: https://graph.microsoft.com/.default)

=back

=head2 get_token()

Returns the current access token, refreshing if necessary.

=head2 clear_token()

Clears the cached token, forcing a refresh on next get_token() call.

=head2 is_token_valid()

Returns true if the cached token is still valid.

=head1 AUTHOR

Xezis

=head1 LICENSE

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.

=cut

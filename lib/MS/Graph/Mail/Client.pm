package MS::Graph::Mail::Client;

use 5.026;
use strict;
use warnings;

use LWP::UserAgent;
use HTTP::Request;
use JSON qw(encode_json decode_json);
use URI;
use URI::Escape qw(uri_escape);
use Carp qw(croak);
use Try::Tiny;

our $VERSION = '0.20';

use constant {
    BASE_URL              => 'https://graph.microsoft.com/v1.0',
    DEFAULT_MAX_RETRIES   => 3,
    DEFAULT_RETRY_DELAY   => 1,
    THROTTLE_WARN_THRESHOLD => 0.8,
};

sub new {
    my ($class, %args) = @_;

    croak "Missing required parameter: auth" unless $args{auth};

    my $self = bless {
        auth              => $args{auth},
        use_immutable_ids => $args{use_immutable_ids} // 1,
        max_retries       => $args{max_retries} // DEFAULT_MAX_RETRIES,
        retry_delay       => $args{retry_delay} // DEFAULT_RETRY_DELAY,
        throttle_callback => $args{throttle_callback},
        _ua               => $args{_ua} // LWP::UserAgent->new(
            agent   => 'MS-Graph-Mail-Perl/' . $VERSION,
            timeout => 60,
        ),
        _last_throttle_pct => undef,
    }, $class;

    return $self;
}

sub get {
    my ($self, $path, %options) = @_;
    return $self->_request('GET', $path, undef, %options);
}

sub post {
    my ($self, $path, $body, %options) = @_;
    return $self->_request('POST', $path, $body, %options);
}

sub patch {
    my ($self, $path, $body, %options) = @_;
    return $self->_request('PATCH', $path, $body, %options);
}

sub delete {
    my ($self, $path, %options) = @_;
    return $self->_request('DELETE', $path, undef, %options);
}

sub put {
    my ($self, $path, $body, %options) = @_;
    return $self->_request('PUT', $path, $body, %options);
}

# PUT raw binary content to an absolute URL (for upload sessions)
sub put_raw {
    my ($self, $url, $binary_content, %options) = @_;

    my $retries = 0;
    my $max_retries = $self->{max_retries};
    my $retry_delay = $self->{retry_delay};

    while ($retries < $max_retries) {
        my $request = HTTP::Request->new('PUT' => $url);

        # Set headers for binary upload
        $request->header('Authorization' => 'Bearer ' . $self->{auth}->get_token());
        $request->header('Content-Type' => 'application/octet-stream');
        $request->header('Content-Length' => length($binary_content));

        # Add Content-Range header if provided
        if ($options{content_range}) {
            $request->header('Content-Range' => $options{content_range});
        }

        # Set binary content
        $request->content($binary_content);

        my $response = $self->{_ua}->request($request);

        # Monitor throttle proximity header
        $self->_check_throttle_header($response);

        # Handle rate limiting
        if ($response->code == 429) {
            my $retry_after = $response->header('Retry-After') // ($retry_delay * (2 ** $retries));
            sleep($retry_after);
            $retries++;
            next;
        }

        # Handle service unavailable
        if ($response->code == 503) {
            sleep($retry_delay * (2 ** $retries));
            $retries++;
            next;
        }

        # Handle token expiry (401)
        if ($response->code == 401 && $retries == 0) {
            $self->{auth}->clear_token();
            $retries++;
            next;
        }

        return $self->_handle_response($response, 'PUT');
    }

    croak "Max retries exceeded for PUT request: $url";
}

sub _request {
    my ($self, $method, $path, $body, %options) = @_;

    my $url = $self->_build_url($path, $options{query});
    my $retries = 0;
    my $max_retries = $self->{max_retries};
    my $retry_delay = $self->{retry_delay};

    while ($retries < $max_retries) {
        my $request = HTTP::Request->new($method => $url);

        # Set headers
        $request->header('Authorization' => 'Bearer ' . $self->{auth}->get_token());
        $request->header('Content-Type' => 'application/json');
        $request->header('Accept' => 'application/json');

        # Add immutable ID header if enabled
        if ($self->{use_immutable_ids}) {
            $request->header('Prefer' => 'IdType="ImmutableId"');
        }

        # Add custom headers
        if ($options{headers}) {
            for my $header (keys %{$options{headers}}) {
                $request->header($header => $options{headers}{$header});
            }
        }

        # Set body for POST/PATCH
        if (defined $body) {
            my $json_body = ref($body) ? encode_json($body) : $body;
            $request->content($json_body);
        }

        my $response = $self->{_ua}->request($request);

        # Monitor throttle proximity header
        $self->_check_throttle_header($response);

        # Handle rate limiting
        if ($response->code == 429) {
            my $retry_after = $response->header('Retry-After') // ($retry_delay * (2 ** $retries));
            sleep($retry_after);
            $retries++;
            next;
        }

        # Handle service unavailable
        if ($response->code == 503) {
            sleep($retry_delay * (2 ** $retries));
            $retries++;
            next;
        }

        # Handle token expiry (401)
        if ($response->code == 401 && $retries == 0) {
            $self->{auth}->clear_token();
            $retries++;
            next;
        }

        return $self->_handle_response($response, $method);
    }

    croak "Max retries exceeded for request: $method $url";
}

sub _build_url {
    my ($self, $path, $query) = @_;

    my $url = URI->new(BASE_URL . $path);

    if ($query && ref($query) eq 'HASH') {
        $url->query_form(%$query);
    }

    return $url->as_string;
}

sub _handle_response {
    my ($self, $response, $method) = @_;

    # DELETE typically returns 204 No Content
    if ($response->code == 204) {
        return { success => 1 };
    }

    # POST sendMail returns 202 Accepted
    if ($response->code == 202) {
        return { success => 1, accepted => 1 };
    }

    unless ($response->is_success) {
        my $error = $self->_parse_error($response);
        croak sprintf(
            "Graph API Error [%s]: %s - %s",
            $error->{code} // $response->code,
            $error->{message} // $response->status_line,
            $error->{details} // ''
        );
    }

    # Parse JSON response
    my $content = $response->decoded_content;
    return {} unless $content;

    return try {
        decode_json($content);
    } catch {
        croak "Failed to parse API response: $_";
    };
}

sub _parse_error {
    my ($self, $response) = @_;

    my $error = {
        code    => $response->code,
        message => $response->status_line,
        details => '',
    };

    try {
        my $data = decode_json($response->decoded_content);
        if (my $err = $data->{error}) {
            $error->{code}    = $err->{code} // $error->{code};
            $error->{message} = $err->{message} // $error->{message};
            $error->{details} = $err->{innerError}{message} // '';
        }
    };

    return $error;
}

sub _check_throttle_header {
    my ($self, $response) = @_;

    my $throttle_pct = $response->header('x-ms-throttle-limit-percentage');
    return unless defined $throttle_pct;

    $self->{_last_throttle_pct} = $throttle_pct;

    # Invoke callback if approaching throttle limit
    if ($throttle_pct >= THROTTLE_WARN_THRESHOLD && $self->{throttle_callback}) {
        $self->{throttle_callback}->($throttle_pct);
    }
}

sub get_throttle_state {
    my ($self) = @_;

    return {
        last_throttle_percentage => $self->{_last_throttle_pct},
        is_near_limit            => defined $self->{_last_throttle_pct}
                                    && $self->{_last_throttle_pct} >= THROTTLE_WARN_THRESHOLD,
    };
}

sub get_all_pages {
    my ($self, $path, %options) = @_;

    my @all_items;
    my $url = $path;

    while ($url) {
        my $response = $self->get($url, %options);

        if ($response->{value} && ref($response->{value}) eq 'ARRAY') {
            push @all_items, @{$response->{value}};
        }

        # Check for next page
        if ($response->{'@odata.nextLink'}) {
            # Extract path from full URL
            my $next_url = URI->new($response->{'@odata.nextLink'});
            $url = $next_url->path_query;
            $url =~ s{^/v1\.0}{};
            # Clear query options for subsequent requests (they're in the nextLink)
            delete $options{query};
        } else {
            $url = undef;
        }
    }

    return \@all_items;
}

1;

__END__

=head1 NAME

MS::Graph::Mail::Client - HTTP client for Microsoft Graph API

=head1 SYNOPSIS

    use MS::Graph::Mail::Client;
    use MS::Graph::Mail::Auth;

    my $auth = MS::Graph::Mail::Auth->new(...);
    my $client = MS::Graph::Mail::Client->new(
        auth              => $auth,
        use_immutable_ids => 1,
    );

    my $response = $client->get('/users/user@domain.com/messages');

=head1 DESCRIPTION

This module handles HTTP requests to the Microsoft Graph API, including
authentication headers, immutable ID preference, error handling, and
automatic retries for rate limiting.

=head1 METHODS

=head2 new(%args)

Creates a new Client object. Required parameters:

=over 4

=item * auth - MS::Graph::Mail::Auth object

=back

Optional parameters:

=over 4

=item * use_immutable_ids - Enable immutable IDs (default: 1)

=item * max_retries - Maximum retry attempts for rate limiting/errors (default: 3)

=item * retry_delay - Base delay in seconds for exponential backoff (default: 1)

=item * throttle_callback - Code reference called when throttle percentage >= 0.8.
Receives the throttle percentage as argument.

=back

=head2 get($path, %options)

Performs a GET request.

=head2 post($path, $body, %options)

Performs a POST request with JSON body.

=head2 patch($path, $body, %options)

Performs a PATCH request with JSON body.

=head2 delete($path, %options)

Performs a DELETE request.

=head2 get_all_pages($path, %options)

Fetches all pages of a paginated response.

=head2 get_throttle_state()

Returns a hash reference with throttle status information:

=over 4

=item * last_throttle_percentage - Last observed throttle percentage (0.0-1.8+), or undef

=item * is_near_limit - Boolean, true if percentage >= 0.8

=back

=head1 OPTIONS

=over 4

=item * query - Hash of query parameters

=item * headers - Hash of additional headers

=back

=head1 AUTHOR

Xezis

=head1 LICENSE

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.

=cut

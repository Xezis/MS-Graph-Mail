#!/usr/bin/env perl

use strict;
use warnings;
use Test::More tests => 15;
use Test::Exception;
use Test::MockObject;
use JSON qw(encode_json decode_json);

use lib 'lib';
use MS::Graph::Mail::Client;

# Create mock auth
sub create_mock_auth {
    my $auth = Test::MockObject->new();
    $auth->set_always('get_token', 'mock-access-token');
    $auth->set_always('clear_token', 1);
    return $auth;
}

# Create mock UA with response
sub create_mock_ua {
    my ($response_data, $status_code, $headers) = @_;
    $status_code //= 200;
    $headers //= {};

    my $response = Test::MockObject->new();
    $response->set_always('is_success', $status_code >= 200 && $status_code < 300);
    $response->set_always('code', $status_code);
    $response->set_always('status_line', "$status_code OK");
    $response->set_always('decoded_content', ref($response_data) ? encode_json($response_data) : $response_data);
    $response->mock('header', sub {
        my ($self, $name) = @_;
        return $headers->{$name} // undef;
    });

    my $ua = Test::MockObject->new();
    $ua->set_always('request', $response);

    return ($ua, $response);
}

subtest 'constructor requires auth' => sub {
    throws_ok {
        MS::Graph::Mail::Client->new();
    } qr/Missing required parameter: auth/, 'dies without auth';
};

subtest 'constructor creates object' => sub {
    my $client = MS::Graph::Mail::Client->new(
        auth => create_mock_auth(),
    );

    isa_ok($client, 'MS::Graph::Mail::Client');
};

subtest 'GET request includes auth header' => sub {
    my $captured_request;
    my ($mock_ua) = create_mock_ua({ value => [] });
    $mock_ua->mock('request', sub {
        my ($self, $req) = @_;
        $captured_request = $req;
        my $response = Test::MockObject->new();
        $response->set_always('is_success', 1);
        $response->set_always('code', 200);
        $response->set_always('decoded_content', encode_json({ value => [] }));
        return $response;
    });

    my $client = MS::Graph::Mail::Client->new(
        auth => create_mock_auth(),
        _ua  => $mock_ua,
    );

    $client->get('/users/test@test.com/messages');

    is($captured_request->header('Authorization'), 'Bearer mock-access-token', 'auth header set');
};

subtest 'immutable ID header is added by default' => sub {
    my $captured_request;
    my ($mock_ua) = create_mock_ua({ value => [] });
    $mock_ua->mock('request', sub {
        my ($self, $req) = @_;
        $captured_request = $req;
        my $response = Test::MockObject->new();
        $response->set_always('is_success', 1);
        $response->set_always('code', 200);
        $response->set_always('decoded_content', encode_json({ value => [] }));
        return $response;
    });

    my $client = MS::Graph::Mail::Client->new(
        auth => create_mock_auth(),
        _ua  => $mock_ua,
    );

    $client->get('/test');

    is($captured_request->header('Prefer'), 'IdType="ImmutableId"', 'immutable ID header set');
};

subtest 'immutable ID header can be disabled' => sub {
    my $captured_request;
    my ($mock_ua) = create_mock_ua({ value => [] });
    $mock_ua->mock('request', sub {
        my ($self, $req) = @_;
        $captured_request = $req;
        my $response = Test::MockObject->new();
        $response->set_always('is_success', 1);
        $response->set_always('code', 200);
        $response->set_always('decoded_content', encode_json({ value => [] }));
        return $response;
    });

    my $client = MS::Graph::Mail::Client->new(
        auth              => create_mock_auth(),
        use_immutable_ids => 0,
        _ua               => $mock_ua,
    );

    $client->get('/test');

    ok(!defined $captured_request->header('Prefer'), 'no Prefer header when disabled');
};

subtest 'POST sends JSON body' => sub {
    my $captured_request;
    my ($mock_ua) = create_mock_ua({ id => 'new-id' }, 201);
    $mock_ua->mock('request', sub {
        my ($self, $req) = @_;
        $captured_request = $req;
        my $response = Test::MockObject->new();
        $response->set_always('is_success', 1);
        $response->set_always('code', 201);
        $response->set_always('decoded_content', encode_json({ id => 'new-id' }));
        return $response;
    });

    my $client = MS::Graph::Mail::Client->new(
        auth => create_mock_auth(),
        _ua  => $mock_ua,
    );

    $client->post('/test', { foo => 'bar' });

    is($captured_request->method, 'POST', 'method is POST');
    is($captured_request->header('Content-Type'), 'application/json', 'content type is JSON');
    my $body = decode_json($captured_request->content);
    is($body->{foo}, 'bar', 'body contains data');
};

subtest 'PATCH sends JSON body' => sub {
    my $captured_request;
    my ($mock_ua) = create_mock_ua({ id => 'updated' });
    $mock_ua->mock('request', sub {
        my ($self, $req) = @_;
        $captured_request = $req;
        my $response = Test::MockObject->new();
        $response->set_always('is_success', 1);
        $response->set_always('code', 200);
        $response->set_always('decoded_content', encode_json({ id => 'updated' }));
        return $response;
    });

    my $client = MS::Graph::Mail::Client->new(
        auth => create_mock_auth(),
        _ua  => $mock_ua,
    );

    $client->patch('/test/123', { isRead => \1 });

    is($captured_request->method, 'PATCH', 'method is PATCH');
};

subtest 'DELETE returns success on 204' => sub {
    my ($mock_ua) = create_mock_ua('', 204);
    $mock_ua->mock('request', sub {
        my $response = Test::MockObject->new();
        $response->set_always('is_success', 1);
        $response->set_always('code', 204);
        $response->set_always('decoded_content', '');
        return $response;
    });

    my $client = MS::Graph::Mail::Client->new(
        auth => create_mock_auth(),
        _ua  => $mock_ua,
    );

    my $result = $client->delete('/test/123');

    ok($result->{success}, 'returns success on 204');
};

subtest 'query parameters are appended to URL' => sub {
    my $captured_request;
    my ($mock_ua) = create_mock_ua({ value => [] });
    $mock_ua->mock('request', sub {
        my ($self, $req) = @_;
        $captured_request = $req;
        my $response = Test::MockObject->new();
        $response->set_always('is_success', 1);
        $response->set_always('code', 200);
        $response->set_always('decoded_content', encode_json({ value => [] }));
        return $response;
    });

    my $client = MS::Graph::Mail::Client->new(
        auth => create_mock_auth(),
        _ua  => $mock_ua,
    );

    $client->get('/test', query => {
        '$top'    => 10,
        '$filter' => 'isRead eq false',
    });

    my $uri = $captured_request->uri->as_string;
    like($uri, qr/top=10/, 'top parameter in URL');
    like($uri, qr/filter=/, 'filter parameter in URL');
};

subtest 'API error throws exception with details' => sub {
    my ($mock_ua) = create_mock_ua({
        error => {
            code    => 'ErrorItemNotFound',
            message => 'The specified object was not found.',
        }
    }, 404);
    $mock_ua->mock('request', sub {
        my $response = Test::MockObject->new();
        $response->set_always('is_success', 0);
        $response->set_always('code', 404);
        $response->set_always('status_line', '404 Not Found');
        $response->set_always('decoded_content', encode_json({
            error => {
                code    => 'ErrorItemNotFound',
                message => 'The specified object was not found.',
            }
        }));
        return $response;
    });

    my $client = MS::Graph::Mail::Client->new(
        auth => create_mock_auth(),
        _ua  => $mock_ua,
    );

    throws_ok {
        $client->get('/test/nonexistent');
    } qr/ErrorItemNotFound.*not found/i, 'throws with API error details';
};

subtest 'configurable max_retries and retry_delay' => sub {
    my $client = MS::Graph::Mail::Client->new(
        auth        => create_mock_auth(),
        max_retries => 5,
        retry_delay => 2,
    );

    is($client->{max_retries}, 5, 'max_retries is configurable');
    is($client->{retry_delay}, 2, 'retry_delay is configurable');
};

subtest 'default retry values' => sub {
    my $client = MS::Graph::Mail::Client->new(
        auth => create_mock_auth(),
    );

    is($client->{max_retries}, 3, 'default max_retries is 3');
    is($client->{retry_delay}, 1, 'default retry_delay is 1');
};

subtest 'throttle callback is invoked on high throttle percentage' => sub {
    my $callback_invoked = 0;
    my $callback_pct;

    my ($mock_ua) = create_mock_ua({ value => [] });
    $mock_ua->mock('request', sub {
        my $response = Test::MockObject->new();
        $response->set_always('is_success', 1);
        $response->set_always('code', 200);
        $response->set_always('decoded_content', encode_json({ value => [] }));
        $response->mock('header', sub {
            my ($self, $name) = @_;
            return 0.85 if $name eq 'x-ms-throttle-limit-percentage';
            return undef;
        });
        return $response;
    });

    my $client = MS::Graph::Mail::Client->new(
        auth              => create_mock_auth(),
        _ua               => $mock_ua,
        throttle_callback => sub {
            my ($pct) = @_;
            $callback_invoked = 1;
            $callback_pct = $pct;
        },
    );

    $client->get('/test');

    ok($callback_invoked, 'throttle callback was invoked');
    is($callback_pct, 0.85, 'callback received correct percentage');
};

subtest 'get_throttle_state returns correct state' => sub {
    my ($mock_ua) = create_mock_ua({ value => [] });
    $mock_ua->mock('request', sub {
        my $response = Test::MockObject->new();
        $response->set_always('is_success', 1);
        $response->set_always('code', 200);
        $response->set_always('decoded_content', encode_json({ value => [] }));
        $response->mock('header', sub {
            my ($self, $name) = @_;
            return 0.9 if $name eq 'x-ms-throttle-limit-percentage';
            return undef;
        });
        return $response;
    });

    my $client = MS::Graph::Mail::Client->new(
        auth => create_mock_auth(),
        _ua  => $mock_ua,
    );

    # Before any request
    my $state = $client->get_throttle_state();
    ok(!defined $state->{last_throttle_percentage}, 'no throttle percentage before request');
    ok(!$state->{is_near_limit}, 'not near limit before request');

    # After request with throttle header
    $client->get('/test');

    $state = $client->get_throttle_state();
    is($state->{last_throttle_percentage}, 0.9, 'throttle percentage recorded');
    ok($state->{is_near_limit}, 'near limit flag is true');
};

subtest 'throttle callback not invoked below threshold' => sub {
    my $callback_invoked = 0;

    my ($mock_ua) = create_mock_ua({ value => [] });
    $mock_ua->mock('request', sub {
        my $response = Test::MockObject->new();
        $response->set_always('is_success', 1);
        $response->set_always('code', 200);
        $response->set_always('decoded_content', encode_json({ value => [] }));
        $response->mock('header', sub {
            my ($self, $name) = @_;
            return 0.5 if $name eq 'x-ms-throttle-limit-percentage';
            return undef;
        });
        return $response;
    });

    my $client = MS::Graph::Mail::Client->new(
        auth              => create_mock_auth(),
        _ua               => $mock_ua,
        throttle_callback => sub {
            $callback_invoked = 1;
        },
    );

    $client->get('/test');

    ok(!$callback_invoked, 'throttle callback not invoked below 0.8 threshold');

    my $state = $client->get_throttle_state();
    is($state->{last_throttle_percentage}, 0.5, 'percentage still recorded');
    ok(!$state->{is_near_limit}, 'not near limit');
};

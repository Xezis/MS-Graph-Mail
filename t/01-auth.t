#!/usr/bin/env perl

use strict;
use warnings;
use Test::More tests => 11;
use Test::Exception;
use Test::MockObject;
use JSON qw(encode_json);

use lib 'lib';
use MS::Graph::Mail::Auth;

# Test constructor validation
subtest 'constructor requires tenant_id' => sub {
    throws_ok {
        MS::Graph::Mail::Auth->new(
            client_id     => 'test-client',
            client_secret => 'test-secret',
        );
    } qr/Missing required parameter: tenant_id/, 'dies without tenant_id';
};

subtest 'constructor requires client_id' => sub {
    throws_ok {
        MS::Graph::Mail::Auth->new(
            tenant_id     => 'test-tenant',
            client_secret => 'test-secret',
        );
    } qr/Missing required parameter: client_id/, 'dies without client_id';
};

subtest 'constructor requires client_secret' => sub {
    throws_ok {
        MS::Graph::Mail::Auth->new(
            tenant_id => 'test-tenant',
            client_id => 'test-client',
        );
    } qr/Missing required parameter: client_secret/, 'dies without client_secret';
};

# Create mock UA
sub create_mock_ua {
    my ($response_data, $is_success) = @_;
    $is_success //= 1;

    my $response = Test::MockObject->new();
    $response->set_always('is_success', $is_success);
    $response->set_always('status_line', $is_success ? '200 OK' : '401 Unauthorized');
    $response->set_always('decoded_content', encode_json($response_data));
    $response->set_always('code', $is_success ? 200 : 401);

    my $ua = Test::MockObject->new();
    $ua->set_always('request', $response);

    return $ua;
}

subtest 'constructor creates object' => sub {
    my $auth = MS::Graph::Mail::Auth->new(
        tenant_id     => 'test-tenant',
        client_id     => 'test-client',
        client_secret => 'test-secret',
    );

    isa_ok($auth, 'MS::Graph::Mail::Auth');
};

subtest 'get_token fetches new token' => sub {
    my $mock_ua = create_mock_ua({
        access_token => 'mock-token-12345',
        expires_in   => 3600,
        token_type   => 'Bearer',
    });

    my $auth = MS::Graph::Mail::Auth->new(
        tenant_id     => 'test-tenant',
        client_id     => 'test-client',
        client_secret => 'test-secret',
        _ua           => $mock_ua,
    );

    my $token = $auth->get_token();
    is($token, 'mock-token-12345', 'returns access token');
};

subtest 'get_token caches token' => sub {
    my $call_count = 0;
    my $mock_ua = Test::MockObject->new();
    $mock_ua->mock('request', sub {
        $call_count++;
        my $response = Test::MockObject->new();
        $response->set_always('is_success', 1);
        $response->set_always('decoded_content', encode_json({
            access_token => 'mock-token-' . $call_count,
            expires_in   => 3600,
        }));
        return $response;
    });

    my $auth = MS::Graph::Mail::Auth->new(
        tenant_id     => 'test-tenant',
        client_id     => 'test-client',
        client_secret => 'test-secret',
        _ua           => $mock_ua,
    );

    my $token1 = $auth->get_token();
    my $token2 = $auth->get_token();

    is($token1, $token2, 'returns cached token');
    is($call_count, 1, 'only one HTTP request made');
};

subtest 'is_token_valid returns false initially' => sub {
    my $auth = MS::Graph::Mail::Auth->new(
        tenant_id     => 'test-tenant',
        client_id     => 'test-client',
        client_secret => 'test-secret',
    );

    ok(!$auth->is_token_valid(), 'token is not valid before fetching');
};

subtest 'is_token_valid returns true after fetch' => sub {
    my $mock_ua = create_mock_ua({
        access_token => 'mock-token',
        expires_in   => 3600,
    });

    my $auth = MS::Graph::Mail::Auth->new(
        tenant_id     => 'test-tenant',
        client_id     => 'test-client',
        client_secret => 'test-secret',
        _ua           => $mock_ua,
    );

    $auth->get_token();
    ok($auth->is_token_valid(), 'token is valid after fetching');
};

subtest 'clear_token invalidates cache' => sub {
    my $mock_ua = create_mock_ua({
        access_token => 'mock-token',
        expires_in   => 3600,
    });

    my $auth = MS::Graph::Mail::Auth->new(
        tenant_id     => 'test-tenant',
        client_id     => 'test-client',
        client_secret => 'test-secret',
        _ua           => $mock_ua,
    );

    $auth->get_token();
    ok($auth->is_token_valid(), 'token valid after fetch');

    $auth->clear_token();
    ok(!$auth->is_token_valid(), 'token invalid after clear');
};

subtest 'auth failure throws exception' => sub {
    my $mock_ua = create_mock_ua({
        error             => 'invalid_client',
        error_description => 'Invalid client credentials',
    }, 0);

    my $auth = MS::Graph::Mail::Auth->new(
        tenant_id     => 'test-tenant',
        client_id     => 'test-client',
        client_secret => 'test-secret',
        _ua           => $mock_ua,
    );

    throws_ok {
        $auth->get_token();
    } qr/Failed to obtain access token/, 'dies on auth failure';
};

subtest 'custom scope is used' => sub {
    my $request_body;
    my $mock_ua = Test::MockObject->new();
    $mock_ua->mock('request', sub {
        my ($self, $req) = @_;
        $request_body = $req->content;
        my $response = Test::MockObject->new();
        $response->set_always('is_success', 1);
        $response->set_always('decoded_content', encode_json({
            access_token => 'mock-token',
            expires_in   => 3600,
        }));
        return $response;
    });

    my $auth = MS::Graph::Mail::Auth->new(
        tenant_id     => 'test-tenant',
        client_id     => 'test-client',
        client_secret => 'test-secret',
        scope         => 'https://custom.scope/.default',
        _ua           => $mock_ua,
    );

    $auth->get_token();
    like($request_body, qr/custom\.scope/, 'custom scope is in request');
};

#!/usr/bin/env perl

use strict;
use warnings;
use Test::More tests => 12;
use Test::Exception;
use Test::MockObject;
use JSON qw(encode_json decode_json);

use lib 'lib';
use MS::Graph::Mail;

# Helper to create full mock setup
sub create_mock_mail {
    my ($responses) = @_;
    $responses //= {};

    my $request_log = [];

    my $mock_ua = Test::MockObject->new();
    $mock_ua->mock('request', sub {
        my ($self, $req) = @_;

        push @$request_log, {
            method  => $req->method,
            uri     => $req->uri->as_string,
            content => $req->content,
        };

        # Token request
        if ($req->uri =~ /oauth2.*token/) {
            my $response = Test::MockObject->new();
            $response->set_always('is_success', 1);
            $response->set_always('code', 200);
            $response->set_always('decoded_content', encode_json({
                access_token => 'mock-token',
                expires_in   => 3600,
            }));
            return $response;
        }

        my $path = $req->uri->path;

        for my $pattern (keys %$responses) {
            if ($path =~ /$pattern/) {
                my $resp_config = $responses->{$pattern};
                my $response = Test::MockObject->new();
                $response->mock('header', sub { undef });
                $response->set_always('is_success', ($resp_config->{code} // 200) < 400);
                $response->set_always('code', $resp_config->{code} // 200);
                $response->set_always('status_line', ($resp_config->{code} // 200) . ' OK');
                $response->set_always('decoded_content', encode_json($resp_config->{body} // {}));
                return $response;
            }
        }

        # Default 200
        my $response = Test::MockObject->new();
        $response->mock('header', sub { undef });
        $response->set_always('is_success', 1);
        $response->set_always('code', 200);
        $response->set_always('decoded_content', encode_json({}));
        return $response;
    });

    my $mail = MS::Graph::Mail->new(
        tenant_id     => 'test-tenant',
        client_id     => 'test-client',
        client_secret => 'test-secret',
    );

    $mail->{_auth}{_ua} = $mock_ua;
    $mail->{_client}{_ua} = $mock_ua;

    return ($mail, $request_log);
}

subtest 'create_subscription requires user_id' => sub {
    my ($mail) = create_mock_mail();
    throws_ok {
        $mail->create_subscription(
            notification_url    => 'https://app.example.com/webhook',
            expiration_datetime => '2026-02-18T11:00:00Z',
        );
    } qr/user_id/, 'dies without user_id';
};

subtest 'create_subscription requires notification_url' => sub {
    my ($mail) = create_mock_mail();
    throws_ok {
        $mail->create_subscription(
            user_id             => 'user@example.com',
            expiration_datetime => '2026-02-18T11:00:00Z',
        );
    } qr/notification_url/, 'dies without notification_url';
};

subtest 'create_subscription requires expiration_datetime' => sub {
    my ($mail) = create_mock_mail();
    throws_ok {
        $mail->create_subscription(
            user_id          => 'user@example.com',
            notification_url => 'https://app.example.com/webhook',
        );
    } qr/expiration_datetime/, 'dies without expiration_datetime';
};

subtest 'create_subscription sends correct POST' => sub {
    my ($mail, $log) = create_mock_mail({
        'subscriptions' => {
            code => 201,
            body => {
                id                 => 'sub-123',
                resource           => 'users/user@example.com/messages',
                changeType         => 'created',
                expirationDateTime => '2026-02-18T11:00:00Z',
            },
        },
    });

    my $result = $mail->create_subscription(
        user_id             => 'user@example.com',
        notification_url    => 'https://app.example.com/webhook',
        expiration_datetime => '2026-02-18T11:00:00Z',
        client_state        => 'secret-token',
    );

    my $request = $log->[-1];
    is($request->{method}, 'POST', 'POST method');
    like($request->{uri}, qr/subscriptions/, 'subscriptions endpoint');

    my $body = decode_json($request->{content});
    is($body->{changeType}, 'created', 'default changeType');
    is($body->{notificationUrl}, 'https://app.example.com/webhook', 'notification URL');
    is($body->{clientState}, 'secret-token', 'client state');
    is($body->{resource}, 'users/user@example.com/messages', 'default resource from user_id');
};

subtest 'create_subscription default resource is user messages' => sub {
    my ($mail, $log) = create_mock_mail({
        'subscriptions' => { body => { id => 'sub-1' } },
    });

    $mail->create_subscription(
        user_id             => 'mailbox@corp.com',
        notification_url    => 'https://app.example.com/webhook',
        expiration_datetime => '2026-02-18T11:00:00Z',
    );

    my $body = decode_json($log->[-1]{content});
    is($body->{resource}, 'users/mailbox@corp.com/messages', 'resource built from user_id');
};

subtest 'create_subscription with include_resource_data' => sub {
    my ($mail, $log) = create_mock_mail({
        'subscriptions' => { body => { id => 'sub-2' } },
    });

    $mail->create_subscription(
        user_id                   => 'user@example.com',
        notification_url          => 'https://app.example.com/webhook',
        expiration_datetime       => '2026-02-18T11:00:00Z',
        include_resource_data     => 1,
        encryption_certificate    => 'MIIBxjCCAW...',
        encryption_certificate_id => 'cert-001',
    );

    my $body = decode_json($log->[-1]{content});
    ok($body->{includeResourceData}, 'includeResourceData set');
    is($body->{encryptionCertificate}, 'MIIBxjCCAW...', 'certificate included');
    is($body->{encryptionCertificateId}, 'cert-001', 'certificate ID included');
};

subtest 'create_subscription requires encryption cert with resource data' => sub {
    my ($mail) = create_mock_mail();
    throws_ok {
        $mail->create_subscription(
            user_id               => 'user@example.com',
            notification_url      => 'https://app.example.com/webhook',
            expiration_datetime   => '2026-02-18T11:00:00Z',
            include_resource_data => 1,
        );
    } qr/encryption_certificate required/, 'dies without cert';
};

subtest 'renew_subscription sends PATCH' => sub {
    my ($mail, $log) = create_mock_mail({
        'subscriptions/sub-123' => {
            body => {
                id                 => 'sub-123',
                expirationDateTime => '2026-02-20T11:00:00Z',
            },
        },
    });

    $mail->renew_subscription(
        subscription_id     => 'sub-123',
        expiration_datetime => '2026-02-20T11:00:00Z',
    );

    my $request = $log->[-1];
    is($request->{method}, 'PATCH', 'PATCH method');
    like($request->{uri}, qr/subscriptions\/sub-123/, 'correct subscription path');

    my $body = decode_json($request->{content});
    is($body->{expirationDateTime}, '2026-02-20T11:00:00Z', 'new expiration');
};

subtest 'renew_subscription requires subscription_id' => sub {
    my ($mail) = create_mock_mail();
    throws_ok {
        $mail->renew_subscription(
            expiration_datetime => '2026-02-20T11:00:00Z',
        );
    } qr/subscription_id/, 'dies without subscription_id';
};

subtest 'delete_subscription sends DELETE' => sub {
    my ($mail, $log) = create_mock_mail({
        'subscriptions/sub-456' => { code => 204, body => {} },
    });

    my $result = $mail->delete_subscription(subscription_id => 'sub-456');

    my $request = $log->[-1];
    is($request->{method}, 'DELETE', 'DELETE method');
    like($request->{uri}, qr/subscriptions\/sub-456/, 'correct subscription path');
    is($result, 1, 'returns success');
};

subtest 'get_subscription sends GET' => sub {
    my ($mail, $log) = create_mock_mail({
        'subscriptions/sub-789' => {
            body => {
                id       => 'sub-789',
                resource => 'users/user@example.com/messages',
            },
        },
    });

    my $result = $mail->get_subscription(subscription_id => 'sub-789');

    my $request = $log->[-1];
    is($request->{method}, 'GET', 'GET method');
    is($result->{id}, 'sub-789', 'subscription returned');
};

subtest 'list_subscriptions returns array' => sub {
    my ($mail, $log) = create_mock_mail({
        'subscriptions$' => {
            body => {
                value => [
                    { id => 'sub-1', resource => 'users/a@b.com/messages' },
                    { id => 'sub-2', resource => 'users/c@d.com/messages' },
                ],
            },
        },
    });

    my $result = $mail->list_subscriptions();

    is(ref($result), 'ARRAY', 'returns arrayref');
    is(scalar @$result, 2, 'two subscriptions');
    is($result->[0]{id}, 'sub-1', 'first subscription ID');
};

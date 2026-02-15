#!/usr/bin/env perl

use strict;
use warnings;
use Test::More tests => 8;
use Test::Exception;
use Test::MockObject;
use JSON qw(encode_json decode_json);

use lib 'lib';
use MS::Graph::Mail;

# Helper to create a mock response with header() method
sub mock_response {
    my (%opts) = @_;
    my $response = Test::MockObject->new();
    $response->mock('header', sub { undef });
    $response->set_always('is_success', ($opts{code} // 200) < 400);
    $response->set_always('code', $opts{code} // 200);
    $response->set_always('decoded_content', encode_json($opts{body} // {}));
    return $response;
}

# Helper to create mock with custom response handler
sub create_mock_mail {
    my ($response_handler) = @_;

    my $request_log = [];

    my $mock_ua = Test::MockObject->new();
    $mock_ua->mock('request', sub {
        my ($self, $req) = @_;

        push @$request_log, {
            method  => $req->method,
            uri     => $req->uri->as_string,
            path    => $req->uri->path,
            content => $req->content,
        };

        # Token request
        if ($req->uri =~ /oauth2.*token/) {
            return mock_response(body => {
                access_token => 'mock-token',
                expires_in   => 3600,
            });
        }

        if ($response_handler) {
            return $response_handler->($req, $request_log);
        }

        return mock_response();
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

subtest 'get_messages_delta requires user_id' => sub {
    my ($mail) = create_mock_mail();
    throws_ok {
        $mail->get_messages_delta();
    } qr/user_id/, 'dies without user_id';
};

subtest 'get_messages_delta initial request sends correct path' => sub {
    my ($mail, $log) = create_mock_mail(sub {
        return mock_response(body => {
            value              => [],
            '@odata.deltaLink' => 'https://graph.microsoft.com/v1.0/users/test%40example.com/mailFolders/Inbox/messages/delta?$deltatoken=abc123',
        });
    });

    $mail->get_messages_delta(user_id => 'test@example.com');

    my $request = $log->[-1];
    like($request->{path}, qr{/users/test.*example\.com/mailFolders/Inbox/messages/delta},
        'correct delta path with default Inbox folder');
};

subtest 'get_messages_delta uses custom folder' => sub {
    my ($mail, $log) = create_mock_mail(sub {
        return mock_response(body => {
            value              => [],
            '@odata.deltaLink' => 'https://graph.microsoft.com/v1.0/delta?$deltatoken=x',
        });
    });

    $mail->get_messages_delta(
        user_id => 'test@example.com',
        folder  => 'SentItems',
    );

    my $request = $log->[-1];
    like($request->{path}, qr/mailFolders\/SentItems\/messages\/delta/,
        'uses custom folder');
};

subtest 'get_messages_delta includes select parameter' => sub {
    my ($mail, $log) = create_mock_mail(sub {
        return mock_response(body => {
            value              => [],
            '@odata.deltaLink' => 'https://graph.microsoft.com/v1.0/delta?$deltatoken=x',
        });
    });

    $mail->get_messages_delta(
        user_id => 'test@example.com',
        select  => [qw(subject from conversationId)],
    );

    my $request = $log->[-1];
    like($request->{uri}, qr/select=subject.*from.*conversationId/,
        'select parameter included');
};

subtest 'get_messages_delta returns messages and delta_link' => sub {
    my ($mail, $log) = create_mock_mail(sub {
        return mock_response(body => {
            value => [
                { id => 'msg-1', subject => 'First Delta' },
                { id => 'msg-2', subject => 'Second Delta' },
            ],
            '@odata.deltaLink' => 'https://graph.microsoft.com/v1.0/users/test/mailFolders/Inbox/messages/delta?$deltatoken=stored-token-123',
        });
    });

    my $result = $mail->get_messages_delta(user_id => 'test@example.com');

    is(ref($result), 'HASH', 'returns hashref');
    is(scalar @{$result->{messages}}, 2, 'two messages returned');
    ok(defined $result->{delta_link}, 'delta_link present');
    like($result->{delta_link}, qr/deltatoken/, 'delta_link contains token');
};

subtest 'get_messages_delta follows pagination' => sub {
    my $call_count = 0;
    my ($mail, $log) = create_mock_mail(sub {
        my ($req) = @_;
        $call_count++;

        if ($call_count == 1) {
            return mock_response(body => {
                value => [
                    { id => 'msg-1', subject => 'Page 1' },
                ],
                '@odata.nextLink' => 'https://graph.microsoft.com/v1.0/users/test/mailFolders/Inbox/messages/delta?$skiptoken=page2',
            });
        } else {
            return mock_response(body => {
                value => [
                    { id => 'msg-2', subject => 'Page 2' },
                ],
                '@odata.deltaLink' => 'https://graph.microsoft.com/v1.0/users/test/mailFolders/Inbox/messages/delta?$deltatoken=final',
            });
        }
    });

    my $result = $mail->get_messages_delta(user_id => 'test@example.com');

    is(scalar @{$result->{messages}}, 2, 'messages from both pages collected');
    is($result->{messages}[0]->subject, 'Page 1', 'first page message');
    is($result->{messages}[1]->subject, 'Page 2', 'second page message');
    like($result->{delta_link}, qr/deltatoken=final/, 'final delta_link captured');
};

subtest 'get_messages_delta with delta_token uses stored link' => sub {
    my ($mail, $log) = create_mock_mail(sub {
        return mock_response(body => {
            value => [
                { id => 'new-msg', subject => 'New Since Last Sync' },
            ],
            '@odata.deltaLink' => 'https://graph.microsoft.com/v1.0/delta?$deltatoken=updated',
        });
    });

    my $stored_link = '/users/test/mailFolders/Inbox/messages/delta?$deltatoken=stored-token-123';
    my $result = $mail->get_messages_delta(
        user_id     => 'test@example.com',
        delta_token => $stored_link,
    );

    my $request = $log->[-1];
    like($request->{uri}, qr/deltatoken=stored-token-123/, 'used stored delta token');
    is(scalar @{$result->{messages}}, 1, 'got incremental results');
    is($result->{messages}[0]->subject, 'New Since Last Sync', 'correct message');
};

subtest 'get_messages_delta returns Message objects' => sub {
    my ($mail) = create_mock_mail(sub {
        return mock_response(body => {
            value => [
                {
                    id             => 'delta-msg-1',
                    subject        => 'Delta Message',
                    conversationId => 'conv-delta',
                    internetMessageHeaders => [
                        { name => 'In-Reply-To', value => '<ref@s.com>' },
                    ],
                },
            ],
            '@odata.deltaLink' => 'https://graph.microsoft.com/v1.0/delta?$deltatoken=x',
        });
    });

    my $result = $mail->get_messages_delta(user_id => 'test@example.com');
    my $msg = $result->{messages}[0];

    isa_ok($msg, 'MS::Graph::Mail::Message');
    is($msg->subject, 'Delta Message', 'subject accessible');
    is($msg->conversation_id, 'conv-delta', 'conversationId accessible');
    is($msg->in_reply_to, '<ref@s.com>', 'internetMessageHeaders parsed');
};

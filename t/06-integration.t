#!/usr/bin/env perl

use strict;
use warnings;
use Test::More tests => 8;
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
            headers => {
                Authorization => $req->header('Authorization'),
                Prefer        => $req->header('Prefer'),
            },
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

        # Find matching response
        my $path = $req->uri->path;
        my $method = $req->method;

        for my $pattern (keys %$responses) {
            if ($path =~ /$pattern/) {
                my $resp_config = $responses->{$pattern};
                my $response = Test::MockObject->new();
                $response->set_always('is_success', ($resp_config->{code} // 200) < 400);
                $response->set_always('code', $resp_config->{code} // 200);
                $response->set_always('status_line', ($resp_config->{code} // 200) . ' OK');
                $response->set_always('decoded_content', encode_json($resp_config->{body} // {}));
                return $response;
            }
        }

        # Default 404
        my $response = Test::MockObject->new();
        $response->set_always('is_success', 0);
        $response->set_always('code', 404);
        $response->set_always('status_line', '404 Not Found');
        $response->set_always('decoded_content', encode_json({
            error => { code => 'NotFound', message => 'Not found' }
        }));
        return $response;
    });

    # Inject mock UA into Auth module
    my $mail = MS::Graph::Mail->new(
        tenant_id     => 'test-tenant',
        client_id     => 'test-client',
        client_secret => 'test-secret',
    );

    # Replace the internal UA
    $mail->{_auth}{_ua} = $mock_ua;
    $mail->{_client}{_ua} = $mock_ua;

    return ($mail, $request_log);
}

subtest 'constructor requires credentials' => sub {
    throws_ok {
        MS::Graph::Mail->new();
    } qr/Missing required parameter/, 'dies without params';

    throws_ok {
        MS::Graph::Mail->new(
            tenant_id => 'test',
            client_id => 'test',
        );
    } qr/client_secret/, 'dies without client_secret';
};

subtest 'list_messages returns Message objects' => sub {
    my ($mail, $log) = create_mock_mail({
        'mailFolders.*messages' => {
            body => {
                value => [
                    { id => 'msg1', subject => 'First' },
                    { id => 'msg2', subject => 'Second' },
                ]
            }
        }
    });

    my $messages = $mail->list_messages(
        user_id => 'test@example.com',
        folder  => 'Inbox',
    );

    is(scalar @$messages, 2, 'two messages returned');
    isa_ok($messages->[0], 'MS::Graph::Mail::Message');
    is($messages->[0]->subject, 'First', 'first message subject');
    is($messages->[1]->subject, 'Second', 'second message subject');
};

subtest 'list_unread_messages filters correctly' => sub {
    my ($mail, $log) = create_mock_mail({
        'mailFolders.*messages' => {
            body => {
                value => [
                    { id => 'unread1', subject => 'Unread', isRead => 0 },
                ]
            }
        }
    });

    my $messages = $mail->list_unread_messages(
        user_id => 'test@example.com',
    );

    # Check that filter was applied
    my $request = $log->[-1];
    like($request->{uri}, qr/isRead.eq.false/i, 'filter includes isRead eq false');
};

subtest 'get_message returns Message object' => sub {
    my ($mail, $log) = create_mock_mail({
        'messages/msg123' => {
            body => {
                id      => 'msg123',
                subject => 'Specific Message',
                body    => {
                    contentType => 'HTML',
                    content     => '<p>Body</p>',
                }
            }
        }
    });

    my $message = $mail->get_message(
        user_id    => 'test@example.com',
        message_id => 'msg123',
    );

    isa_ok($message, 'MS::Graph::Mail::Message');
    is($message->subject, 'Specific Message', 'subject correct');
    is($message->body_content, '<p>Body</p>', 'body content correct');
};

subtest 'mark_as_read sends PATCH' => sub {
    my ($mail, $log) = create_mock_mail({
        'messages/msg456' => { body => { id => 'msg456', isRead => 1 } }
    });

    $mail->mark_as_read(
        user_id    => 'test@example.com',
        message_id => 'msg456',
    );

    my $request = $log->[-1];
    is($request->{method}, 'PATCH', 'used PATCH method');
    my $body = decode_json($request->{content});
    ok($body->{isRead}, 'isRead set to true');
};

subtest 'send_mail sends POST with correct structure' => sub {
    my ($mail, $log) = create_mock_mail({
        'sendMail' => { code => 202, body => {} }
    });

    $mail->send_mail(
        user_id   => 'sender@example.com',
        to        => ['recipient@example.com'],
        subject   => 'Test Email',
        body      => 'Hello!',
        body_type => 'Text',
    );

    my $request = $log->[-1];
    is($request->{method}, 'POST', 'used POST method');
    like($request->{uri}, qr/sendMail/, 'sendMail endpoint');

    my $body = decode_json($request->{content});
    is($body->{message}{subject}, 'Test Email', 'subject in body');
    is($body->{message}{body}{content}, 'Hello!', 'body content');
    is($body->{message}{toRecipients}[0]{emailAddress}{address}, 'recipient@example.com', 'recipient');
};

subtest 'list_folders returns Folder objects' => sub {
    my ($mail, $log) = create_mock_mail({
        'mailFolders$' => {
            body => {
                value => [
                    { id => 'f1', displayName => 'Inbox', unreadItemCount => 5 },
                    { id => 'f2', displayName => 'Sent', unreadItemCount => 0 },
                ]
            }
        }
    });

    my $folders = $mail->list_folders(user_id => 'test@example.com');

    is(scalar @$folders, 2, 'two folders returned');
    isa_ok($folders->[0], 'MS::Graph::Mail::Folder');
    is($folders->[0]->display_name, 'Inbox', 'first folder name');
    is($folders->[0]->unread_item_count, 5, 'unread count');
};

subtest 'forward_message sends to correct endpoint' => sub {
    my ($mail, $log) = create_mock_mail({
        'forward' => { code => 202, body => {} }
    });

    $mail->forward_message(
        user_id    => 'test@example.com',
        message_id => 'msg789',
        to         => 'forward@example.com',
        comment    => 'Please review',
    );

    my $request = $log->[-1];
    is($request->{method}, 'POST', 'used POST method');
    like($request->{uri}, qr/msg789.*forward/, 'forward endpoint');

    my $body = decode_json($request->{content});
    is($body->{comment}, 'Please review', 'comment in body');
    is($body->{toRecipients}[0]{emailAddress}{address}, 'forward@example.com', 'forward recipient');
};

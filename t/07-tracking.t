#!/usr/bin/env perl

use strict;
use warnings;
use Test::More tests => 20;
use Test::Exception;
use Test::MockObject;
use JSON qw(encode_json decode_json);

use lib 'lib';
use MS::Graph::Mail;
use MS::Graph::Mail::Message;

# Helper to create full mock setup (same pattern as 06-integration.t)
sub create_mock_mail {
    my ($response_handler) = @_;

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

        # Delegate to handler
        if ($response_handler) {
            return $response_handler->($req, $request_log);
        }

        # Default 200 OK
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

#
# Phase 1: Message internetMessageHeaders tests
#

subtest 'internet_message_headers parsed from API data' => sub {
    my $msg = MS::Graph::Mail::Message->new({
        internetMessageHeaders => [
            { name => 'In-Reply-To', value => '<original@server.com>' },
            { name => 'References',  value => '<ref1@server.com> <ref2@server.com>' },
            { name => 'X-Custom',    value => 'custom-value' },
        ],
    });

    my $headers = $msg->internet_message_headers;
    is(ref($headers), 'HASH', 'headers is a hashref');
    is($headers->{'in-reply-to'}[0], '<original@server.com>', 'In-Reply-To parsed');
    is($headers->{'x-custom'}[0], 'custom-value', 'custom header parsed');
};

subtest 'get_header is case-insensitive' => sub {
    my $msg = MS::Graph::Mail::Message->new({
        internetMessageHeaders => [
            { name => 'X-App-Tracking-Id', value => 'track-123' },
        ],
    });

    is($msg->get_header('X-App-Tracking-Id'), 'track-123', 'exact case');
    is($msg->get_header('x-app-tracking-id'), 'track-123', 'lowercase');
    is($msg->get_header('X-APP-TRACKING-ID'), 'track-123', 'uppercase');
};

subtest 'in_reply_to convenience method' => sub {
    my $msg = MS::Graph::Mail::Message->new({
        internetMessageHeaders => [
            { name => 'In-Reply-To', value => '<parent@server.com>' },
        ],
    });

    is($msg->in_reply_to, '<parent@server.com>', 'in_reply_to returns value');
};

subtest 'references convenience method' => sub {
    my $msg = MS::Graph::Mail::Message->new({
        internetMessageHeaders => [
            { name => 'References', value => '<ref1@s.com> <ref2@s.com>' },
        ],
    });

    is($msg->references, '<ref1@s.com> <ref2@s.com>', 'references returns string');
};

subtest 'references_list parses space-separated IDs' => sub {
    my $msg = MS::Graph::Mail::Message->new({
        internetMessageHeaders => [
            { name => 'References', value => '<a@s.com> <b@s.com> <c@s.com>' },
        ],
    });

    my $list = $msg->references_list;
    is_deeply($list, ['<a@s.com>', '<b@s.com>', '<c@s.com>'], 'references_list splits correctly');
};

subtest 'internet_message_headers handles missing data' => sub {
    my $msg = MS::Graph::Mail::Message->new({});

    is_deeply($msg->internet_message_headers, {}, 'empty hash for no headers');
    is($msg->get_header('In-Reply-To'), undef, 'get_header returns undef');
    is($msg->in_reply_to, undef, 'in_reply_to returns undef');
    is_deeply($msg->references_list, [], 'references_list returns empty array');
};

subtest 'internet_message_headers_raw returns original array' => sub {
    my $raw = [
        { name => 'X-Test', value => 'val1' },
        { name => 'X-Test', value => 'val2' },
    ];
    my $msg = MS::Graph::Mail::Message->new({
        internetMessageHeaders => $raw,
    });

    is_deeply($msg->internet_message_headers_raw, $raw, 'raw array preserved');
    is(scalar @{$msg->get_header_values('x-test')}, 2, 'multiple values for same header');
};

#
# Phase 3: Tracking token tests
#

subtest 'generate_tracking_token produces valid tokens' => sub {
    my ($mail) = create_mock_mail();

    my $token = $mail->generate_tracking_token();
    like($token, qr/^REF-[a-f0-9]{8}$/, 'default token format');

    my $custom = $mail->generate_tracking_token(prefix => 'INV', length => 12);
    like($custom, qr/^INV-[a-f0-9]{12}$/, 'custom prefix and length');
};

subtest 'extract_tracking_token parses subject' => sub {
    my ($mail) = create_mock_mail();

    is($mail->extract_tracking_token('[REF-abc12345] Your Invoice'),
        'REF-abc12345', 'extracts token');
    is($mail->extract_tracking_token('Re: [REF-abc12345] Your Invoice'),
        'REF-abc12345', 'extracts from reply subject');
    is($mail->extract_tracking_token('No token here'),
        undef, 'returns undef without token');
    is($mail->extract_tracking_token('[INV-ff00aa11] Invoice', prefix => 'INV'),
        'INV-ff00aa11', 'custom prefix extraction');
};

subtest 'send_mail_tracked creates draft with headers and sends' => sub {
    my ($mail, $log) = create_mock_mail(sub {
        my ($req) = @_;
        my $path = $req->uri->path;
        my $response = Test::MockObject->new();
        $response->mock('header', sub { undef });

        # Draft creation
        if ($req->method eq 'POST' && $path =~ /users\/.*\/messages$/) {
            $response->set_always('is_success', 1);
            $response->set_always('code', 201);
            $response->set_always('decoded_content', encode_json({
                id             => 'draft-123',
                conversationId => 'conv-456',
                subject        => 'Test Subject',
            }));
            return $response;
        }
        # Draft send
        if ($req->method eq 'POST' && $path =~ /send$/) {
            $response->set_always('is_success', 1);
            $response->set_always('code', 202);
            $response->set_always('decoded_content', encode_json({}));
            return $response;
        }
        # SentItems query
        if ($req->method eq 'GET' && $path =~ /SentItems/) {
            $response->set_always('is_success', 1);
            $response->set_always('code', 200);
            $response->set_always('decoded_content', encode_json({
                value => [{
                    id                => 'sent-789',
                    internetMessageId => '<sent-msg@server.com>',
                    conversationId    => 'conv-456',
                }]
            }));
            return $response;
        }

        $response->set_always('is_success', 1);
        $response->set_always('code', 200);
        $response->set_always('decoded_content', encode_json({}));
        return $response;
    });

    my $result = $mail->send_mail_tracked(
        user_id          => 'test@example.com',
        to               => 'recipient@example.com',
        subject          => 'Test Subject',
        body             => 'Hello',
        sent_items_delay => 0,
    );

    ok($result, 'returns tracking result');
    is($result->{message_id}, 'draft-123', 'message_id from draft');
    is($result->{conversation_id}, 'conv-456', 'conversation_id from draft');
    is($result->{internet_message_id}, '<sent-msg@server.com>', 'internet_message_id from SentItems');
    like($result->{tracking_token}, qr/^REF-[a-f0-9]+$/, 'tracking_token generated');
    is($result->{subject}, 'Test Subject', 'subject unchanged (no embed_subject_token)');
};

subtest 'send_mail_tracked embeds tracking token when opted in' => sub {
    my ($mail, $log) = create_mock_mail(sub {
        my ($req) = @_;
        my $response = Test::MockObject->new();
        $response->mock('header', sub { undef });
        $response->set_always('is_success', 1);
        $response->set_always('code', $req->method eq 'POST' && $req->uri->path =~ /messages$/ ? 201 : 200);
        my $body = $req->method eq 'POST' && $req->uri->path =~ /messages$/
            ? { id => 'draft-1', conversationId => 'conv-1' }
            : $req->uri->path =~ /SentItems/ ? { value => [] } : {};
        $response->set_always('decoded_content', encode_json($body));
        return $response;
    });

    my $result = $mail->send_mail_tracked(
        user_id             => 'test@example.com',
        to                  => 'r@example.com',
        subject             => 'Original Subject',
        body                => 'Test',
        embed_subject_token => 1,
        tracking_token      => 'MY-TOKEN-123',
        sent_items_delay    => 0,
    );

    is($result->{subject}, '[MY-TOKEN-123] Original Subject', 'token embedded in subject');
    is($result->{tracking_token}, 'MY-TOKEN-123', 'caller-provided token used');
};

subtest 'send_mail_tracked with custom headers' => sub {
    my $captured_body;
    my ($mail, $log) = create_mock_mail(sub {
        my ($req) = @_;
        my $response = Test::MockObject->new();
        $response->mock('header', sub { undef });
        if ($req->method eq 'POST' && $req->uri->path =~ /users\/.*\/messages$/) {
            $captured_body = decode_json($req->content);
            $response->set_always('is_success', 1);
            $response->set_always('code', 201);
            $response->set_always('decoded_content', encode_json({
                id => 'draft-2', conversationId => 'conv-2',
            }));
            return $response;
        }
        $response->set_always('is_success', 1);
        $response->set_always('code', 200);
        my $body = $req->uri->path =~ /SentItems/ ? { value => [] } : {};
        $response->set_always('decoded_content', encode_json($body));
        return $response;
    });

    $mail->send_mail_tracked(
        user_id                  => 'test@example.com',
        to                       => 'r@example.com',
        subject                  => 'Test',
        body                     => 'Body',
        internet_message_headers => [
            { name => 'x-my-custom', value => 'my-value' },
        ],
        sent_items_delay         => 0,
    );

    my @headers = @{$captured_body->{internetMessageHeaders} // []};
    my %header_map = map { $_->{name} => $_->{value} } @headers;

    ok(exists $header_map{'x-my-custom'}, 'custom header included');
    is($header_map{'x-my-custom'}, 'my-value', 'custom header value correct');
    ok(exists $header_map{'x-app-tracking-id'}, 'tracking header added');
    ok(exists $header_map{'x-auto-response-suppress'}, 'auto-response-suppress added');
};

#
# Phase 6: Reply matching tests
#

subtest 'match_reply by In-Reply-To (Signal 1)' => sub {
    my ($mail) = create_mock_mail();

    my $msg = MS::Graph::Mail::Message->new({
        internetMessageHeaders => [
            { name => 'In-Reply-To', value => '<orig@server.com>' },
        ],
    });

    my $result = $mail->match_reply(
        message           => $msg,
        outbound_tracking => [
            { internet_message_id => '<orig@server.com>', conversation_id => 'conv-1' },
        ],
    );

    ok($result->{matched}, 'matched');
    is($result->{method}, 'in_reply_to', 'matched via In-Reply-To');
    is($result->{confidence}, 'highest', 'highest confidence');
};

subtest 'match_reply by References (Signal 2)' => sub {
    my ($mail) = create_mock_mail();

    my $msg = MS::Graph::Mail::Message->new({
        internetMessageHeaders => [
            { name => 'References', value => '<other@s.com> <orig@s.com>' },
        ],
    });

    my $result = $mail->match_reply(
        message           => $msg,
        outbound_tracking => [
            { internet_message_id => '<orig@s.com>' },
        ],
    );

    ok($result->{matched}, 'matched');
    is($result->{method}, 'references', 'matched via References');
    is($result->{confidence}, 'high', 'high confidence');
};

subtest 'match_reply by conversationId (Signal 3)' => sub {
    my ($mail) = create_mock_mail();

    my $msg = MS::Graph::Mail::Message->new({
        conversationId => 'conv-match-123',
    });

    my $result = $mail->match_reply(
        message           => $msg,
        outbound_tracking => [
            { conversation_id => 'conv-match-123' },
        ],
    );

    ok($result->{matched}, 'matched');
    is($result->{method}, 'conversation_id', 'matched via conversationId');
    is($result->{confidence}, 'medium_high', 'medium_high confidence');
};

subtest 'match_reply by tracking_token (Signal 4)' => sub {
    my ($mail) = create_mock_mail();

    my $msg = MS::Graph::Mail::Message->new({
        subject => 'Re: [REF-abc12345] Your Invoice',
    });

    my $result = $mail->match_reply(
        message           => $msg,
        outbound_tracking => [
            { tracking_token => 'REF-abc12345' },
        ],
    );

    ok($result->{matched}, 'matched');
    is($result->{method}, 'tracking_token', 'matched via tracking token');
    is($result->{confidence}, 'high', 'high confidence');
};

subtest 'match_reply fuzzy disabled by default' => sub {
    my ($mail) = create_mock_mail();

    my $msg = MS::Graph::Mail::Message->new({
        subject => 'Re: Your Invoice',
        from    => { emailAddress => { address => 'debtor@external.com' } },
    });

    my $result = $mail->match_reply(
        message           => $msg,
        outbound_tracking => [
            { recipient_email => 'debtor@external.com', subject => 'Your Invoice' },
        ],
    );

    is($result, undef, 'no match when fuzzy disabled');
};

subtest 'match_reply fuzzy when enabled (Signal 5)' => sub {
    my ($mail) = create_mock_mail();

    my $msg = MS::Graph::Mail::Message->new({
        subject => 'Re: Your Invoice',
        from    => { emailAddress => { address => 'debtor@external.com' } },
    });

    my $result = $mail->match_reply(
        message           => $msg,
        outbound_tracking => [
            { recipient_email => 'debtor@external.com', subject => 'Your Invoice' },
        ],
        enable_fuzzy => 1,
    );

    ok($result->{matched}, 'matched with fuzzy enabled');
    is($result->{method}, 'fuzzy_sender_subject', 'matched via fuzzy');
    is($result->{confidence}, 'low', 'low confidence');
};

subtest 'match_reply returns undef for no match' => sub {
    my ($mail) = create_mock_mail();

    my $msg = MS::Graph::Mail::Message->new({
        subject        => 'Unrelated Email',
        conversationId => 'conv-unrelated',
    });

    my $result = $mail->match_reply(
        message           => $msg,
        outbound_tracking => [
            { internet_message_id => '<other@s.com>', conversation_id => 'conv-different' },
        ],
    );

    is($result, undef, 'no match for unrelated message');
};

subtest 'match_reply cascading priority - In-Reply-To wins over others' => sub {
    my ($mail) = create_mock_mail();

    # Message matches on multiple signals
    my $msg = MS::Graph::Mail::Message->new({
        subject        => 'Re: [REF-abc123] Test',
        conversationId => 'conv-match',
        internetMessageHeaders => [
            { name => 'In-Reply-To', value => '<orig@s.com>' },
        ],
    });

    my $result = $mail->match_reply(
        message           => $msg,
        outbound_tracking => [
            {
                internet_message_id => '<orig@s.com>',
                conversation_id     => 'conv-match',
                tracking_token      => 'REF-abc123',
            },
        ],
    );

    is($result->{method}, 'in_reply_to', 'In-Reply-To wins over other signals');
};

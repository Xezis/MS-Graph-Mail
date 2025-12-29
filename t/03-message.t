#!/usr/bin/env perl

use strict;
use warnings;
use Test::More tests => 12;

use lib 'lib';
use MS::Graph::Mail::Message;

subtest 'constructor creates empty object' => sub {
    my $msg = MS::Graph::Mail::Message->new();
    isa_ok($msg, 'MS::Graph::Mail::Message');
    is($msg->subject, undef, 'subject is undef');
};

subtest 'constructor populates from API data' => sub {
    my $msg = MS::Graph::Mail::Message->new({
        id          => 'AAMkAD123',
        subject     => 'Test Subject',
        bodyPreview => 'This is a preview...',
        isRead      => 1,
        importance  => 'high',
    });

    is($msg->id, 'AAMkAD123', 'id set');
    is($msg->subject, 'Test Subject', 'subject set');
    is($msg->body_preview, 'This is a preview...', 'body_preview set');
    is($msg->is_read, 1, 'is_read set');
    is($msg->importance, 'high', 'importance set');
};

subtest 'body content is parsed correctly' => sub {
    my $msg = MS::Graph::Mail::Message->new({
        body => {
            contentType => 'HTML',
            content     => '<p>Hello World</p>',
        }
    });

    is($msg->body_content_type, 'HTML', 'body content type');
    is($msg->body_content, '<p>Hello World</p>', 'body content');
};

subtest 'from recipient is parsed correctly' => sub {
    my $msg = MS::Graph::Mail::Message->new({
        from => {
            emailAddress => {
                name    => 'John Doe',
                address => 'john@example.com',
            }
        }
    });

    is($msg->from->{name}, 'John Doe', 'from name');
    is($msg->from->{address}, 'john@example.com', 'from address');
};

subtest 'from_address convenience method' => sub {
    my $msg = MS::Graph::Mail::Message->new({
        from => {
            emailAddress => {
                name    => 'Jane Doe',
                address => 'jane@example.com',
            }
        }
    });

    is($msg->from_address, 'jane@example.com', 'from_address returns email');
    is($msg->from_name, 'Jane Doe', 'from_name returns name');
};

subtest 'to_recipients is parsed correctly' => sub {
    my $msg = MS::Graph::Mail::Message->new({
        toRecipients => [
            { emailAddress => { name => 'Recipient 1', address => 'r1@example.com' } },
            { emailAddress => { name => 'Recipient 2', address => 'r2@example.com' } },
        ]
    });

    my $to = $msg->to_recipients;
    is(scalar @$to, 2, 'two recipients');
    is($to->[0]{address}, 'r1@example.com', 'first recipient address');
    is($to->[1]{address}, 'r2@example.com', 'second recipient address');
};

subtest 'to_addresses convenience method' => sub {
    my $msg = MS::Graph::Mail::Message->new({
        toRecipients => [
            { emailAddress => { address => 'a@test.com' } },
            { emailAddress => { address => 'b@test.com' } },
        ]
    });

    my $addresses = $msg->to_addresses;
    is_deeply($addresses, ['a@test.com', 'b@test.com'], 'to_addresses returns array');
};

subtest 'is_unread is opposite of is_read' => sub {
    my $read_msg = MS::Graph::Mail::Message->new({ isRead => 1 });
    my $unread_msg = MS::Graph::Mail::Message->new({ isRead => 0 });

    ok(!$read_msg->is_unread, 'read message is not unread');
    ok($unread_msg->is_unread, 'unread message is unread');
};

subtest 'datetime fields are preserved' => sub {
    my $msg = MS::Graph::Mail::Message->new({
        receivedDateTime => '2024-01-15T10:30:00Z',
        sentDateTime     => '2024-01-15T10:29:00Z',
        createdDateTime  => '2024-01-15T10:29:30Z',
    });

    is($msg->received_datetime, '2024-01-15T10:30:00Z', 'received datetime');
    is($msg->sent_datetime, '2024-01-15T10:29:00Z', 'sent datetime');
    is($msg->created_datetime, '2024-01-15T10:29:30Z', 'created datetime');
};

subtest 'to_string returns readable format' => sub {
    my $msg = MS::Graph::Mail::Message->new({
        subject => 'Important Meeting',
        isRead  => 0,
        from    => {
            emailAddress => { address => 'boss@company.com' }
        }
    });

    my $str = $msg->to_string;
    like($str, qr/UNREAD/, 'contains UNREAD');
    like($str, qr/boss\@company\.com/, 'contains from address');
    like($str, qr/Important Meeting/, 'contains subject');
};

subtest 'raw accessor returns original data' => sub {
    my $data = {
        id      => 'test-id',
        subject => 'Test',
        custom  => 'value',
    };
    my $msg = MS::Graph::Mail::Message->new($data);

    is($msg->raw->{custom}, 'value', 'raw data accessible');
};

subtest 'handles missing data gracefully' => sub {
    my $msg = MS::Graph::Mail::Message->new({});

    is($msg->from_address, undef, 'from_address undef when no from');
    is($msg->from_name, undef, 'from_name undef when no from');
    is_deeply($msg->to_addresses, [], 'to_addresses empty array');
    is_deeply($msg->categories, [], 'categories empty array');
};

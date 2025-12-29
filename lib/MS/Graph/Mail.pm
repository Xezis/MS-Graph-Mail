package MS::Graph::Mail;

use 5.026;
use strict;
use warnings;

use Carp qw(croak);
use URI::Escape qw(uri_escape);

use MS::Graph::Mail::Auth;
use MS::Graph::Mail::Client;
use MS::Graph::Mail::Message;
use MS::Graph::Mail::Folder;
use MS::Graph::Mail::Attachment;

our $VERSION = '0.10';

sub new {
    my ($class, %args) = @_;

    for my $required (qw(tenant_id client_id client_secret)) {
        croak "Missing required parameter: $required" unless defined $args{$required};
    }

    my $auth = MS::Graph::Mail::Auth->new(
        tenant_id     => $args{tenant_id},
        client_id     => $args{client_id},
        client_secret => $args{client_secret},
    );

    my $client = MS::Graph::Mail::Client->new(
        auth              => $auth,
        use_immutable_ids => $args{use_immutable_ids} // 1,
    );

    my $self = bless {
        _auth   => $auth,
        _client => $client,
    }, $class;

    return $self;
}

#
# Message operations
#

sub list_messages {
    my ($self, %args) = @_;

    croak "Missing required parameter: user_id" unless $args{user_id};

    my $folder = $args{folder} // 'Inbox';
    my $path = $self->_build_messages_path($args{user_id}, $folder);

    my $query = $self->_build_query_params(%args);

    my $response = $args{all_pages}
        ? $self->{_client}->get_all_pages($path, query => $query)
        : $self->{_client}->get($path, query => $query);

    # Handle paginated response
    my $items = $args{all_pages}
        ? $response
        : ($response->{value} // []);

    return [map { MS::Graph::Mail::Message->new($_) } @$items];
}

sub list_unread_messages {
    my ($self, %args) = @_;

    # Add filter for unread messages
    my $filter = $args{filter} // '';
    if ($filter) {
        $filter = "($filter) and isRead eq false";
    } else {
        $filter = "isRead eq false";
    }

    return $self->list_messages(%args, filter => $filter);
}

sub get_message {
    my ($self, %args) = @_;

    croak "Missing required parameter: user_id" unless $args{user_id};
    croak "Missing required parameter: message_id" unless $args{message_id};

    my $path = sprintf('/users/%s/messages/%s',
        uri_escape($args{user_id}),
        uri_escape($args{message_id})
    );

    my $query = {};

    # Select specific fields
    if ($args{select}) {
        $query->{'$select'} = ref($args{select}) eq 'ARRAY'
            ? join(',', @{$args{select}})
            : $args{select};
    }

    # Expand attachments inline
    if ($args{expand_attachments}) {
        $query->{'$expand'} = 'attachments';
    }

    my $response = $self->{_client}->get($path, query => $query);
    return MS::Graph::Mail::Message->new($response);
}

sub mark_as_read {
    my ($self, %args) = @_;

    croak "Missing required parameter: user_id" unless $args{user_id};
    croak "Missing required parameter: message_id" unless $args{message_id};

    my $path = sprintf('/users/%s/messages/%s',
        uri_escape($args{user_id}),
        uri_escape($args{message_id})
    );

    $self->{_client}->patch($path, { isRead => \1 });
    return 1;
}

sub mark_as_unread {
    my ($self, %args) = @_;

    croak "Missing required parameter: user_id" unless $args{user_id};
    croak "Missing required parameter: message_id" unless $args{message_id};

    my $path = sprintf('/users/%s/messages/%s',
        uri_escape($args{user_id}),
        uri_escape($args{message_id})
    );

    $self->{_client}->patch($path, { isRead => \0 });
    return 1;
}

sub move_message {
    my ($self, %args) = @_;

    croak "Missing required parameter: user_id" unless $args{user_id};
    croak "Missing required parameter: message_id" unless $args{message_id};
    croak "Missing required parameter: destination_folder" unless $args{destination_folder};

    my $path = sprintf('/users/%s/messages/%s/move',
        uri_escape($args{user_id}),
        uri_escape($args{message_id})
    );

    my $response = $self->{_client}->post($path, {
        destinationId => $args{destination_folder}
    });

    return MS::Graph::Mail::Message->new($response);
}

sub delete_message {
    my ($self, %args) = @_;

    croak "Missing required parameter: user_id" unless $args{user_id};
    croak "Missing required parameter: message_id" unless $args{message_id};

    my $path = sprintf('/users/%s/messages/%s',
        uri_escape($args{user_id}),
        uri_escape($args{message_id})
    );

    # Soft delete moves to Deleted Items, hard delete permanently removes
    if ($args{hard_delete}) {
        # First move to deleted items, then delete from there
        $self->move_message(
            user_id       => $args{user_id},
            message_id    => $args{message_id},
            destination_folder => 'deleteditems',
        );
        # Then permanently delete
        $self->{_client}->delete($path);
    } else {
        # Soft delete - just move to deleted items
        $self->move_message(
            user_id       => $args{user_id},
            message_id    => $args{message_id},
            destination_folder => 'deleteditems',
        );
    }

    return 1;
}

sub send_mail {
    my ($self, %args) = @_;

    croak "Missing required parameter: user_id" unless $args{user_id};
    croak "Missing required parameter: to" unless $args{to};
    croak "Missing required parameter: subject" unless defined $args{subject};
    croak "Missing required parameter: body" unless defined $args{body};

    my $path = sprintf('/users/%s/sendMail', uri_escape($args{user_id}));

    my $message = {
        subject => $args{subject},
        body    => {
            contentType => $args{body_type} // 'Text',
            content     => $args{body},
        },
        toRecipients => $self->_format_recipients($args{to}),
    };

    # Optional recipients
    if ($args{cc}) {
        $message->{ccRecipients} = $self->_format_recipients($args{cc});
    }
    if ($args{bcc}) {
        $message->{bccRecipients} = $self->_format_recipients($args{bcc});
    }

    # Optional importance
    if ($args{importance}) {
        $message->{importance} = $args{importance};
    }

    # Optional attachments
    if ($args{attachments}) {
        $message->{attachments} = $args{attachments};
    }

    my $body = {
        message         => $message,
        saveToSentItems => $args{save_to_sent} // \1,
    };

    $self->{_client}->post($path, $body);
    return 1;
}

sub forward_message {
    my ($self, %args) = @_;

    croak "Missing required parameter: user_id" unless $args{user_id};
    croak "Missing required parameter: message_id" unless $args{message_id};
    croak "Missing required parameter: to" unless $args{to};

    my $path = sprintf('/users/%s/messages/%s/forward',
        uri_escape($args{user_id}),
        uri_escape($args{message_id})
    );

    my $body = {
        toRecipients => $self->_format_recipients($args{to}),
    };

    if (defined $args{comment}) {
        $body->{comment} = $args{comment};
    }

    $self->{_client}->post($path, $body);
    return 1;
}

sub reply_message {
    my ($self, %args) = @_;

    croak "Missing required parameter: user_id" unless $args{user_id};
    croak "Missing required parameter: message_id" unless $args{message_id};

    my $action = $args{reply_all} ? 'replyAll' : 'reply';
    my $path = sprintf('/users/%s/messages/%s/%s',
        uri_escape($args{user_id}),
        uri_escape($args{message_id}),
        $action
    );

    my $body = {};
    if (defined $args{comment}) {
        $body->{comment} = $args{comment};
    }

    $self->{_client}->post($path, $body);
    return 1;
}

#
# Folder operations
#

sub list_folders {
    my ($self, %args) = @_;

    croak "Missing required parameter: user_id" unless $args{user_id};

    my $path = sprintf('/users/%s/mailFolders', uri_escape($args{user_id}));

    my $query = {};
    if ($args{include_hidden}) {
        $query->{includeHiddenFolders} = 'true';
    }

    my $response = $args{all_pages}
        ? $self->{_client}->get_all_pages($path, query => $query)
        : $self->{_client}->get($path, query => $query);

    my $items = $args{all_pages}
        ? $response
        : ($response->{value} // []);

    return [map { MS::Graph::Mail::Folder->new($_) } @$items];
}

sub get_folder {
    my ($self, %args) = @_;

    croak "Missing required parameter: user_id" unless $args{user_id};
    croak "Missing required parameter: folder_id" unless $args{folder_id};

    my $path = sprintf('/users/%s/mailFolders/%s',
        uri_escape($args{user_id}),
        uri_escape($args{folder_id})
    );

    my $response = $self->{_client}->get($path);
    return MS::Graph::Mail::Folder->new($response);
}

sub list_child_folders {
    my ($self, %args) = @_;

    croak "Missing required parameter: user_id" unless $args{user_id};
    croak "Missing required parameter: folder_id" unless $args{folder_id};

    my $path = sprintf('/users/%s/mailFolders/%s/childFolders',
        uri_escape($args{user_id}),
        uri_escape($args{folder_id})
    );

    my $response = $self->{_client}->get($path);
    return [map { MS::Graph::Mail::Folder->new($_) } @{$response->{value} // []}];
}

#
# Attachment operations
#

sub list_attachments {
    my ($self, %args) = @_;

    croak "Missing required parameter: user_id" unless $args{user_id};
    croak "Missing required parameter: message_id" unless $args{message_id};

    my $path = sprintf('/users/%s/messages/%s/attachments',
        uri_escape($args{user_id}),
        uri_escape($args{message_id})
    );

    my $response = $self->{_client}->get($path);
    return [map { MS::Graph::Mail::Attachment->new($_) } @{$response->{value} // []}];
}

sub get_attachment {
    my ($self, %args) = @_;

    croak "Missing required parameter: user_id" unless $args{user_id};
    croak "Missing required parameter: message_id" unless $args{message_id};
    croak "Missing required parameter: attachment_id" unless $args{attachment_id};

    my $path = sprintf('/users/%s/messages/%s/attachments/%s',
        uri_escape($args{user_id}),
        uri_escape($args{message_id}),
        uri_escape($args{attachment_id})
    );

    my $query = {};
    # Request large file content
    $query->{'$select'} = 'id,name,contentType,size,contentBytes'
        unless $args{metadata_only};

    my $response = $self->{_client}->get($path, query => $query);
    return MS::Graph::Mail::Attachment->new($response);
}

sub download_attachment {
    my ($self, %args) = @_;

    my $attachment = $self->get_attachment(%args);
    return $attachment->content;
}

#
# Helper methods
#

sub _build_messages_path {
    my ($self, $user_id, $folder) = @_;

    return sprintf('/users/%s/mailFolders/%s/messages',
        uri_escape($user_id),
        uri_escape($folder)
    );
}

sub _build_query_params {
    my ($self, %args) = @_;

    my $query = {};

    # Pagination
    $query->{'$top'} = $args{top} if defined $args{top};
    $query->{'$skip'} = $args{skip} if defined $args{skip};

    # Filtering
    $query->{'$filter'} = $args{filter} if defined $args{filter};

    # Field selection
    if ($args{select}) {
        $query->{'$select'} = ref($args{select}) eq 'ARRAY'
            ? join(',', @{$args{select}})
            : $args{select};
    }

    # Ordering
    if ($args{orderby}) {
        $query->{'$orderby'} = $args{orderby};
    }

    # Search
    if ($args{search}) {
        $query->{'$search'} = '"' . $args{search} . '"';
    }

    return $query;
}

sub _format_recipients {
    my ($self, $recipients) = @_;

    $recipients = [$recipients] unless ref($recipients) eq 'ARRAY';

    return [
        map {
            if (ref($_) eq 'HASH') {
                {
                    emailAddress => {
                        address => $_->{address} // $_->{email},
                        name    => $_->{name},
                    }
                };
            } else {
                {
                    emailAddress => {
                        address => $_,
                    }
                };
            }
        } @$recipients
    ];
}

1;

__END__

=head1 NAME

MS::Graph::Mail - Perl interface to Microsoft Graph Mail API

=head1 SYNOPSIS

    use MS::Graph::Mail;

    my $mail = MS::Graph::Mail->new(
        tenant_id     => 'your-tenant-id',
        client_id     => 'your-client-id',
        client_secret => 'your-client-secret',
    );

    # List messages in Inbox
    my $messages = $mail->list_messages(
        user_id => 'user@domain.com',
        folder  => 'Inbox',
        top     => 10,
    );

    # List unread messages
    my $unread = $mail->list_unread_messages(
        user_id => 'user@domain.com',
        folder  => 'Inbox',
    );

    # Send an email
    $mail->send_mail(
        user_id   => 'user@domain.com',
        to        => 'recipient@example.com',
        subject   => 'Hello',
        body      => 'This is a test email.',
        body_type => 'Text',
    );

=head1 DESCRIPTION

This module provides a Perl interface to the Microsoft Graph Mail API,
allowing you to manage email messages across multiple mailboxes.

=head1 CONSTRUCTOR

=head2 new(%args)

Creates a new MS::Graph::Mail object.

Required parameters:

=over 4

=item * tenant_id - Azure AD tenant ID

=item * client_id - Application (client) ID

=item * client_secret - Client secret

=back

Optional parameters:

=over 4

=item * use_immutable_ids - Use immutable IDs (default: 1)

=back

=head1 MESSAGE METHODS

=head2 list_messages(%args)

List messages in a folder.

    my $messages = $mail->list_messages(
        user_id   => 'user@domain.com',
        folder    => 'Inbox',           # default: Inbox
        top       => 25,                # max results
        skip      => 0,                 # pagination offset
        filter    => 'hasAttachments eq true',
        select    => [qw(id subject from receivedDateTime)],
        orderby   => 'receivedDateTime desc',
        search    => 'quarterly report',
        all_pages => 1,                 # fetch all pages
    );

=head2 list_unread_messages(%args)

List unread messages. Same parameters as list_messages.

=head2 get_message(%args)

Get a single message.

    my $message = $mail->get_message(
        user_id            => 'user@domain.com',
        message_id         => 'AAMkAD...',
        expand_attachments => 1,
    );

=head2 mark_as_read(%args)

Mark a message as read.

    $mail->mark_as_read(
        user_id    => 'user@domain.com',
        message_id => 'AAMkAD...',
    );

=head2 mark_as_unread(%args)

Mark a message as unread.

=head2 move_message(%args)

Move a message to another folder.

    $mail->move_message(
        user_id            => 'user@domain.com',
        message_id         => 'AAMkAD...',
        destination_folder => 'Archive',
    );

=head2 delete_message(%args)

Delete a message.

    $mail->delete_message(
        user_id     => 'user@domain.com',
        message_id  => 'AAMkAD...',
        hard_delete => 0,  # 0 = soft delete (default), 1 = permanent
    );

=head2 send_mail(%args)

Send an email.

    $mail->send_mail(
        user_id     => 'user@domain.com',
        to          => ['recipient1@example.com', 'recipient2@example.com'],
        cc          => 'cc@example.com',
        bcc         => 'bcc@example.com',
        subject     => 'Subject',
        body        => '<h1>Hello</h1>',
        body_type   => 'HTML',  # or 'Text'
        importance  => 'high',  # low, normal, high
        attachments => [...],
        save_to_sent => 1,
    );

=head2 forward_message(%args)

Forward a message.

    $mail->forward_message(
        user_id    => 'user@domain.com',
        message_id => 'AAMkAD...',
        to         => 'forward@example.com',
        comment    => 'FYI - see below',
    );

=head2 reply_message(%args)

Reply to a message.

    $mail->reply_message(
        user_id    => 'user@domain.com',
        message_id => 'AAMkAD...',
        comment    => 'Thanks for your email.',
        reply_all  => 0,  # 1 for reply all
    );

=head1 FOLDER METHODS

=head2 list_folders(%args)

List mail folders.

    my $folders = $mail->list_folders(
        user_id        => 'user@domain.com',
        include_hidden => 0,
        all_pages      => 1,
    );

=head2 get_folder(%args)

Get a specific folder.

    my $folder = $mail->get_folder(
        user_id   => 'user@domain.com',
        folder_id => 'Inbox',
    );

=head2 list_child_folders(%args)

List child folders of a folder.

=head1 ATTACHMENT METHODS

=head2 list_attachments(%args)

List attachments for a message.

    my $attachments = $mail->list_attachments(
        user_id    => 'user@domain.com',
        message_id => 'AAMkAD...',
    );

=head2 get_attachment(%args)

Get a specific attachment.

    my $attachment = $mail->get_attachment(
        user_id       => 'user@domain.com',
        message_id    => 'AAMkAD...',
        attachment_id => 'AAMkAD...',
    );

=head2 download_attachment(%args)

Download attachment content.

    my $content = $mail->download_attachment(
        user_id       => 'user@domain.com',
        message_id    => 'AAMkAD...',
        attachment_id => 'AAMkAD...',
    );

=head1 REQUIRED PERMISSIONS

This module requires the following Microsoft Graph API permissions:

=over 4

=item * Mail.ReadWrite - Read and write mail

=item * Mail.Send - Send mail

=back

=head1 IMMUTABLE IDS

By default, this module uses immutable IDs (Prefer: IdType="ImmutableId" header).
Immutable IDs remain constant throughout an item's lifetime in the same mailbox,
making them suitable for storing references to messages.

Note: Folder IDs do not support immutable IDs.

=head1 AUTHOR

Xezis

=head1 LICENSE

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.

=cut

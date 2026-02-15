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

our $VERSION = '0.25';

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
        max_retries       => $args{max_retries},
        retry_delay       => $args{retry_delay},
        throttle_callback => $args{throttle_callback},
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

    # Handle file_paths parameter - auto-detect if upload sessions needed
    if ($args{file_paths}) {
        my $file_paths = ref($args{file_paths}) eq 'ARRAY'
            ? $args{file_paths}
            : [$args{file_paths}];

        # Validate all files exist
        for my $file_path (@$file_paths) {
            my $size = -s $file_path;
            croak "File not found: $file_path" unless defined $size;
            croak "File exceeds maximum size of 150MB: $file_path"
                if $size > MS::Graph::Mail::Attachment::MAX_ATTACHMENT_SIZE;
        }

        # Check if any file needs upload session
        my $needs_upload_session = 0;
        for my $file_path (@$file_paths) {
            if (MS::Graph::Mail::Attachment->requires_upload_session($file_path)) {
                $needs_upload_session = 1;
                last;
            }
        }

        if ($needs_upload_session) {
            # Use draft + upload session workflow for large files
            return $self->_send_mail_with_upload_sessions(%args, file_paths => $file_paths);
        } else {
            # All files are small - convert to attachments array
            $args{attachments} = [
                map { MS::Graph::Mail::Attachment->create_file_attachment(file_path => $_) }
                @$file_paths
            ];
        }
    }

    # Standard sendMail workflow (single POST)
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

#
# Tracked send operations
#

sub generate_tracking_token {
    my ($self, %args) = @_;
    my $prefix = $args{prefix} // 'REF';
    my $length = $args{length} // 8;
    my $token = '';
    for (1..$length) {
        $token .= sprintf('%x', int(rand(16)));
    }
    return "$prefix-$token";
}

sub extract_tracking_token {
    my ($self, $subject, %args) = @_;
    my $prefix = $args{prefix} // 'REF';
    if ($subject && $subject =~ /\[(\Q$prefix\E-[a-f0-9]+)\]/i) {
        return $1;
    }
    return undef;
}

sub send_mail_tracked {
    my ($self, %args) = @_;

    croak "Missing required parameter: user_id" unless $args{user_id};
    croak "Missing required parameter: to" unless $args{to};
    croak "Missing required parameter: subject" unless defined $args{subject};
    croak "Missing required parameter: body" unless defined $args{body};

    # Use caller-provided token or auto-generate
    my $tracking_token = $args{tracking_token}
        // $self->generate_tracking_token(
            prefix => $args{tracking_prefix} // 'REF',
        );

    # Subject is unchanged by default; only embed token if explicitly requested
    my $subject = $args{subject};
    if ($args{embed_subject_token}) {
        $subject = "[$tracking_token] $subject";
    }

    # Build custom internet message headers
    my @custom_headers;
    if ($args{internet_message_headers}) {
        my $h = $args{internet_message_headers};
        push @custom_headers, ref($h) eq 'ARRAY' ? @$h : $h;
    }

    # Add tracking header for internal reference
    push @custom_headers, {
        name  => 'x-app-tracking-id',
        value => $tracking_token,
    };

    # Add auto-response suppression unless caller provided it
    unless (grep { lc($_->{name}) eq 'x-auto-response-suppress' } @custom_headers) {
        push @custom_headers, {
            name  => 'x-auto-response-suppress',
            value => 'OOF, AutoReply',
        };
    }

    # Step 1: Create draft message with headers
    my $draft = $self->create_draft_message(
        user_id                  => $args{user_id},
        to                       => $args{to},
        cc                       => $args{cc},
        bcc                      => $args{bcc},
        subject                  => $subject,
        body                     => $args{body},
        body_type                => $args{body_type},
        importance               => $args{importance},
        internet_message_headers => \@custom_headers,
    );

    my $draft_id        = $draft->id;
    my $conversation_id = $draft->conversation_id;

    # Step 2: Attach files if any
    if ($args{file_paths}) {
        my $file_paths = ref($args{file_paths}) eq 'ARRAY'
            ? $args{file_paths} : [$args{file_paths}];

        for my $file_path (@$file_paths) {
            if (MS::Graph::Mail::Attachment->requires_upload_session($file_path)) {
                my $session = $self->create_upload_session(
                    user_id    => $args{user_id},
                    message_id => $draft_id,
                    file_path  => $file_path,
                );
                $self->upload_large_attachment(
                    upload_url        => $session->{upload_url},
                    file_path         => $file_path,
                    file_size         => $session->{file_size},
                    progress_callback => $args{progress_callback},
                );
            } else {
                $self->add_small_attachment(
                    user_id    => $args{user_id},
                    message_id => $draft_id,
                    file_path  => $file_path,
                );
            }
        }
    }

    # Step 3: Send the draft
    $self->send_draft_message(
        user_id    => $args{user_id},
        message_id => $draft_id,
    );

    # Step 4: Capture final internetMessageId from SentItems
    my $internet_message_id;
    if ($args{capture_internet_message_id} // 1) {
        sleep($args{sent_items_delay} // 2);

        my $sent_messages = $self->list_messages(
            user_id => $args{user_id},
            folder  => 'SentItems',
            filter  => "conversationId eq '$conversation_id'",
            orderby => 'sentDateTime desc',
            top     => 1,
            select  => [qw(internetMessageId conversationId)],
        );

        if ($sent_messages && @$sent_messages) {
            $internet_message_id = $sent_messages->[0]->internet_message_id;
        }
    }

    return {
        message_id          => $draft_id,
        conversation_id     => $conversation_id,
        internet_message_id => $internet_message_id,
        tracking_token      => $tracking_token,
        subject             => $subject,
    };
}

#
# Large attachment operations
#

sub create_draft_message {
    my ($self, %args) = @_;

    croak "Missing required parameter: user_id" unless $args{user_id};
    croak "Missing required parameter: subject" unless defined $args{subject};
    croak "Missing required parameter: body" unless defined $args{body};
    croak "Missing required parameter: to" unless $args{to};

    my $path = sprintf('/users/%s/messages', uri_escape($args{user_id}));

    my $message = {
        subject => $args{subject},
        body    => {
            contentType => $args{body_type} // 'Text',
            content     => $args{body},
        },
        toRecipients => $self->_format_recipients($args{to}),
    };

    if ($args{cc}) {
        $message->{ccRecipients} = $self->_format_recipients($args{cc});
    }
    if ($args{bcc}) {
        $message->{bccRecipients} = $self->_format_recipients($args{bcc});
    }
    if ($args{importance}) {
        $message->{importance} = $args{importance};
    }

    # Custom internet message headers
    if ($args{internet_message_headers}) {
        my $headers = $args{internet_message_headers};
        $headers = [$headers] unless ref($headers) eq 'ARRAY';
        $message->{internetMessageHeaders} = [
            map { { name => $_->{name}, value => $_->{value} } } @$headers
        ];
    }

    my $response = $self->{_client}->post($path, $message);
    return MS::Graph::Mail::Message->new($response);
}

sub send_draft_message {
    my ($self, %args) = @_;

    croak "Missing required parameter: user_id" unless $args{user_id};
    croak "Missing required parameter: message_id" unless $args{message_id};

    my $path = sprintf('/users/%s/messages/%s/send',
        uri_escape($args{user_id}),
        uri_escape($args{message_id})
    );

    $self->{_client}->post($path, undef);
    return 1;
}

sub add_small_attachment {
    my ($self, %args) = @_;

    croak "Missing required parameter: user_id" unless $args{user_id};
    croak "Missing required parameter: message_id" unless $args{message_id};
    croak "Missing required parameter: file_path" unless $args{file_path};

    my $path = sprintf('/users/%s/messages/%s/attachments',
        uri_escape($args{user_id}),
        uri_escape($args{message_id})
    );

    my $attachment = MS::Graph::Mail::Attachment->create_file_attachment(
        file_path    => $args{file_path},
        name         => $args{name},
        content_type => $args{content_type},
    );

    my $response = $self->{_client}->post($path, $attachment);
    return MS::Graph::Mail::Attachment->new($response);
}

sub create_upload_session {
    my ($self, %args) = @_;

    croak "Missing required parameter: user_id" unless $args{user_id};
    croak "Missing required parameter: message_id" unless $args{message_id};
    croak "Missing required parameter: file_path" unless $args{file_path};

    my $file_path = $args{file_path};
    my $file_size = -s $file_path;

    croak "File not found: $file_path" unless defined $file_size;
    croak "File exceeds maximum size of 150MB"
        if $file_size > MS::Graph::Mail::Attachment::MAX_ATTACHMENT_SIZE;

    my $file_name = $args{name} // (split m{/}, $file_path)[-1];

    my $path = sprintf('/users/%s/messages/%s/attachments/createUploadSession',
        uri_escape($args{user_id}),
        uri_escape($args{message_id})
    );

    my $body = {
        AttachmentItem => {
            attachmentType => 'file',
            name           => $file_name,
            size           => $file_size,
        }
    };

    my $response = $self->{_client}->post($path, $body);
    return {
        upload_url     => $response->{uploadUrl},
        expiration     => $response->{expirationDateTime},
        file_path      => $file_path,
        file_size      => $file_size,
        file_name      => $file_name,
    };
}

sub upload_large_attachment {
    my ($self, %args) = @_;

    croak "Missing required parameter: upload_url" unless $args{upload_url};
    croak "Missing required parameter: file_path" unless $args{file_path};
    croak "Missing required parameter: file_size" unless $args{file_size};

    my $upload_url = $args{upload_url};
    my $file_path  = $args{file_path};
    my $file_size  = $args{file_size};
    my $chunk_size = MS::Graph::Mail::Attachment::UPLOAD_CHUNK_SIZE;
    my $progress_callback = $args{progress_callback};

    open my $fh, '<:raw', $file_path
        or croak "Cannot open file '$file_path': $!";

    my $offset = 0;
    my $response;

    while ($offset < $file_size) {
        my $remaining = $file_size - $offset;
        my $current_chunk_size = $remaining < $chunk_size ? $remaining : $chunk_size;

        my $chunk;
        my $bytes_read = read($fh, $chunk, $current_chunk_size);
        croak "Error reading file: $!" unless defined $bytes_read;
        croak "Unexpected end of file" if $bytes_read == 0;

        my $range_end = $offset + $bytes_read - 1;
        my $content_range = "bytes $offset-$range_end/$file_size";

        $response = $self->{_client}->put_raw(
            $upload_url,
            $chunk,
            content_range => $content_range,
        );

        $offset += $bytes_read;

        if ($progress_callback) {
            $progress_callback->($offset, $file_size);
        }
    }

    close $fh;

    return MS::Graph::Mail::Attachment->new($response) if $response && $response->{id};
    return $response;
}

# Internal method for sending mail with upload sessions (large attachments)
sub _send_mail_with_upload_sessions {
    my ($self, %args) = @_;

    my $file_paths = $args{file_paths};

    # Create draft message
    my $draft = $self->create_draft_message(
        user_id    => $args{user_id},
        to         => $args{to},
        cc         => $args{cc},
        bcc        => $args{bcc},
        subject    => $args{subject},
        body       => $args{body},
        body_type  => $args{body_type},
        importance => $args{importance},
    );

    my $message_id = $draft->id;
    my $progress_callback = $args{progress_callback};

    # Attach each file
    for my $file_path (@$file_paths) {
        my $file_size = -s $file_path;

        if (MS::Graph::Mail::Attachment->requires_upload_session($file_path)) {
            # Large file - use upload session
            my $session = $self->create_upload_session(
                user_id    => $args{user_id},
                message_id => $message_id,
                file_path  => $file_path,
            );

            $self->upload_large_attachment(
                upload_url        => $session->{upload_url},
                file_path         => $file_path,
                file_size         => $session->{file_size},
                progress_callback => $progress_callback,
            );
        } else {
            # Small file - use Base64
            $self->add_small_attachment(
                user_id    => $args{user_id},
                message_id => $message_id,
                file_path  => $file_path,
            );
        }
    }

    # Send the draft
    $self->send_draft_message(
        user_id    => $args{user_id},
        message_id => $message_id,
    );

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
# Subscription operations (webhooks / change notifications)
#

sub create_subscription {
    my ($self, %args) = @_;

    croak "Missing required parameter: user_id" unless $args{user_id};
    croak "Missing required parameter: notification_url" unless $args{notification_url};
    croak "Missing required parameter: expiration_datetime" unless $args{expiration_datetime};

    my $resource = $args{resource}
        // sprintf('users/%s/messages', $args{user_id});

    my $body = {
        changeType         => $args{change_type} // 'created',
        notificationUrl    => $args{notification_url},
        resource           => $resource,
        expirationDateTime => $args{expiration_datetime},
    };

    if (defined $args{client_state}) {
        $body->{clientState} = $args{client_state};
    }

    if ($args{lifecycle_notification_url}) {
        $body->{lifecycleNotificationUrl} = $args{lifecycle_notification_url};
    }

    if ($args{include_resource_data}) {
        $body->{includeResourceData} = \1;
        croak "encryption_certificate required when include_resource_data is true"
            unless $args{encryption_certificate};
        croak "encryption_certificate_id required when include_resource_data is true"
            unless $args{encryption_certificate_id};
        $body->{encryptionCertificate}   = $args{encryption_certificate};
        $body->{encryptionCertificateId} = $args{encryption_certificate_id};
    }

    return $self->{_client}->post('/subscriptions', $body);
}

sub renew_subscription {
    my ($self, %args) = @_;

    croak "Missing required parameter: subscription_id" unless $args{subscription_id};
    croak "Missing required parameter: expiration_datetime" unless $args{expiration_datetime};

    my $path = sprintf('/subscriptions/%s', uri_escape($args{subscription_id}));

    return $self->{_client}->patch($path, {
        expirationDateTime => $args{expiration_datetime},
    });
}

sub delete_subscription {
    my ($self, %args) = @_;

    croak "Missing required parameter: subscription_id" unless $args{subscription_id};

    my $path = sprintf('/subscriptions/%s', uri_escape($args{subscription_id}));
    $self->{_client}->delete($path);
    return 1;
}

sub get_subscription {
    my ($self, %args) = @_;

    croak "Missing required parameter: subscription_id" unless $args{subscription_id};

    my $path = sprintf('/subscriptions/%s', uri_escape($args{subscription_id}));
    return $self->{_client}->get($path);
}

sub list_subscriptions {
    my ($self) = @_;

    my $response = $self->{_client}->get('/subscriptions');
    return $response->{value} // [];
}

#
# Delta query operations
#

sub get_messages_delta {
    my ($self, %args) = @_;

    croak "Missing required parameter: user_id" unless $args{user_id};

    my $folder = $args{folder} // 'Inbox';

    # If a delta_token (stored delta_link) is provided, use it directly
    if ($args{delta_token}) {
        return $self->_follow_delta_chain($args{delta_token});
    }

    # Initial delta query
    my $path = sprintf('/users/%s/mailFolders/%s/messages/delta',
        uri_escape($args{user_id}),
        uri_escape($folder)
    );

    my $query = {};
    if ($args{select}) {
        $query->{'$select'} = ref($args{select}) eq 'ARRAY'
            ? join(',', @{$args{select}})
            : $args{select};
    }

    return $self->_follow_delta_chain($path, query => $query);
}

sub _follow_delta_chain {
    my ($self, $initial_url, %opts) = @_;

    my @all_messages;
    my $url = $initial_url;
    my $query = $opts{query};
    my $delta_link;

    while ($url) {
        my $response = $self->{_client}->get($url, query => $query);

        if ($response->{value} && ref($response->{value}) eq 'ARRAY') {
            push @all_messages,
                map { MS::Graph::Mail::Message->new($_) }
                @{$response->{value}};
        }

        if ($response->{'@odata.nextLink'}) {
            my $next = URI->new($response->{'@odata.nextLink'});
            $url = $next->path_query;
            $url =~ s{^/v1\.0}{};
            $query = undef;
        }
        elsif ($response->{'@odata.deltaLink'}) {
            my $dlink = URI->new($response->{'@odata.deltaLink'});
            $delta_link = $dlink->path_query;
            $delta_link =~ s{^/v1\.0}{};
            $url = undef;
        }
        else {
            $url = undef;
        }
    }

    return {
        messages   => \@all_messages,
        delta_link => $delta_link,
    };
}

#
# Reply matching utilities
#

sub extract_reply_signals {
    my ($self, %args) = @_;

    croak "Missing required parameter: message" unless $args{message};

    my $message = $args{message};
    my $prefix  = $args{tracking_prefix} // 'REF';

    return {
        in_reply_to     => $message->in_reply_to,
        references      => $message->references_list,
        conversation_id => $message->conversation_id,
        tracking_token  => $self->extract_tracking_token(
            $message->subject // '', prefix => $prefix,
        ),
    };
}

sub match_reply {
    my ($self, %args) = @_;

    croak "Missing required parameter: message" unless $args{message};
    croak "Missing required parameter: outbound_tracking" unless $args{outbound_tracking};

    my $message  = $args{message};
    my $tracking = $args{outbound_tracking};

    # Signal 1: In-Reply-To header matching (highest confidence)
    my $in_reply_to = $message->in_reply_to;
    if ($in_reply_to) {
        for my $outbound (@$tracking) {
            if ($outbound->{internet_message_id}
                && $in_reply_to eq $outbound->{internet_message_id})
            {
                return {
                    matched       => 1,
                    method        => 'in_reply_to',
                    confidence    => 'highest',
                    outbound      => $outbound,
                    matched_value => $in_reply_to,
                };
            }
        }
    }

    # Signal 2: References header chain (high confidence)
    my $references = $message->references_list;
    if ($references && @$references) {
        for my $outbound (@$tracking) {
            next unless $outbound->{internet_message_id};
            for my $ref_id (@$references) {
                if ($ref_id eq $outbound->{internet_message_id}) {
                    return {
                        matched       => 1,
                        method        => 'references',
                        confidence    => 'high',
                        outbound      => $outbound,
                        matched_value => $ref_id,
                    };
                }
            }
        }
    }

    # Signal 3: conversationId matching (medium-high confidence)
    my $conv_id = $message->conversation_id;
    if ($conv_id) {
        for my $outbound (@$tracking) {
            if ($outbound->{conversation_id}
                && $conv_id eq $outbound->{conversation_id})
            {
                return {
                    matched       => 1,
                    method        => 'conversation_id',
                    confidence    => 'medium_high',
                    outbound      => $outbound,
                    matched_value => $conv_id,
                };
            }
        }
    }

    # Signal 4: Subject-line tracking token (high confidence)
    my $subject = $message->subject // '';
    for my $outbound (@$tracking) {
        next unless $outbound->{tracking_token};
        my $token = $outbound->{tracking_token};
        if ($subject =~ /\[\Q$token\E\]/i) {
            return {
                matched       => 1,
                method        => 'tracking_token',
                confidence    => 'high',
                outbound      => $outbound,
                matched_value => $token,
            };
        }
    }

    # Signal 5: Fuzzy sender/subject matching (low confidence, opt-in)
    if ($args{enable_fuzzy}) {
        my $sender_addr  = $message->from_address;
        my $norm_subject = _normalize_subject($subject);

        for my $outbound (@$tracking) {
            next unless $outbound->{recipient_email} && $outbound->{subject};
            if ($sender_addr
                && lc($sender_addr) eq lc($outbound->{recipient_email})
                && _normalize_subject($outbound->{subject}) eq $norm_subject)
            {
                return {
                    matched       => 1,
                    method        => 'fuzzy_sender_subject',
                    confidence    => 'low',
                    outbound      => $outbound,
                    matched_value => "$sender_addr / $norm_subject",
                };
            }
        }
    }

    return undef;
}

sub _normalize_subject {
    my ($subject) = @_;
    return '' unless defined $subject;
    $subject =~ s/^\s*(re|fw|fwd)\s*:\s*//gi;
    $subject =~ s/\[[A-Z]+-[a-f0-9]+\]\s*//gi;
    $subject =~ s/\s+/ /g;
    $subject =~ s/^\s+|\s+$//g;
    return lc($subject);
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

sub get_throttle_state {
    my ($self) = @_;
    return $self->{_client}->get_throttle_state();
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

=item * max_retries - Maximum retry attempts for rate limiting/errors (default: 3)

=item * retry_delay - Base delay in seconds for exponential backoff (default: 1)

=item * throttle_callback - Code reference called when API throttle percentage >= 0.8.
Receives throttle percentage as argument. Use this for proactive rate limiting.

=back

=head1 RATE LIMIT MONITORING

=head2 get_throttle_state()

Returns a hash reference with throttle status:

    my $state = $mail->get_throttle_state();
    if ($state->{is_near_limit}) {
        # Slow down requests
        sleep(1);
    }

Keys:

=over 4

=item * last_throttle_percentage - Last observed throttle value (0.0-1.8+), or undef

=item * is_near_limit - Boolean, true if percentage >= 0.8

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

=head2 send_mail_tracked(%args)

Send an email using the draft-then-send pattern to capture tracking identifiers.
Returns a hash reference with tracking information instead of a simple success flag.

    my $tracking = $mail->send_mail_tracked(
        user_id   => 'user@domain.com',
        to        => 'recipient@example.com',
        subject   => 'Your Account Notice',
        body      => '<p>Please review your balance.</p>',
        body_type => 'HTML',

        # Optional: provide your own tracking token
        tracking_token => 'INV-2026-001',

        # Optional: embed token in subject (default: 0 - subject unchanged)
        embed_subject_token => 1,

        # Optional: custom internet message headers
        internet_message_headers => [
            { name => 'x-my-header', value => 'my-value' },
        ],

        # Optional: skip SentItems query (default: 1)
        capture_internet_message_id => 1,

        # Optional: delay before querying SentItems (default: 2)
        sent_items_delay => 3,
    );

    # $tracking = {
    #     message_id          => 'AAMkAD...',
    #     conversation_id     => 'AAQk...',
    #     internet_message_id => '<msg-id@server.com>',
    #     tracking_token      => 'INV-2026-001',
    #     subject             => 'Your Account Notice',
    # }

=head2 generate_tracking_token(%args)

Generate a unique tracking token.

    my $token = $mail->generate_tracking_token();           # REF-a3f9b21c
    my $token = $mail->generate_tracking_token(prefix => 'INV');  # INV-a3f9b21c

=head2 extract_tracking_token($subject, %args)

Extract a tracking token from a subject line.

    my $token = $mail->extract_tracking_token('[REF-a3f9b21c] Subject');  # REF-a3f9b21c
    my $token = $mail->extract_tracking_token('No token here');           # undef

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

=head1 SUBSCRIPTION METHODS (WEBHOOKS)

=head2 create_subscription(%args)

Create a webhook subscription for change notifications.

    my $sub = $mail->create_subscription(
        user_id             => 'user@domain.com',
        notification_url    => 'https://yourapp.example.com/api/webhooks',
        expiration_datetime => '2026-02-18T11:00:00.0000000Z',
        change_type         => 'created',          # default: 'created'
        client_state        => 'your-secret-token', # optional
        resource            => 'users/user@domain.com/messages', # optional, auto-built from user_id
        lifecycle_notification_url => 'https://yourapp.example.com/api/lifecycle', # optional
    );

Maximum subscription lifetime is ~4,230 minutes (~2.94 days). Renew before expiration.

=head2 renew_subscription(%args)

Renew a subscription before it expires.

    $mail->renew_subscription(
        subscription_id     => $sub->{id},
        expiration_datetime => '2026-02-20T11:00:00.0000000Z',
    );

=head2 delete_subscription(%args)

Delete a subscription.

    $mail->delete_subscription(subscription_id => $sub->{id});

=head2 get_subscription(%args)

Get a subscription by ID.

=head2 list_subscriptions()

List all subscriptions for the application.

=head1 DELTA QUERY METHODS

=head2 get_messages_delta(%args)

Get messages using delta queries for incremental sync.

    # Initial sync
    my $result = $mail->get_messages_delta(
        user_id => 'user@domain.com',
        folder  => 'Inbox',
        select  => [qw(subject from internetMessageHeaders conversationId)],
    );
    my @messages = @{$result->{messages}};
    my $delta_link = $result->{delta_link};  # persist this

    # Subsequent sync - only changes since last call
    my $changes = $mail->get_messages_delta(
        user_id     => 'user@domain.com',
        delta_token => $delta_link,
    );

=head1 REPLY MATCHING

=head2 extract_reply_signals(%args)

Extract all matchable values from an incoming message for database lookup.

    my $signals = $mail->extract_reply_signals(message => $msg);
    # $signals = {
    #     in_reply_to     => '<msg-id@server.com>',
    #     references      => ['<id1>', '<id2>'],
    #     conversation_id => 'AAQk...',
    #     tracking_token  => 'REF-a3f9b21c',  # or undef
    # }

Use these values for indexed database queries against your outbound tracking table.

=head2 match_reply(%args)

Score a pre-filtered candidate set using the cascading 5-signal match algorithm.

    my $result = $mail->match_reply(
        message           => $incoming_msg,
        outbound_tracking => \@db_candidates,
        enable_fuzzy      => 0,  # default: 0
    );

    if ($result) {
        printf "Matched via %s (confidence: %s)\n",
            $result->{method}, $result->{confidence};
    }

Match signals in priority order: In-Reply-To, References, conversationId,
tracking_token, fuzzy sender/subject (opt-in).

=head1 REQUIRED PERMISSIONS

This module requires the following Microsoft Graph API permissions:

=over 4

=item * Mail.ReadWrite - Read and write mail

=item * Mail.Send - Send mail

=item * Mail.Read - Required for webhook subscriptions (application permission)

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

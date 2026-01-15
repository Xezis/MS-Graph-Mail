# MS::Graph::Mail

A Perl module for interacting with Microsoft Graph Mail API. Manage emails across multiple Microsoft 365 mailboxes using OAuth2 Client Credentials authentication.

## Features

- **Multi-account support** - Access any mailbox in your tenant
- **Immutable IDs** - Stable message identifiers by default
- **Full mail operations** - List, read, send, forward, move, delete messages
- **Folder management** - List and navigate mail folders
- **Attachments** - Download and send file attachments
- **Pagination** - Automatic handling of paginated results
- **Rate limit handling** - Automatic retry with backoff and throttle monitoring

## Requirements

- Perl 5.26 or higher
- Microsoft 365 tenant with Azure AD
- Application registration with appropriate permissions

## Installation

```bash
# From the module directory
perl Makefile.PL
make
make test
make install

# Or install dependencies manually
cpanm LWP::UserAgent LWP::Protocol::https JSON URI Try::Tiny
```

## Azure AD Setup

### 1. Register an Application

1. Go to [Azure Portal](https://portal.azure.com) > Azure Active Directory > App registrations
2. Click "New registration"
3. Enter a name (e.g., "Mail API Client")
4. Select "Accounts in this organizational directory only"
5. Click "Register"

### 2. Configure API Permissions

1. Go to "API permissions" in your app
2. Click "Add a permission" > "Microsoft Graph" > "Application permissions"
3. Add the following permissions:

| Permission | Description | Required for |
|------------|-------------|--------------|
| `Mail.ReadWrite` | Read and write mail in all mailboxes | List, read, move, delete messages |
| `Mail.Send` | Send mail as any user | Send and forward emails |

4. Click "Grant admin consent for [Your Organization]"

### 3. Create Client Secret

1. Go to "Certificates & secrets"
2. Click "New client secret"
3. Set an expiration period and click "Add"
4. **Copy the secret value immediately** (it won't be shown again)

### 4. Note Your Credentials

You'll need:
- **Tenant ID**: Found in Azure AD > Overview
- **Client ID**: Found in your app registration > Overview
- **Client Secret**: The value you copied above

## Minimum Required Permissions

| Operation | Permission |
|-----------|------------|
| List/Read messages | `Mail.ReadWrite` |
| Mark as read/unread | `Mail.ReadWrite` |
| Move/Delete messages | `Mail.ReadWrite` |
| List folders | `Mail.ReadWrite` |
| Get attachments | `Mail.ReadWrite` |
| Send mail | `Mail.Send` |
| Forward mail | `Mail.Send` |

**Minimum for full functionality**: `Mail.ReadWrite` + `Mail.Send`

## Quick Start

```perl
use MS::Graph::Mail;

my $mail = MS::Graph::Mail->new(
    tenant_id     => 'your-tenant-id',
    client_id     => 'your-client-id',
    client_secret => 'your-client-secret',
);

# List unread messages
my $messages = $mail->list_unread_messages(
    user_id => 'user@yourdomain.com',
    folder  => 'Inbox',
);

for my $msg (@$messages) {
    printf "%s: %s\n", $msg->from_address, $msg->subject;
}
```

## Usage Examples

### List Messages

```perl
# List messages in Inbox
my $messages = $mail->list_messages(
    user_id => 'user@domain.com',
    folder  => 'Inbox',
    top     => 25,                    # Max results per page
    orderby => 'receivedDateTime desc',
    select  => [qw(id subject from receivedDateTime)],
);

# List all unread messages
my $unread = $mail->list_unread_messages(
    user_id => 'user@domain.com',
);

# Search messages
my $results = $mail->list_messages(
    user_id => 'user@domain.com',
    search  => 'quarterly report',
);

# Filter messages
my $filtered = $mail->list_messages(
    user_id => 'user@domain.com',
    filter  => 'hasAttachments eq true',
);
```

### Read a Message

```perl
my $message = $mail->get_message(
    user_id            => 'user@domain.com',
    message_id         => 'AAMkAD...',
    expand_attachments => 1,  # Include attachment metadata
);

print "Subject: " . $message->subject . "\n";
print "From: " . $message->from_address . "\n";
print "Body: " . $message->body_content . "\n";
```

### Mark as Read/Unread

```perl
$mail->mark_as_read(
    user_id    => 'user@domain.com',
    message_id => 'AAMkAD...',
);

$mail->mark_as_unread(
    user_id    => 'user@domain.com',
    message_id => 'AAMkAD...',
);
```

### Move Messages

```perl
$mail->move_message(
    user_id            => 'user@domain.com',
    message_id         => 'AAMkAD...',
    destination_folder => 'Archive',  # Well-known name or folder ID
);
```

### Delete Messages

```perl
# Soft delete (move to Deleted Items)
$mail->delete_message(
    user_id    => 'user@domain.com',
    message_id => 'AAMkAD...',
);

# Hard delete (permanent)
$mail->delete_message(
    user_id     => 'user@domain.com',
    message_id  => 'AAMkAD...',
    hard_delete => 1,
);
```

### Send Email

```perl
$mail->send_mail(
    user_id   => 'sender@domain.com',
    to        => ['recipient@example.com'],
    cc        => ['cc@example.com'],
    subject   => 'Hello from Perl',
    body      => '<h1>Hello!</h1><p>This is a test email.</p>',
    body_type => 'HTML',
);
```

### Send with Attachments

```perl
use MS::Graph::Mail::Attachment;

my $attachment = MS::Graph::Mail::Attachment->create_file_attachment(
    file_path => '/path/to/document.pdf',
);

$mail->send_mail(
    user_id     => 'sender@domain.com',
    to          => ['recipient@example.com'],
    subject     => 'Document attached',
    body        => 'Please find the document attached.',
    attachments => [$attachment],
);
```

### Forward Email

```perl
$mail->forward_message(
    user_id    => 'user@domain.com',
    message_id => 'AAMkAD...',
    to         => ['forward-to@example.com'],
    comment    => 'FYI - please review this.',
);
```

### List Folders

```perl
my $folders = $mail->list_folders(
    user_id => 'user@domain.com',
);

for my $folder (@$folders) {
    printf "%s: %d messages (%d unread)\n",
        $folder->display_name,
        $folder->total_item_count,
        $folder->unread_item_count;
}
```

### Download Attachments

```perl
my $attachments = $mail->list_attachments(
    user_id    => 'user@domain.com',
    message_id => 'AAMkAD...',
);

for my $att (@$attachments) {
    print "Downloading: " . $att->name . " (" . $att->size_human . ")\n";

    my $full_att = $mail->get_attachment(
        user_id       => 'user@domain.com',
        message_id    => 'AAMkAD...',
        attachment_id => $att->id,
    );

    $full_att->save_to_file("/downloads/" . $att->name);
}
```

## Immutable IDs

By default, this module requests immutable IDs from Microsoft Graph. Immutable IDs remain constant throughout an item's lifetime, making them suitable for storing references to messages.

```perl
# Disable immutable IDs if needed
my $mail = MS::Graph::Mail->new(
    tenant_id         => '...',
    client_id         => '...',
    client_secret     => '...',
    use_immutable_ids => 0,
);
```

Note: Folder IDs do not support immutable IDs per Microsoft's documentation.

## Well-Known Folder Names

You can use these names instead of folder IDs:

- `Inbox`
- `Drafts`
- `SentItems`
- `DeletedItems`
- `JunkEmail`
- `Archive`
- `Outbox`

## Error Handling

```perl
use Try::Tiny;

try {
    my $messages = $mail->list_messages(user_id => 'user@domain.com');
} catch {
    if (/ErrorItemNotFound/) {
        print "User or folder not found\n";
    } elsif (/401/) {
        print "Authentication failed\n";
    } else {
        print "Error: $_\n";
    }
};
```

## Rate Limits and Application Responsibilities

This module automatically handles transient errors and rate limiting responses from Microsoft Graph (HTTP 429). However, applications using this module are responsible for managing their own request patterns to stay within Microsoft's limits.

### What This Module Handles

- **Automatic retry** on HTTP 429 (rate limited) with `Retry-After` header respect
- **Automatic retry** on HTTP 503 (service unavailable) with exponential backoff
- **Token refresh** on HTTP 401 (expired token)
- **Pagination** of large result sets
- **Throttle monitoring** via `get_throttle_state()` and optional callback

### Configuring Retry Behavior

```perl
my $mail = MS::Graph::Mail->new(
    tenant_id     => '...',
    client_id     => '...',
    client_secret => '...',
    max_retries   => 5,        # default: 3
    retry_delay   => 2,        # default: 1 second
    throttle_callback => sub {
        my ($pct) = @_;
        warn "Approaching rate limit: $pct";
    },
);

# Check throttle state after requests
my $state = $mail->get_throttle_state();
if ($state->{is_near_limit}) {
    sleep(1);  # Proactive slowdown
}
```

### Application Responsibilities

| Limit | Value | Your Responsibility |
|-------|-------|---------------------|
| Sending rate | 30 messages/minute | Throttle your send operations |
| Daily recipients | 10,000 per 24 hours | Track recipient counts |
| Concurrent requests | 4 per mailbox | Limit parallel API calls |
| Sustainable rate | 4-10 requests/second | Don't burst at maximum speed |

### Recommended Patterns

**For bulk sending:**

```perl
use Time::HiRes qw(sleep);

for my $recipient (@recipients) {
    $mail->send_mail(
        user_id => 'sender@domain.com',
        to      => [$recipient],
        subject => 'Newsletter',
        body    => $content,
    );
    sleep(2);  # ~30 messages/minute
}
```

**For high-volume reading:**

- Use `select` to limit returned fields
- Use `filter` to narrow results server-side
- Consider delta queries for incremental sync
- Use webhooks instead of polling when possible

See [LIMITS.md](LIMITS.md) for detailed Microsoft Graph rate limit documentation.

## Running Tests

```bash
# Run all tests
prove -l t/

# Run specific test
prove -l t/03-message.t

# Verbose output
prove -lv t/
```

## Example Scripts

See the `examples/` directory:

```bash
# List unread messages
perl examples/list_unread.pl --help
perl examples/list_unread.pl user@domain.com
```

## License

This is free software; you can redistribute it and/or modify it under the same terms as the Perl 5 programming language system itself.

## See Also

- [Microsoft Graph Mail API Documentation](https://learn.microsoft.com/en-us/graph/api/resources/mail-api-overview)
- [Microsoft Graph Immutable IDs](https://learn.microsoft.com/en-us/graph/outlook-immutable-id)
- [Azure AD App Registration](https://learn.microsoft.com/en-us/azure/active-directory/develop/quickstart-register-app)

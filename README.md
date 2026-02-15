# MS::Graph::Mail

A Perl module for interacting with Microsoft Graph Mail API. Manage emails across multiple Microsoft 365 mailboxes using OAuth2 Client Credentials authentication.

## Features

- **Multi-account support** - Access any mailbox in your tenant
- **Immutable IDs** - Stable message identifiers by default
- **Full mail operations** - List, read, send, forward, move, delete messages
- **Folder management** - List and navigate mail folders
- **Attachments** - Download and send file attachments (including large files up to 150MB)
- **Pagination** - Automatic handling of paginated results
- **Rate limit handling** - Automatic retry with backoff and throttle monitoring
- **Email tracking** - Send emails with tracking IDs, match incoming replies
- **Webhook subscriptions** - Change notifications for new messages
- **Delta queries** - Incremental sync for efficient mailbox monitoring

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
| `Mail.Read` | Read mail in all mailboxes | Webhook subscriptions |

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
| Tracked send | `Mail.ReadWrite` + `Mail.Send` |
| Webhook subscriptions | `Mail.Read` |
| Delta queries | `Mail.ReadWrite` |

**Minimum for full functionality**: `Mail.ReadWrite` + `Mail.Send` (+ `Mail.Read` for webhooks)

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

Use `file_paths` for any file size - the module automatically handles upload sessions for large files:

```perl
$mail->send_mail(
    user_id    => 'sender@domain.com',
    to         => ['recipient@example.com'],
    subject    => 'Files attached',
    body       => 'Please see the attached files.',
    file_paths => ['/path/to/small.pdf', '/path/to/large.zip'],
);
```

The module automatically:
- Uses Base64 encoding for files under 3MB (single POST)
- Creates upload sessions for files 3MB-150MB (chunked PUT)

**File size limits:**
| Size | Method |
|------|--------|
| Under 3MB | Standard Base64 attachment |
| 3MB - 150MB | Upload session with chunked uploads |
| Over 150MB | Not supported by Microsoft Graph API |

For progress tracking on large uploads:

```perl
$mail->send_mail(
    user_id    => 'sender@domain.com',
    to         => ['recipient@example.com'],
    subject    => 'Large file',
    body       => 'Uploading...',
    file_paths => ['/path/to/large.zip'],
    progress_callback => sub {
        my ($uploaded, $total) = @_;
        printf "Progress: %d%%\n", int($uploaded / $total * 100);
    },
);
```

You can also use pre-encoded attachments for backward compatibility:

```perl
use MS::Graph::Mail::Attachment;

my $attachment = MS::Graph::Mail::Attachment->create_file_attachment(
    file_path => '/path/to/small.pdf',
);

$mail->send_mail(
    user_id     => 'sender@domain.com',
    to          => ['recipient@example.com'],
    subject     => 'Document attached',
    body        => 'Please find the document attached.',
    attachments => [$attachment],  # Pre-encoded, only for files < 3MB
);
```

### Tracked Sending

Use `send_mail_tracked()` to send emails and capture tracking identifiers for reply matching. This uses the draft-then-send pattern to obtain `conversationId` and `internetMessageId`.

```perl
my $tracking = $mail->send_mail_tracked(
    user_id   => 'sender@domain.com',
    to        => ['recipient@example.com'],
    subject   => 'Invoice #1234',
    body      => '<p>Please review the attached invoice.</p>',
    body_type => 'HTML',
);

# Store tracking data in your database
# $tracking = {
#     message_id          => 'AAMkAD...',
#     conversation_id     => 'AAQk...',
#     internet_message_id => '<msg-id@server.com>',
#     tracking_token      => 'REF-a3f9b21c',
#     subject             => 'Invoice #1234',
# }
```

**Optional: embed tracking token in subject** (disabled by default to preserve original subject):

```perl
my $tracking = $mail->send_mail_tracked(
    user_id             => 'sender@domain.com',
    to                  => ['recipient@example.com'],
    subject             => 'Invoice #1234',
    body                => 'Please review.',
    embed_subject_token => 1,  # Subject becomes: [REF-a3f9b21c] Invoice #1234
);
```

**Optional: provide your own tracking token:**

```perl
my $tracking = $mail->send_mail_tracked(
    user_id        => 'sender@domain.com',
    to             => ['recipient@example.com'],
    subject        => 'Invoice #1234',
    body           => 'Please review.',
    tracking_token => 'INV-2026-001',
);
```

### Reply Matching

Match incoming messages to previously sent emails using a 5-signal cascade. The library is stateless -- your application owns the database.

**Step 1: Extract signals from an incoming message for DB lookup:**

```perl
my $signals = $mail->extract_reply_signals(message => $incoming_msg);
# $signals = {
#     in_reply_to     => '<original-msg-id@server.com>',
#     references      => ['<id1>', '<id2>'],
#     conversation_id => 'AAQk...',
#     tracking_token  => 'REF-a3f9b21c',  # or undef
# }

# Use these values for indexed queries against your outbound tracking table:
# SELECT * FROM sent_emails
#   WHERE internet_message_id IN ($signals->{in_reply_to}, @{$signals->{references}})
#      OR conversation_id = $signals->{conversation_id}
#      OR tracking_token = $signals->{tracking_token}
```

**Step 2: Score pre-filtered candidates:**

```perl
my $result = $mail->match_reply(
    message           => $incoming_msg,
    outbound_tracking => \@db_candidates,  # small set from DB query
    enable_fuzzy      => 0,
);

if ($result) {
    printf "Matched via %s (confidence: %s)\n",
        $result->{method}, $result->{confidence};
    # $result->{outbound} is the matched tracking record
}
```

Match signals in priority order:

| Signal | Confidence | Field |
|--------|-----------|-------|
| In-Reply-To header | highest | `internet_message_id` |
| References header | high | `internet_message_id` |
| conversationId | medium-high | `conversation_id` |
| Subject tracking token | high | `tracking_token` |
| Fuzzy sender/subject | low (opt-in) | `recipient_email` + `subject` |

### Webhook Subscriptions

Create webhook subscriptions to receive notifications when new messages arrive. Maximum subscription lifetime is ~2.94 days; renew before expiration.

```perl
# Create subscription
my $sub = $mail->create_subscription(
    user_id             => 'user@domain.com',
    notification_url    => 'https://yourapp.example.com/api/webhooks',
    expiration_datetime => '2026-02-18T11:00:00.0000000Z',
    change_type         => 'created',
    client_state        => 'your-secret-token',
);

# Renew before expiration
$mail->renew_subscription(
    subscription_id     => $sub->{id},
    expiration_datetime => '2026-02-21T11:00:00.0000000Z',
);

# Delete when no longer needed
$mail->delete_subscription(subscription_id => $sub->{id});
```

### Delta Queries

Use delta queries for efficient incremental mailbox sync instead of polling with `list_messages()`.

```perl
# Initial sync - fetches all messages
my $result = $mail->get_messages_delta(
    user_id => 'user@domain.com',
    folder  => 'Inbox',
    select  => [qw(subject from internetMessageHeaders conversationId)],
);

my @messages   = @{$result->{messages}};
my $delta_link = $result->{delta_link};  # persist this in your database

# Subsequent sync - only changes since last call
my $changes = $mail->get_messages_delta(
    user_id     => 'user@domain.com',
    delta_token => $delta_link,
);

my @new_messages   = @{$changes->{messages}};
my $new_delta_link = $changes->{delta_link};  # update stored delta_link
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

### Internet Message Headers

Access RFC 5322 headers on message objects. Include `internetMessageHeaders` in your `$select` to retrieve them.

```perl
my $message = $mail->get_message(
    user_id    => 'user@domain.com',
    message_id => 'AAMkAD...',
    select     => [qw(id subject internetMessageHeaders conversationId)],
);

# Get a specific header (case-insensitive)
my $in_reply_to = $message->in_reply_to;
my $references  = $message->references;
my $ref_list    = $message->references_list;  # arrayref of Message-IDs

# Get any header by name
my $mailer = $message->get_header('X-Mailer');
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
- Use [delta queries](#delta-queries) for incremental sync
- Use [webhook subscriptions](#webhook-subscriptions) instead of polling when possible

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
perl examples/list_unread.pl user@domain.com

# Send email (with optional attachments of any size)
perl examples/send_mail.pl sender@domain.com recipient@example.com
perl examples/send_mail.pl sender@domain.com recipient@example.com file1.pdf file2.zip --progress

# Send with single attachment
perl examples/send_with_attachment.pl sender@domain.com recipient@example.com /path/to/file.pdf
```

Run any script with `--help` for full usage details.

## License

This is free software; you can redistribute it and/or modify it under the same terms as the Perl 5 programming language system itself.

## See Also

- [Microsoft Graph Mail API Documentation](https://learn.microsoft.com/en-us/graph/api/resources/mail-api-overview)
- [Microsoft Graph Immutable IDs](https://learn.microsoft.com/en-us/graph/outlook-immutable-id)
- [Azure AD App Registration](https://learn.microsoft.com/en-us/azure/active-directory/develop/quickstart-register-app)

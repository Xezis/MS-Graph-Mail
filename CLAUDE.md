# Project Guide

## Overview

MS::Graph::Mail is a Perl module for interacting with the Microsoft Graph Mail API. It provides a complete interface for managing emails across Microsoft 365 mailboxes using OAuth2 Client Credentials authentication.

## Project Structure

```
lib/MS/Graph/Mail/
├── Auth.pm         - OAuth2 authentication handler
├── Client.pm       - HTTP client for Graph API requests
├── Message.pm      - Email message object model
├── Folder.pm       - Mail folder object model
└── Attachment.pm   - Attachment handling and encoding

lib/MS/Graph/Mail.pm - Main API interface

t/                  - Test suite
examples/           - Usage examples
```

## Key Components

### MS::Graph::Mail (lib/MS/Graph/Mail.pm)
Main entry point providing high-level methods for:
- Listing and searching messages
- Reading message details
- Sending and forwarding emails
- Managing folders
- Handling attachments
- Moving and deleting messages

### MS::Graph::Mail::Auth (lib/MS/Graph/Mail/Auth.pm)
Handles OAuth2 Client Credentials flow:
- Token acquisition and refresh
- Automatic token caching
- Token expiration handling

### MS::Graph::Mail::Client (lib/MS/Graph/Mail/Client.pm)
HTTP client wrapper:
- Makes authenticated requests to Graph API
- Handles pagination
- Error processing
- Immutable ID support

### MS::Graph::Mail::Message (lib/MS/Graph/Mail/Message.pm)
Message object model representing email properties:
- Subject, from, to, cc, bcc
- Body content and type
- Timestamps
- Read/unread status
- Attachments metadata

### MS::Graph::Mail::Folder (lib/MS/Graph/Mail/Folder.pm)
Folder object model:
- Display name and ID
- Total and unread counts
- Parent folder reference

### MS::Graph::Mail::Attachment (lib/MS/Graph/Mail/Attachment.pm)
Attachment handling:
- File attachment creation from filesystem
- Base64 encoding
- Size formatting
- Content type detection
- Saving attachments to disk

## Important Concepts

### Immutable IDs
By default, the module requests immutable IDs from Microsoft Graph. These IDs remain stable throughout an item's lifetime, making them suitable for storing references. This is controlled by the `use_immutable_ids` flag (default: 1).

**Note**: Folder IDs do not support immutable IDs per Microsoft's API design.

### Well-Known Folder Names
The API supports well-known folder names instead of IDs:
- Inbox, Drafts, SentItems, DeletedItems, JunkEmail, Archive, Outbox

These are translated to Graph API paths like `/mailFolders/Inbox`.

### Multi-Account Support
The module uses application permissions (Client Credentials flow) which allows accessing any mailbox in the tenant. Every method requires a `user_id` parameter specifying which mailbox to operate on.

## Authentication Flow

1. Application registers in Azure AD with app permissions
2. Module requests token using client_id, client_secret, tenant_id
3. Token is cached and reused until expiration
4. Token is automatically refreshed when needed
5. All API requests include Bearer token in Authorization header

## Required Azure AD Permissions

- `Mail.ReadWrite` - Application permission for list, read, move, delete operations
- `Mail.Send` - Application permission for sending and forwarding emails

Admin consent must be granted in Azure AD.

## API Endpoints Used

Base URL: `https://graph.microsoft.com/v1.0`

- `POST /users/{id}/sendMail` - Send email
- `POST /users/{id}/messages/{id}/forward` - Forward email
- `GET /users/{id}/messages` - List messages
- `GET /users/{id}/messages/{id}` - Get message details
- `PATCH /users/{id}/messages/{id}` - Update message (mark read/unread)
- `POST /users/{id}/messages/{id}/move` - Move message
- `DELETE /users/{id}/messages/{id}` - Delete message
- `GET /users/{id}/mailFolders` - List folders
- `GET /users/{id}/messages/{id}/attachments` - List attachments
- `GET /users/{id}/messages/{id}/attachments/{id}` - Get attachment

## Common Development Tasks

### Adding a New Message Operation

1. Add method to `MS::Graph::Mail`
2. Use `$self->{client}` to make API request
3. Return appropriate object type (Message, Folder, etc.)
4. Handle errors with `die` for exceptions
5. Add tests in `t/` directory

### Modifying Message Object Model

1. Update `MS::Graph::Mail::Message->new()` to parse new fields
2. Add accessor methods if needed
3. Update tests to verify new fields

### Adding Query Parameters

The `list_messages()` method supports OData query parameters:
- `$top` - Page size (max results)
- `$orderby` - Sort order
- `$filter` - Filter expression
- `$search` - Search query
- `$select` - Specific fields to return

Example: `$filter=hasAttachments eq true`

## Testing

Tests use Test::More and Test::MockObject to mock HTTP responses.

```bash
# Run all tests
prove -l t/

# Run with verbose output
prove -lv t/

# Run specific test
prove -l t/03-message.t
```

Test files:
- `01-auth.t` - Authentication tests
- `02-client.t` - HTTP client tests
- `03-message.t` - Message operations
- `04-folder.t` - Folder operations
- `05-attachment.t` - Attachment handling

## Error Handling

The module dies on errors with descriptive messages. Users should wrap calls in `eval` or `Try::Tiny`:

```perl
use Try::Tiny;

try {
    my $messages = $mail->list_messages(user_id => 'user@domain.com');
} catch {
    warn "Error: $_";
};
```

Common error patterns:
- HTTP 401 - Authentication failed (check credentials)
- HTTP 403 - Insufficient permissions
- HTTP 404 - User/folder/message not found
- `ErrorItemNotFound` - Resource not found
- `ErrorInvalidIdMalformed` - Invalid ID format

## Dependencies

Core dependencies:
- `LWP::UserAgent` - HTTP client
- `LWP::Protocol::https` - HTTPS support
- `JSON` - JSON encoding/decoding
- `URI` - URL handling
- `Try::Tiny` - Exception handling
- `MIME::Base64` - Base64 encoding for attachments

## Development Guidelines

1. **Follow Perl Best Practices**
   - Use strict and warnings
   - Minimum Perl version 5.26
   - Use proper scoping with `my`

2. **Object-Oriented Design**
   - Bless hash references
   - Use `$self` for instance methods
   - Return objects where appropriate

3. **Error Handling**
   - Die with descriptive error messages
   - Include HTTP status codes in errors
   - Let callers handle exceptions

4. **Documentation**
   - Use POD for public methods
   - Include usage examples
   - Document parameters and return types

5. **Testing**
   - Mock external API calls
   - Test error conditions
   - Verify object construction

## Pagination Handling

The `Client` module automatically handles pagination:
- Returns all results across multiple pages
- Follows `@odata.nextLink` from responses
- Respects `$top` parameter for limiting results

## Attachment Handling

Attachments are Base64-encoded for the Graph API:
- Files are read from disk
- Content is Base64-encoded
- Size limits apply (Microsoft Graph limits)
- Content-Type is auto-detected from file extension

## Common Pitfalls

1. **Folder IDs vs Names**: Use well-known names when possible; folder IDs are long strings
2. **User ID Format**: Must be UPN (user@domain.com) or Azure AD object ID
3. **Token Expiration**: Handled automatically, but ensure system clock is accurate
4. **Immutable IDs**: Enabled by default; disable if you need legacy behavior
5. **Permissions**: Requires **application** permissions, not delegated
6. **Admin Consent**: Must be granted in Azure AD portal

## Build and Installation

```bash
perl Makefile.PL    # Generate Makefile
make               # Build
make test          # Run tests
make install       # Install to system
```

Or use `cpanm` for dependencies:
```bash
cpanm --installdeps .
```

## Version Information

- Module version is defined in `lib/MS/Graph/Mail.pm`
- Follows semantic versioning
- Update VERSION and Changes file for releases

package MS::Graph::Mail::Message;

use 5.026;
use strict;
use warnings;

our $VERSION = '0.10';

sub new {
    my ($class, $data) = @_;
    $data //= {};

    my $self = bless {
        id                  => $data->{id},
        subject             => $data->{subject},
        body_preview        => $data->{bodyPreview},
        body_content        => $data->{body}{content},
        body_content_type   => $data->{body}{contentType},
        is_read             => $data->{isRead} // 0,
        is_draft            => $data->{isDraft} // 0,
        has_attachments     => $data->{hasAttachments} // 0,
        importance          => $data->{importance} // 'normal',
        received_datetime   => $data->{receivedDateTime},
        sent_datetime       => $data->{sentDateTime},
        created_datetime    => $data->{createdDateTime},
        parent_folder_id    => $data->{parentFolderId},
        conversation_id     => $data->{conversationId},
        internet_message_id => $data->{internetMessageId},
        web_link            => $data->{webLink},
        from                => _parse_recipient($data->{from}),
        sender              => _parse_recipient($data->{sender}),
        to_recipients       => _parse_recipients($data->{toRecipients}),
        cc_recipients       => _parse_recipients($data->{ccRecipients}),
        bcc_recipients      => _parse_recipients($data->{bccRecipients}),
        reply_to            => _parse_recipients($data->{replyTo}),
        categories          => $data->{categories} // [],
        flag                => $data->{flag},
        _raw                => $data,
    }, $class;

    return $self;
}

sub _parse_recipient {
    my ($recipient) = @_;
    return undef unless $recipient && $recipient->{emailAddress};
    return {
        name    => $recipient->{emailAddress}{name},
        address => $recipient->{emailAddress}{address},
    };
}

sub _parse_recipients {
    my ($recipients) = @_;
    return [] unless $recipients && ref($recipients) eq 'ARRAY';
    return [map { _parse_recipient($_) } @$recipients];
}

# Accessors
sub id                  { shift->{id} }
sub subject             { shift->{subject} }
sub body_preview        { shift->{body_preview} }
sub body_content        { shift->{body_content} }
sub body_content_type   { shift->{body_content_type} }
sub is_read             { shift->{is_read} }
sub is_draft            { shift->{is_draft} }
sub has_attachments     { shift->{has_attachments} }
sub importance          { shift->{importance} }
sub received_datetime   { shift->{received_datetime} }
sub sent_datetime       { shift->{sent_datetime} }
sub created_datetime    { shift->{created_datetime} }
sub parent_folder_id    { shift->{parent_folder_id} }
sub conversation_id     { shift->{conversation_id} }
sub internet_message_id { shift->{internet_message_id} }
sub web_link            { shift->{web_link} }
sub from                { shift->{from} }
sub sender              { shift->{sender} }
sub to_recipients       { shift->{to_recipients} }
sub cc_recipients       { shift->{cc_recipients} }
sub bcc_recipients      { shift->{bcc_recipients} }
sub reply_to            { shift->{reply_to} }
sub categories          { shift->{categories} }
sub flag                { shift->{flag} }
sub raw                 { shift->{_raw} }

# Convenience methods
sub from_address {
    my $self = shift;
    return $self->{from} ? $self->{from}{address} : undef;
}

sub from_name {
    my $self = shift;
    return $self->{from} ? $self->{from}{name} : undef;
}

sub to_addresses {
    my $self = shift;
    return [map { $_->{address} } @{$self->{to_recipients}}];
}

sub is_unread {
    my $self = shift;
    return !$self->{is_read};
}

sub to_string {
    my $self = shift;
    return sprintf(
        "[%s] From: %s | Subject: %s",
        $self->is_read ? 'READ' : 'UNREAD',
        $self->from_address // 'unknown',
        $self->subject // '(no subject)'
    );
}

1;

__END__

=head1 NAME

MS::Graph::Mail::Message - Message object for MS Graph Mail API

=head1 SYNOPSIS

    my $message = MS::Graph::Mail::Message->new($api_response);

    print $message->subject;
    print $message->from_address;
    print $message->is_read ? "Read" : "Unread";

=head1 DESCRIPTION

This class represents an email message from the Microsoft Graph API.

=head1 METHODS

=head2 new($data)

Creates a new Message object from API response data.

=head2 Accessors

=over 4

=item * id - Message ID (immutable if requested)

=item * subject - Email subject

=item * body_preview - Short preview of message body

=item * body_content - Full message body content

=item * body_content_type - 'text' or 'html'

=item * is_read - Boolean, message read status

=item * is_draft - Boolean, draft status

=item * has_attachments - Boolean, has attachments

=item * importance - 'low', 'normal', or 'high'

=item * received_datetime - When received

=item * sent_datetime - When sent

=item * parent_folder_id - Containing folder ID

=item * from - Hash with name and address

=item * to_recipients - Array of recipient hashes

=item * cc_recipients - Array of CC recipient hashes

=item * bcc_recipients - Array of BCC recipient hashes

=back

=head2 Convenience Methods

=over 4

=item * from_address - Sender email address

=item * from_name - Sender display name

=item * to_addresses - Array of recipient addresses

=item * is_unread - Opposite of is_read

=item * to_string - Human-readable summary

=back

=head1 AUTHOR

Xezis

=head1 LICENSE

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.

=cut

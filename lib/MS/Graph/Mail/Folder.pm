package MS::Graph::Mail::Folder;

use 5.026;
use strict;
use warnings;

our $VERSION = '0.15';

# Well-known folder names
our %WELL_KNOWN_FOLDERS = (
    inbox        => 'Inbox',
    drafts       => 'Drafts',
    sentitems    => 'SentItems',
    deleteditems => 'DeletedItems',
    junkemail    => 'JunkEmail',
    archive      => 'Archive',
    outbox       => 'Outbox',
);

sub new {
    my ($class, $data) = @_;
    $data //= {};

    my $self = bless {
        id                  => $data->{id},
        display_name        => $data->{displayName},
        parent_folder_id    => $data->{parentFolderId},
        child_folder_count  => $data->{childFolderCount} // 0,
        unread_item_count   => $data->{unreadItemCount} // 0,
        total_item_count    => $data->{totalItemCount} // 0,
        is_hidden           => $data->{isHidden} // 0,
        size_in_bytes       => $data->{sizeInBytes},
        _raw                => $data,
    }, $class;

    return $self;
}

# Accessors
sub id                  { shift->{id} }
sub display_name        { shift->{display_name} }
sub parent_folder_id    { shift->{parent_folder_id} }
sub child_folder_count  { shift->{child_folder_count} }
sub unread_item_count   { shift->{unread_item_count} }
sub total_item_count    { shift->{total_item_count} }
sub is_hidden           { shift->{is_hidden} }
sub size_in_bytes       { shift->{size_in_bytes} }
sub raw                 { shift->{_raw} }

# Convenience methods
sub has_children {
    my $self = shift;
    return $self->{child_folder_count} > 0;
}

sub has_unread {
    my $self = shift;
    return $self->{unread_item_count} > 0;
}

sub is_empty {
    my $self = shift;
    return $self->{total_item_count} == 0;
}

sub to_string {
    my $self = shift;
    return sprintf(
        "%s (%d messages, %d unread)",
        $self->display_name // 'Unknown',
        $self->total_item_count,
        $self->unread_item_count
    );
}

# Class method to get well-known folder path
sub well_known_folder_path {
    my ($class, $name) = @_;
    my $normalized = lc($name);
    return $WELL_KNOWN_FOLDERS{$normalized} // $name;
}

1;

__END__

=head1 NAME

MS::Graph::Mail::Folder - Folder object for MS Graph Mail API

=head1 SYNOPSIS

    my $folder = MS::Graph::Mail::Folder->new($api_response);

    print $folder->display_name;
    print $folder->unread_item_count;

=head1 DESCRIPTION

This class represents a mail folder from the Microsoft Graph API.

=head1 METHODS

=head2 new($data)

Creates a new Folder object from API response data.

=head2 Accessors

=over 4

=item * id - Folder ID

=item * display_name - Folder name

=item * parent_folder_id - Parent folder ID

=item * child_folder_count - Number of child folders

=item * unread_item_count - Number of unread messages

=item * total_item_count - Total number of messages

=item * is_hidden - Boolean, folder visibility

=item * size_in_bytes - Folder size

=back

=head2 Convenience Methods

=over 4

=item * has_children - Boolean, has child folders

=item * has_unread - Boolean, has unread messages

=item * is_empty - Boolean, no messages

=item * to_string - Human-readable summary

=back

=head2 Class Methods

=over 4

=item * well_known_folder_path($name) - Convert folder name to API path

=back

=head1 WELL-KNOWN FOLDERS

=over 4

=item * inbox, drafts, sentitems, deleteditems, junkemail, archive, outbox

=back

=head1 AUTHOR

Xezis

=head1 LICENSE

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.

=cut

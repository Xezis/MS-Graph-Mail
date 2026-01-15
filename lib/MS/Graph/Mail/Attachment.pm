package MS::Graph::Mail::Attachment;

use 5.026;
use strict;
use warnings;

use MIME::Base64 qw(decode_base64 encode_base64);

our $VERSION = '0.15';

sub new {
    my ($class, $data) = @_;
    $data //= {};

    my $self = bless {
        id              => $data->{id},
        name            => $data->{name},
        content_type    => $data->{contentType},
        size            => $data->{size} // 0,
        is_inline       => $data->{isInline} // 0,
        content_id      => $data->{contentId},
        content_bytes   => $data->{contentBytes},
        odata_type      => $data->{'@odata.type'},
        last_modified   => $data->{lastModifiedDateTime},
        _raw            => $data,
    }, $class;

    return $self;
}

# Accessors
sub id              { shift->{id} }
sub name            { shift->{name} }
sub content_type    { shift->{content_type} }
sub size            { shift->{size} }
sub is_inline       { shift->{is_inline} }
sub content_id      { shift->{content_id} }
sub content_bytes   { shift->{content_bytes} }
sub odata_type      { shift->{odata_type} }
sub last_modified   { shift->{last_modified} }
sub raw             { shift->{_raw} }

# Get decoded binary content
sub content {
    my $self = shift;
    return undef unless $self->{content_bytes};
    return decode_base64($self->{content_bytes});
}

# Check attachment type
sub is_file_attachment {
    my $self = shift;
    return ($self->{odata_type} // '') eq '#microsoft.graph.fileAttachment';
}

sub is_item_attachment {
    my $self = shift;
    return ($self->{odata_type} // '') eq '#microsoft.graph.itemAttachment';
}

sub is_reference_attachment {
    my $self = shift;
    return ($self->{odata_type} // '') eq '#microsoft.graph.referenceAttachment';
}

# Save to file
sub save_to_file {
    my ($self, $path) = @_;

    my $content = $self->content;
    return 0 unless defined $content;

    open my $fh, '>:raw', $path
        or die "Cannot open file '$path' for writing: $!";
    print $fh $content;
    close $fh;

    return 1;
}

# Create file attachment for sending
sub create_file_attachment {
    my ($class, %args) = @_;

    my $content_bytes;

    if ($args{file_path}) {
        open my $fh, '<:raw', $args{file_path}
            or die "Cannot open file '$args{file_path}': $!";
        local $/;
        my $content = <$fh>;
        close $fh;
        $content_bytes = encode_base64($content, '');
        $args{name} //= (split m{/}, $args{file_path})[-1];
    } elsif ($args{content}) {
        $content_bytes = encode_base64($args{content}, '');
    } elsif ($args{content_bytes}) {
        $content_bytes = $args{content_bytes};
    } else {
        die "Must provide file_path, content, or content_bytes";
    }

    return {
        '@odata.type' => '#microsoft.graph.fileAttachment',
        name          => $args{name} // 'attachment',
        contentType   => $args{content_type} // 'application/octet-stream',
        contentBytes  => $content_bytes,
    };
}

# Human-readable size
sub size_human {
    my $self = shift;
    my $size = $self->{size};

    return '0 B' unless $size;

    my @units = qw(B KB MB GB);
    my $unit_idx = 0;

    while ($size >= 1024 && $unit_idx < $#units) {
        $size /= 1024;
        $unit_idx++;
    }

    return sprintf("%.1f %s", $size, $units[$unit_idx]);
}

sub to_string {
    my $self = shift;
    return sprintf(
        "%s (%s, %s)",
        $self->name // 'unnamed',
        $self->content_type // 'unknown type',
        $self->size_human
    );
}

1;

__END__

=head1 NAME

MS::Graph::Mail::Attachment - Attachment object for MS Graph Mail API

=head1 SYNOPSIS

    my $attachment = MS::Graph::Mail::Attachment->new($api_response);

    print $attachment->name;
    print $attachment->size_human;

    # Save to file
    $attachment->save_to_file('/path/to/save');

    # Create for sending
    my $new_att = MS::Graph::Mail::Attachment->create_file_attachment(
        file_path => '/path/to/file.pdf',
    );

=head1 DESCRIPTION

This class represents an email attachment from the Microsoft Graph API.

=head1 METHODS

=head2 new($data)

Creates a new Attachment object from API response data.

=head2 Accessors

=over 4

=item * id - Attachment ID

=item * name - File name

=item * content_type - MIME type

=item * size - Size in bytes

=item * is_inline - Boolean, inline attachment

=item * content_id - Content ID for inline attachments

=item * content_bytes - Base64 encoded content

=back

=head2 Instance Methods

=over 4

=item * content() - Returns decoded binary content

=item * is_file_attachment() - Boolean, is a file attachment

=item * is_item_attachment() - Boolean, is an item attachment

=item * is_reference_attachment() - Boolean, is a reference attachment

=item * save_to_file($path) - Save attachment to file

=item * size_human() - Human-readable size (e.g., "1.5 MB")

=item * to_string() - Human-readable summary

=back

=head2 Class Methods

=over 4

=item * create_file_attachment(%args) - Create attachment hash for sending

Args: file_path OR content OR content_bytes, name, content_type

=back

=head1 AUTHOR

Xezis

=head1 LICENSE

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.

=cut

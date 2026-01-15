#!/usr/bin/env perl

=head1 NAME

send_with_attachment.pl - Send an email with file attachment

=head1 SYNOPSIS

    # Using environment variables
    export MS_GRAPH_TENANT_ID="your-tenant-id"
    export MS_GRAPH_CLIENT_ID="your-client-id"
    export MS_GRAPH_CLIENT_SECRET="your-client-secret"

    perl send_with_attachment.pl sender@domain.com recipient@example.com /path/to/file.pdf

    # With custom subject
    perl send_with_attachment.pl sender@domain.com recipient@example.com /path/to/file.pdf \
        --subject "Document attached"

=head1 DESCRIPTION

This script demonstrates sending an email with a file attachment using the
MS::Graph::Mail module. Files of any size (up to 150MB) are supported -
the module automatically uses upload sessions for large files.

=cut

use strict;
use warnings;
use 5.026;

use FindBin;
use lib "$FindBin::Bin/../lib";

use Getopt::Long;
use MS::Graph::Mail;

# Configuration
my $tenant_id     = $ENV{MS_GRAPH_TENANT_ID};
my $client_id     = $ENV{MS_GRAPH_CLIENT_ID};
my $client_secret = $ENV{MS_GRAPH_CLIENT_SECRET};
my $subject       = 'Email with Attachment';
my $body          = 'Please see the attached file.';
my $html          = 0;
my $progress      = 0;
my $help          = 0;

GetOptions(
    'tenant-id=s'     => \$tenant_id,
    'client-id=s'     => \$client_id,
    'client-secret=s' => \$client_secret,
    'subject=s'       => \$subject,
    'body=s'          => \$body,
    'html'            => \$html,
    'progress'        => \$progress,
    'help|h'          => \$help,
) or die "Error parsing options\n";

if ($help) {
    print <<'USAGE';
Usage: send_with_attachment.pl [OPTIONS] SENDER RECIPIENT FILE

Send an email with a file attachment using Microsoft Graph API.
Files of any size (up to 150MB) are supported.

Options:
    --tenant-id       Azure AD tenant ID (or set MS_GRAPH_TENANT_ID env var)
    --client-id       Application client ID (or set MS_GRAPH_CLIENT_ID env var)
    --client-secret   Client secret (or set MS_GRAPH_CLIENT_SECRET env var)
    --subject         Email subject (default: "Email with Attachment")
    --body            Email body content
    --html            Send body as HTML
    --progress        Show upload progress for large files
    -h, --help        Show this help message

File Size Handling:
    - Files under 3MB: Standard Base64 attachment
    - Files 3MB - 150MB: Automatic upload session
    - Files over 150MB: Not supported by Microsoft Graph

Examples:
    # Send PDF attachment
    perl send_with_attachment.pl sender@company.com recipient@example.com report.pdf

    # Large file with progress
    perl send_with_attachment.pl sender@company.com recipient@example.com backup.zip --progress

    # Custom subject and body
    perl send_with_attachment.pl sender@company.com recipient@example.com invoice.pdf \
        --subject "Invoice #12345" \
        --body "Please find the invoice attached."

USAGE
    exit 0;
}

# Get arguments
my $sender    = shift @ARGV;
my $recipient = shift @ARGV;
my $file_path = shift @ARGV;

unless ($sender && $recipient && $file_path) {
    die "Error: Sender, recipient, and file path are all required.\n";
}

# Validate file exists
unless (-f $file_path) {
    die "Error: File not found: $file_path\n";
}

# Validate credentials
unless ($tenant_id && $client_id && $client_secret) {
    die <<'ERROR';
Error: Missing required credentials.

Please provide Microsoft Graph API credentials via:
  - Environment variables: MS_GRAPH_TENANT_ID, MS_GRAPH_CLIENT_ID, MS_GRAPH_CLIENT_SECRET
  - Command line options: --tenant-id, --client-id, --client-secret

See --help for more information.
ERROR
}

# Get file info
my $file_size = -s $file_path;
my $file_name = (split m{/}, $file_path)[-1];

# Format file size
my $size_str;
if ($file_size < 1024) {
    $size_str = "$file_size B";
} elsif ($file_size < 1024 * 1024) {
    $size_str = sprintf("%.1f KB", $file_size / 1024);
} else {
    $size_str = sprintf("%.1f MB", $file_size / (1024 * 1024));
}

# Create Mail client
print "Connecting to Microsoft Graph API...\n";

my $mail = MS::Graph::Mail->new(
    tenant_id     => $tenant_id,
    client_id     => $client_id,
    client_secret => $client_secret,
);

# Progress callback
my $progress_callback = $progress ? sub {
    my ($uploaded, $total) = @_;
    my $pct = int(($uploaded / $total) * 100);
    print "\r  Upload progress: $pct%";
    print "\n" if $uploaded >= $total;
} : undef;

# Send email
print "Sending email from $sender to $recipient...\n";
print "  Attachment: $file_name ($size_str)\n";

eval {
    $mail->send_mail(
        user_id           => $sender,
        to                => [$recipient],
        subject           => $subject,
        body              => $body,
        body_type         => $html ? 'HTML' : 'Text',
        file_paths        => [$file_path],
        progress_callback => $progress_callback,
    );
};

if ($@) {
    die "\nError sending email: $@\n";
}

print "\nEmail sent successfully!\n";
print "  From:       $sender\n";
print "  To:         $recipient\n";
print "  Subject:    $subject\n";
print "  Attachment: $file_name ($size_str)\n";

exit 0;

__END__

=head1 REQUIRED PERMISSIONS

This script requires the following Microsoft Graph API permissions:

=over 4

=item * Mail.Send (Application permission)

=item * Mail.ReadWrite (Application permission) - only needed for files >= 3MB

=back

=head1 AUTHOR

Xezis

=cut

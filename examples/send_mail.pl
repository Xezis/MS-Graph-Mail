#!/usr/bin/env perl

=head1 NAME

send_mail.pl - Send an email using MS Graph API

=head1 SYNOPSIS

    # Using environment variables
    export MS_GRAPH_TENANT_ID="your-tenant-id"
    export MS_GRAPH_CLIENT_ID="your-client-id"
    export MS_GRAPH_CLIENT_SECRET="your-client-secret"

    # Simple email
    perl send_mail.pl sender@domain.com recipient@example.com

    # With subject and body
    perl send_mail.pl sender@domain.com recipient@example.com --subject "Hello" --body "Message"

    # With attachments (any size - handled automatically)
    perl send_mail.pl sender@domain.com recipient@example.com file1.pdf file2.zip

    # With attachments and progress (for large files)
    perl send_mail.pl sender@domain.com recipient@example.com large_file.zip --progress

=head1 DESCRIPTION

This script demonstrates email sending using the MS::Graph::Mail module.
Attachments of any size are handled automatically - small files use Base64,
large files (3MB+) use upload sessions.

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
my $subject       = 'Test Email';
my $body          = 'This is a test email sent via Microsoft Graph API.';
my $html          = 0;
my $cc            = '';
my $bcc           = '';
my $importance    = '';
my $progress      = 0;
my $help          = 0;

GetOptions(
    'tenant-id=s'     => \$tenant_id,
    'client-id=s'     => \$client_id,
    'client-secret=s' => \$client_secret,
    'subject=s'       => \$subject,
    'body=s'          => \$body,
    'html'            => \$html,
    'cc=s'            => \$cc,
    'bcc=s'           => \$bcc,
    'importance=s'    => \$importance,
    'progress'        => \$progress,
    'help|h'          => \$help,
) or die "Error parsing options\n";

if ($help) {
    print <<'USAGE';
Usage: send_mail.pl [OPTIONS] SENDER RECIPIENT [FILE...]

Send an email using Microsoft Graph API. Optionally attach files of any size.

Options:
    --tenant-id       Azure AD tenant ID (or set MS_GRAPH_TENANT_ID env var)
    --client-id       Application client ID (or set MS_GRAPH_CLIENT_ID env var)
    --client-secret   Client secret (or set MS_GRAPH_CLIENT_SECRET env var)
    --subject         Email subject (default: "Test Email")
    --body            Email body content
    --html            Send as HTML email (default: plain text)
    --cc              CC recipient(s), comma-separated
    --bcc             BCC recipient(s), comma-separated
    --importance      Email importance: low, normal, high
    --progress        Show upload progress for large files
    -h, --help        Show this help message

File Size Handling:
    - Files under 3MB: Standard Base64 attachment
    - Files 3MB - 150MB: Automatic upload session
    - Files over 150MB: Not supported by Microsoft Graph

Examples:
    # Simple text email
    perl send_mail.pl sender@company.com recipient@example.com

    # Email with attachments
    perl send_mail.pl sender@company.com recipient@example.com report.pdf data.xlsx

    # Large files with progress
    perl send_mail.pl sender@company.com recipient@example.com backup.zip --progress

    # HTML email with CC
    perl send_mail.pl sender@company.com recipient@example.com \
        --subject "Report" --body "<h1>See attached</h1>" --html \
        --cc "manager@company.com" report.pdf

USAGE
    exit 0;
}

# Get sender and recipient from arguments
my $sender    = shift @ARGV;
my $recipient = shift @ARGV;
my @files     = @ARGV;

unless ($sender && $recipient) {
    die "Error: Both sender and recipient email addresses are required.\n";
}

# Validate required parameters
unless ($tenant_id && $client_id && $client_secret) {
    die <<'ERROR';
Error: Missing required credentials.

Please provide Microsoft Graph API credentials via:
  - Environment variables: MS_GRAPH_TENANT_ID, MS_GRAPH_CLIENT_ID, MS_GRAPH_CLIENT_SECRET
  - Command line options: --tenant-id, --client-id, --client-secret

See --help for more information.
ERROR
}

# Validate files exist
for my $file (@files) {
    die "Error: File not found: $file\n" unless -f $file;
}

# Create Mail client
print "Connecting to Microsoft Graph API...\n";

my $mail = MS::Graph::Mail->new(
    tenant_id     => $tenant_id,
    client_id     => $client_id,
    client_secret => $client_secret,
);

# Build recipient lists
my @to = ($recipient);
my @cc_list = $cc ? split(/,/, $cc) : ();
my @bcc_list = $bcc ? split(/,/, $bcc) : ();

# Progress callback for large files
my $progress_callback = $progress ? sub {
    my ($uploaded, $total) = @_;
    my $pct = int(($uploaded / $total) * 100);
    print "\r  Upload progress: $pct%";
    print "\n" if $uploaded >= $total;
} : undef;

# Send email
print "Sending email from $sender to $recipient";
print " with " . scalar(@files) . " attachment(s)" if @files;
print "...\n";

eval {
    my %send_args = (
        user_id    => $sender,
        to         => \@to,
        cc         => @cc_list ? \@cc_list : undef,
        bcc        => @bcc_list ? \@bcc_list : undef,
        subject    => $subject,
        body       => $body,
        body_type  => $html ? 'HTML' : 'Text',
        importance => $importance || undef,
    );

    if (@files) {
        $send_args{file_paths} = \@files;
        $send_args{progress_callback} = $progress_callback if $progress_callback;
    }

    $mail->send_mail(%send_args);
};

if ($@) {
    die "\nError sending email: $@\n";
}

print "\nEmail sent successfully!\n";
print "  From:    $sender\n";
print "  To:      $recipient\n";
print "  Subject: $subject\n";
print "  Type:    " . ($html ? 'HTML' : 'Text') . "\n";
if (@files) {
    print "  Files:   " . scalar(@files) . " attachment(s)\n";
    for my $file (@files) {
        my $size = -s $file;
        my $size_str = $size < 1024*1024
            ? sprintf("%.1f KB", $size/1024)
            : sprintf("%.1f MB", $size/(1024*1024));
        print "    - $file ($size_str)\n";
    }
}

exit 0;

__END__

=head1 REQUIRED PERMISSIONS

This script requires the following Microsoft Graph API permissions:

=over 4

=item * Mail.Send (Application permission) - for sending emails

=item * Mail.ReadWrite (Application permission) - only needed for large attachments (creates draft)

=back

=head1 AUTHOR

Xezis

=cut

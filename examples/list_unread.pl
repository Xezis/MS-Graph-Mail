#!/usr/bin/env perl

=head1 NAME

list_unread.pl - List all unread emails from a mailbox

=head1 SYNOPSIS

    # Using environment variables
    export MS_GRAPH_TENANT_ID="your-tenant-id"
    export MS_GRAPH_CLIENT_ID="your-client-id"
    export MS_GRAPH_CLIENT_SECRET="your-client-secret"

    perl list_unread.pl user@domain.com

    # Or with command line arguments
    perl list_unread.pl --tenant-id xxx --client-id xxx --client-secret xxx user@domain.com

    # Specify folder (default: Inbox)
    perl list_unread.pl user@domain.com --folder "Archive"

    # Limit results
    perl list_unread.pl user@domain.com --limit 10

=head1 DESCRIPTION

This script demonstrates how to use the MS::Graph::Mail module to list
unread emails from a Microsoft 365 mailbox.

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
my $folder        = 'Inbox';
my $limit         = 50;
my $verbose       = 0;
my $help          = 0;

GetOptions(
    'tenant-id=s'     => \$tenant_id,
    'client-id=s'     => \$client_id,
    'client-secret=s' => \$client_secret,
    'folder=s'        => \$folder,
    'limit=i'         => \$limit,
    'verbose|v'       => \$verbose,
    'help|h'          => \$help,
) or die "Error parsing options\n";

if ($help) {
    print <<'USAGE';
Usage: list_unread.pl [OPTIONS] USER_EMAIL

List unread emails from a Microsoft 365 mailbox.

Options:
    --tenant-id       Azure AD tenant ID (or set MS_GRAPH_TENANT_ID env var)
    --client-id       Application client ID (or set MS_GRAPH_CLIENT_ID env var)
    --client-secret   Client secret (or set MS_GRAPH_CLIENT_SECRET env var)
    --folder          Mail folder to check (default: Inbox)
    --limit           Maximum number of messages to retrieve (default: 50)
    -v, --verbose     Show detailed message information
    -h, --help        Show this help message

Example:
    perl list_unread.pl --folder Inbox user@company.com

USAGE
    exit 0;
}

# Get user email from arguments
my $user_id = shift @ARGV;

unless ($user_id) {
    die "Error: User email address is required.\n";
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

# Create Mail client with throttle monitoring
print "Connecting to Microsoft Graph API...\n" if $verbose;

my $mail = MS::Graph::Mail->new(
    tenant_id     => $tenant_id,
    client_id     => $client_id,
    client_secret => $client_secret,
    # Optional: callback when approaching rate limits (throttle >= 80%)
    throttle_callback => sub {
        my ($pct) = @_;
        warn "Approaching rate limit: ${pct}%\n" if $verbose;
    },
);

# Fetch unread messages
print "Fetching unread messages from '$folder' for $user_id...\n" if $verbose;

my $messages;
eval {
    $messages = $mail->list_unread_messages(
        user_id => $user_id,
        folder  => $folder,
        top     => $limit,
        orderby => 'receivedDateTime desc',
        select  => [qw(id subject from receivedDateTime hasAttachments importance)],
    );
};

if ($@) {
    die "Error fetching messages: $@\n";
}

# Display results
my $count = scalar @$messages;

if ($count == 0) {
    print "No unread messages in '$folder'.\n";
    exit 0;
}

print "\n";
print "=" x 80 . "\n";
print "UNREAD MESSAGES ($count" . ($count >= $limit ? "+" : "") . ")\n";
print "Folder: $folder | User: $user_id\n";
print "=" x 80 . "\n\n";

for my $msg (@$messages) {
    my $from = $msg->from_address // 'Unknown';
    my $from_name = $msg->from_name;
    my $subject = $msg->subject // '(No subject)';
    my $date = $msg->received_datetime // '';
    my $has_att = $msg->has_attachments ? ' [+]' : '';
    my $importance = '';

    if ($msg->importance && $msg->importance ne 'normal') {
        $importance = $msg->importance eq 'high' ? ' [!]' : ' [v]';
    }

    # Format date (extract date part)
    if ($date =~ /^(\d{4}-\d{2}-\d{2})T(\d{2}:\d{2})/) {
        $date = "$1 $2";
    }

    if ($verbose) {
        print "-" x 80 . "\n";
        print "ID:      $msg->{id}\n" if $msg->id;
        print "From:    " . ($from_name ? "$from_name <$from>" : $from) . "\n";
        print "Subject: $subject$has_att$importance\n";
        print "Date:    $date\n";
    } else {
        # Compact format
        my $from_display = $from_name ? substr($from_name, 0, 20) : substr($from, 0, 20);
        $subject = substr($subject, 0, 45);
        printf "%-20s | %-45s | %s%s%s\n",
            $from_display, $subject, $date, $has_att, $importance;
    }
}

print "\n";
print "=" x 80 . "\n";
print "Total: $count unread message(s)\n";

if ($count >= $limit) {
    print "(Limited to $limit results. Use --limit to increase.)\n";
}

exit 0;

__END__

=head1 REQUIRED PERMISSIONS

This script requires the following Microsoft Graph API permissions:

=over 4

=item * Mail.Read or Mail.ReadWrite (Application permission)

=back

=head1 AZURE AD APP SETUP

1. Go to Azure Portal > Azure Active Directory > App registrations
2. Create a new registration
3. Add API permissions: Microsoft Graph > Application > Mail.Read
4. Create a client secret
5. Grant admin consent for the permissions

=head1 AUTHOR

Your Name <your.email@example.com>

=cut

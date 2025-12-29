#!/usr/bin/env perl

use strict;
use warnings;
use Test::More tests => 10;
use Test::Exception;
use MIME::Base64 qw(encode_base64);
use File::Temp qw(tempfile tempdir);

use lib 'lib';
use MS::Graph::Mail::Attachment;

subtest 'constructor creates empty object' => sub {
    my $att = MS::Graph::Mail::Attachment->new();
    isa_ok($att, 'MS::Graph::Mail::Attachment');
    is($att->name, undef, 'name is undef');
};

subtest 'constructor populates from API data' => sub {
    my $att = MS::Graph::Mail::Attachment->new({
        id           => 'AAMkAD123',
        name         => 'document.pdf',
        contentType  => 'application/pdf',
        size         => 1024,
        isInline     => 0,
        contentBytes => encode_base64('test content', ''),
        '@odata.type' => '#microsoft.graph.fileAttachment',
    });

    is($att->id, 'AAMkAD123', 'id set');
    is($att->name, 'document.pdf', 'name set');
    is($att->content_type, 'application/pdf', 'content_type set');
    is($att->size, 1024, 'size set');
    is($att->is_inline, 0, 'is_inline set');
};

subtest 'content decodes base64' => sub {
    my $original = "Hello, World!";
    my $att = MS::Graph::Mail::Attachment->new({
        contentBytes => encode_base64($original, ''),
    });

    is($att->content, $original, 'content decoded correctly');
};

subtest 'attachment type detection' => sub {
    my $file_att = MS::Graph::Mail::Attachment->new({
        '@odata.type' => '#microsoft.graph.fileAttachment',
    });
    my $item_att = MS::Graph::Mail::Attachment->new({
        '@odata.type' => '#microsoft.graph.itemAttachment',
    });
    my $ref_att = MS::Graph::Mail::Attachment->new({
        '@odata.type' => '#microsoft.graph.referenceAttachment',
    });

    ok($file_att->is_file_attachment, 'file attachment detected');
    ok(!$file_att->is_item_attachment, 'not item attachment');

    ok($item_att->is_item_attachment, 'item attachment detected');
    ok(!$item_att->is_file_attachment, 'not file attachment');

    ok($ref_att->is_reference_attachment, 'reference attachment detected');
};

subtest 'size_human returns readable sizes' => sub {
    my @tests = (
        [0, '0 B'],
        [512, '512.0 B'],
        [1024, '1.0 KB'],
        [1536, '1.5 KB'],
        [1048576, '1.0 MB'],
        [1073741824, '1.0 GB'],
    );

    for my $test (@tests) {
        my ($size, $expected) = @$test;
        my $att = MS::Graph::Mail::Attachment->new({ size => $size });
        is($att->size_human, $expected, "size $size => $expected");
    }
};

subtest 'to_string returns readable format' => sub {
    my $att = MS::Graph::Mail::Attachment->new({
        name        => 'report.xlsx',
        contentType => 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
        size        => 2097152,
    });

    my $str = $att->to_string;
    like($str, qr/report\.xlsx/, 'contains name');
    like($str, qr/2\.0 MB/, 'contains human size');
};

subtest 'save_to_file writes content' => sub {
    my $content = "File content here";
    my $att = MS::Graph::Mail::Attachment->new({
        contentBytes => encode_base64($content, ''),
    });

    my $dir = tempdir(CLEANUP => 1);
    my $path = "$dir/test_output.txt";

    ok($att->save_to_file($path), 'save_to_file returns true');
    ok(-f $path, 'file exists');

    open my $fh, '<', $path or die "Cannot read $path: $!";
    my $read_content = do { local $/; <$fh> };
    close $fh;

    is($read_content, $content, 'file content matches');
};

subtest 'save_to_file returns false when no content' => sub {
    my $att = MS::Graph::Mail::Attachment->new({});

    my $dir = tempdir(CLEANUP => 1);
    my $path = "$dir/empty.txt";

    is($att->save_to_file($path), 0, 'returns false when no content');
};

subtest 'create_file_attachment from file path' => sub {
    # Create temp file with content
    my ($fh, $filename) = tempfile(SUFFIX => '.txt');
    print $fh "Test file content";
    close $fh;

    my $att_data = MS::Graph::Mail::Attachment->create_file_attachment(
        file_path => $filename,
    );

    is($att_data->{'@odata.type'}, '#microsoft.graph.fileAttachment', 'correct type');
    ok($att_data->{contentBytes}, 'has content bytes');
    like($att_data->{name}, qr/\.txt$/, 'name extracted from path');

    unlink $filename;
};

subtest 'create_file_attachment from content' => sub {
    my $att_data = MS::Graph::Mail::Attachment->create_file_attachment(
        name         => 'inline.txt',
        content      => 'Inline content',
        content_type => 'text/plain',
    );

    is($att_data->{'@odata.type'}, '#microsoft.graph.fileAttachment', 'correct type');
    is($att_data->{name}, 'inline.txt', 'name set');
    is($att_data->{contentType}, 'text/plain', 'content type set');
    ok($att_data->{contentBytes}, 'has content bytes');
};

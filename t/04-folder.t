#!/usr/bin/env perl

use strict;
use warnings;
use Test::More tests => 8;

use lib 'lib';
use MS::Graph::Mail::Folder;

subtest 'constructor creates empty object' => sub {
    my $folder = MS::Graph::Mail::Folder->new();
    isa_ok($folder, 'MS::Graph::Mail::Folder');
    is($folder->display_name, undef, 'display_name is undef');
};

subtest 'constructor populates from API data' => sub {
    my $folder = MS::Graph::Mail::Folder->new({
        id               => 'AAMkAD123',
        displayName      => 'Inbox',
        parentFolderId   => 'AAMkAD000',
        childFolderCount => 3,
        unreadItemCount  => 5,
        totalItemCount   => 100,
        isHidden         => 0,
    });

    is($folder->id, 'AAMkAD123', 'id set');
    is($folder->display_name, 'Inbox', 'display_name set');
    is($folder->parent_folder_id, 'AAMkAD000', 'parent_folder_id set');
    is($folder->child_folder_count, 3, 'child_folder_count set');
    is($folder->unread_item_count, 5, 'unread_item_count set');
    is($folder->total_item_count, 100, 'total_item_count set');
    is($folder->is_hidden, 0, 'is_hidden set');
};

subtest 'has_children checks child_folder_count' => sub {
    my $with_children = MS::Graph::Mail::Folder->new({ childFolderCount => 2 });
    my $no_children = MS::Graph::Mail::Folder->new({ childFolderCount => 0 });

    ok($with_children->has_children, 'has children when count > 0');
    ok(!$no_children->has_children, 'no children when count is 0');
};

subtest 'has_unread checks unread_item_count' => sub {
    my $with_unread = MS::Graph::Mail::Folder->new({ unreadItemCount => 10 });
    my $no_unread = MS::Graph::Mail::Folder->new({ unreadItemCount => 0 });

    ok($with_unread->has_unread, 'has unread when count > 0');
    ok(!$no_unread->has_unread, 'no unread when count is 0');
};

subtest 'is_empty checks total_item_count' => sub {
    my $empty = MS::Graph::Mail::Folder->new({ totalItemCount => 0 });
    my $not_empty = MS::Graph::Mail::Folder->new({ totalItemCount => 50 });

    ok($empty->is_empty, 'empty when count is 0');
    ok(!$not_empty->is_empty, 'not empty when count > 0');
};

subtest 'to_string returns readable format' => sub {
    my $folder = MS::Graph::Mail::Folder->new({
        displayName     => 'Projects',
        totalItemCount  => 42,
        unreadItemCount => 7,
    });

    my $str = $folder->to_string;
    like($str, qr/Projects/, 'contains folder name');
    like($str, qr/42/, 'contains total count');
    like($str, qr/7/, 'contains unread count');
};

subtest 'well_known_folder_path returns correct names' => sub {
    is(MS::Graph::Mail::Folder->well_known_folder_path('inbox'), 'Inbox', 'inbox mapping');
    is(MS::Graph::Mail::Folder->well_known_folder_path('INBOX'), 'Inbox', 'case insensitive');
    is(MS::Graph::Mail::Folder->well_known_folder_path('drafts'), 'Drafts', 'drafts mapping');
    is(MS::Graph::Mail::Folder->well_known_folder_path('sentitems'), 'SentItems', 'sentitems mapping');
    is(MS::Graph::Mail::Folder->well_known_folder_path('deleteditems'), 'DeletedItems', 'deleteditems mapping');
    is(MS::Graph::Mail::Folder->well_known_folder_path('CustomFolder'), 'CustomFolder', 'unknown passed through');
};

subtest 'raw accessor returns original data' => sub {
    my $data = {
        id          => 'folder-id',
        displayName => 'Test',
        custom      => 'field',
    };
    my $folder = MS::Graph::Mail::Folder->new($data);

    is($folder->raw->{custom}, 'field', 'raw data accessible');
};

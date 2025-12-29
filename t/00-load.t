#!/usr/bin/env perl

use strict;
use warnings;
use Test::More tests => 6;

BEGIN {
    use_ok('MS::Graph::Mail');
    use_ok('MS::Graph::Mail::Auth');
    use_ok('MS::Graph::Mail::Client');
    use_ok('MS::Graph::Mail::Message');
    use_ok('MS::Graph::Mail::Folder');
    use_ok('MS::Graph::Mail::Attachment');
}

diag("Testing MS::Graph::Mail $MS::Graph::Mail::VERSION");

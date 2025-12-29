use 5.026;
use strict;
use warnings;
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME             => 'MS::Graph::Mail',
    AUTHOR           => 'Xezis',
    VERSION_FROM     => 'lib/MS/Graph/Mail.pm',
    ABSTRACT         => 'Perl interface to Microsoft Graph Mail API',
    LICENSE          => 'perl_5',
    MIN_PERL_VERSION => '5.026',
    CONFIGURE_REQUIRES => {
        'ExtUtils::MakeMaker' => '0',
    },
    BUILD_REQUIRES => {
        'Test::More'       => '0',
        'Test::MockObject' => '0',
        'Test::Exception'  => '0',
    },
    PREREQ_PM => {
        'LWP::UserAgent'   => '0',
        'LWP::Protocol::https' => '0',
        'HTTP::Request'    => '0',
        'JSON'             => '0',
        'URI'              => '0',
        'URI::Escape'      => '0',
        'MIME::Base64'     => '0',
        'Try::Tiny'        => '0',
        'Carp'             => '0',
    },
    META_MERGE => {
        'meta-spec' => { version => 2 },
        resources => {
            repository => {
                type => 'git',
                url  => 'https://github.com/Xezis/MS-Graph-Mail.git',
                web  => 'https://github.com/Xezis/MS-Graph-Mail',
            },
        },
    },
    dist  => { COMPRESS => 'gzip -9f', SUFFIX => 'gz', },
    clean => { FILES => 'MS-Graph-Mail-*' },
);

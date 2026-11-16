use strict;
use warnings;
use Module::Build;

Module::Build->new(
  module_name        => 'Weefax',
  dist_author        => 'Roger Pettett <rmp@psyphi.net>',
  dist_version_from  => 'lib/Weefax.pm',
  license            => 'perl',
  script_files       => [ 'weefax.pl', 'weefax-news.pl' ],
  configure_requires => { 'Module::Build' => '0.4004' },
  requires           => {
    'perl'               => '5.020',
    'Mojolicious'        => '9.0',
    'IO::Socket::SSL'    => '2.009',
    'Unicode::Normalize' => 0,
  },
  test_requires      => { 'Test::More' => '0.98' },
  meta_merge         => {
    'meta-spec' => { version => 2 },
    prereqs     => {
      develop => {
        requires => {
          'Test::Perl::Critic'   => 0,
          'Test::Pod'            => '1.41',
          'Test::Pod::Coverage'  => '1.08',
          'Pod::Coverage'        => 0,
          'Test::Kwalitee'       => '1.21',
          'Test::CPAN::Changes'  => 0,
          'Test::MinimumVersion' => 0,
        },
      },
    },
  },
  add_to_cleanup     => [ 'Weefax-[0-9]*' ],
)->create_build_script;

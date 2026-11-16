use strict;
use warnings;
use Test::More;
use Test::MinimumVersion;

all_minimum_version_ok('5.020', { paths => [ 'lib', 't', 'xt', 'weefax.pl', 'weefax-news.pl', 'Build.PL' ] });

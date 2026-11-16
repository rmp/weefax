use strict;
use warnings;
use Test::More;
use Test::Perl::Critic (-profile => '.perlcriticrc');

all_critic_ok('lib', 'weefax.pl', 'weefax-news.pl');

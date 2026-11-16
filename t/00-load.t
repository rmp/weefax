use Mojo::Base -strict;
use Test::More;
use Mojo::File qw(curfile);

use_ok $_ for qw(Weefax Weefax::News);

my $root = curfile->dirname->dirname;
for my $script (qw(weefax.pl weefax-news.pl)) {
  my $out = qx{"$^X" -c "$root/$script" 2>&1};
  like $out, qr/syntax OK/, "$script compiles";
}

done_testing;

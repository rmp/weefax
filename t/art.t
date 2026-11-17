use Mojo::Base -strict, -signatures;
use Test::More;

use Weefax qw(sextant_byte parse_txt mk_delay);
use Weefax::Art qw(read_pnm fit sextant mosaic art_page);

sub cells ($line) { length($line =~ s/\{\{|\{\w+\}/x/gr) }

sub image ($w, $h, $colour) {
  return { w => $w, h => $h, rgb => [ map { my $x = $_ % $w; @{ $colour->($x) } } 0 .. $w * $h - 1 ] };
}

is sextant_byte(ord sextant($_)) // 0x20, 0x20 + ($_ & 0x1F) + ($_ & 0x20 ? 0x40 : 0), "sextant $_"
  for 0 .. 63;

subtest read_pnm => sub {
  my $ppm = read_pnm("P6\n2 1\n255\n\x01\x02\x03\x04\x05\x06");
  is_deeply $ppm, { w => 2, h => 1, rgb => [1 .. 6] }, 'PPM';
  is_deeply read_pnm("P5 1 1 255\n\x09")->{rgb}, [9, 9, 9], 'PGM as grey RGB';
  ok !eval { read_pnm('GIF89a') }, 'other formats refused';
};

subtest fit => sub {
  is_deeply [ fit(1000, 100) ], [ 76, 10 ], 'wide fills the width';
  is_deeply [ fit(100, 1000) ], [ 5, 60 ], 'tall fills the height';
};

subtest mosaic => sub {
  my @rows = mosaic(image(40, 30, sub ($x) { $x < 20 ? [255, 0, 0] : [0, 0, 255] }));
  is scalar @rows, 20, 'twenty rows';
  ok !(grep { cells($_) != 40 } @rows), 'rows are 40 cells';
  my $row = $rows[10];
  like $row, qr/^\{hold\}\{gred\} *\x{2588}+\{gblue\}\x{2588}+ *$/, 'one colour change per row, solid blocks';
};

subtest art_page => sub {
  my $art  = { title => 'Wheat {Field}', artistDisplayName => 'Vincent van Gogh', objectDate => '1889',
               artistDisplayBio => 'Dutch', medium => 'Oil on canvas' };
  my $page = art_page(600, $art, [ mosaic(image(4, 3, sub { [200, 200, 0] })) ], 'One. ' x 200);
  my @screens = parse_txt($page, mk_delay(12, 's'));
  is scalar @screens, 2, 'picture and about screens';
  for my $s (split /^\@screen\n/m, $page) {
    my @lines = split /\n/, $s;
    is scalar @lines, 24, 'screen fills 24 rows';
    ok !(grep { cells($_) > 40 } @lines), 'rows fit 40 cells';
  }
  like $page, qr/Wheat \{\{Field\}/, 'braces escaped';
  like $page, qr/^\{white\} One\. One\./m, 'about text';
  like $page, qr/Wikipedia/, 'about text credited';
  unlike art_page(600, $art, [], undef), qr/Wikipedia/, 'no about text, no credit';
};

done_testing;

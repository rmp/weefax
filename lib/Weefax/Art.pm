package Weefax::Art;
use Mojo::Base -strict, -signatures;
use Exporter qw(import);
use List::Util qw(max min sum);
use Mojo::File qw(path tempfile);
use Mojo::JSON qw(from_json);
use Mojo::UserAgent;
use Mojo::Util qw(url_escape);
use Weefax::News qw(clean wrap);

our $VERSION   = '0.01';
our @EXPORT_OK = qw(run read_pnm fit mosaic sextant art_page);

my $MET    = 'https://collectionapi.metmuseum.org/public/collection';
my $SEARCH = "$MET/v1.1/search?isHighlight=true&hasImages=true&medium=Paintings&q=*&limit=1";
my $COLS   = 38;     # cells after {hold} and a colour code
my $ROWS   = 20;     # rows 2-21
my $PIXEL  = 1.25;   # a sextant is 1/80 of a 4:3 screen wide and 1/75 high
my @BAYER  = (0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5);
my @NAMES  = qw(black red green yellow blue magenta cyan white);
my $SWITCH = 2e4;   # squared RGB error a colour change must save
my $SAT    = 4;
my $GAMMA  = 1.6;

sub read_pnm ($bytes) {
  my ($type, $w, $h, $max) = $bytes =~ /\AP([56])\s+(\d+)\s+(\d+)\s+(\d+)\s/ or die "not a PNM image\n";
  die "16-bit PNM\n" if $max > 255;
  my @v = unpack 'C*', substr $bytes, $+[0];
  @v = map { ($_) x 3 } @v if $type == 5;
  return { w => $w, h => $h, rgb => \@v };
}

sub fit ($w, $h) {
  my $pw = min(2 * $COLS, 3 * $ROWS * $w / $h / $PIXEL);
  return (int($pw + 0.5), int(min(3 * $ROWS, $pw * $h / $w * $PIXEL) + 0.5));
}

sub sextant ($v) {
  return $v == 0  ? ' '
       : $v == 63 ? "\x{2588}"
       : $v == 21 ? "\x{258C}"
       : $v == 42 ? "\x{2590}"
       :            chr(0x1FB00 + $v - 1 - ($v > 21) - ($v > 42));
}

sub _pixels ($img) {
  my ($w, $h, $v) = @$img{qw(w h rgb)};
  my ($pw, $ph) = fit($w, $h);
  my ($x0, $y0) = (2 * int((2 * $COLS - $pw) / 4), 3 * int((3 * $ROWS - $ph) / 6));
  my @px;
  for my $y (0 .. $ph - 1) {
    my ($sy0, $sy1) = (int($y * $h / $ph), max(int($y * $h / $ph) + 1, int(($y + 1) * $h / $ph)));
    for my $x (0 .. $pw - 1) {
      my ($sx0, $sx1) = (int($x * $w / $pw), max(int($x * $w / $pw) + 1, int(($x + 1) * $w / $pw)));
      my @sum = (0, 0, 0);
      for my $sy ($sy0 .. $sy1 - 1) {
        for my $sx ($sx0 .. $sx1 - 1) { $sum[$_] += $v->[3 * ($sy * $w + $sx) + $_] for 0 .. 2 }
      }
      $px[$y0 + $y][$x0 + $x] = [ map { $_ / ($sy1 - $sy0) / ($sx1 - $sx0) } @sum ];
    }
  }
  my @all = sort { $a <=> $b } map { @$_ } grep {$_} map { @{ $_ // [] } } @px;
  my ($lo, $hi) = ($all[ @all / 100 ], $all[ 99 * @all / 100 ]);
  for my $p (grep {$_} map { @{ $_ // [] } } @px) {
    my ($mx, $mn) = (max(@$p), min(@$p));
    my $k = $mx > $mn ? min($mx, $SAT * ($mx - $mn)) / ($mx - $mn) : 0;
    @$p = map { 255 * max(0, min(1, ($mx - ($mx - $_) * $k - $lo) / max(1, $hi - $lo))) ** $GAMMA } @$p;
  }
  return \@px;
}

# How far, 0 to 1, a colour reaches towards teletext colour $k.
sub _along ($rgb, $k) {
  my @on = grep { $k >> $_ & 1 } 0 .. 2;
  return min(1, sum(@$rgb[@on]) / @on / 255);
}

# Per row, a Viterbi pass picks each cell's colour to fit its mean, charging
# for each change since that takes a cell; held mosaics fill those cells.
sub mosaic ($img) {
  my $px = _pixels($img);
  my @lines;
  for my $r (0 .. $ROWS - 1) {
    my @cells = map {
      my $c = $_;
      [ map { $px->[3 * $r + int($_ / 2)][2 * $c + $_ % 2] // [0, 0, 0] } 0 .. 5 ];
    } 0 .. $COLS - 1;
    my (@cost, @from);
    for my $i (0 .. $#cells) {
      my @mean = map { my $ch = $_; sum(map { $_->[$ch] } @{ $cells[$i] }) / 6 } 0 .. 2;
      for my $k (1 .. 7) {
        my $f   = _along(\@mean, $k);
        my $err = sum(map { ($mean[$_] - 255 * $f * ($k >> $_ & 1)) ** 2 } 0 .. 2);
        my ($best) = !$i ? [ 0, $k ]
          : sort { $a->[0] <=> $b->[0] } map { [ $cost[$i - 1][$_] + ($_ == $k ? 0 : $SWITCH), $_ ] } 1 .. 7;
        ($cost[$i][$k], $from[$i][$k]) = ($best->[0] + $err, $best->[1]);
      }
    }
    my ($k) = sort { $cost[-1][$a] <=> $cost[-1][$b] } 1 .. 7;
    my @colour = ($k);
    unshift @colour, $k = $from[$_][$k] for reverse 1 .. $#cells;
    my $line = "{hold}{g$NAMES[$colour[0]]}";
    for my $i (0 .. $#cells) {
      if ($i && $colour[$i] != $colour[ $i - 1 ]) { $line .= "{g$NAMES[$colour[$i]]}"; next }
      my $v = 0;
      for my $b (0 .. 5) {
        my ($x, $y) = (2 * $i + $b % 2, 3 * $r + int($b / 2));
        $v |= 1 << $b if 255 * _along($cells[$i][$b], $colour[$i]) > ($BAYER[4 * ($y % 4) + $x % 4] + 1) * 15;
      }
      $line .= _esc(sextant($v));
    }
    push @lines, $line;
  }
  return @lines;
}

sub _esc ($s) { return $s =~ s/\{/{{/gr }

sub _fits ($text, $rows) {
  my @out;
  for my $sentence (split /(?<=[.!?]) /, $text) {
    my @try = wrap(join ' ', @out, $sentence);
    last if @try > $rows;
    push @out, $sentence;
  }
  return wrap(join ' ', @out);
}

sub art_page ($page, $art, $image, $about) {
  my $title  = clean($art->{title} // 'Untitled');
  my $artist = clean($art->{artistDisplayName} || 'Unknown artist');
  my $date   = clean($art->{objectDate} // '');
  my $byline = join ', ', grep {length} $artist, $date;
  my $header = Weefax::News::_header('blue', 'Artwork of the day');
  my $footer = Weefax::News::_footer('blue', "Page $page", 'Index 100');

  my @facts = (
    (map { "{yellow} " . _esc($_) } wrap($title)),
    (map { "{white} " . _esc($_) } wrap($byline)),
    (map { "{cyan} " . _esc($_) } wrap(clean($art->{artistDisplayBio} // ''))),
    (map { "{green} " . _esc($_) } wrap(clean($art->{medium} // ''))),
  );
  my @text = map { "{white} " . _esc($_) } _fits(clean($about // ''), 20 - @facts - 1);
  return join "\n",
    '{blue}{newbg}{white} Artwork of the day', @$image,
    '{yellow} ' . _esc(Weefax::News::_shorten($title, 38)),
    '{white} ' . _esc(Weefax::News::_shorten($byline, 38)), $footer,
    '@screen',
    Weefax::News::_screen($header, '', @facts, (@text ? ('', @text) : ())),
    (@text ? "{cyan} The Met, New York; Wikipedia" : "{cyan} The Met, New York"), $footer;
}

sub _json ($ua, $url) {
  my $body = Weefax::News::_fetch($ua, $url) // return;
  return eval { from_json($body) };
}

sub _image ($ua, $url) {
  my $res = $ua->get($url)->result;
  die 'HTTP ' . $res->code . "\n" unless $res->is_success;
  my $jpeg = tempfile->spew($res->body);
  open my $fh, '-|', 'djpeg', '-scale', '1/4', '-pnm', "$jpeg" or die "djpeg: $!\n";
  binmode $fh;
  my $pnm = do { local $/; <$fh> };
  close $fh or die "djpeg failed\n";
  return read_pnm($pnm);
}

sub _wikipedia ($ua, $wikidata) {
  my ($q) = ($wikidata // '') =~ m{/(Q\d+)$} or return;
  my $entity = _json($ua, "https://www.wikidata.org/wiki/Special:EntityData/$q.json") // return;
  my $title  = $entity->{entities}{$q}{sitelinks}{enwiki}{title} // return;
  my $sum    = _json($ua, 'https://en.wikipedia.org/api/rest_v1/page/summary/' . url_escape($title =~ tr/ /_/r));
  return $sum && $sum->{extract};
}

sub run (%opt) {
  my $page = $opt{page} // 600;
  die "bad page number '$page'\n" unless $page =~ /^[1-8][0-9A-F]{2}$/i;
  my ($lo, $hi) = ($opt{aspect} // '0.8-2.5') =~ /^([\d.]+)-([\d.]+)$/ or die "bad aspect '$opt{aspect}'\n";
  my $out = path($opt{out} // path($ENV{MODE7_PAGES} // 'pages')->child('art'));
  my $ua  = Mojo::UserAgent->new(connect_timeout => 10, request_timeout => 30, max_redirects => 3);
  $ua->transactor->name('weefax-art/1.0 (https://github.com/rmp/weefax)');

  my $total = (_json($ua, $SEARCH) // {})->{total} or die "no artworks found; previous page left in place\n";
  for (1 .. 20) {
    my ($id) = @{ (_json($ua, "$SEARCH&offset=" . int rand $total) // {})->{objectIDs} // [] };
    my $art = $id && _json($ua, "$MET/v1/objects/$id") or next;
    next unless $art->{isPublicDomain} && $art->{primaryImageSmall};
    my $img = eval { _image($ua, $art->{primaryImageSmall}) } or do { warn "$art->{primaryImageSmall}: $@"; next };
    my $aspect = $img->{w} / $img->{h};
    next if $aspect < $lo || $aspect > $hi;
    my $file = $out->make_path->child("$page artwork.txt");
    $out->child(".$page artwork.txt")
      ->spew(art_page($page, $art, [ mosaic($img) ], _wikipedia($ua, $art->{objectWikidata_URL})||q[]) . "\n", 'UTF-8')
      ->move_to($file);
    return say "$art->{title} ($id) written to $file";
  }
  die "no suitable artwork found; previous page left in place\n";
}

1;

__END__

=encoding utf8

=head1 NAME

Weefax::Art - build a weefax artwork of the day page

=head1 VERSION

0.01

=head1 SYNOPSIS

  use Weefax::Art qw(run);
  run(page => 600, out => 'pages/art', aspect => '0.8-2.5');

=head1 DESCRIPTION

Picks a random public-domain highlight painting from the Metropolitan Museum
of Art's open-access API, draws it in teletext mosaics and writes a
two-screen C<.txt> page for C<weefax.pl>: the picture with its title and
artist, then an about screen with the artist, medium and Wikipedia summary.
Decoding needs C<djpeg> from libjpeg-turbo. A failed run leaves the previous
page in place.

=head1 FUNCTIONS

=head2 run

Builds the page. Options: C<page> (default 600), C<out>, the folder (default
F<art> under C<$ENV{MODE7_PAGES}> or F<pages>), and C<aspect>, the range of
width/height ratios to accept (default C<0.8-2.5>). Dies if no artwork fits.

=head2 read_pnm

Parses a binary PPM or PGM image into width, height and RGB values.

=head2 fit

Returns the width and height in sextant pixels at which an image of the given
size fills the picture area without distortion.

=head2 sextant

Returns the Unicode block sextant for a six-bit mosaic value.

=head2 mosaic

Renders an image as twenty C<.txt> rows of held mosaics.

=head2 art_page

Renders the page as C<.txt> from a Met object record, mosaic rows and about
text.

=head1 AUTHOR

Roger Pettett <rmp@psyphi.net>

=head1 LICENSE

This library is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut

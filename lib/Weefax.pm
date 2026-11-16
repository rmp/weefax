package Weefax;
use Mojo::Base -strict, -signatures;
use Exporter qw(import);
use Mojo::Util qw(decode);

our $VERSION   = '0.01';
our @EXPORT_OK = qw(pad40 sextant_byte txt_line decode_edittf mk_delay name_delay
                    parse_txt parse_tti load_file scan);

my $PAGE_RE  = qr/^([1-8][0-9A-F]{2})(?![0-9A-Za-z])/i;
my $DELAY_RE = qr/(\d+(?:\.\d+)?)([sc]?)/i;

# Level 1 spacing attributes, by mnemonic, for .txt pages: {red}, {gblue}, ...
my %CTRL = (
  black   => 0x00, red      => 0x01, green    => 0x02, yellow   => 0x03,
  blue    => 0x04, magenta  => 0x05, cyan     => 0x06, white    => 0x07,
  flash   => 0x08, steady   => 0x09, endbox   => 0x0A, startbox => 0x0B,
  normal  => 0x0C, double   => 0x0D, dblwidth => 0x0E, dblsize  => 0x0F,
  gblack  => 0x10, gred     => 0x11, ggreen   => 0x12, gyellow  => 0x13,
  gblue   => 0x14, gmagenta => 0x15, gcyan    => 0x16, gwhite   => 0x17,
  conceal => 0x18, contig   => 0x19, sep      => 0x1A,
  blackbg => 0x1C, newbg    => 0x1D, hold     => 0x1E, release  => 0x1F,
);

sub pad40 ($s) { return substr(($s // '') . (' ' x 40), 0, 40) }

sub sextant_byte ($cp) {
  my $v;
  if    ($cp == 0x2588) { $v = 63 }
  elsif ($cp == 0x258C) { $v = 21 }
  elsif ($cp == 0x2590) { $v = 42 }
  elsif ($cp >= 0x1FB00 && $cp <= 0x1FB3B) {
    $v = $cp - 0x1FB00 + 1;
    $v++ if $v >= 21;
    $v++ if $v >= 42;
  }
  else { return }
  return 0x20 + ($v & 0x1F) + (($v & 0x20) ? 0x40 : 0);
}

sub txt_line ($s) {
  my $out = '';
  while (length $s) {
    if    ($s =~ s/^\{\{//)                { $out .= '{' }
    elsif ($s =~ s/^\{x([0-9a-f]{2})\}//i) { $out .= chr(hex($1) & 0x7F) }
    elsif ($s =~ s/^\{(\w+)\}//) {
      die "unknown code {$1}\n" unless exists $CTRL{lc $1};
      $out .= chr $CTRL{lc $1};
    }
    else {
      my $c = ord substr($s, 0, 1, '');
      my $b = sextant_byte($c);
      $out .= defined $b    ? chr $b
            : $c == 0xA3    ? '#'                     # £ lives at 0x23 in G0
            : ($c < 0x20 || $c > 0x7E) ? ' '
            :                 chr $c;
    }
  }
  return pad40($out);
}

sub decode_edittf ($b64) {
  my %val;
  my @a = ('A'..'Z', 'a'..'z', 0..9, '-', '_');
  @val{@a} = 0 .. 63;
  my $bits  = join '', map { sprintf '%06b', $val{$_} // 0 } split //, $b64;
  my @chars = map { chr oct "0b$_" } grep { length == 7 } unpack '(a7)*', $bits;
  my @rows  = map { pad40(join '', map { $_ // ' ' } @chars[$_*40 .. $_*40+39]) } 0 .. 24;
  return \@rows;
}

sub mk_delay ($n, $unit) {
  return unless defined $n && $n > 0;
  return { n => $n + 0, unit => lc($unit // '') eq 'c' ? 'c' : 's' };
}

sub name_delay ($name) {
  return $name =~ /\@$DELAY_RE(?![\w])/ ? mk_delay($1, $2) : undef;
}

sub parse_txt ($text, $delay) {
  my (@screens, $cur);
  my $start = sub { push @screens, $cur = { lines => [], delay => $delay } };
  $start->();
  for my $line (split /\r?\n/, $text) {
    if ($line =~ /^\@delay\s+$DELAY_RE\s*$/i) {
      $delay = $cur->{delay} = mk_delay($1, $2) // $delay;
    }
    elsif ($line =~ /^\@screen(?:\s+$DELAY_RE)?\s*$/i) {
      $start->();
      $cur->{delay} = mk_delay($1, $2) // $delay if defined $1;
    }
    else {
      push @{ $cur->{lines} }, $line;
    }
  }
  return map {
    my @l    = @{ $_->{lines} };
    my $body = join "\n", @l;
    my $rows = $body =~ m{edit\.tf/?#\d*:([A-Za-z0-9_-]+)}
      ? decode_edittf($1)
      : [ pad40(''), map { txt_line($l[$_] // '') } 0 .. 23 ];
    +{ rows => $rows, delay => $_->{delay} };
  } grep { @{ $_->{lines} } } @screens;
}

sub parse_tti ($bytes, $delay) {
  my (@subs, $cur);
  my $start = sub { push @subs, $cur = { rows => [ (pad40('')) x 25 ], delay => $delay } };
  for my $line (split /\r?\n/, $bytes) {
    if ($line =~ /^PN,/) { $start->(); next }
    if ($line =~ /^CT,(\d+),([TC])/i) {
      $start->() unless $cur;
      $cur->{delay} = mk_delay($1, uc $2 eq 'C' ? 'c' : 's') // $delay;
      next;
    }
    next unless $line =~ /^OL,(\d{1,2}),(.*)$/s;
    my ($row, $data) = ($1, $2);
    next if $row < 1 || $row > 24;
    $start->() unless $cur;
    my ($out, $esc) = ('', 0);
    for my $c (map { ord } split //, $data) {
      if    ($c == 0x1B) { $esc = 1; next }
      elsif ($esc)       { $out .= chr(($c - 0x40) & 0x7F); $esc = 0 }
      else               { $out .= chr($c & 0x7F) }
    }
    $cur->{rows}[$row] = pad40($out);
  }
  return @subs;
}

sub load_file ($file, $delay) {
  my $bytes = $file->slurp;
  return parse_tti($bytes, $delay) if $file->basename =~ /\.ttix?$/xi;
  my $text = decode('UTF-8', $bytes) // $bytes;
  return parse_txt($text, $delay);
}

sub _natural ($name) { return $name =~ s/(\d+)/sprintf '%09d', $1/ger }

sub _walk ($pages, $dir, $inherit, $idelay) {
  my @entries = sort { _natural($a->basename) cmp _natural($b->basename) }
                $dir->list({dir => 1})->each;
  for my $e (@entries) {
    my $name = $e->basename;
    next if $name =~ /^\./;
    my ($num) = $name =~ $PAGE_RE;
    $num = uc $num if defined $num;
    my $delay = name_delay($name) // $idelay;
    if (-d $e) { _walk($pages, $e, $num // $inherit, $delay); next }
    my $target = $inherit // $num // next;
    my @subs = eval { load_file($e, $delay) };
    if ($@) { warn "skipping $e: $@"; next }
    push @{ $pages->{$target} }, @subs;
  }
  return;
}

sub scan ($root, $delay) {
  my %pages;
  _walk(\%pages, $root, undef, $delay) if -d $root;
  return \%pages;
}

1;

__END__

=encoding utf8

=head1 NAME

Weefax - read teletext page folders for the weefax carousel

=head1 VERSION

0.01

=head1 SYNOPSIS

  use Weefax qw(scan mk_delay);
  my $pages = scan(Mojo::File::path('pages'), mk_delay(12, 's'));
  # { '100' => [ { rows => [25 rows of 40 bytes], delay => {n => 12, unit => 's'} } ] }

=head1 DESCRIPTION

Turns a folder of C<.txt>, C<.tti> and C<.ttix> files into teletext screens,
as served by C<weefax.pl>. The README describes the file formats and folder
conventions. Nothing is exported by default.

=head1 FUNCTIONS

=head2 pad40

Pads or truncates a string to one 40-cell row.

=head2 sextant_byte

Maps a Unicode block-sextant code point (U+1FB00-1FB3B, or U+258C, U+2590,
U+2588) to its teletext mosaic byte, or returns nothing for any other code
point.

=head2 txt_line

Converts one line of the C<.txt> format, with C<{code}> spacing attributes,
to a 40-byte teletext row. Dies on an unknown code.

=head2 decode_edittf

Decodes the hash of an edit.tf URL into 25 rows.

=head2 mk_delay

Builds a screen delay from a number and a unit: C<s> (seconds, the default)
or C<c> (carousel cycles). Returns nothing for a missing or non-positive
number.

=head2 name_delay

Reads an C<@8>, C<@8s> or C<@3c> delay from a file or folder name.

=head2 parse_txt

Splits C<.txt> text into screens, honouring C<@delay> and C<@screen> lines.
Takes the text and the inherited delay.

=head2 parse_tti

Splits MRG C<.tti> bytes into screens, one per C<PN> line, with C<CT> delays.
Takes the bytes and the inherited delay.

=head2 load_file

Parses one page file, a L<Mojo::File>, by its extension.

=head2 scan

Walks a page folder and returns screens keyed by page number. A file or
folder whose name starts with a page number holds that page; files inside a
numbered folder are its screens. Names starting with a dot are skipped, and
files that fail to parse are skipped with a warning. Takes the folder and the
default delay.

=head1 AUTHOR

Roger Pettett <rmp@psyphi.net>

=head1 LICENSE

This library is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut

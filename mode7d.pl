#!/usr/bin/env perl
# mode7d - a teletext-style carousel server.
#
# Walks a folder of page files, transmits one page per tick over WebSocket,
# and loops forever. Every client sees the rolling header; only clients that
# have selected a page receive its body when it comes round.
#
#   MODE7_PAGES=./pages MODE7_INTERVAL=150 ./mode7d.pl daemon -l http://*:3000
#
use Mojolicious::Lite -signatures;
use Mojo::File qw(path);
use Mojo::Util qw(decode);
use POSIX qw(strftime);
use Time::HiRes qw(time);

my $ROOT     = path($ENV{MODE7_PAGES}    // app->home->child('pages'));
my $INTERVAL = $ENV{MODE7_INTERVAL}      // 150;         # ms per page
my $SUBSECS  = $ENV{MODE7_SUBPAGE_SECS}  // 12;          # default screen delay
my $SERVICE  = substr(($ENV{MODE7_SERVICE} // 'WEEFAX 1') . (' ' x 8), 0, 8);

my $PAGE_RE = qr/^([1-8][0-9A-F]{2})(?![0-9A-Za-z])/i;

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

sub pad40 ($s) { substr(($s // '') . (' ' x 40), 0, 40) }

# Unicode block sextants (U+1FB00..1FB3B, plus ▌ ▐ █) -> teletext mosaic byte.
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
  else { return undef }
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

# edit.tf URL hash: base64url of 25x40 7-bit characters.
sub decode_edittf ($b64) {
  my %val; my @a = ('A'..'Z', 'a'..'z', 0..9, '-', '_');
  @val{@a} = 0 .. 63;
  my $bits  = join '', map { sprintf '%06b', $val{$_} // 0 } split //, $b64;
  my @chars = map { chr oct "0b$_" } grep { length == 7 } unpack '(a7)*', $bits;
  my @rows  = map { pad40(join '', @chars[$_*40 .. $_*40+39]) } 0 .. 24;
  return \@rows;
}

# A delay is seconds ("8", "8s") or carousel cycles ("3c"): how long a screen
# stays up before the page moves on to its next screen.
my $DELAY_RE = qr/(\d+(?:\.\d+)?)([sc]?)/i;

sub mk_delay ($n, $unit) {
  return undef unless defined $n && $n > 0;
  return { n => $n + 0, unit => lc($unit // '') eq 'c' ? 'c' : 's' };
}

# "@8", "@8s" or "@3c" anywhere in a file or folder name.
sub name_delay ($name) {
  return $name =~ /\@$DELAY_RE(?![\w])/ ? mk_delay($1, $2) : undef;
}

# A .txt file holds one or more screens. Directive lines:
#   @delay N    delay for this screen and the ones after it in the file
#   @screen [N] start the next screen; N overrides the delay for it alone
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

# MRG .tti: OL,<row>,<text> with ESC+(code+0x40) or high-bit control bytes.
# Each PN line starts another screen; CT,<n>,T (seconds) or CT,<n>,C
# (cycles) sets that screen's delay.
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
    for my $c (map ord, split //, $data) {
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
  return parse_tti($bytes, $delay) if $file->basename =~ /\.ttix?$/i;
  my $text = decode('UTF-8', $bytes) // $bytes;
  return parse_txt($text, $delay);
}

sub natural ($name) { $name =~ s/(\d+)/sprintf '%09d', $1/ger }

# Returns { '100' => [ { rows => [25 rows], delay => {n, unit} }, ... ] }
# Delay precedence: in-file directive > file name > nearest folder name
# > MODE7_SUBPAGE_SECS.
sub scan ($root) {
  my %pages;
  my $walk;
  $walk = sub ($dir, $inherit, $idelay) {
    my @entries = sort { natural($a->basename) cmp natural($b->basename) }
                  $dir->list({dir => 1})->each;
    for my $e (@entries) {
      my $name = $e->basename;
      next if $name =~ /^\./;
      my ($num) = $name =~ $PAGE_RE;
      $num = uc $num if defined $num;
      my $delay = name_delay($name) // $idelay;
      if (-d $e) { $walk->($e, $num // $inherit, $delay); next }
      my $target = $inherit // $num // next;
      my @subs = eval { load_file($e, $delay) };
      if ($@) { app->log->warn("skipping $e: $@"); next }
      push @{ $pages{$target} }, @subs;
    }
  };
  $walk->($root, undef, mk_delay($SUBSECS, 's')) if -d $root;
  return \%pages;
}

sub header ($num) {
  # 32 cells, CEEFAX-style: service, page in transit, date, yellow clock.
  sprintf '%s %s %s%s%s', $SERVICE, $num,
    strftime('%a %d %b', localtime), chr(0x03), strftime('%H:%M/%S', localtime);
}

my (%clients, @queue, $catalogue, $index_sig, %rot);
$catalogue = {};

sub page_list { [ sort { hex $a <=> hex $b } keys %$catalogue ] }

# Each page keeps its own place in its screen rotation. A screen changes only
# when the page is transmitted, as on air, so a delay is rounded up to the
# next time the page comes round.
sub advance ($num, $subs) {
  my $now = time;
  my $st  = $rot{$num} //= { i => 0, since => $now, seen => 0 };
  $st->{i} = 0 if $st->{i} >= @$subs;
  if (@$subs > 1) {
    my $d   = $subs->[ $st->{i} ]{delay};
    my $due = $d->{unit} eq 'c' ? $st->{seen} >= $d->{n} : $now - $st->{since} >= $d->{n};
    if ($due) {
      $st->{i} = ($st->{i} + 1) % @$subs;
      @$st{qw(since seen)} = ($now, 0);
    }
  }
  $st->{seen}++;
  return $st->{i};
}

sub tick {
  unless (@queue) {
    $catalogue = scan($ROOT);
    @queue = @{ page_list() };
    my $sig = join ',', @queue;
    if (!defined $index_sig || $sig ne $index_sig) {
      $index_sig = $sig;
      $_->{tx}->send({json => {t => 'index', pages => [@queue]}}) for values %clients;
    }
    delete @rot{ grep { !$catalogue->{$_} } keys %rot };
    return unless @queue;
  }
  my $num  = shift @queue;
  my $subs = $catalogue->{$num} or return;
  my $s    = advance($num, $subs);
  my $h    = header($num);
  for my $c (values %clients) {
    my %msg = (t => 'pkt', p => $num, h => $h);
    if ($c->{want}{$num}) {
      @msg{qw(s n rows)} = ($s + 1, scalar @$subs, [ @{ $subs->[$s]{rows} }[1 .. 24] ]);
    }
    $c->{tx}->send({json => \%msg});
  }
}

Mojo::IOLoop->recurring($INTERVAL / 1000 => \&tick);

get '/' => sub ($c) { $c->reply->static('index.html') };

websocket '/ws' => sub ($c) {
  my $id = "$c";
  $c->inactivity_timeout(60);
  $clients{$id} = { tx => $c->tx, want => {} };
  $c->send({json => {t => 'index', pages => page_list(), interval => $INTERVAL}});

  $c->on(json => sub ($c, $m) {
    return unless ref $m eq 'HASH' && ($m->{t} // '') eq 'select';
    my @want = ref $m->{pages} eq 'ARRAY' ? @{ $m->{pages} } : ();
    $clients{$id}{want} = { map { uc($_) => 1 } grep { /^[1-8][0-9A-F]{2}$/i } @want };
  });
  $c->on(finish => sub { delete $clients{$id} });
};

app->start;

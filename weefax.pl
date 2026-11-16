#!/usr/bin/env perl
# weefax - a teletext-style carousel server.
#
# Walks a folder of page files, transmits one page per tick over WebSocket,
# and loops forever. Every client sees the rolling header; only clients that
# have selected a page receive its body when it comes round.
#
#   MODE7_PAGES=./pages MODE7_INTERVAL=150 ./weefax.pl daemon -l http://*:3000
#
use FindBin;
use lib "$FindBin::Bin/lib";
use Mojolicious::Lite -signatures;
use Mojo::File qw(path);
use POSIX qw(strftime);
use Time::HiRes qw(time);
use Weefax qw(mk_delay scan);

my $ROOT     = path($ENV{MODE7_PAGES}    // app->home->child('pages'));
my $INTERVAL = $ENV{MODE7_INTERVAL}      // 150;         # ms per page
my $SUBSECS  = $ENV{MODE7_SUBPAGE_SECS}  // 12;          # default screen delay
my $SERVICE  = substr(($ENV{MODE7_SERVICE} // 'WEEFAX 1') . (' ' x 8), 0, 8);

sub header ($num) {
  # 32 cells, CEEFAX-style: service, page in transit, date, yellow clock.
  return sprintf '%s %s %s%s%s', $SERVICE, $num,
    strftime('%a %d %b', localtime), chr(0x03), strftime('%H:%M/%S', localtime);
}

my (%clients, @queue, $catalogue, $index_sig, %rot);
$catalogue = {};

sub page_list { return [ sort { hex $a <=> hex $b } keys %$catalogue ] }

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
    $catalogue = scan($ROOT, mk_delay($SUBSECS, 's'));
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
  return;
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

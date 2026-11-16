use Mojo::Base -strict, -signatures;
use Test::More;
use Test::Mojo;
use Mojo::File qw(curfile tempdir);
use Mojo::JSON qw(decode_json);

my $pages = tempdir;
$pages->child('100 index.txt')->spew("{red}Hello\n");
$pages->child('101.txt')->spew("one\n\@screen\ntwo\n");
local $ENV{MODE7_PAGES}    = "$pages";
local $ENV{MODE7_INTERVAL} = 10;

my $t = Test::Mojo->new(curfile->dirname->sibling('weefax.pl'));
$t->app->log->level('fatal');

$t->get_ok('/')->status_is(200)->content_like(qr/<mode7-screen/);

# Packets until one satisfies $want, or give up after a whole carousel's worth.
sub next_json ($t, $want) {
  for (1 .. 20) {
    $t->message_ok or return;
    my $m = decode_json($t->message->[1]);
    return $m if $want->($m);
  }
  return;
}

$t->websocket_ok('/ws');
my $index = next_json($t, sub ($m) { $m->{t} eq 'index' && @{ $m->{pages} } });
is_deeply $index->{pages}, [qw(100 101)], 'index lists the pages';

my $header = next_json($t, sub ($m) { $m->{t} eq 'pkt' });
like $header->{h}, qr/^WEEFAX 1 10[01] /, 'header packet names the service and page';
ok !exists $header->{rows}, 'no rows for an unselected page';

$t->send_ok({json => {t => 'select', pages => ['100', 'bogus']}});
my $body = next_json($t, sub ($m) { $m->{t} eq 'pkt' && $m->{rows} });
is $body->{p}, '100', 'rows only for the selected page';
is scalar @{ $body->{rows} }, 24, 'rows 1-24';
is $body->{rows}[0], "\x01Hello" . ' ' x 34, 'row 1 decoded';
is_deeply [ @$body{qw(s n)} ], [1, 1], 'subpage 1 of 1';

$t->send_ok({json => {t => 'select', pages => ['101']}});
$body = next_json($t, sub ($m) { $m->{t} eq 'pkt' && $m->{rows} });
is_deeply [ @$body{qw(p n)} ], ['101', 2], 'rotating page reports its screens';
$t->finish_ok;

done_testing;

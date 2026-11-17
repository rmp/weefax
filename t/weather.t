use Mojo::Base -strict, -signatures;
use Test::More;
use Mojo::File qw(tempdir);
use Mojo::IOLoop::Server;
use Mojolicious;
use Mojo::Util qw(encode);

use Weefax::Weather qw(run parse_uk parse_region);

my $uk = <<'HTML';
<ul><li><a class="national-forecast-link" href="./x"><span class="location-name">Aberdeen</span>
<img class="icon" alt="Light rain"><span class="temp" data-value="-3">-3&deg;C</span></a></li></ul>
<div id="tab-content-d1"><div class="tab-content-paragraph"><h3>Tonight:</h3><p>Rain {spreading}.</p></div>
<div class="updated">Updated: 16:00 (UTC) on Tue 17 Nov 2026</div></div>
<div id="tab-content-d3"><div class="tab-content-paragraph"><h3>Long range</h3><p>Ignored.</p></div></div>
<h2>UK regions</h2>
<a href="../forecast/regional/ee">East of England</a>
<a href="../forecast/regional/gone">Gone</a>
<a href="../forecast/regional/ee">East of England</a>
HTML
my $region = <<'HTML';
<div id="fiveDayText">
<div class="forecast-text-section"><h4>Headline:</h4><p>Clouding over.</p></div>
<div class="forecast-text-section"><h4>Wednesday:</h4><p>Maximum temperature 12&nbsp;&deg;C.</p></div>
<p class="updated">Updated: <time>16:00 (UTC) on Tue 17 Nov 2026</time></p></div>
HTML

my $port = Mojo::IOLoop::Server->generate_port;
my $pid  = fork // die;
if (!$pid) {
  my $app = Mojolicious->new;
  $app->log->level('fatal');
  $app->routes->get('/forecast/uk' => sub ($c) { $c->render(data => encode('UTF-8', $uk)) });
  $app->routes->get('/forecast/regional/ee' => sub ($c) { $c->render(data => encode('UTF-8', $region)) });
  $app->start('daemon', '-l', "http://127.0.0.1:$port");
  exit;
}
END { kill 'TERM', $pid if $pid }
sleep 1;

sub cells ($line) { length($line =~ s/\{\{|\{\w+\}/x/gr) }

subtest parse_uk => sub {
  my $p = parse_uk($uk);
  is_deeply $p->{cities}, [ { name => 'Aberdeen', weather => 'Light rain', temp => -3 } ], 'cities';
  is_deeply $p->{sections}, [ [ 'Tonight', 'Rain {spreading}.' ] ], 'short-range sections only';
  is_deeply [ map { $_->{name} } @{ $p->{regions} } ], [ 'East of England', 'Gone' ], 'regions deduplicated';
  like $p->{regions}[0]{url}, qr{^https://weather\.metoffice\.gov\.uk/forecast/regional/ee$}, 'absolute URL';
  is $p->{updated}, '16:00 (UTC) on Tue 17 Nov 2026', 'updated';
};

is_deeply parse_region($region)->{sections}[1], [ 'Wednesday', 'Maximum temperature 12C.' ], 'degree sign dropped';

my $out  = tempdir->child('weather');
my $base = "http://127.0.0.1:$port/forecast/uk";
$out->make_path->child('403 gone.txt')->spew("old\n");
$out->child('400@8')->make_path;
run($out, $base);
ok -e $out->child('400 uk.txt'), 'UK page';
ok -e $out->child('401 regions.txt'), 'regions index';
ok -e $out->child('402 east-of-england.txt'), 'region page';
is $out->child('403 gone.txt')->slurp, "old\n", 'failed region keeps its previous page';
ok !-e $out->child('400@8'), 'old pages replaced';
like $out->child('400 uk.txt')->slurp('UTF-8'), qr/Aberdeen .*-3C/, 'city temperature';
like $out->child('402 east-of-england.txt')->slurp('UTF-8'), qr/Clouding over\./, 'headline';

for my $file (grep { !/gone/ } $out->list->each) {
  for my $s (split /^\@screen\n/m, $file->slurp('UTF-8')) {
    my @lines = split /\n/, $s;
    is scalar @lines, 24, "$file: screen fills 24 rows";
    ok !(grep { cells($_) > 40 } @lines), "$file: rows fit 40 cells";
  }
}

ok !eval { run($out, "http://127.0.0.1:$port/missing"); 1 }, 'failed UK forecast is an error';
ok -e $out->child('400 uk.txt'), 'and leaves the previous run in place';

done_testing;

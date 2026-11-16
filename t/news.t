use Mojo::Base -strict, -signatures;
use Test::More;
use Mojo::File qw(tempdir);
use Mojo::IOLoop::Server;
use Mojolicious;
use Mojo::Util qw(encode);

use Weefax::News qw(run clean wrap read_conf parse_feed index_page);

my $long = join ' ', ('Paragraph words that need wrapping {braces}') x 30;
my $rss  = <<"XML";
<?xml version="1.0"?>
<rss><channel><title>Fixture News</title>
<item><title>Caf\x{e9} \x{2018}quoted\x{2019} headline that is long enough to need a second row</title>
<description><![CDATA[<p>First \x{a3}5 paragraph</p><ul><li><p>Related link</p></li></ul><p>$long</p><p>Continue reading...</p>]]></description></item>
<item><title>Second story</title><description>Plain summary</description></item>
</channel></rss>
XML

my $port = Mojo::IOLoop::Server->generate_port;
my $pid  = fork // die;
if (!$pid) {
  my $app = Mojolicious->new;
  $app->log->level('fatal');
  $app->routes->get('/feed' => sub ($c) { $c->render(data => encode('UTF-8', $rss), format => 'xml') });
  $app->start('daemon', '-l', "http://127.0.0.1:$port");
  exit;
}
END { kill 'TERM', $pid if $pid }
sleep 1;

my $dir  = tempdir;
my $out  = $dir->child('daily');
my $good = "http://127.0.0.1:$port/feed";
my $bad  = "http://127.0.0.1:$port/missing";
my $conf = $dir->child('news.conf')->spew("120 Contents\n130 Good $good\n140 Bad $bad\n");

# Cells as weefax.pl counts them: {{ and each {code} take one.
sub cells ($line) { length($line =~ s/\{\{|\{\w+\}/x/gr) }

sub check_page ($file) {
  my @screens = split /^\@screen.*\n/m, $file->slurp('UTF-8');
  for my $s (@screens) {
    my @lines = split /\n/, $s;
    ok @lines <= 24, "$file: screen fits 24 rows";
    ok !(grep { cells($_) > 40 } @lines), "$file: rows fit 40 cells";
    ok !($s =~ /[^\x00-\x7F\x{a3}]/), "$file: teletext-safe characters";
  }
  return scalar @screens;
}

run($conf, $out);
my $section = $out->child('news-good');
ok -e $out->child('120 contents.txt'), 'contents page';
ok -e $section->child("$_ story.txt"), "story $_" for 131, 132;
ok !-e $out->child('news-bad'), 'failed section with no history is absent';
check_page($_) for $out->list_tree->each;
cmp_ok check_page($section->child('131 story.txt')), '>', 1, 'long story rotates';

my $story = $section->child('131 story.txt')->slurp('UTF-8');
like $story, qr/Cafe 'quoted'/, 'transliterated';
like $story, qr/\x{a3}5/, 'pound sign kept';
like $story, qr/\{\{braces\}/, 'braces escaped';
unlike $story, qr/Related link|Continue reading/, 'related links dropped';

$out->child('news-bad')->make_path->child('140 index.txt')->spew("old\n");
run($conf, $out);
is $out->child('news-bad', '140 index.txt')->slurp, "old\n", 'failed section keeps previous pages';

$conf->spew("130 Bad $bad\n");
ok !eval { run($conf, $out); 1 }, 'all feeds failing is an error';
ok -e $out->child('news-good', '131 story.txt'), 'and leaves the previous run in place';

subtest clean => sub {
  is clean("  a\tb \n c "), 'a b c', 'whitespace collapsed';
  is clean("\x{201C}Na\x{ef}ve\x{201D} \x{2013} \x{2026}"), '"Naive" - ...', 'punctuation and accents';
  is clean("\x{a3}9 \x{20ac}9"), "\x{a3}9 EUR 9", 'currency';
  is clean("\x{4e2d}x"), 'x', 'unmappable dropped';
};

subtest wrap => sub {
  is_deeply [ wrap('aa bb cc', 5) ], ['aa bb', 'cc'], 'breaks between words';
  is_deeply [ wrap('abcdefgh', 4) ], ['abcd'], 'long word cut';
  is_deeply [ wrap('', 5) ], [], 'nothing to wrap';
  ok !(grep { length > 38 } wrap(join ' ', ('word') x 40)), '38 cells by default';
};

subtest read_conf => sub {
  my $file = $dir->child('conf');
  $file->spew("# comment\n\n130 Local news https://a/x https://b/y\n");
  my ($contents, $sections) = read_conf($file);
  is_deeply $contents, { num => '199', title => 'News' }, 'default contents page';
  is_deeply $sections->[0]{urls}, ['https://a/x', 'https://b/y'], 'urls';
  is $sections->[0]{title}, 'Local news', 'title';
  is $sections->[0]{contents}, '199', 'linked to contents';
  $file->spew("135 Odd https://a/x\n");
  ok !eval { read_conf($file) }, 'page must end in 0';
  $file->spew("120 Only contents\n");
  ok !eval { read_conf($file) }, 'needs a section';
};

subtest 'parse_feed atom' => sub {
  my ($item) = parse_feed(<<'XML');
<?xml version="1.0"?>
<feed xmlns="http://www.w3.org/2005/Atom"><title>Atom &amp; Co</title>
<entry><title type="html">A &lt;b&gt;bold&lt;/b&gt; claim</title>
<summary type="html">&lt;p&gt;One&lt;/p&gt;&lt;p&gt;Two&lt;/p&gt;</summary></entry>
<entry><title></title></entry></feed>
XML
  is $item->{source}, 'Atom & Co', 'feed title';
  is $item->{title}, 'A bold claim', 'html title reduced to text';
  is_deeply $item->{paras}, ['One', 'Two'], 'paragraphs';
  is scalar parse_feed('<rss><channel></channel></rss>'), 0, 'empty feed';
};

subtest index_page => sub {
  my $sec  = { num => 140, title => 'World', colour => 'red', contents => 120 };
  my $page = index_page($sec, [ { title => 'Short' }, { title => 'x ' x 40 } ], 141, 'Today');
  like $page, qr/^\{white\} Short {29}\{yellow\}141$/m, 'number on the first row';
  like $page, qr/^\{white\} [x ]+\.\.\.$/m, 'overflow cut with ...';
  like $page, qr/Contents 120$/, 'links to contents';
};

done_testing;

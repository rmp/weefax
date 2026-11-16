use Mojo::Base -strict, -signatures;
use Test::More;
use Mojo::File qw(tempdir);
use Weefax qw(pad40 sextant_byte txt_line decode_edittf mk_delay name_delay
              parse_txt parse_tti load_file scan);

my $blank = ' ' x 40;

subtest pad40 => sub {
  is pad40(undef), $blank, 'undef is a blank row';
  is pad40('abc'), 'abc' . ' ' x 37, 'short row padded';
  is pad40('x' x 50), 'x' x 40, 'long row cut';
};

subtest sextant_byte => sub {
  is sextant_byte(0x1FB00), 0x21, 'first sextant is top-left';
  is sextant_byte(0x1FB13), 0x34, 'last before the left-column gap';
  is sextant_byte(0x1FB14), 0x36, 'skips 21, the left column';
  is sextant_byte(0x1FB3B), 0x7E, 'last sextant';
  is sextant_byte(0x258C),  0x35, 'left half block';
  is sextant_byte(0x2590),  0x6A, 'right half block';
  is sextant_byte(0x2588),  0x7F, 'full block';
  is sextant_byte(ord 'A'), undef, 'not a sextant';
};

subtest txt_line => sub {
  is txt_line('{red}A'), pad40("\x01A"), 'colour code';
  is txt_line('{RED}A'), pad40("\x01A"), 'codes ignore case';
  is txt_line('{{red}'), pad40('{red}'), 'escaped brace';
  is txt_line('{x1F}{x9F}'), pad40("\x1F\x1F"), 'hex codes keep 7 bits';
  is txt_line("\x{a3}5"), pad40('#5'), 'pound sign is 0x23';
  is txt_line("caf\x{e9}"), pad40('caf '), 'other non-ASCII is a space';
  is txt_line("{gred}\x{1FB00}"), pad40("\x11\x21"), 'sextant becomes mosaic';
  is txt_line('y' x 45), 'y' x 40, 'cut at 40 cells';
  ok !eval { txt_line('{bogus}'); 1 }, 'unknown code dies';
  like $@, qr/unknown code \{bogus\}/, 'and names it';
};

# edit.tf packs 25 rows of 40 seven-bit characters into base64url.
sub edittf (@rows) {
  my @a    = ('A'..'Z', 'a'..'z', 0..9, '-', '_');
  my $bits = join '', map { sprintf '%07b', ord } split //, join '', map { pad40($_) } @rows;
  $bits .= '0' x (-length($bits) % 6);
  return join '', map { $a[oct "0b$_"] } unpack '(a6)*', $bits;
}

subtest decode_edittf => sub {
  my $rows = decode_edittf(edittf('', "\x01HELLO", 'row two'));
  is scalar @$rows, 25, '25 rows';
  is $rows->[1], pad40("\x01HELLO"), 'row 1';
  is $rows->[2], pad40('row two'), 'row 2';
  my @warnings;
  local $SIG{__WARN__} = sub { push @warnings, @_ };
  $rows = decode_edittf('QUJD');
  is $rows->[24], $blank, 'short hash pads with blanks';
  is_deeply \@warnings, [], 'without warnings';
};

subtest delays => sub {
  is_deeply mk_delay(8, ''),    { n => 8,   unit => 's' }, 'seconds by default';
  is_deeply mk_delay(3, 'C'),   { n => 3,   unit => 'c' }, 'cycles';
  is_deeply mk_delay('1.5', 's'), { n => 1.5, unit => 's' }, 'fractional';
  is mk_delay(0, 's'),     undef, 'zero is no delay';
  is mk_delay(undef, 's'), undef, 'missing is no delay';
  is_deeply name_delay('400@8'),     { n => 8, unit => 's' }, 'folder delay';
  is_deeply name_delay('2@3c.txt'),  { n => 3, unit => 'c' }, 'file delay in cycles';
  is name_delay('plain.txt'), undef, 'no delay';
  is name_delay('a@8x.txt'),  undef, 'delay must end the token';
};

subtest parse_txt => sub {
  my $d = mk_delay(12, 's');
  my @s = parse_txt("one\n\@delay 6\n\@screen 4\ntwo\n\@screen\n{red}three\n", $d);
  is scalar @s, 3, 'three screens';
  is_deeply [ map { $_->{delay}{n} } @s ], [6, 4, 6], '@delay carries on, @screen N is local';
  is scalar @{ $s[0]{rows} }, 25, '25 rows';
  is $s[0]{rows}[0], $blank, 'row 0 left for the header';
  is $s[0]{rows}[1], pad40('one'), 'first line is row 1';
  is $s[2]{rows}[1], pad40("\x01three"), 'codes decoded';
  is scalar parse_txt("\@screen\n\@screen\n", $d), 0, 'empty screens dropped';

  my ($tf) = parse_txt('https://edit.tf/#0:' . edittf('', 'drawn'), $d);
  is $tf->{rows}[1], pad40('drawn'), 'edit.tf URL decoded';
};

subtest parse_tti => sub {
  my $d   = mk_delay(12, 's');
  my $tti = join "\n", 'DE,test', 'PN,10000', 'CT,8,T', "OL,1,\x1BAred", 'OL,0,header',
                       'OL,25,beyond', 'PN,10001', 'CT,2,C', "OL,3,\x81high";
  my @s = parse_tti($tti, $d);
  is scalar @s, 2, 'one screen per PN';
  is_deeply $s[0]{delay}, { n => 8, unit => 's' }, 'CT seconds';
  is_deeply $s[1]{delay}, { n => 2, unit => 'c' }, 'CT cycles';
  is $s[0]{rows}[1], pad40("\x01red"), 'ESC code';
  is $s[0]{rows}[0], $blank, 'row 0 ignored';
  is $s[1]{rows}[3], pad40("\x01high"), 'high-bit code';
  is_deeply [ parse_tti("OL,1,x\n", $d) ]->[0]{delay}, $d, 'no PN: one screen, inherited delay';
};

subtest 'load_file and scan' => sub {
  my $dir = tempdir;
  $dir->child('100 index.txt')->spew("index\n");
  $dir->child('1A0.txt')->spew("hex\n");
  $dir->child('notes.txt')->spew("not a page\n");
  $dir->child('news')->make_path->child('101 story.txt')->spew("story\n");
  $dir->child('news', '102.tti')->spew("PN,10200\nOL,1,tti\n");
  my $folder = $dir->child('200@5')->make_path;
  $folder->child("$_.txt")->spew("screen $_\n") for 10, 2;
  $dir->child('.hidden')->make_path->child('300.txt')->spew("hidden\n");
  $dir->child('400 bad.txt')->spew("{bogus}\n");

  is +(load_file($dir->child('news', '102.tti'), undef))[0]{rows}[1], pad40('tti'), 'load_file reads .tti';

  my @warnings;
  local $SIG{__WARN__} = sub { push @warnings, @_ };
  my $pages = scan($dir, mk_delay(12, 's'));
  is_deeply [ sort keys %$pages ], [qw(100 101 102 1A0 200)], 'numbered files and folders only';
  is scalar @{ $pages->{200} }, 2, 'folder files are screens of one page';
  is_deeply [ map { $_->{rows}[1] } @{ $pages->{200} } ], [ pad40('screen 2'), pad40('screen 10') ],
    'in natural order';
  is $pages->{200}[0]{delay}{n}, 5, 'folder delay applies';
  is $pages->{100}[0]{delay}{n}, 12, 'default delay applies';
  is scalar @warnings, 1, 'one warning';
  like $warnings[0], qr/skipping .*400 bad\.txt/, 'for the bad file';
  is_deeply scan($dir->child('missing'), undef), {}, 'missing folder is empty';
};

done_testing;

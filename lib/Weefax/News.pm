package Weefax::News;
use Mojo::Base -strict, -signatures;
use Exporter qw(import);
use Mojo::DOM;
use Mojo::File qw(path);
use Mojo::UserAgent;
use Mojo::Util qw(decode);
use POSIX qw(strftime);
use Unicode::Normalize qw(NFD);

our $VERSION   = '0.01';
our @EXPORT_OK = qw(run read_conf parse_feed clean wrap story_page index_page contents_page);

my $WIDTH   = 38;   # text cells after a colour code and a space
my $BODY    = 19;   # rows 3-21 of a story screen
my $SCREENS = 4;
my @COLOURS = qw(red blue magenta green);   # bars that yellow and white read on

my %ASCII = (
  "\x{2018}" => "'", "\x{2019}" => "'", "\x{201A}" => "'", "\x{2032}" => "'",
  "\x{201C}" => '"', "\x{201D}" => '"', "\x{201E}" => '"', "\x{2033}" => '"',
  "\x{2013}" => '-', "\x{2014}" => '-', "\x{2015}" => '-', "\x{2212}" => '-',
  "\x{2026}" => '...', "\x{2022}" => '*', "\x{00D7}" => 'x', "\x{00A0}" => ' ',
  "\x{00BD}" => '1/2', "\x{00BC}" => '1/4', "\x{00BE}" => '3/4', "\x{20AC}" => 'EUR ',
);

sub clean ($s) {
  $s =~ s{([^\x00-\x7F])}{$ASCII{$1} // $1}ge;
  $s = NFD($s) =~ s/\p{Mn}//gr;
  $s =~ s/[^\x20-\x7E\x{A3}]/ /g;
  return $s =~ s/\s+/ /gr =~ s/^ | $//gr;
}

sub _esc ($s) { return $s =~ s/\{/{{/gr }

sub wrap ($s, $width = $WIDTH) {
  my (@lines, $line);
  for my $w (split / /, $s) {
    $w = substr($w, 0, $width) if length $w > $width;
    if (defined $line && length($line) + 1 + length($w) <= $width) { $line .= " $w" }
    else { push @lines, $line if defined $line; $line = $w }
  }
  push @lines, $line if defined $line;
  return @lines;
}

sub _shorten ($s, $width) {
  return $s if length $s <= $width;
  my ($first) = wrap($s, $width);
  return $first;
}

sub _leader ($text, $num, $colour) {
  my $t = _shorten($text, 32);
  return "{$colour} " . _esc($t) . ('.' x (34 - length $t)) . "{yellow}$num";
}

# Paragraphs from a feed's summary, which may hold escaped HTML.
sub _paragraphs ($html) {
  my $dom = Mojo::DOM->new($html);
  my @p = $dom->find('p')->grep(sub { !$_->ancestors('li')->size })->map('all_text')->each;
  @p = ($dom->all_text) unless @p;
  return grep { length && !/^continue reading/i } map { clean($_) } @p;
}

sub _text_at ($node, $selector) {
  my $hit = $node->at($selector);
  return $hit ? clean($hit->all_text) : '';
}

sub parse_feed ($xml) {
  my $dom    = Mojo::DOM->new->xml(1)->parse($xml);
  my $source = _text_at($dom, 'channel > title, feed > title');
  my @items;
  for my $e ($dom->find('item, entry')->each) {
    my $node  = $e->at('title');
    my $title = !$node                          ? ''
              : ($node->attr('type') // '') eq 'html' ? clean(Mojo::DOM->new($node->text)->all_text)
              :                                   clean($node->all_text);
    next unless length $title;
    my $sum = $e->at('description, summary, content');
    push @items, {
      title  => $title,
      paras  => [ $sum ? _paragraphs($sum->text) : () ],
      source => $source,
    };
  }
  return @items;
}

sub _fetch ($ua, $url) {
  for my $try (1 .. 3) {
    sleep 5 * ($try - 1);
    my $res = eval { $ua->get($url)->result };
    return decode('UTF-8', $res->body) // $res->body if $res && $res->is_success;
    warn "$url: ", ($res ? 'HTTP ' . $res->code . "\n" : $@);
    return if $res && $res->code < 500;
  }
  return;
}

sub _fetch_items ($ua, @urls) {
  my @lists;
  for my $url (@urls) {
    my $xml = _fetch($ua, $url) // next;
    my @items = eval { parse_feed($xml) };
    warn "$url: $@" if $@;
    warn "$url: no items\n" unless @items;
    push @lists, \@items if @items;
  }
  my (%seen, @mixed);
  while (grep {@$_} @lists) {
    for my $l (@lists) {
      my $i = shift @$l // next;
      push @mixed, $i unless $seen{ lc $i->{title} }++;
    }
  }
  return @mixed;
}

sub _header ($colour, $title) { return "{$colour}{newbg}{white}{double} " . _esc(_shorten($title, 35)) }

sub _footer ($colour, $left, $right) { return "{$colour}{newbg}{yellow} $left {white} $right" }

sub _screen (@rows) {
  $#rows = 21 if @rows > 22;
  push @rows, '' while @rows < 22;
  return @rows;
}

sub story_page ($sec, $item, $num, $next) {
  my @text = map { "{yellow} " . _esc($_) } wrap($item->{title});
  for my $p (@{ $item->{paras} }) {
    push @text, '', map { "{white} " . _esc($_) } wrap($p);
  }
  my @screens;
  while (@text && @screens < $SCREENS) {
    my @chunk = splice @text, 0, $BODY;
    shift @chunk while @chunk && $chunk[0] eq '';
    push @screens, \@chunk if @chunk;
  }
  my ($n, @lines) = (scalar @screens);
  for my $i (0 .. $#screens) {
    my $title = $n > 1 ? sprintf('%-28s%d/%d', _shorten($sec->{title}, 27), $i + 1, $n) : $sec->{title};
    push @lines, '@screen' if $i;
    push @lines, _screen(_header($sec->{colour}, $title), '', @{ $screens[$i] }),
      '{cyan} ' . _esc(_shorten($item->{source}, $WIDTH)),
      _footer($sec->{colour}, "Next $next", "Index $sec->{num}");
  }
  return join "\n", @lines;
}

# Two rows per headline: the page number on the first, the rest of the
# headline on the second, cut with ... if it still does not fit.
sub _headline_rows ($title, $num) {
  my ($first, @rest) = wrap($title, 34);
  my $more = join ' ', @rest;
  $more = _shorten($more, 31) . '...' if length $more > 34;
  return ('{white} ' . _esc($first) . (' ' x (34 - length $first)) . "{yellow}$num",
          '{white} ' . _esc($more));
}

sub index_page ($sec, $items, $next, $date) {
  my @rows = (_header($sec->{colour}, $sec->{title}), '', "{cyan} $date", '');
  my $i = 0;
  push @rows, map { _headline_rows($_->{title}, $sec->{num} + ++$i) } @$items;
  return join "\n", _screen(@rows), "{cyan} Updated " . strftime('%H:%M', localtime),
    _footer($sec->{colour}, "Next $next", "Contents $sec->{contents}");
}

sub contents_page ($num, $title, $sections, $date) {
  my @rows = (_header('blue', $title), '', "{cyan} $date", '');
  push @rows, map { (_leader($_->{title}, $_->{num}, 'cyan'), '') } @$sections;
  return join "\n", _screen(@rows), '{cyan} Headlines from free public feeds',
    _footer('blue', "Next $sections->[0]{num}", 'Index 100');
}

# "NUM Title words URL URL..."; a line without URLs names the contents page.
sub read_conf ($file) {
  my ($contents, @sections);
  for (split /\n/, path($file)->slurp) {
    next if /^\s*(#|$)/;
    my ($num, @words) = split ' ';
    die "$file: bad page number '$num'\n" unless $num =~ /^[1-8][0-9]0$/;
    my @urls  = grep { m{^https?://} } @words;
    my $title = join ' ', grep { !m{^https?://} } @words;
    if (@urls) { push @sections, { num => $num, title => $title, urls => \@urls } }
    else       { $contents = { num => $num, title => $title } }
  }
  die "$file: no sections\n" unless @sections;
  $contents //= { num => '199', title => 'News' };
  my $i = 0;
  for (@sections) { $_->{colour} = $COLOURS[ $i++ % @COLOURS ]; $_->{contents} = $contents->{num} }
  return ($contents, \@sections);
}

sub _write_page ($dir, $num, $name, $text) {
  return $dir->child("$num $name.txt")->spew("$text\n", 'UTF-8');
}

# Not starting with a digit, or weefax.pl would merge its files into one page.
sub _folder ($sec) { return 'news-' . lc($sec->{title} =~ s/\W+/-/gr) }

sub run ($conf, $out = undef) {
  $out = path($out // path($ENV{MODE7_PAGES} // 'pages')->child('daily'));
  my ($contents, $sections) = read_conf($conf);
  my $ua = Mojo::UserAgent->new(connect_timeout => 10, request_timeout => 30, max_redirects => 3);
  $ua->transactor->name('weefax-news/1.0');

  $_->{items} = [ grep { $_ } (_fetch_items($ua, @{ $_->{urls} }))[0 .. 8] ] for @$sections;
  my $fresh = grep { @{ $_->{items} } } @$sections;
  die "every feed failed; previous pages left in place\n" unless $fresh;

  my $new  = $out->sibling('.' . $out->basename . '-new')->remove_tree->make_path;
  my $date = strftime('%A %e %B %Y', localtime) =~ s/  / /r;
  for my $s (0 .. $#$sections) {
    my $sec   = $sections->[$s];
    my $items = $sec->{items};
    my $dir   = $new->child(_folder($sec));
    if (!@$items) {
      warn "$sec->{title}: no items, keeping previous pages\n";
      my $prev = $out->child(_folder($sec));
      $prev->move_to($dir) if -d $prev;
      next;
    }
    my $after = $s < $#$sections ? $sections->[ $s + 1 ]{num} : $contents->{num};
    $dir->make_path;
    _write_page($dir, $sec->{num}, 'index', index_page($sec, $items, $sec->{num} + 1, $date));
    for my $i (0 .. $#$items) {
      my $num  = $sec->{num} + $i + 1;
      my $next = $i == $#$items ? $after : $num + 1;
      _write_page($dir, $num, 'story', story_page($sec, $items->[$i], $num, $next));
    }
  }
  _write_page($new, $contents->{num}, 'contents', contents_page($contents->{num}, $contents->{title}, $sections, $date));

  my $old = $out->sibling('.' . $out->basename . '-old')->remove_tree;
  $out->move_to($old) if -e $out;
  $new->move_to($out);
  $old->remove_tree;
  return say "$fresh of ${\ scalar @$sections} sections updated in $out";
}

1;

__END__

=encoding utf8

=head1 NAME

Weefax::News - build weefax news pages from RSS and Atom feeds

=head1 VERSION

0.01

=head1 SYNOPSIS

  use Weefax::News qw(run);
  run('news.conf', 'pages/daily');

=head1 DESCRIPTION

Fetches the feeds named in a configuration file and writes C<.txt> pages for
C<weefax.pl>: a contents page, and for each section an index page and up to
nine stories. A section whose feeds all fail keeps its previous pages; a run
where every feed fails changes nothing. Output is built in a hidden sibling
folder, which C<weefax.pl> ignores, and swapped in when complete.

=head1 CONFIGURATION

One section per line: a page number ending in 0, a title, then one or more
feed URLs. The line with no URLs names the contents page. Blank lines and
lines starting with C<#> are ignored.

  120 Today's news
  140 World news  https://feeds.bbci.co.uk/news/world/rss.xml

=head1 FUNCTIONS

=head2 run

Builds the pages. Takes the configuration file and the output folder, which
defaults to F<daily> under C<$ENV{MODE7_PAGES}> or F<pages>. Dies if every
feed fails.

=head2 read_conf

Parses a configuration file into the contents page and a list of sections.

=head2 parse_feed

Returns the stories in an RSS or Atom document: title, summary paragraphs
and source name, cleaned for teletext.

=head2 clean

Reduces text to the characters teletext can show: typographic punctuation
becomes ASCII, accents are dropped and whitespace is collapsed.

=head2 wrap

Word-wraps text to a width, 38 cells by default.

=head2 story_page

Renders one story as C<.txt>, rotating over up to four screens.

=head2 index_page

Renders a section's index of headlines as C<.txt>.

=head2 contents_page

Renders the contents page listing every section as C<.txt>.

=head1 AUTHOR

Roger Pettett <rmp@psyphi.net>

=head1 LICENSE

This library is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut

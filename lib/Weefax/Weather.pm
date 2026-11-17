package Weefax::Weather;
use Mojo::Base -strict, -signatures;
use Exporter qw(import);
use Mojo::DOM;
use Mojo::File qw(path);
use Mojo::URL;
use Mojo::UserAgent;
use POSIX qw(strftime);
use Weefax::News qw(clean story_page);

our $VERSION   = '0.01';
our @EXPORT_OK = qw(run parse_uk parse_region uk_page regions_page);

my $UK     = 'https://weather.metoffice.gov.uk/forecast/uk';
my $COLOUR = 'green';
my $FIRST  = 400;

sub _text ($node) { return $node ? clean($node->all_text =~ s/\s*\x{B0}//gr) : '' }

sub _sections ($dom, $selector) {
  return [ map { [ _text($_->at('h3, h4')) =~ s/:$//r, _text($_->at('p')) ] } $dom->find($selector)->each ];
}

sub _updated ($dom) { return _text($dom->at('.updated')) =~ s/^Updated: //r }

sub parse_uk ($html, $base = $UK) {
  my $dom = Mojo::DOM->new($html);
  my %seen;
  return {
    cities => [ map { {
      name    => _text($_->at('.location-name')),
      weather => clean($_->at('img') ? $_->at('img')->attr('alt') // '' : ''),
      temp    => $_->at('.temp') ? $_->at('.temp')->attr('data-value') : undef,
    } } $dom->find('a.national-forecast-link')->each ],
    sections => _sections($dom, '#tab-content-d1 .tab-content-paragraph, #tab-content-d2 .tab-content-paragraph'),
    regions  => [ grep { !$seen{ $_->{url} }++ } map { { name => _text($_), url => Mojo::URL->new($_->attr('href'))->to_abs(Mojo::URL->new($base))->to_string } }
                  $dom->find('a[href*="forecast/regional/"]')->each ],
    updated  => _updated($dom),
  };
}

sub parse_region ($html) {
  my $dom = Mojo::DOM->new($html);
  return { sections => _sections($dom, '#fiveDayText .forecast-text-section'), updated => _updated($dom) };
}

sub _forecast ($title, $num, $next, $forecast) {
  my ($headline, @rest) = @{ $forecast->{sections} };
  ($headline, @rest) = (['', ''], $headline, @rest) unless $headline && $headline->[0] eq 'Headline';
  my $sec = { title => $title, colour => $COLOUR, num => $FIRST + 1 };
  return story_page($sec, {
    title  => $headline->[1],
    paras  => [ map { "$_->[0]: $_->[1]" } @rest ],
    source => "Met Office $forecast->{updated}",
  }, $num, $next);
}

sub uk_page ($uk, $date) {
  my @rows = (Weefax::News::_header($COLOUR, 'UK weather'), '', "{cyan} $date", '');
  push @rows, map {
    sprintf '{white} %-13s{cyan}%-18s{yellow}%s', substr($_->{name}, 0, 12), substr($_->{weather}, 0, 17),
      defined $_->{temp} ? sprintf('%3dC', $_->{temp}) : ''
  } @{ $uk->{cities} };
  return join "\n", Weefax::News::_screen(@rows), '{cyan} ' . Weefax::News::_shorten("Met Office $uk->{updated}", 38),
    Weefax::News::_footer($COLOUR, 'Next 401', 'Index 100'),
    '@screen', _forecast('UK weather', $FIRST, $FIRST + 1, { %$uk, sections => [ grep {$_} @{ $uk->{sections} }[ 0 .. 2 ] ] });
}

sub regions_page ($regions, $date) {
  my $i = 0;
  my @rows = (Weefax::News::_header($COLOUR, 'Regional weather'), '', "{cyan} $date", '',
              map { Weefax::News::_leader($_->{name}, $FIRST + 2 + $i++, 'cyan') } @$regions);
  return join "\n", Weefax::News::_screen(@rows), '{cyan} Forecasts from the Met Office',
    Weefax::News::_footer($COLOUR, 'Next ' . ($FIRST + 2), "UK $FIRST");
}

sub _slug ($name) { return lc($name =~ s/\W+/-/gr =~ s/^-|-$//gr) }

sub _write ($dir, $num, $name, $text) { return $dir->child("$num $name.txt")->spew("$text\n", 'UTF-8') }

sub run ($out = undef, $url = $UK) {
  $out = path($out // path($ENV{MODE7_PAGES} // 'pages')->child('weather'));
  my $ua = Mojo::UserAgent->new(connect_timeout => 10, request_timeout => 30, max_redirects => 3);
  $ua->transactor->name('weefax-weather/1.0 (https://github.com/rmp/weefax)');

  my $html = Weefax::News::_fetch($ua, $url) // die "UK forecast failed; previous pages left in place\n";
  my $uk   = parse_uk($html, $url);
  die "UK forecast unreadable; previous pages left in place\n" unless @{ $uk->{sections} };

  my $new  = $out->sibling('.' . $out->basename . '-new')->remove_tree->make_path;
  my $date = strftime('%A %e %B %Y', localtime) =~ s/  / /r;
  _write($new, $FIRST, 'uk', uk_page($uk, $date));
  _write($new, $FIRST + 1, 'regions', regions_page($uk->{regions}, $date));
  my $fresh = 0;
  for my $i (0 .. $#{ $uk->{regions} }) {
    my ($region, $num) = ($uk->{regions}[$i], $FIRST + 2 + $i);
    my $name     = "$num " . _slug($region->{name}) . '.txt';
    my $forecast = parse_region(Weefax::News::_fetch($ua, $region->{url}) // '');
    if (!@{ $forecast->{sections} }) {
      warn "$region->{name}: no forecast, keeping previous page\n";
      $out->child($name)->copy_to($new->child($name)) if -e $out->child($name);
      next;
    }
    my $next = $i == $#{ $uk->{regions} } ? $FIRST : $num + 1;
    _write($new, $num, _slug($region->{name}), _forecast($region->{name}, $num, $next, $forecast));
    $fresh++;
  }

  my $old = $out->sibling('.' . $out->basename . '-old')->remove_tree;
  $out->move_to($old) if -e $out;
  $new->move_to($out);
  $old->remove_tree;
  return say "UK and $fresh of ${\ scalar @{ $uk->{regions} }} regions updated in $out";
}

1;

__END__

=encoding utf8

=head1 NAME

Weefax::Weather - build weefax weather pages from Met Office forecasts

=head1 VERSION

0.01

=head1 SYNOPSIS

  use Weefax::Weather qw(run);
  run('pages/weather');

=head1 DESCRIPTION

Reads the Met Office's UK and regional text forecasts and writes C<.txt>
pages for C<weefax.pl>: 400, UK city temperatures then the national
forecast; 401, an index of regions; and from 402 one page per region. A
region that fails keeps its previous page; a failed UK forecast changes
nothing. Output is built in a hidden sibling folder and swapped in.

=head1 FUNCTIONS

=head2 run

Builds the pages. Takes the output folder, which defaults to F<weather> under
C<$ENV{MODE7_PAGES}> or F<pages>, and the UK forecast URL. Dies if the UK
forecast cannot be read.

=head2 parse_uk

Returns the cities, national forecast sections, regions and update time from
the Met Office UK forecast page, with region links resolved against the
optional base URL.

=head2 parse_region

Returns the forecast sections and update time from a Met Office regional
forecast page.

=head2 uk_page

Renders page 400 as C<.txt>: city temperatures, then the national forecast.

=head2 regions_page

Renders the index of regional forecasts as C<.txt>.

=head1 AUTHOR

Roger Pettett <rmp@psyphi.net>

=head1 LICENSE

This library is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut

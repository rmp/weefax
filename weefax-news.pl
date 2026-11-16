#!/usr/bin/env perl
# weefax-news - builds news pages for weefax.pl from free RSS and Atom feeds.
#
#   ./weefax-news.pl [news.conf] [output folder]
#
# Each section gets an index page at its number and up to nine stories after
# it. A section whose feeds all fail keeps yesterday's pages. Output is built
# in a hidden folder beside the target, which weefax.pl ignores, then swapped
# in, so the carousel never sees half a run.
#
use FindBin;
use lib "$FindBin::Bin/lib";
use Mojo::Base -strict;
use Weefax::News qw(run);

run($ARGV[0] // "$FindBin::Bin/news.conf", $ARGV[1]);

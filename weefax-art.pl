#!/usr/bin/env perl
# weefax-art - builds an artwork of the day page for weefax.pl from a random
# public-domain painting at the Met, drawn in teletext mosaics.
#
#   ./weefax-art.pl [--page 600] [--out pages/art] [--aspect 0.8-2.5]
#
# --aspect limits the width/height ratio of the paintings picked.
#
use FindBin;
use lib "$FindBin::Bin/lib";
use Mojo::Base -strict;
use Getopt::Long;
use Weefax::Art qw(run);

GetOptions(\my %opt, 'page=s', 'out=s', 'aspect=s') or die "usage: $0 [--page N] [--out DIR] [--aspect MIN-MAX]\n";
run(%opt);

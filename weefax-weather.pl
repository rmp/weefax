#!/usr/bin/env perl
# weefax-weather - builds weather pages for weefax.pl from the Met Office's
# UK and regional text forecasts.
#
#   ./weefax-weather.pl [output folder]
#
# Page 400 is the UK, 401 an index of regions, 402 onwards the regions. A
# region that fails keeps its previous page. Output is built in a hidden
# folder beside the target, then swapped in.
#
use FindBin;
use lib "$FindBin::Bin/lib";
use Mojo::Base -strict;
use Weefax::Weather qw(run);

run($ARGV[0]);

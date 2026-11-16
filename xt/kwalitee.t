use strict;
use warnings;
use Test::More;

# Run from a built distribution (make distdir): META.yml and MANIFEST exist only there.
use Test::Kwalitee 1.21 qw(kwalitee_ok);

kwalitee_ok();
done_testing;

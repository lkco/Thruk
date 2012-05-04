use strict;
use warnings;
use Data::Dumper;
use Test::More;

plan skip_all => 'internal test only' if defined $ENV{'CATALYST_SERVER'};
plan tests => 240;

BEGIN {
    use lib('t');
    require TestUtils;
    import TestUtils;
}
use_ok 'Thruk::Controller::error';

$ENV{'TEST_ERROR'} = 1;
for(0..23) {
    my $nr = $_;
    my $test = {
        'url'     => '/error/'.$nr,
        'fail'    => 1,
    };
    if($nr == 13) {
        $test->{'unlike'} = ['ARRAY', 'HASH'];
    }
    TestUtils::test_page(%{$test});
}

delete $ENV{'TEST_ERROR'};
use Test::More;
use Test::Deep;
use Test::Exception;

use strict;
use warnings;
use lib 't/lib';
use Search::Elasticsearch::Bulk;
use Log::Any::Adapter;

my $es   = do "es_sync.pl";
my $TRUE = $es->transport->serializer->decode('{"true":true}')->{true};

my $is_0_90 = $es->info->{version}{number} =~ /^0.90/;

$es->indices->delete( index => '_all' );

my @Std = (
    { id => 1, source => { count => 1 } },
    { id => 1, source => { count => 'foo' } },
    { id => 1, version => 10, source => {} },
);

my ( $b, $success_count, $error_count, $custom_count, $conflict_count );

# Cxn error - to not clear buffers

## Default error handling
$b = bulk( { index => 'test', type => 'test' }, @Std );
test_flush( "Default", 0, 2, 0, 0 );

## Custom error handling
$b = bulk(
    {   index    => 'test',
        type     => 'test',
        on_error => sub { $custom_count++ }
    },
    @Std
);
test_flush( "Custom error", 0, 0, 2, 0 );

# Conflict errors
$b = bulk(
    {   index       => 'test',
        type        => 'test',
        on_conflict => sub { $conflict_count++ }
    },
    @Std
);
test_flush( "Conflict error", 0, 1, 0, 1 );

# Both error handling
$b = bulk(
    {   index       => 'test',
        type        => 'test',
        on_conflict => sub { $conflict_count++ },
        on_error    => sub { $custom_count++ }
    },
    @Std
);

test_flush( "Conflict and custom", 0, 0, 1, 1 );

# Conflict disable error
$b = bulk(
    {   index       => 'test',
        type        => 'test',
        on_conflict => sub { $conflict_count++ },
        on_error    => undef
    },
    @Std
);

test_flush( "Conflict, error undef", 0, 0, 0, 1 );

# Disable both
$b = bulk(
    {   index       => 'test',
        type        => 'test',
        on_conflict => undef,
        on_error    => undef
    },
    @Std
);

test_flush( "Both undef", 0, 0, 0, 0 );

# Success
$b = bulk(
    {   index      => 'test',
        type       => 'test',
        on_success => sub { $success_count++ },
    },
    @Std
);

test_flush( "Success", 1, 2, 0, 0 );

# cbs have correct params
$b = bulk(
    {   index      => 'test',
        type       => 'test',
        on_success => test_params(
            'on_success',
            {   _index   => 'test',
                _type    => 'test',
                _id      => 1,
                _version => 1,
                status   => 201,
                ok       => $TRUE,
            },
            0
        ),
        on_error => test_params(
            'on_error',
            {   _index => 'test',
                _type  => 'test',
                _id    => 1,
                error  => re('MapperParsingException'),
                status => 400,
            },
            1
        ),
        on_conflict => test_params(
            'on_conflict',
            {   _index => 'test',
                _type  => 'test',
                _id    => 1,
                error  => re('VersionConflictEngineException'),
                status => 409,
            },
            2, 1
        ),
    },
    @Std
);
$b->flush;

done_testing;

$es->indices->delete( index => 'test' );

#===================================
sub bulk {
#===================================
    my $params = shift;
    my $b      = Search::Elasticsearch::Bulk->new(
        es => $es,
        %$params,
    );

    $es->indices->delete( index => 'test', ignore => 404 );
    $es->indices->create( index => 'test' );
    $es->cluster->health( wait_for_status => 'yellow' );
    $b->index(@_);
    return $b;
}

#===================================
sub test_flush {
#===================================
    my ( $title, $success, $default, $custom, $conflict ) = @_;
    $success_count = $custom_count = $error_count = $conflict_count = 0;
    {
        local $SIG{__WARN__} = sub { $error_count++ };
        $b->flush;
    }
    is $success_count,  $success,  "$title - success";
    is $error_count,    $default,  "$title - default";
    is $custom_count,   $custom,   "$title - custom";
    is $conflict_count, $conflict, "$title - conflict";

}

#===================================
sub test_params {
#===================================
    my ( $type, $result, $j, $version ) = @_;
    delete $result->{ok}
        unless $is_0_90;

    return sub {
        is $_[0], 'index', "$type - action";
        cmp_deeply $_[1], subhashof($result), "$type - result";
        is $_[2], $j,       "$type - array index";
        is $_[3], $version, "$type - version";
    };
}

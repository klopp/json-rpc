#!/usr/bin/perl
# ------------------------------------------------------------------------------
#  Created on: 10.12.2015, 18:20:58
#  Author: Vsevolod Lutovinov <kloppspb@bk.ru>
# ------------------------------------------------------------------------------
use open qw/:std :utf8/;
use Modern::Perl;
use Carp;
use English qw/-no_match_vars/;
use Try::Catch;
use Const::Fast;
use Data::Printer sort_keys => 1;

# ------------------------------------------------------------------------------
use DBI;
use JSON;
use FindBin qw/$RealScript $RealBin/;
use HTTP::Status qw/:constants/;
use Mojo::Server::Prefork;

# ------------------------------------------------------------------------------
use vars qw/$pg $pgstmt $opt $daemon/;
const my $PG_SELECT       => 'SELECT * FROM %s(%s)';
const my $JSON_RPC_VER    => '2.0';
const my $JSON_RPC_SERVER => 'JSON-RPC test server v0.01';
const my $ERR_BAD_JSON    => -32_700;
const my $ERR_BAD_REQUEST => -32_600;
const my $ERR_BAD_METHOD  => -32_601;
const my $ERR_DB_ERROR    => -32_001;

# ------------------------------------------------------------------------------
END {
    undef $pgstmt;
    $pg->disconnect() if $pg;
}

# ------------------------------------------------------------------------------
_get_config_data();
_pg_connect( $opt->{'pg'} );
_create_daemon($opt);

$daemon->on(
    'request' => sub {
        my ( $parent, $tx ) = @_;

# Для использования в caller, если захочется выводить в лог,
# например. См. http://x.ato.su/d/snippets/lang/perl/anon
# В данном случае получим 'Mojo::EventEmitter::emit(request)'
        local *__ANON__ = ( caller(1) )[3] . '(request)';

        my $path = $tx->req->url->path->to_string;

       # А не надо было given в experimental запихивать...
        if ( $path eq '/source' ) {

            # Просто выводим свой исходник:
            my $body;
            if ( open my $file, q{<}, $RealBin . q{/} . $RealScript ) {
                local $INPUT_RECORD_SEPARATOR = undef;
                $body = <$file>;
                close $file;
                $tx->res->code(HTTP_OK);
            }
            else {
                $body = "Can not open \"$RealScript\": $OS_ERROR";
                $tx->res->code(HTTP_INTERNAL_SERVER_ERROR);
            }
            $tx->res->headers->content_type('text/plain;charset=UTF-8');
            $tx->res->headers->content_length( length $body );
            $tx->res->body($body);
        }
        elsif ( $path eq '/json' ) {

            # Основная точка входа:
            $tx->res->code( _json_rpc( $parent, $tx ) );
        }
        elsif ( $path eq '/abs' ) {

            # test case 1:
            $tx->res->code(
                _json_rpc(
                    $parent,
                    $tx,
                    '{"jsonrpc": "2.0", "method": "abs", "params": [1], "id": 1}'
                )
            );
        }
        elsif ( $path eq '/text_le' ) {

            # test case 2:
            $tx->res->code(
                _json_rpc(
                    $parent,
                    $tx,
                    '{"jsonrpc": "2.0", "method": "text_le", "params": ["aaa", "bbb"], "id": 1}'
                )
            );
        }
        elsif ( $path eq '/text_ge' ) {

            # test case 3:
            $tx->res->code(
                _json_rpc(
                    $parent,
                    $tx,
                    '{"jsonrpc": "2.0", "method": "text_ge", "params": ["aaa", "bbb"], "id": 1}'
                )
            );
        }
        else {
            $tx->res->code(HTTP_NOT_FOUND);
        }
        $tx->resume;
    }
);
$daemon->run();

# ------------------------------------------------------------------------------
sub _pg_connect {
    my ($pgopt) = @_;

    # Явно укажем имя для блоков try/catch:
    local *__ANON__ = ( caller(0) )[3];
    try {
        $pg
            = DBI->connect(
            "dbi:Pg:dbname=$pgopt->{dbname};host=$pgopt->{dbhost};port=$pgopt->{dbport}",
            $pgopt->{dbuser}, $pgopt->{dbpass}, $pgopt->{options} );
    }
    catch {
        confess "Pg connection error: $_";
    };

    return $pg;
}

# ------------------------------------------------------------------------------
sub _create_daemon {
    my ($opt) = @_;

    $daemon = Mojo::Server::Prefork->new(
        'listen' => $opt->{'daemon'}->{'listen'} );

    # Без особых изысков:
    $daemon->workers( $opt->{'daemon'}->{'children'} );
    $daemon->silent(1);
    $daemon->accepts(0);
    $daemon->inactivity_timeout(0);

    return $daemon;
}

# ------------------------------------------------------------------------------
sub _get_config_data {

    my $config = $RealScript;
    $config =~ s/[.][^.]+$//;
    $config = $ARGV[0] || $RealBin . q{/} . $config . '.conf';

    $opt = do $config;
    confess 'Invalid config data!' unless $opt;
    return $opt;
}

# ------------------------------------------------------------------------------
sub _json_rpc {
    my ( $parent, $tx, $rq ) = @_;

    $tx->res->headers->content_type('text/plain;charset=UTF-8');

    my $request = $rq ? $rq : $tx->req->param('request');

    my $json;
    my $error;
    my $rc     = HTTP_OK;
    my $answer = {
        jsonrpc => $JSON_RPC_VER,
        server  => $JSON_RPC_SERVER,

# id в любом случае укажем явно, пусть будет null по умолчанию:
        id => undef,
    };

    # Явно укажем имя для блоков try/catch:
    local *__ANON__ = ( caller(0) )[3];

    if ($rq) {
        try {
            $json = decode_json($request);
        }
        catch {
            $error = {
                code    => $ERR_BAD_JSON,
                message => "Can not decode JSON request: $_"
            };
        };
    }
    else {
        $error = {
            code    => $ERR_BAD_REQUEST,
            message => 'No request!'
        };
    }
    unless ($error) {
        $error = {
            code    => $ERR_BAD_REQUEST,
            message => 'Invalid JSON-RPC version!'
            }
            if !$json->{jsonrpc} || $json->{jsonrpc} ne $JSON_RPC_VER;
    }
    unless ($error) {
        $error = {
            code    => $ERR_BAD_REQUEST,
            message => 'No \"id\" parameter in request!'
            }
            unless $json->{id};
    }
    unless ($error) {
        $error = {
            code    => $ERR_BAD_METHOD,
            message => 'No \"method\" parameter in request!'
            }
            unless $json->{method};
    }
    unless ($error) {

# Не самый шустрый вариант, надо бы массив методов в хэш переделат
# при разборе конфига. Ну да ладно...
        $error = {
            code    => $ERR_BAD_METHOD,
            message => "Method \"$json->{method}\" is not allowed!"
            }
            unless grep { $json->{method} eq $_ } @{ $opt->{pg}->{methods} };
    }

    if ($error) {
        $answer->{error} = $error;
        $rc = HTTP_BAD_REQUEST;
    }
    else {
        try {
          # Получаем что-то вроде: 'SELECT * FROM method(?,?)'
            my $callstr = sprintf $PG_SELECT, $json->{method},
                join( q{,}, map {q{?}} @{ $json->{'params'} } );

            $pgstmt = $pg->prepare($callstr);
            $pgstmt->execute( @{ $json->{'params'} } );
            my $data = $pg->selectall_arrayref( $pgstmt, { Slice => {} } );

            $answer->{result} = $data;

# А вот тут переносим в ответ id из запроса, если ошибок нет:
            $answer->{id} = $json->{id};
        }
        catch {
            $answer->{error} = {
                code    => $ERR_DB_ERROR,
                message => "Database error: $_"
            };
            $rc = HTTP_INTERNAL_SERVER_ERROR;
        };
    }
    undef $pgstmt;

    $answer
        = encode_json($answer)
        . "\n\nDebug, IN:\n\n"
        . p( $json, return_value => 'dump' )
        . "\n\nDebug, OUT:\n\n"
        . p( $answer, return_value => 'dump' )
        . "\n\nHTTP code: $rc";

    $tx->res->headers->content_length( length $answer );
    $tx->res->body($answer);

    return $rc;
}

# ------------------------------------------------------------------------------

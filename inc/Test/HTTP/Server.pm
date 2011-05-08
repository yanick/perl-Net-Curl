package Test::HTTP::Server;
#
use strict;
use warnings;
use IO::Socket;
use POSIX ":sys_wait_h";

sub _open_socket
{
	my $port = $ENV{HTTP_PORT} || $$;
	foreach ( 0..100 ) {
		my $socket = IO::Socket::INET->new(
			Proto => 'tcp',
			LocalPort => $port,
			Listen => 5,
			Reuse => 1,
			Blocking => 1,
		);
		return ( $port, $socket ) if $socket;
		$port = 1024 + int rand 63 * 1024;
	}
}

sub new
{
	my $class = shift;

	my ( $port, $socket ) = _open_socket()
		or die "Could not start HTTP server\n";

	my $pid = fork;
	die "Could not fork\n"
		unless defined $pid;
	if ( $pid ) {
		my $self = { port => $port, pid => $pid };
		return bless $self, $class;
	} else {
		$SIG{CHLD} = \&_sigchld;
		HTTP::Server::_main_loop( $socket, @_ );
		exec "true";
		die "Should not be here\n";
	}
}

sub uri
{
	my $self = shift;
	return "http://localhost:$self->{port}/";
}

sub _sigchld
{
	my $kid;
	do {
		$kid = waitpid -1, WNOHANG;
	} while ( $kid > 0 );
}

sub DESTROY
{
	my $self = shift;
	my $done = 0;
	local $SIG{CHLD} = \&_sigchld;
	my $cnt = kill 15, $self->{pid};
	return unless $cnt;
	foreach my $sig ( 15, 15, 15, 9, 9, 9 ) {
		$cnt = kill $sig, $self->{pid};
		last unless $cnt;
		select undef, undef, undef, 0.1;
	}
}

package HTTP::Server;

sub _term
{
	exec "true";
	die "Should not be here\n";
}

sub _main_loop
{
	my $socket = shift;
	$SIG{TERM} = \&_term;

	for (;;) {
		my $client = $socket->accept()
			or redo;
		my $pid = fork;
		die "Could not fork\n" unless defined $pid;
		if ( $pid ) {
			close $client;
		} else {
			HTTP::Server::Request->open( $client, @_ );
			_term();
		}
	}
}

package HTTP::Server::Connection;

use constant {
	DNAME => [qw(Sun Mon Tue Wed Thu Fri Sat)],
	MNAME => [qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)],
};

sub _http_time
{
	my $self = shift;
	my @t = gmtime( shift || time );
	return sprintf '%s, %02d %s %04d %02d:%02d:%02d GMT',
		DNAME->[ $t[6] ], $t[3], MNAME->[ $t[4] ], 1900+$t[5],
		$t[2], $t[1], $t[0];
}

sub open
{
	my $class = shift;
	my $socket = shift;

	open STDOUT, '>&', $socket;
	open STDIN, '<&', $socket;

	my $self = {
		version => "1.0",
		@_,
		socket => $socket,
	};
	bless $self, $class;
	$self->process;
}

sub process
{
	my $self = shift;
	$self->in_all;
	$self->out_all;
	close STDIN;
	close STDOUT;
	close $self->{socket};
}

sub in_all
{
	my $self = shift;
	$self->{request} = $self->in_request;
	$self->{headers} = $self->in_headers;

	if ( $self->{request}->[0] =~ /^(?:POST|PUT)/ ) {
		$self->{body} = $self->in_body;
	} else {
		delete $self->{body};
	}
}

sub in_request
{
	local $/ = "\r\n";
	$_ = <STDIN>;
	chomp;
	return [ split /\s+/, $_ ];
}

sub in_headers
{
	local $/ = "\r\n";
	my @headers;
	while ( <STDIN> ) {
		chomp;
		last unless length $_;
		s/(\S+):\s*//;
		my $header = $1;
		$header =~ tr/-/_/;
		push @headers, ( lc $header, $_ );
	}

	return \@headers;
}

sub in_body
{
	my $self = shift;
	my %headers = @{ $self->{headers} };

	$_ = "";
	my $len = $headers{content_length};
	$len = 10 * 1024 * 1024 unless defined $len;

	read STDIN, $_, $len;
	return $_;
}

sub out_response
{
	my $self = shift;
	my $code = shift;
	print "HTTP/$self->{version} $code\r\n";
}

sub out_headers
{
	my $self = shift;
	while ( my ( $name, $value ) = splice @_, 0, 2 ) {
		$name = join "-", map { ucfirst lc $_ } split /[_-]+/, $name;
		print "$name: $value\r\n";
	}
}

sub out_body
{
	my $self = shift;
	my $body = shift;

	use bytes;
	my $len = length $body;
	print "Content-Length: $len\r\n";
	print "\r\n";
	print $body;
}

sub out_all
{
	my $self = shift;

	my %default_headers = (
		content_type => "text/plain",
		date => $self->_http_time,
	);
	$self->{out_headers} = { %default_headers };

	my $func = $self->{request}->[1];
	$func =~ s#^/+##;
	$func =~ s#/.*##;
	$func = "index" unless length $func;

	my $body;
	eval {
		$body = $self->$func();
	};
	if ( $@ ) {
		warn "Server error: $@\n";
		$self->out_response( "404 Not Found" );
		$self->out_headers(
			%default_headers
		);
		$self->out_body(
			"Server error: $@\n"
		);
	} elsif ( defined $body ) {
		$self->out_response( $self->{out_code} || "200 OK" );
		$self->out_headers( %{ $self->{out_headers} } );
		$self->out_body( $body );
	}
}

sub index
{
	my $self = shift;
	my $body = "Available functions:\n";
	$body .= ( join "", map "- $_\n", sort { $a cmp $b}
		grep { not __PACKAGE__->can( $_ ) }
		grep { HTTP::Server::Request->can( $_ ) }
		keys %{HTTP::Server::Request::} )
		|| "NONE\n";
	return $body;
};

package HTTP::Server::Request;
our @ISA = qw(HTTP::Server::Connection);

1;

__END__

=head1 NAME

Test::HTTPServer - simple forking http server

=head1 SYNOPSIS

 my $server = Test::HTTPServer->new();

 client_get( $server->uri );

=head1 DESCRIPTION

This package provices a simple forking http server which can be used for
testing http clients.

=cut

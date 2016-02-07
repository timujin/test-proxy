use strict;
use warnings;
use AnyEvent::Socket;
use AnyEvent::Handle;
use Data::Dumper; 

sub http_connect($$) {
	my %s = %{$_[0]};
	my $chdl = $_[1];
	my %r;
	tcp_connect $s{host}, "http", sub {
		my ($fh) = @_
		or die "unable to connect: $!";

		my $hdl; $hdl = new AnyEvent::Handle
			fh     => $fh,
			on_error => sub {warn "Unhandled error(s)! " . Dumper(@_) },
			on_eof => sub {
				$hdl->destroy;
				$chdl->destroy;
				#warn "----RESPONSE FINISH----";
			};

		$hdl->push_write ("$s{method} $s{path} HTTP/1.1\015\012");
		#warn "-----REQUEST START-----";
		#warn ("$s{method} $s{path} HTTP/1.1\015\012");

		for (keys %{$s{headers}}) {
			$hdl->push_write ("$_: $s{headers}{$_}\015\012");
			#warn "$_: $s{headers}{$_}\015\012";
		}
		$hdl->push_write("\015\012");

		if ($s{method} eq "POST") {
			$chdl->on_read(sub {
				$hdl->push_write($_[0]->rbuf);
				$_[0]->rbuf = "";
			});
		}
		#warn("\015\012");
		#warn "-----REQUEST FINISH----";

		#warn "-----RESPONSE START----";
		$hdl->push_read (line => "\015\012\015\012", sub {
			my ($hdl, $line) = @_;
			$chdl->push_write("$line\015\012\015\012");
			#warn ("$line\015\012\015\012");
			$hdl->on_read (sub {
				$chdl->push_write($_[0]->rbuf);
				#warn ($_[0]->rbuf);
				$_[0]->rbuf = "";
			});
		});
	}
};

sub _400_bad_request($) {
	my ($chdl) = @_;
	my $body = <<"EOF";
<!DOCTYPE HTML PUBLIC "-//IETF//DTD HTML 2.0//EN">
<html>

<head>
   <title>400 Bad Request</title>
</head>

<body>
   <h1>Bad Request</h1>
   <p>Your browser sent a request that this server could not understand.<p>
   <p>The request line contained invalid characters following the protocol string.<p>
</body>

</html>
EOF
	my $headers = <<"EOF";
HTTP/1.1 400 Bad Request
Content-Type: text/html;
Connection: Closed
Content-Length: 230
EOF
	$chdl->push_write("$headers\r\n$body\r\n");
	#$chdl->destroy;
}

sub CONNECT($$) {
	my %s = %{$_[0]};
	my $chdl = $_[1];

	tcp_connect $s{host}, 443, sub {
		my ($fh) = @_
		or die "unable to connect: $!";

		my $hdl; $hdl = new AnyEvent::Handle
			fh     => $fh,
			on_error => sub {warn "Unhandled error(s)! " . Dumper(@_) };

		$chdl->push_write("200 OK\015\012");

		$hdl->on_read(sub { 
			my $self = @_;
			$chdl->push_write($_[0]->rbuf);
			$_[0]->rbuf = "";
		});
		$chdl->on_read(sub {
			my $self = @_;
			$hdl->push_write($_[0]->rbuf);
			$_[0]->rbuf = "";
		});
	}
}

tcp_server '127.0.0.1', '7777', sub {
	my ($fh, $host, $port) = @_;
	#warn "Connect from $host:$port\n";
	my %s;
	$fh = AnyEvent::Handle->new(
		fh => $fh,
		on_error => sub { warn "Unhandled error(s)! " . Dumper(@_) }
	);
	$fh->push_read(regex => "\r\n\r\n", sub {
		my ($self, $rbuf) = @_;
		($s{start_line}, $s{headers}) = split "\r\n", $rbuf, 2;
		unless ($s{start_line} =~ m{^(?<method>GET|POST|CONNECT) (?<path>[^ ]+) (?<proto>HTTP/1\.[01])$}) {
			#warn$s{start_line};
			#warn "400 Bad Request";
			_400_bad_request($fh);
			$fh->destroy;
			return;
		}
		delete $s{start_line};
		$s{$_} = $+{$_} for (qw{method path proto});
		my @h = split "\r\n", $s{headers};
		$s{headers} = {};
		for (@h) {
			unless(m{(?<name>[a-zA-Z0-9-]+): *(?<value>.*)}) {
				#warn $_;
				#warn "400 Bad Request";
				_400_bad_request($fh);
				$fh->destroy;
				return;
			}
			$s{headers}{$+{name}} = $+{value};
		}
		if ($s{method} eq "CONNECT") {
			unless ($s{path} =~ "^(?<host>[0-9a-zA-z-\.]+):443") {
				##warn $s{path};
				#warn "400 Bad Request";
				_400_bad_request($fh);
				$fh->destroy;
				return;
			}
			$s{host} = $+{host};
			#warn Dumper \%s;
			CONNECT(\%s, $fh);
			return
		}

		if ($s{headers}{'Connection'}) { $s{headers}{'Connection'} = "close";}
		unless ($s{path} =~ "http:\/\/(?<host>[0-9a-zA-z-\.]+)(?<path>\/.*)") {
			#warn $s{path};
			#warn "400 Bad Request";
			_400_bad_request($fh);
			$fh->destroy;
			return;
		}

		#if ($s{method} eq "POST") {
		#	$fh->on_read(sub { $s{client_body} .= $_[0]->rbuf; $_[0]->rbuf="";});
		#}

		($s{host}, $s{path}) = ($+{host}, $+{path});
		#warn Dumper \%s;
		http_connect(\%s, $fh);
	});
};


AnyEvent->condvar->recv;

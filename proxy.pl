use strict;
use warnings;
use AnyEvent::Socket;
use AnyEvent::Handle;
use Data::Dumper; 

mkdir "proxy_logs";

my $print_bodies = 0;

sub new_log_file() {
	# A new file for every connection, because, with the server being asynchronous, data from several connections would mix
	my $filename = "proxy_logs/" . localtime();
	my $collision = 0;
	while (-e $filename . (" #$collision" or "")) {
		$collision += 1;
	}
	open (my $fh, '>', $filename . (" #$collision" or ""));
	return $fh;
}

sub http_connect($$$) {
	my %s = %{$_[0]};
	my $chdl = $_[1];
	my $log = $_[2];
	tcp_connect $s{host}, "http", sub {
		my ($fh) = @_ or print $log "Could not connect to server" and return;
		print $log "Connecting to server $s{host}...\n";
		my $hdl; $hdl = new AnyEvent::Handle
			fh     => $fh,
			on_error => sub {print $log  "Unhandled error(s)! " . Dumper(@_) },
			on_eof => sub {
				$hdl->destroy;
				$chdl->destroy;
				print $log  "----RESPONSE FINISH----\n";
			};

		$hdl->push_write ("$s{method} $s{path} HTTP/1.1\015\012");
		print $log "-----REQUEST START-----\n";
		print $log  ("$s{method} $s{path} HTTP/1.1\015\012");

		for (keys %{$s{headers}}) {
			$hdl->push_write ("$_: $s{headers}{$_}\015\012");
			print $log "$_: $s{headers}{$_}\015\012";
		}
		$hdl->push_write("\015\012");
		print $log ("\015\012");

		if ($s{method} eq "POST") {
			$chdl->on_read(sub {
				# if the client body is big, it may mess up ordering of data in the logs; not in the actual sockets, however.
				$hdl->push_write($_[0]->rbuf);
				if ($print_bodies) {print $log $_[0]->rbuf};
				$_[0]->rbuf = "";
			});
		}
		print $log  "-----REQUEST FINISH----\n";

		print $log  "-----RESPONSE START----\n";
		$hdl->push_read (line => "\015\012\015\012", sub {
			my ($hdl, $line) = @_;
			$chdl->push_write("$line\015\012\015\012");
			print $log ("$line\015\012\015\012");
			$hdl->on_read (sub {
				$chdl->push_write($_[0]->rbuf);
				if ($print_bodies) {print $log ($_[0]->rbuf)};
				$_[0]->rbuf = "";
			});
		});
	}
};

sub _400_bad_request($$) {
	my ($chdl, $log) = @_;
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
	print $log ("$headers\r\n$body\r\n");
}

sub CONNECT($$$) {
	my %s = %{$_[0]};
	my $chdl = $_[1];
	my $log = $_[2];

	tcp_connect $s{host}, 443, sub {
		my ($fh) = @_  or print $log "Could not connect to server" and return;
		print $log "Connecting to server $s{host}...\n";

		my $hdl; $hdl = new AnyEvent::Handle
			fh     => $fh,
			on_error => sub {print $log "Unhandled error(s)! " . Dumper(@_) };

		$chdl->push_write("200 OK\015\012");
		print $log "200 OK\015\012";
		print $log "Streaming data back and forth...";
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
	my $log = new_log_file();
	print $log "Connect from $host:$port\n";
	my %s;
	$fh = AnyEvent::Handle->new(
		fh => $fh,
		on_error => sub { print $log "Unhandled error(s)! " . Dumper(@_) }
	);
	$fh->push_read(regex => "\r\n\r\n", sub {
		my ($self, $rbuf) = @_;
		($s{start_line}, $s{headers}) = split "\r\n", $rbuf, 2;
		unless ($s{start_line} =~ m{^(?<method>GET|POST|CONNECT) (?<path>[^ ]+) (?<proto>HTTP/1\.[01])$}) {
			print $log $s{start_line};
			_400_bad_request($fh, $log);
			$fh->destroy;
			return;
		}
		delete $s{start_line};
		$s{$_} = $+{$_} for (qw{method path proto});
		my @h = split "\r\n", $s{headers};
		$s{headers} = {};
		for (@h) {
			unless(m{(?<name>[a-zA-Z0-9-]+): *(?<value>.*)}) {
				print $log  $_;
				_400_bad_request($fh, $log);
				$fh->destroy;
				return;
			}
			$s{headers}{$+{name}} = $+{value};
		}
		if ($s{method} eq "CONNECT") {
			unless ($s{path} =~ "^(?<host>[0-9a-zA-z-\.]+):443") {
				print $log $s{path};
				_400_bad_request($fh, $log);
				$fh->destroy;
				return;
			}
			$s{host} = $+{host};
			print $log Dumper \%s;
			CONNECT(\%s, $fh, $log);
			return
		}

		if ($s{headers}{'Connection'}) { $s{headers}{'Connection'} = "close";}
		unless ($s{path} =~ "http:\/\/(?<host>[0-9a-zA-z-\.]+)(?<path>\/.*)") {
			print $log $s{path};
			_400_bad_request($fh, $log);
			$fh->destroy;
			return;
		}

		($s{host}, $s{path}) = ($+{host}, $+{path});
		print $log "\n";
		print $log Dumper \%s;
		http_connect(\%s, $fh, $log);
	});
};


AnyEvent->condvar->recv;

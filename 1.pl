use Time::HiRes qw(time);

$t = time;

$s = 99999999;

while ($s) {
	$s -= 1;
}

print time - $t;

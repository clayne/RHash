package Crypt::Rhash;

use 5.006001;
use strict;
use warnings;

require Exporter;
our @ISA = (qw(Exporter));

# possible tags for export
our %EXPORT_TAGS = (
	Functions => [qw(raw2hex raw2base32 raw2base64)],
	Constants => [qw(RHASH_CRC32 RHASH_CRC32C RHASH_MD4 RHASH_MD5
		RHASH_SHA1 RHASH_TIGER RHASH_TTH RHASH_BTIH RHASH_ED2K
		RHASH_AICH RHASH_WHIRLPOOL RHASH_RIPEMD160 RHASH_GOST94
		RHASH_GOST94_CRYPTOPRO RHASH_GOST12_256 RHASH_GOST12_512
		RHASH_SHA224 RHASH_SHA256 RHASH_SHA384 RHASH_SHA512
		RHASH_SHA3_224 RHASH_SHA3_256 RHASH_SHA3_384 RHASH_SHA3_512
		RHASH_BLAKE2S RHASH_BLAKE2B RHASH_EDONR256 RHASH_EDONR512
		RHASH_HAS160 RHASH_SNEFRU128 RHASH_SNEFRU256 RHASH_ALL)]
);

Exporter::export_tags( );
Exporter::export_ok_tags( qw(Functions Constants) );

our $VERSION = '1.05';

require XSLoader;
XSLoader::load('Crypt::Rhash', $VERSION);

##############################################################################
# identifiers of hash functions
use constant RHASH_CRC32 => 0x01;
use constant RHASH_MD4   => 0x02;
use constant RHASH_MD5   => 0x04;
use constant RHASH_SHA1  => 0x08;
use constant RHASH_TIGER => 0x10;
use constant RHASH_TTH   => 0x20;
use constant RHASH_BTIH  => 0x40;
use constant RHASH_ED2K  => 0x80;
use constant RHASH_AICH  => 0x100;
use constant RHASH_WHIRLPOOL => 0x200;
use constant RHASH_RIPEMD160 => 0x400;
use constant RHASH_GOST94    => 0x800;
use constant RHASH_GOST94_CRYPTOPRO => 0x1000;
use constant RHASH_HAS160    => 0x2000;
use constant RHASH_GOST12_256 => 0x4000;
use constant RHASH_GOST12_512 => 0x8000;
use constant RHASH_SHA224    => 0x10000;
use constant RHASH_SHA256    => 0x20000;
use constant RHASH_SHA384    => 0x40000;
use constant RHASH_SHA512    => 0x80000;
use constant RHASH_EDONR256  => 0x100000;
use constant RHASH_EDONR512  => 0x200000;
use constant RHASH_SHA3_224  => 0x0400000;
use constant RHASH_SHA3_256  => 0x0800000;
use constant RHASH_SHA3_384  => 0x1000000;
use constant RHASH_SHA3_512  => 0x2000000;
use constant RHASH_CRC32C    => 0x4000000;
use constant RHASH_SNEFRU128 => 0x8000000;
use constant RHASH_SNEFRU256 => 0x10000000;
use constant RHASH_BLAKE2S   => 0x20000000;
use constant RHASH_BLAKE2B   => 0x40000000;
use constant RHASH_ALL       => 0x7FFFFFFF;

##############################################################################
# Rhash class methods

# Rhash object constructor
sub new($$@)
{
	my ($class, @hash_ids) = @_;

	# validate @hash_ids to be an array of hash identifiers
	scalar(@_) > 0 or die "hash_id not specified\n";
	for my $id (@hash_ids) {
		if (ref($id) || !scalar($id) || (scalar($id) & RHASH_ALL) != $id) {
			die "bad hash_id = " . scalar($id) . " " . ref($id) . "\n";
		}
	}
	# handle legacy initialization by a single bitmask
	if (scalar(@hash_ids) == 1 && ($hash_ids[0] & ($hash_ids[0] - 1)) != 0) {
		# Split the bit mask into the array of single bits
		for (my $mask = shift(@hash_ids); $mask; $mask = $mask & ($mask - 1)) {
			push(@hash_ids, $mask & -$mask);
		}
	}
	my $context = rhash_init_multi_wrapper(\@hash_ids) or return undef;
	my $self = {
		context => $context,
	};
	return bless $self, $class;
}

# destructor
sub DESTROY($)
{
	my $self = shift;
	# the 'if' added as workaround for perl 'global destruction' bug
	# ($self->{context} can disappear on global destruction)
	rhash_free($self->{context}) if $self->{context};
}

sub update($$)
{
	my $self = shift;
	my $message = shift;
	rhash_update($self->{context}, $message);
	return $self;
}

sub update_fd($$;$$)
{
	my ($self, $fd, $start, $size) = @_;
	my $res = 0;
	my $num = 0;

	binmode($fd);
	if(defined($start)) {
		seek($fd, scalar($start), 0) or return undef;
	}

	my $data;
	if(defined($size)) {
		for(my $left = scalar($size); $left > 0; $left -= 8192) {
			($res = read($fd, $data,
				($left < 8192 ? $left : 8192))) || last;
			rhash_update($self->{context}, $data);
			$num += $res;
		}
	} else {
		while( ($res = read($fd, $data, 8192)) ) {
			rhash_update($self->{context}, $data);
			$num += $res;
		}
	}

	return (defined($res) ? $num : undef); # return undef on read error
}

sub update_file($$;$$)
{
	my ($self, $file, $start, $size) = @_;
	open(my $fd, "<", $file) or return undef;
	my $res = $self->update_fd($fd, $start, $size);
	close($fd);
	return $res;
}

sub final($)
{
	my $self = shift;
	rhash_final($self->{context});
	return $self;
}

sub reset($)
{
	my $self = shift;
	rhash_reset($self->{context});
	return $self;
}

sub hashed_length($)
{
	my $self = shift;
	return rhash_get_hashed_length($self->{context});
}

sub hash_id($)
{
	my $self = shift;
	return rhash_get_hash_id($self->{context});
}

##############################################################################
# Message digest formatting functions

# printing constants
use constant RHPR_DEFAULT   => 0x0;
use constant RHPR_RAW       => 0x1;
use constant RHPR_HEX       => 0x2;
use constant RHPR_BASE32    => 0x3;
use constant RHPR_BASE64    => 0x4;
use constant RHPR_UPPERCASE => 0x8;
use constant RHPR_REVERSE   => 0x10;

sub hash($;$$)
{
	my $self = shift;
	my $hash_id = scalar(shift) || 0;
	my $print_flags = scalar(shift) || RHPR_DEFAULT;
	return rhash_print_wrapper($self->{context}, $hash_id, $print_flags);
}

sub hash_base32($;$)
{
	hash($_[0], $_[1], RHPR_BASE32);
}

sub hash_base64($;$)
{
	hash($_[0], $_[1], RHPR_BASE64);
}

sub hash_hex($;$)
{
	hash($_[0], $_[1], RHPR_HEX);
}

sub hash_rhex($;$)
{
	hash($_[0], $_[1], RHPR_HEX | RHPR_REVERSE);
}

sub hash_raw($;$)
{
	hash($_[0], $_[1], RHPR_RAW);
}

sub magnet_link($;$@)
{
	my ($self, $filename, @hash_ids) = @_;
	my $hash_mask = 0;
	if (scalar(@hash_ids)) {
		for my $id (@hash_ids) {
			if (ref($id) || !scalar($id) || (scalar($id) & RHASH_ALL) != $id) {
				die "bad hash_id = " . scalar($id) . " " . ref($id) . "\n";
			}
			$hash_mask = $hash_mask | scalar($id);
		}
	} else {
		$hash_mask = undef;
	}
	return rhash_print_magnet_wrapper($self->{context}, $filename, $hash_mask);
}

our $AUTOLOAD;

# report error if a script called unexisting method/field
sub AUTOLOAD
{
	my ($self, $field, $type, $pkg) = ($_[0], $AUTOLOAD, undef, __PACKAGE__);
	$field =~ s/.*://;
	die "function $field does not exist\n" if $field =~ /^(rhash_|raw2)/;
	die "no arguments specified to $field()\n" if !@_;
	die "the $field() argument is undefined\n" if !defined $self;

	($type = ref($self)) && $type eq $pkg || die "the $field() argument is not a $pkg reference\n";
	my $text = (exists $self->{$field} ? "is not accessible" : "does not exist");
	die "the method $field() $text in the class $pkg\n";
}

# static functions

sub msg($$)
{
	my ($hash_id, $msg) = @_;
	my $raw = rhash_msg_wrapper($hash_id, $msg); # get a binary message digest
	return (is_base32($hash_id) ? raw2base32($raw) : raw2hex($raw));
}

1;
__END__
# Below is Rhash module documentation in the standard POD format

=head1 NAME

Crypt::Rhash - Compute message digests and magnet links

=head1 SYNOPSIS

  use Crypt::Rhash;
  my $msg = "a message text";
  print "MD5 = " . Crypt::Rhash::msg(RHASH_MD5, $msg) . "\n";

or

  use Crypt::Rhash;
  my $filepath = "/tmp/file.txt";
  # Calculate two hash functions simultaneously
  my $r = Crypt::Rhash->new(RHASH_SHA1, RHASH_SHA512);
  $res = $r->update_file($filepath);
  defined($res) or die "failed to read $filepath: $!\n";
  print "SHA1   = " . $r->hash(RHASH_SHA1) . "\n";
  print "SHA512 = " . $r->hash(RHASH_SHA512) . "\n";

=head1 DESCRIPTION

Crypt::Rhash module is an object-oriented interface to LibRHash library,
allowing simultaneous calculation of several hash functions for a file or a
text message.

Calculated message digest can be obtained in hexadecimal, BASE32, BASE64, raw
binary format or as a magnet link.

=head1 SUPPORTED ALGORITHMS

The module supports the following hash functions:
CRC32, CRC32C, MD4, MD5, SHA1, SHA256, SHA512, SHA3, AICH, ED2K, Tiger,
DC++ TTH, GOST R 34.11-94, GOST R 34.11-2012, BitTorrent BTIH, RIPEMD-160,
HAS-160, BLAKE2s/BLAKE2b, EDON-R 256/512, Whirlpool and Snefru-128/256.

=head1 CONSTRUCTOR

Creates and returns new Crypt::Rhash object.

  my $r = Crypt::Rhash->new($hash_id1, $hash_id2, ...);
  my $p = new Crypt::Rhash($hash_id1, ...); # alternative way to call the constructor

Constructor accepts the following constants as arguments:

  RHASH_CRC32,
  RHASH_CRC32C,
  RHASH_MD4,
  RHASH_MD5,
  RHASH_SHA1,
  RHASH_TIGER,
  RHASH_TTH,
  RHASH_BTIH,
  RHASH_ED2K,
  RHASH_AICH,
  RHASH_WHIRLPOOL,
  RHASH_RIPEMD160,
  RHASH_GOST94,
  RHASH_GOST94_CRYPTOPRO,
  RHASH_GOST12_256,
  RHASH_GOST12_512
  RHASH_HAS160,
  RHASH_SHA224,
  RHASH_SHA256,
  RHASH_SHA384,
  RHASH_SHA512,
  RHASH_SHA3_224,
  RHASH_SHA3_256,
  RHASH_SHA3_384,
  RHASH_SHA3_512,
  RHASH_EDONR256,
  RHASH_EDONR512,
  RHASH_SNEFRU128,
  RHASH_SNEFRU256,
  RHASH_BLAKE2S,
  RHASH_BLAKE2B,
  RHASH_ALL

The RHASH_ALL bit mask is bitwise union of all listed above bit-flags.
An object created as Crypt::Rhash->new(RHASH_ALL) calculates all
supported hash functions for the same data.

=head1 COMPUTING MESSAGE DIGESTS

=over

=item $rhash->update( $msg )

Calculates message digests of the $msg string.
The method can be called repeatedly with chunks of the message to be hashed.
It returns the $rhash object itself allowing the following construction:

  $rhash = Crypt::Rhash->new(RHASH_MD5)->update( $chunk1 )->update( $chunk2 );

=item $rhash->update_file( $file_path, $start, $size )

=item $rhash->update_fd( $fd, $start, $size )

Calculate a message digest of the file (or its part) specified by $file_path or a file descriptor $fd.
The update_fd method doesn't close the $fd, leaving the file position after the hashed block.
The optional $start and $size specify the block of the file to process. If $start is undefined,
then the file is read from the start. If $size is undefined, then the file is read till the end.
No error is reported if the $size is greater than the number of the unread bytes left in the file.

Returns the number of characters actually read, 0 at the end of file,
or undef if there was an error (in the latter case $! is also set).

  use Crypt::Rhash;
  my $r = new Crypt::Rhash(RHASH_SHA1);
  open(my $fd, "<", "input.txt") or die "cannot open < input.txt: $!\n";
  while ((my $n = $r->update_fd($fd, undef, 1024) != 0)) {
      print "$n bytes hashed. The SHA1 is " . $r->final()->hash() . "\n";
      $r->reset();
  }
  defined($n) or die "read error for input.txt: $!\n";
  close($fd);

=item $rhash->final()

Finishes calculation for all data buffered by updating methods and stops
message digest calculation.  The function is called automatically by any
of the $rhash->hash*() methods if the final() call was skipped.

=item $rhash->reset()

Resets the $rhash object to the initial state.

=item $rhash->hashed_length()

Returns the total length of the hashed message.

=item $rhash->hash_id()

Returns the hash mask, the $rhash object was constructed with.

=back

=head1 FORMATTING MESSAGE DIGEST

Computed message digest can be formatted as a hexadecimal string (in the forward or
reverse byte order), a base32/base64-encoded string or as raw binary data.

=over

=item $rhash->hash( $hash_id )

Returns the message digest in the default format,
which can be hexadecimal or base32. Actually the method is equivalent of

  (Crypt::Rhash::is_base32($hash_id) ? $rhash->hash_base32($hash_id) :
    $rhash->hash_hex($hash_id))

If the optional $hash_id parameter is omitted or zero, then the method returns
the message digest for the algorithm contained in $rhash with the lowest identifier.

=item $rhash->hash_hex( $hash_id )

Returns the specified message digest in the hexadecimal format.

  use Crypt::Rhash;
  my $msg = "abc";
  print "MD5 = " . Crypt::Rhash->new(RHASH_MD5)->update($msg)->hash_hex() . "\n";

=item $rhash->hash_rhex( $hash_id )

Returns the specified message digest in the hexadecimal format with reversed order of bytes.
Some programs prefer to output the GOST R 34.11-94 message digest in this format.

=item $rhash->hash_base32( $hash_id )

Returns the specified message digest in the base32 format.

=item $rhash->hash_base64( $hash_id )

Returns the specified message digest in the base64 format.

=item $rhash->magnet_link( $filename, $hash_mask )

Returns the magnet link containing the computed message digests, filesize,
and, optionaly, $filename. The $filename (if specified) is URL-encoded,
by converting special characters into the %<hexadecimal-code> form.
The optional parameter $hash_mask can limit which message digests to put
into the link.

=back

=head1 STATIC METHODS

=over

=item Crypt::Rhash::count()

Returns the number of supported hash functions

=item Crypt::Rhash::is_base32($hash_id)

Returns nonzero if default output format is Base32 for the hash function specified by $hash_id.
Returns zero if default format is hexadecimal.

=item Crypt::Rhash::get_digest_size($hash_id)

Returns the size in bytes of raw binary message digest of the specified hash function.

=item Crypt::Rhash::get_hash_length($hash_id)

Returns the length of a message digest in default output format for the specified hash function.

=item Crypt::Rhash::get_name($hash_id)

Returns the name of the specified hash function.

=item Crypt::Rhash::librhash_version_string()

Returns the version of LibRHash as string.

=back

=head1 ALTERNATIVE WAY TO COMPUTE A MESSAGE DIGEST

=over

=item Crypt::Rhash::msg($hash_id, $message)

Computes and returns a single message digest (in its default format) of the $message by the selected hash function.

  use Crypt::Rhash;
  print "SHA1( 'abc' ) = " . Crypt::Rhash::msg(RHASH_SHA1, "abc") . "\n";

=back

=head1 LICENSE

                           BSD Zero Clause License

Copyright (c) 2011, Aleksey Kravchenko

Permission to use, copy, modify, and/or distribute this software for any
purpose with or without fee is hereby granted.

THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES WITH
REGARD TO THIS SOFTWARE  INCLUDING ALL IMPLIED WARRANTIES OF  MERCHANTABILITY
AND FITNESS.  IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT,
INDIRECT,  OR CONSEQUENTIAL DAMAGES  OR ANY DAMAGES WHATSOEVER RESULTING FROM
LOSS OF USE,  DATA OR PROFITS,  WHETHER IN AN ACTION OF CONTRACT,  NEGLIGENCE
OR OTHER TORTIOUS ACTION,  ARISING OUT OF  OR IN CONNECTION  WITH THE USE  OR
PERFORMANCE OF THIS SOFTWARE.

=cut


package main;

use strict;
use warnings;

use Fcntl;

# Key retrieved from /dev/random, guaranteed to be random ;-)
my $key = "u/R\xf9R\x7fv\xa5";

sub
co2mini_Initialize($)
{
  my ($hash) = @_;

  $hash->{DefFn}    = "co2mini_Define";
  $hash->{ReadFn}   = "co2mini_Read";
  $hash->{NOTIFYDEV} = "global";
  $hash->{NotifyFn} = "co2mini_Notify";
  $hash->{UndefFn}  = "co2mini_Undefine";
  $hash->{AttrFn}   = "co2mini_Attr";
  $hash->{AttrList} = "disable:0,1 showraw:0,1 ".
                      $readingFnAttributes;
}

#####################################

sub
co2mini_Define($$)
{
  my ($hash, $def) = @_;

  my @a = split("[ \t][ \t]*", $def);

  return "Usage: define <name> co2mini [device]"  if(@a < 2);

  my $name = $a[0];

  $hash->{DEVICE} = $a[2] // "/dev/co2mini0";

  $hash->{NAME} = $name;

  if( $init_done ) {
    co2mini_Disconnect($hash);
    co2mini_Connect($hash);
  } elsif( $hash->{STATE} ne "???" ) {
    $hash->{STATE} = "Initialized";
  }

  return undef;
}

sub
co2mini_Notify($$)
{
  my ($hash,$dev) = @_;

  return if($dev->{NAME} ne "global");
  return if(!grep(m/^INITIALIZED|REREADCFG$/, @{$dev->{CHANGED}}));

  co2mini_Connect($hash);
}

sub
co2mini_Connect($)
{
  my ($hash) = @_;
  my $name = $hash->{NAME};

  return undef if( AttrVal($name, "disable", 0 ) == 1 );

  sysopen($hash->{HANDLE}, $hash->{DEVICE}, O_RDWR | O_APPEND | O_NONBLOCK) or return undef;

  # Result of printf("0x%08X\n", HIDIOCSFEATURE(9)); in C
  my $HIDIOCSFEATURE_9 = 0xC0094806;

  # Send a FEATURE Set_Report with our key
  ioctl($hash->{HANDLE}, $HIDIOCSFEATURE_9, "\x00".$key) or return undef;

  $hash->{FD} = fileno($hash->{HANDLE});
  $selectlist{"$name"} = $hash;

  $hash->{STATE} = "connecting";

}

sub
co2mini_Disconnect($)
{
  my ($hash) = @_;
  my $name   = $hash->{NAME};

  if($hash->{HANDLE}) {
    delete $selectlist{"$name"};
    delete $hash->{FD};

    close($hash->{HANDLE});
    delete $hash->{HANDLE};
  }

  $hash->{STATE} = "disconnected";
  Log3 $name, 3, "$name: disconnected";
}


# Input: string key, string data
# Output: array of integers result
sub
co2mini_decrypt($$)
{
  my ($key_, $data_) = @_;
  my @key = map { ord } split //, $key_;
  my @data = map { ord } split //, $data_;
  my @cstate = (0x48,  0x74,  0x65,  0x6D,  0x70,  0x39,  0x39,  0x65);
  my @shuffle = (2, 4, 0, 7, 1, 6, 5, 3);
  
  my @phase1 = (0..7);
  for my $i (0 .. $#phase1) { $phase1[ $shuffle[$i] ] = $data[$i]; }
  
  my @phase2 = (0..7);
  for my $i (0 .. 7) { $phase2[$i] = $phase1[$i] ^ $key[$i]; }
  
  my @phase3 = (0..7);
  for my $i (0 .. 7) { $phase3[$i] = ( ($phase2[$i] >> 3) | ($phase2[ ($i-1+8)%8 ] << 5) ) & 0xff; }
  
  my @ctmp = (0 .. 7);
  for my $i (0 .. 7) { $ctmp[$i] = ( ($cstate[$i] >> 4) | ($cstate[$i]<<4) ) & 0xff; }
  
  my @out = (0 .. 7);
  for my $i (0 .. 7) { $out[$i] = (0x100 + $phase3[$i] - $ctmp[$i]) & 0xff; }
  
  return @out;
}

sub
co2mini_Read($)
{
  my ($hash) = @_;
  my $name   = $hash->{NAME};
  my ($buf, $readlength);

  my $showraw = AttrVal($name, "showraw", 0);

  readingsBeginUpdate($hash);
  while ( defined($readlength = sysread($hash->{HANDLE}, $buf, 8)) and $readlength == 8 ) {
    my @data = co2mini_decrypt($key, $buf);
    Log3 $name, 5, "co2mini data received " . join(" ", @data);
    # FIXME Verify checksum

    my ($item, $val_hi, $val_lo, $rest) = @data;
    my $value = $val_hi << 8 | $val_lo;
    
    if($item == 0x50) {
      readingsBulkUpdate($hash, "co2", $value);
    } elsif($item == 0x42) {
      readingsBulkUpdate($hash, "temperature", $value/16.0 - 273.15);
    } elsif($item == 0x44) {
      readingsBulkUpdate($hash, "humidity", $value/100.0);
    }
    if($showraw) {
      readingsBulkUpdate($hash, sprintf("raw_%02X", $item), $value);
    }
    
    $hash->{STATE} = "connected";
  }
  readingsEndUpdate($hash, 1);

}

sub
co2mini_Undefine($$)
{
  my ($hash, $arg) = @_;

  co2mini_Disconnect($hash);

  return undef;
}

sub
co2mini_Attr($$$)
{
  my ($cmd, $name, $attrName, $attrVal) = @_;

  if( $attrName eq "disable" ) {
    my $hash = $defs{$name};
    if( $cmd eq "set" && $attrVal ne "0" ) {
      co2mini_Disconnect($hash);
    } else {
      $attr{$name}{$attrName} = 0;
      co2mini_Disconnect($hash);
      co2mini_Connect($hash);
    }
  }

  return;
}

1;

=pod
=begin html

<a name="co2mini"></a>
<h3>co2mini</h3>
<ul>
  Module for measuring temperature and air CO2 concentration with a co2mini like device. 
  These are available under a variety of different branding, but all register as a USB HID device
  with a vendor and product ID of 04d9:a052.
  For photos and further documentation on the reverse engineering process see
  <a href="https://hackaday.io/project/5301-reverse-engineering-a-low-cost-usb-co-monitor">Reverse-Engineering a low-cost USB CO₂ monitor</a>.

  Notes:
  <ul>
    <li>FHEM has to have permissions to open the device. To configure this with udev, put a file named <tt>90-co2mini.rules</tt>
        into <tt>/etc/udev/rules.d</tt> with this content:
<pre>ACTION=="remove", GOTO="co2mini_end"

SUBSYSTEMS=="usb", KERNEL=="hidraw*", ATTRS{idVendor}=="04d9", ATTRS{idProduct}=="a052", GROUP="plugdev", MODE="0660", SYMLINK+="co2mini%n", GOTO="co2mini_end"

LABEL="co2mini_end"
</pre> where <tt>plugdev</tt> would be a group that your FHEM process is in.</li>
  </ul><br>

  <a name="co2mini_Define"></a>
  <b>Define</b>
  <ul>
    <code>define &lt;name&gt; co2mini [device]</code><br>
    <br>

    Defines a co2mini device. Optionally a device node may be specified, otherwise this defaults to <tt>/dev/co2mini0</tt>.<br><br>

    Examples:
    <ul>
      <code>define co2 co2mini</code><br>
    </ul>
  </ul><br>

  <a name="co2mini_Readings"></a>
  <b>Readings</b> FIXME

  <a name="co2mini_Attr"></a>
  <b>Attributes</b>
  <ul>
    <li>disable<br>
      1 -> disconnect</li>
  </ul>
</ul>

=end html
=cut

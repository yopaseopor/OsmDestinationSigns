#!/usr/bin/perl 
use CGI ':standard';
use CGI::Carp qw(warningsToBrowser fatalsToBrowser); 
use warnings;
use strict;
use utf8;
binmode(STDIN, ":encoding(UTF-8)");
use JSON::XS;
use LWP::Simple;
use Encode qw(encode from_to);
use URI::Escape qw(uri_unescape uri_escape);
use Data::Dumper;
use List::MoreUtils qw(uniq);
use Math::Trig;
use Encode;

print "Content-Type: application/json; charset=utf-8\r\n\r\n";

my $q = CGI->new;
my $data, my $db;
my $entries;
my $out;

#################################################
## Read and organize data
## reads data from JSON input
################################################# 
sub readData {
  my $input = shift @_;
   my $url = 'http://overpass-api.de/api/interpreter';
#  my $url = "http://localhost/destination/$input.json";
  my $st = shift @_ || 0;
  my $json;
  
  if($input =~ /elements/) {
    from_to ($input,"iso-8859-1","utf-8");
    $json = uri_unescape($input);
    }
  elsif ($input =~ /^[0-9]+$/ ) {
    my $query = <<QUERY;
[out:json][timeout:25];
(
  node($input)->.start;
  rel(bn.start)[type=destination_sign]->.rels;
  node(r.rels)->.nodes;
  way(bn.nodes)[highway]->.wa;
  way(bn.start)[highway]->.wb;
);
out body;
node(w);
out skel;  
(rel(bw.wb);rel(bw.wa););
out body;  
QUERY
    my $ua      = LWP::UserAgent->new();
    my $request = $ua->post( $url, ['data' => encode('utf-8',$query)] ); 
       $json = $request->content();
    }
  else {
    die "Can not parse input";
    }
  $data = decode_json($json) or die "No valid JSON from Overpass";
  foreach my $w (@{$data->{elements}}) {
    next if $db->{$w->{'type'}}{$w->{'id'}};
    $db->{$w->{'type'}}{$w->{'id'}} = $w;
    }
  }

#################################################
## Direction of X->A
#################################################
sub calcDirection {
  my ($x,$a) = @_;
  my $lat = $db->{node}{$x}{lat} * 0.01745;
  my $dxa = 111.3 * cos($lat) * ($db->{node}{$a}{lon} - $db->{node}{$x}{lon});
  my $dya = 111.3 * ($db->{node}{$a}{lat} - $db->{node}{$x}{lat});
  
  return 0 if($dxa == 0);
  my $anga = rad2deg(atan(abs($dya)/abs($dxa)));
  $anga = -$anga     if $dxa>=0 && $dya>=0;
  $anga = -180+$anga if $dxa<0 && $dya>=0;
  $anga = 180-$anga  if $dxa<0 && $dya<0;
  $anga = 0+$anga    if $dxa>=0 && $dya<0;
  
  return $anga;
  }     
  
#################################################
## Prepare direction calc for one end of way
#################################################  
sub getDirection {
  my ($s) = @_;
  my $o = -1000;
  #To-way and intersection node
  if($s->{to} && $s->{intersection} && !$s->{tonode}) {
    if($db->{way}{$s->{to}}){
      my @ns = @{$db->{way}{$s->{to}}{nodes}};
      if ($ns[0] == $s->{intersection}) {
        $o = calcDirection($ns[0],$ns[1]);
        }
      elsif ($ns[-1] == $s->{intersection}) {
        $o = calcDirection($ns[-1],$ns[-2]);
        }
      }
    }
  #To-node and intersection node
  elsif ($s->{tonode} && $s->{intersection}) {
    $o = calcDirection($s->{intersection},$s->{tonode});
    }
  #To-node and sign node
  elsif ($s->{tonode} && $s->{sign}) {
    $o = calcDirection($s->{sign},$s->{tonode});
    }
  return int $o;  
  }

#Helper: is an object member of a given relation?  
sub isRelationMember {
  my ($type,$id,$parid) = @_;
  foreach my $k (@{$db->{relation}{$parid}{'members'}}) {
    if ($k->{'ref'} == $id  && $k->{'type'} eq $type) {
      return 1;
      }
    }
  return 0;  
  }

#Helper: is a node part of a given way?
sub isWayNode {
  my ($id,$parid) = @_;
  my $pos = -1;
  foreach my $k (@{$db->{way}{$parid}{'nodes'}}) {
    $pos++;
    if ($k == $id) {
      return $pos;
      }
    }
  return -1;  
  }  

#Helper: find a way the given node is on
sub findWayfromNode {
  my $n = shift @_;
  foreach my $w  (keys %{$db->{way}}) {
    if(isWayNode($n,$w)>=0) {
      return $w;
      }
    }
  return 0;  
  }  
  
#Take destination string, add destination:lang:XX (if not already in string)
sub DestinationString {
  my ($r,$num) = @_;
  $num //= 0;
  my @t = split(';',$db->{relation}{$r}{'tags'}{'destination'});
  my $o = $t[$num];
  foreach my $k (keys %{$db->{relation}{$r}{'tags'}}) {
    if ($k =~ /^destination:lang:/) {
      @t = split(';',$db->{relation}{$r}{'tags'}{$k});
      next if (index($o,$t[$num]) != -1);
      $o .= '<br>'.$t[$num];
      }
    }
  $o =~ s/;/<br>/g;
  return $o;
  }

#Search through sources of refs  
sub getRef {
  my $s = shift @_;
  my $o ='';
  #ref from destination:ref
  if ($db->{relation}{$s->{id}}{'tags'}{'destination:ref'}) {
    $o = $db->{relation}{$s->{id}}{'tags'}{'destination:ref'};
    }
  #ref from ref on to-way  
  elsif ($db->{way}{$s->{to}}{'tags'}{'ref'}) {
    $o = $db->{way}{$s->{to}}{'tags'}{'ref'};
    }
  #ref from relation to-way belongs to
  else {
    foreach my $r (keys %{$db->{relation}}) { 
      if ($db->{relation}{$r}{'tags'}{'type'} eq 'route' &&
          $db->{relation}{$r}{'tags'}{'route'} eq 'hiking') {
        if (isRelationMember('way',$s->{to},$r)) {    
          if ($db->{relation}{$r}{'tags'}{'ref'}) {
            $o = $db->{relation}{$r}{'tags'}{'ref'};
            }
          } 
        }
      }
    } 
  $o =~ s/;/ /g;   
  return $o;
  }

  
sub getTimeDistance {
  my ($r,$num) = @_;
  $num //= 0;
  my $o = '';
  my @t = split(';',$db->{relation}{$r}{'tags'}{'time'});
  if($t[$num]) {
    $o .= $t[$num];
    }
  @t = split(';',$db->{relation}{$r}{'tags'}{'distance'});
  if($t[$num]) {
    if($o) {$o .= ' | ';}
    $o .= $t[$num];
    $o .= ' km' if($t[$num] =~ /^[0-9\.]+$/)
    }
  return $o;  
  }
  
#################################################
## Read & Display information from relations
#################################################  
sub parseData {
  foreach my $w (keys %{$db->{relation}}) {
    next unless $db->{relation}{$w}{'tags'}{'type'} eq 'destination_sign';
    my $s;
    $s->{id} = $w;
    foreach my $m (@{$db->{relation}{$w}{'members'}}) {
      if ($m->{'role'} eq 'sign' && $m->{'type'} eq 'node') {
        $s->{sign} = $m->{'ref'};
        }
      if ($m->{'role'} eq 'intersection' && $m->{'type'} eq 'node') {
        $s->{intersection} = $m->{'ref'};
        }
      if ($m->{'role'} eq 'from' && $m->{'type'} eq 'way') {
        $s->{from} = $m->{'ref'};
        }
      if ($m->{'role'} eq 'from' && $m->{'type'} eq 'node') {
        $s->{fromnode} = $m->{'ref'};
        $s->{from} = findWayfromNode($m->{'ref'});
        }
      if ($m->{'role'} eq 'to' && $m->{'type'} eq 'way') {
        $s->{to} = $m->{'ref'};
        }
      if ($m->{'role'} eq 'to' && $m->{'type'} eq 'node') {
        $s->{tonode} = $m->{'ref'};
        $s->{to} = findWayfromNode($m->{'ref'});
        }
      }
    
    $s->{dir} = getDirection($s);
    $s->{wayref}  = getRef($s);
    foreach my $i (0..(scalar split(';',$db->{relation}{$w}{'tags'}{destination})-1)) {
      $s->{dest} = DestinationString($w,$i);
      $s->{dura} = getTimeDistance($w,$i);

      my $o;
      $o = "<div class=\"entry\" style=\"";
      $o .= "color:".$db->{relation}{$w}{'tags'}{'colour:text'}.";" if $db->{relation}{$w}{'tags'}{'colour:text'}; 
      $o .= "background:".$db->{relation}{$w}{'tags'}{'colour:back'}.";" if $db->{relation}{$w}{'tags'}{'colour:back'}; 
      $o .= "\">";
      if($s->{dir} != -1000) {
        $o .= "<div class=\"compass\" style=\"transform: rotate($s->{dir}deg);";
        $o .= "color:".$db->{relation}{$w}{'tags'}{'colour:arrow'}.";" if $db->{relation}{$w}{'tags'}{'colour:arrow'}; 
        $o .= "\"  onClick=\"showObj('relation',".$db->{relation}{$w}{'id'}.")\">&#10137;</div>";
        }
      else {
        $o .= "<div class=\"compass\"  
              onClick=\"showObj('relation',".$db->{relation}{$w}{'id'}.")\">&nbsp;?&nbsp;</div>";
        }
      $o .= "<span class=\"dest\">$s->{dest}</span>";
      $o .= "<div class=\"detail\"><span class=\"ref\">$s->{wayref}</span><br>";
      $o .= "<span class=\"dura\">$s->{dura}</span></div>";
      $o .= "</div>";
      $entries->{$s->{dir}.$s->{dest}.$i} = $o;
      }
    
    my $o = '';
    unless($entries->{'Z'.$s->{sign}}) {
      $o .= "<span><a href=\"".$db->{node}{$s->{sign}}{'tags'}{'image'}."\">Image</a></span>" if $db->{node}{$s->{sign}}{'tags'}{'image'};
      $o .= "<span><a href=\"http://www.mapillary.com/map/im/".$db->{node}{$s->{sign}}{'tags'}{'mapillary'}."\">Mapillary</a></span>" if $db->{node}{$s->{sign}}{'tags'}{'mapillary'};
      $o .= "<span><a href=\"".$db->{node}{$s->{sign}}{'tags'}{'website'}."\">Website</a></span>" if $db->{node}{$s->{sign}}{'tags'}{'website'};
      $o .= "<span>Operator: $db->{node}{$s->{sign}}{'tags'}{'operator'}</span>" if $db->{node}{$s->{sign}}{'tags'}{'operator'};
      
      if($o) {
        $o = "<div class=\"details\">".$o."</div>";
        }
      $entries->{'Z'.$s->{sign}} = $o;
      }  
    }
  }

  
  
 
readData($q->param('nodeid'));
parseData();

my $o;
foreach my $e (sort keys %{$entries}) {
  $o .= $entries->{$e}."\n";
  }

$out->{html} = $o;
$out->{lat} = $db->{node}{$q->param('nodeid')}{lat};
$out->{lon} = $db->{node}{$q->param('nodeid')}{lon};

print  encode_json($out);

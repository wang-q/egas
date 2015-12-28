#!/usr/bin/perl
use strict;
use warnings;
use autodie;

use Getopt::Long qw(HelpMessage);
use FindBin;
use YAML qw(Dump Load DumpFile LoadFile);

use Path::Tiny;
use Bio::SearchIO;

use AlignDB::IntSpan;
use AlignDB::Stopwatch;

use lib "$FindBin::RealBin/lib";
use MyUtil qw(decode_header);

#----------------------------------------------------------#
# GetOpt section
#----------------------------------------------------------#
# record ARGV and Config
my $stopwatch = AlignDB::Stopwatch->new(
    program_name => $0,
    program_argv => [@ARGV],
);

=head1 NAME

blastn_paralog.pl - Link paralog sequences
    
=head1 SYNOPSIS

    perl blastn_paralog.pl -f <blast result file> [options]
      Options:
        --help          -?          brief help message
        --file          -f  STR     blast result file
        --view          -M  STR     blast output format, default is [0]
                                    `blastall -m`
                                    0 => "blast",         # Pairwise
                                    7 => "blastxml",      # BLAST XML
                                    9 => "blasttable",    # Hit Table
        --identity      -i  INT     default is [90]
        --coverage      -c  FLOAT   default is [0.95]       

=cut

my $output;

GetOptions(
    'help|?'   => sub { HelpMessage(0) },
    'file|f=s' => \my $file,
    'view|m=s'     => \( my $alignment_view = 0 ),
    'identity|i=i' => \( my $identity       = 90 ),
    'coverage|c=f' => \( my $coverage       = 0.95 ),
) or HelpMessage(1);

if ( !defined $file ) {
    die "Need --file\n";
}
elsif ( !path($file)->is_file ) {
    die "--file [$file] doesn't exist\n";
}

my $view_name = {
    0 => "blast",         # Pairwise
    7 => "blastxml",      # BLAST XML
    9 => "blasttable",    # Hit Table
};
my $result_format = $view_name->{$alignment_view};

if ( !$output ) {
    $output = path($file)->basename;
    ($output) = grep {defined} split /\./, $output;
    $output = "$output.blast.tsv";
}

#----------------------------------------------------------#
# init
#----------------------------------------------------------#
$stopwatch->start_message("Link paralog...");

#----------------------------------------------------------#
# load blast reports
#----------------------------------------------------------#
$stopwatch->block_message("load blast reports");
open my $out_fh,   ">", $output;
open my $blast_fh, '<', $file;

my $searchio = Bio::SearchIO->new(
    -format => $result_format,
    -fh     => $blast_fh,
);

ALN: while ( my $result = $searchio->next_result ) {
    my $query_name = $result->query_name;

    # blasttable don't have $result->query_length
    my $query_info   = decode_header($query_name);
    my $query_length = $query_info->{chr_end} - $query_info->{chr_start} + 1;
    print "Name $query_name\tLength $query_length\n";
    while ( my $hit = $result->next_hit ) {
        my $hit_name = $hit->name;
        next if $query_name eq $hit_name;

        # blasttable don't have $hit->length
        my $hit_info   = decode_header($hit_name);
        my $hit_length = $hit_info->{chr_end} - $hit_info->{chr_start} + 1;

        my $query_set     = AlignDB::IntSpan->new;
        my $hit_set       = AlignDB::IntSpan->new;
        my $hit_set_plus  = AlignDB::IntSpan->new;
        my $hit_set_minus = AlignDB::IntSpan->new;
        while ( my $hsp = $hit->next_hsp ) {

            # process the Bio::Search::HSP::HSPI object
            my $hsp_identity = $hsp->percent_identity;
            next if $hsp_identity < $identity;

            # use "+" for default strand
            # -1 = Minus strand, +1 = Plus strand
            my ( $query_strand, $hit_strand ) = $hsp->strand("list");
            my $hsp_strand = "+";
            if ( $query_strand + $hit_strand == 0 and $query_strand != 0 ) {
                $hsp_strand = "-";
            }

            my ( $q_start, $q_end ) = $hsp->range('query');
            if ( $q_start > $q_end ) {
                ( $q_start, $q_end ) = ( $q_end, $q_start );
            }
            $query_set->add_range( $q_start, $q_end );

            my ( $h_start, $h_end ) = $hsp->range('hit');
            if ( $h_start > $h_end ) {
                ( $h_start, $h_end ) = ( $h_end, $h_start );
            }
            $hit_set->add_range( $h_start, $h_end );

            if ( $hsp_strand eq "+" ) {
                $hit_set_plus->add_range( $h_start, $h_end );
            }
            elsif ( $hsp_strand eq "-" ) {
                $hit_set_minus->add_range( $h_start, $h_end );
            }

            #print Dump {
            #    hsp_identity => $hsp_identity,
            #    q_start      => $q_start,
            #    q_end        => $q_end,
            #    h_start      => $h_start,
            #    h_end        => $h_end,
            #    query_strand        => $query_strand,
            #    hit_strand        => $hit_strand,
            #    hsp_strand        => $hsp_strand,
            #};
        }
        my $query_coverage = $query_set->size / $query_length;
        my $hit_coverage   = $hit_set->size / $hit_length;
        next if $query_coverage < $coverage;
        next if $hit_coverage < $coverage;

        my $strand = "+";
        if ( $hit_set_plus->size < $hit_set_minus->size ) {
            print " " x 4, "Hit on revere strand\n";
            $strand = "-";
        }
        print {$out_fh} join "\t", $query_name, $hit_name, $strand,
            $query_length,
            $query_coverage, $query_set->runlist, $hit_length,
            $hit_coverage, $hit_set->runlist;
        print {$out_fh} "\n";
    }
}
close $out_fh;
close $blast_fh;

$stopwatch->end_message;

exit;

__END__

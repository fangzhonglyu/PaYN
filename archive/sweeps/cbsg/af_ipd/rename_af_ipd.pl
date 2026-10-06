#!/usr/bin/env perl
# Module / include-guard / include-path renames that turn a source file of the AF
# (signed_segmented_csa_cbsg_af), BP (signed_segmented_csa_bp) or IPD
# (signed_segmented_csa_bp_ipd) variant into its copy in
# designs/payn/variants/signed_segmented_csa_cbsg_af_ipd.  Every copied module gets
# the suffix AfIpd, so the copies compile next to the originals (the lockstep and
# unit benches instantiate both).  Used by sweeps/cbsg/af_ipd/check_copies.sh to
# show that each copy is its source plus exactly the listed edits.
#   perl sweeps/cbsg/af_ipd/rename_af_ipd.pl < source.sv > renamed.sv
use strict;
use warnings;
my @mods = qw(CbsgAfStreamGen CbsgAfKaEncoder CbsgAfPeripheral InnerPESignedSegmentedCsaIpd
              InnerPESignedSegmentedCsaBpIpdFlat InnerPESignedSegmentedCsaBpIpdGrid PaynBpCombiner);
my %guards = (
    'PAYN_CBSG_AF_STREAM_GEN'                         => 'PAYN_CBSG_AF_IPD_STREAM_GEN',
    'PAYN_CBSG_AF_PERIPHERAL'                         => 'PAYN_CBSG_AF_IPD_PERIPHERAL',
    'PAYN_SIGNED_SEGMENTED_CSA_IPD_INNER_PE_CORE'     => 'PAYN_SIGNED_SEGMENTED_CSA_CBSG_AF_IPD_INNER_PE_CORE',
    'PAYN_SIGNED_SEGMENTED_CSA_BP_IPD_INNER_PE'       => 'PAYN_SIGNED_SEGMENTED_CSA_CBSG_AF_IPD_INNER_PE',
    'PAYN_SIGNED_SEGMENTED_CSA_BP_IPD_INNER_PE_GRID'  => 'PAYN_SIGNED_SEGMENTED_CSA_CBSG_AF_IPD_INNER_PE_GRID',
    'PAYN_BP_COMBINER'                                => 'PAYN_CBSG_AF_IPD_BP_COMBINER',
);
my %paths = (
    'payn/variants/signed_segmented_csa_bp_ipd/inner_pe_core_signed_segmented_csa_ipd.sv' =>
        'payn/variants/signed_segmented_csa_cbsg_af_ipd/inner_pe_core_signed_segmented_csa_cbsg_af_ipd.sv',
    'payn/variants/signed_segmented_csa_bp_ipd/inner_pe_signed_segmented_csa_bp_ipd.sv' =>
        'payn/variants/signed_segmented_csa_cbsg_af_ipd/inner_pe_signed_segmented_csa_cbsg_af_ipd.sv',
);
while (my $l = <STDIN>) {
    for my $m (@mods) { $l =~ s/\b$m\b/${m}AfIpd/g; }
    for my $g (keys %guards) { $l =~ s/\b$g\b/$guards{$g}/g; }
    for my $p (keys %paths) { $l =~ s/\Q$p\E/$paths{$p}/g; }
    print $l;
}

=head1 LICENSE

Copyright [1999-2015] Wellcome Trust Sanger Institute and the EMBL-European Bioinformatics Institute
Copyright [2016-2019] EMBL-European Bioinformatics Institute

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

     http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

=cut

package Bio::EnsEMBL::Production::Pipeline::ProteinFeatures::InterProScan;

use strict;
use warnings;
use base ('Bio::EnsEMBL::Production::Pipeline::Common::Base');

use File::Path qw(make_path remove_tree);
use File::Temp qw(tempdir);

sub param_defaults {
  my ($self) = @_;
  
  return {
    %{$self->SUPER::param_defaults},
    'run_interproscan' => 1,
    'seq_type'         => 'p',
  };
}

sub fetch_input {
  my ($self) = @_;
  
  my $input_file = $self->param_required('input_file');
  $self->throw("File '$input_file' does not exist") if (! -e $input_file);
}

sub run {
  my ($self) = @_;
  
  my $input_file       = $self->param_required('input_file');
  my $seq_type         = $self->param_required('seq_type');
  my $run_mode         = $self->param_required('run_mode');
  my $interproscan_exe = $self->param_required('interproscan_exe');
  my $applications     = $self->param_required('interproscan_applications');
  my $run_interproscan = $self->param_required('run_interproscan');
  
  my $outfile_base = "$input_file.$run_mode";
  my $outfile_xml  = "$outfile_base.xml";
  my $outfile_tsv  = "$outfile_base.tsv";
  
  if ($run_interproscan) {
    unlink $outfile_xml if -e $outfile_xml;
    unlink $outfile_tsv if -e $outfile_tsv;
    
    # Must use /scratch for short temporary file names; TMHMM can't cope with longer ones.
    my $scratch_dir = tempdir(DIR => '/scratch', CLEANUP => 1);
    
    if (! -e $scratch_dir) {
      $self->warning("Output directory '$scratch_dir' does not exist. I shall create it.");
      make_path($scratch_dir) or $self->throw("Failed to create output directory '$scratch_dir'");
    }
    
    my $options = "--iprlookup --goterms --pathways ";
    $options .= "-f TSV, XML -t $seq_type --tempdir $scratch_dir ";
    $options .= '--applications '.join(',', @$applications).' ';
    my $input_option  = "-i $input_file ";
    my $output_option = "--output-file-base $outfile_base ";  
    
    if ($run_mode =~ /^(nolookup|local)$/) {
      $options .= "--disable-precalc ";
    }
    
    my $interpro_cmd = qq($interproscan_exe $options $input_option $output_option);
    
    if ($self->param_is_defined('species')) {
      my $dba = $self->get_DBAdaptor('core');
      $dba->dbc && $dba->dbc->disconnect_if_idle();
    }
    $self->dbc and $self->dbc->disconnect_if_idle();
    
    system($interpro_cmd) == 0 or $self->throw("Failed to run ".$interpro_cmd);
    
    unlink $scratch_dir if -e $scratch_dir;
  }
  
  if (! -e $outfile_xml) {
    $self->throw("Output file '$outfile_xml' was not created");
  } elsif (-s $outfile_xml == 0) {
    $self->throw("Output file '$outfile_xml' was zero size");
  }
  
  $self->param('outfile_xml', $outfile_xml);
  $self->param('outfile_tsv', $outfile_tsv);
}

sub write_output {
  my ($self) = @_;
  
  my $output_ids =
  {
    'outfile_xml' => $self->param('outfile_xml'),
    'outfile_tsv' => $self->param('outfile_tsv'),
  };
  $self->dataflow_output_id($output_ids, 1);
}

1;

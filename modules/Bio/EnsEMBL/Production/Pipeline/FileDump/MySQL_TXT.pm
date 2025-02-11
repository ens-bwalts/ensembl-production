=head1 LICENSE

Copyright [1999-2015] Wellcome Trust Sanger Institute and the EMBL-European Bioinformatics Institute
Copyright [2016-2020] EMBL-European Bioinformatics Institute

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

package Bio::EnsEMBL::Production::Pipeline::FileDump::MySQL_TXT;

use strict;
use warnings;
use base qw(Bio::EnsEMBL::Production::Pipeline::FileDump::Base_Filetype);

use File::Spec::Functions qw/catdir/;
use Path::Tiny;

sub param_defaults {
  my ($self) = @_;

  return {
    %{$self->SUPER::param_defaults},
    data_type   => 'mysql',
    file_type   => 'txt',
    timestamped => 1,
  };
}

sub fetch_input {
  my ($self) = @_;

  my $dump_dir            = $self->param_required('dump_dir');
  my $timestamped_dirname = $self->param_required('timestamped_dirname');
  my $overwrite           = $self->param_required('overwrite');
  my $data_type           = $self->param_required('data_type');

  my $output_dir = catdir(
    $dump_dir,
    $timestamped_dirname,
    $data_type,
    $self->timestamp($self->dba)
  );

  if (-e $output_dir) {
    if (! $overwrite) {
      $self->complete_early('Files exist and will not be overwritten');
    }
  } else {
    path($output_dir)->mkpath();
  }

  $self->param('output_dir', $output_dir);
  $self->param('output_filenames', []);
}

sub run {
  my ($self) = @_;

  my $output_dir = $self->param_required('output_dir');

  my $dba = $self->dba;

  my $database = $dba->dbc->dbname;
  my $tables = $self->get_tables($dba);
  my $dbc_params = join(' ', (
    '--host='.$dba->dbc->host,
    '--port='.$dba->dbc->port,
    '--user='.$dba->dbc->user,
    '--password='.$dba->dbc->password
    )
  );

  $dba->dbc->disconnect_if_idle();

  my $db_filename = $self->generate_custom_filename($output_dir, $database, 'sql');

  if (defined $db_filename) {
    $self->write_database($database, $tables, $dbc_params, $db_filename);
  }

  foreach my $table (@{$tables}) {
    my $filename = $self->generate_custom_filename($output_dir, $table, 'txt');

    if (defined $filename) {
      $self->write_table($database, $table, $dbc_params, $filename);
    }
  }
}

sub write_output {
  my ($self) = @_;

  $self->SUPER::write_output;

  my %output = (
    output_dir => $self->param('output_dir')
  );

  $self->dataflow_output_id(\%output, 3);
}

sub timestamp {
  my ($self, $dba) = @_;

  return $dba->dbc->dbname();
}

sub get_tables {
  my ($self, $dba) = @_;
  my $database = $dba->dbc->dbname;

  my $table_list_sql = qq/
    SELECT TABLE_NAME FROM 
      information_schema.tables
    WHERE 
      TABLE_SCHEMA = '$database' AND
      TABLE_NAME not like 'MTMP_%'
  /;

  my $helper = $dba->dbc->sql_helper;
  my $tables = $helper->execute_simple(-SQL => $table_list_sql);

  return $tables;
}

sub write_database {
  my ($self, $database, $tables, $db_params, $filename) = @_;

  my $mysqldump_exe = 'mysqldump';

  $self->assert_executable($mysqldump_exe);

  my @cmd = (
    $mysqldump_exe,
    $db_params,
    '-d',
    '--skip-lock-tables',
    $database,
    @$tables,
    '>',
    $filename
  );
  my $cmd = join(' ', @cmd);
  my ($rc, $output) = $self->run_cmd($cmd);

  if ($rc) {
    my $msg =
      "$mysqldump_exe failed for '$filename'\n".
      "Command: $cmd\n".
      "Output: $output";
    $self->throw($msg);
  }
}

sub write_table {
  my ($self, $database, $table, $db_params, $filename) = @_;

  my $mysql_exe = 'mysql';

  $self->assert_executable($mysql_exe);

  my @cmd = (
    $mysql_exe,
    $db_params,
    '--max_allowed_packet=1024M',
    '--quick',
    '--silent',
    '--skip-column-names',
    "-e 'SELECT * FROM ${database}.${table}'",
    '|',
    'sed -r ',
    '-e \'s/(^|\t)NULL($|\t)/\1\\N\2/g\'',
    '-e \'s/(^|\t)NULL($|\t)/\1\\N\2/g\'',
    '>',
    $filename
  );
  my $cmd = join(' ', @cmd);
  my ($rc, $output) = $self->run_cmd($cmd);

  if ($rc) {
    my $msg =
      "$mysql_exe failed for '$filename'\n".
      "Command: $cmd\n".
      "Output: $output";
    $self->throw($msg);
  }
}

1;

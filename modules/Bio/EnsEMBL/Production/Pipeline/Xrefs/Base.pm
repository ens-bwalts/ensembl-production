=head1 LICENSE

Copyright [2009-2015] EMBL-European Bioinformatics Institute

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

package Bio::EnsEMBL::Production::Pipeline::Xrefs::Base;

use strict;
use warnings;
use DBI;
use Net::FTP;
use HTTP::Tiny;
use URI;
use URI::file;
use File::Basename;
use File::Spec::Functions;
use File::Path qw/make_path/;
use XrefParser::BaseParser;
use IO::File;
use JSON;
use Bio::EnsEMBL::Hive::Utils::URL;
use Text::Glob qw( match_glob );
use Bio::EnsEMBL::Utils::IO qw/slurp/;
use Bio::EnsEMBL::Utils::URI qw(parse_uri);

use base qw/Bio::EnsEMBL::Production::Pipeline::Common::Base/;

sub parse_config {
  my ($self, $file) = @_;
  my $contents = slurp($file);
  my $sources = from_json($contents);
  return $sources;
}

sub create_db {
  my ($self, $source_dir, $user, $pass, $db_url, $source_db, $host, $port) = @_;
  my $dbconn = sprintf( "dbi:mysql:host=%s;port=%s", $host, $port);
  my $dbh = DBI->connect( $dbconn, $user, $pass, {'RaiseError' => 1}) or croak( "Can't connect to server: " . $DBI::errstr );
  my %dbs = map {$_->[0] => 1} @{$dbh->selectall_arrayref('SHOW DATABASES')};
  if ($dbs{$source_db}) {
    $dbh->do( "DROP DATABASE $source_db" );
  }
  $dbh->do( 'CREATE DATABASE ' . $source_db);
  my $table_file = catfile( $source_dir, 'table.sql' );
  my $cmd = "mysql -u $user -p'$pass' -P $port -h $host $source_db < $table_file";
  system($cmd);
}

sub download_file {
  my ($self, $file, $base_path, $source_name, $db, $release) = @_;

  my $uri = URI->new($file);
  if (!defined $uri->scheme) { return $file; }
  my $file_path;
  $source_name =~ s/\///g;
  my $dest_dir = catdir($base_path, $source_name);
  if (defined $db and $db eq 'checksum') {
    $dest_dir = catdir($base_path, 'Checksum');
  }

  if ($uri->scheme eq 'ftp') {
    my $ftp = Net::FTP->new( $uri->host(), 'Debug' => 0);
    if (!defined($ftp) or ! $ftp->can('ls') or !$ftp->ls()) {
      $ftp = Net::FTP->new( $uri->host(), 'Debug' => 0);
    }
    $ftp->login( 'anonymous', '-anonymous@' ); 
    $ftp->cwd( dirname( $uri->path ) );
    $ftp->binary();
    foreach my $remote_file ( ( @{ $ftp->ls() } ) ) {
      if ( !match_glob( basename( $uri->path() ), $remote_file ) ) { next; }
      $remote_file =~ s/\///g;
      $file_path = catfile($dest_dir, basename($remote_file));
      mkdir(dirname($file_path));
      $ftp->get( $remote_file, $file_path );
    }
  } elsif ($uri->scheme eq 'http') {
    $file_path = catfile($dest_dir, basename($uri->path));
    mkdir(dirname($file_path));
    open OUT, ">$file_path" or die "Couldn't open file $file_path $!";
    my $http = HTTP::Tiny->new();
    my $response = $http->get($uri->as_string());
    print OUT $response->{content};
    close OUT;
  }
  if (defined $release) {
    return $file_path;
  }
  return dirname($file_path);
  
}

sub parse_url {
  my ($self, $url) = @_;
  my $parsed_url = Bio::EnsEMBL::Hive::Utils::URL::parse($url);
  my $user = $parsed_url->{'user'};
  my $pass = $parsed_url->{'pass'};
  my $host = $parsed_url->{'host'};
  my $port = $parsed_url->{'port'};
  my $db   = $parsed_url->{'dbname'};
  return ($user, $pass, $host, $port, $db);
}

sub load_checksum {
  my ($self, $path, $dbi) = @_;
  my $load_checksum_sth = $dbi->prepare("load data local infile ? into table checksum_xref");
  my $checksum_dir = catdir($path, 'Checksum');
  make_path($checksum_dir);
  my $counter = 1;

  my @files = `ls $checksum_dir`;
  my $checksum_file = catfile($checksum_dir, 'checksum.txt');
  my $output_fh = IO::File->new($checksum_file, 'w');
  foreach my $file (@files) {
    $file =~ s/\n//;
    if ($file =~ /checksum/) { next; }
    my $input_file = catfile($checksum_dir, $file);
    my $input_fh = XrefParser::BaseParser->get_filehandle($input_file);
    while(my $line = <$input_fh>) {
      chomp $line;
      my ($id, $checksum) = split(/\s+/, $line);
      my @output = ($counter++, 1, $id, $checksum);
      print $output_fh join("\t", @output);
      print $output_fh "\n";
    }
    close $input_fh;
  }
  close $output_fh;

  $load_checksum_sth->execute($checksum_file);

}

sub get_source_id {
  my ($self, $dbi, $parser, $species_id) = @_;
  my $select_source_id_sth = $dbi->prepare("SELECT source_id FROM source_url WHERE parser = ? and species_id = ?");
  $select_source_id_sth->execute($parser, $species_id);
  my $source_id = ($select_source_id_sth->fetchrow_array())[0];
  # If no species-specific source, look for common sources
  if (!defined $source_id) {
    $select_source_id_sth->execute($parser, 1);
    $source_id = ($select_source_id_sth->fetchrow_array())[0];
  }
  $select_source_id_sth->finish();
  return $source_id;
}

sub get_dbi {
  my ($self, $host, $port, $user, $pass, $dbname) = @_;
  my $dbconn;
  if (defined $dbname) {
    $dbconn = sprintf("dbi:mysql:host=%s;port=%s;database=%s", $host, $port, $dbname);
  } else {
    $dbconn = sprintf("dbi:mysql:host=%s;port=%s", $host, $port);
  }
  my $dbi = DBI->connect( $dbconn, $user, $pass, { 'RaiseError' => 1 } ) or croak( "Can't connect to database: " . $DBI::errstr );
  return $dbi;
}

sub get_path {
  my ($self, $base_path, $species, $release, $category, $file_name) = @_;
  my $full_path = File::Spec->catfile($base_path, $species, $release, $category);
  make_path($full_path);
  if (defined $file_name) {
    return File::Spec->catfile($full_path, $file_name);
  } else {
    return $full_path;
  }
}


1;


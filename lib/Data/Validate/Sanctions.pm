package Data::Validate::Sanctions;

use strict;
use warnings;

require Exporter;
our @ISA       = qw(Exporter);
our @EXPORT_OK = qw/is_sanctioned set_sanction_file get_sanction_file/;

use Carp;
use Data::Validate::Sanctions::Fetcher;
use File::stat;
use File::ShareDir;
use YAML::XS qw/DumpFile LoadFile/;
use Scalar::Util qw(blessed);
use Date::Utility;

our $VERSION = '0.11';

# for OO
sub new {    ## no critic (RequireArgUnpacking)
    my $class = shift;
    my %args  = @_;
    my $self  = {};
    $self->{sanction_file} = $args{sanction_file} // _default_sanction_file();
    $self->{last_time} = 0;
    return bless $self, ref($class) || $class;
}

my $sanction_file = _default_sanction_file();
my $instance;

sub set_sanction_file {    ## no critic (RequireArgUnpacking)
    $sanction_file = shift // die "sanction_file is needed";
    undef $instance;
    return;
}

sub get_sanction_file {
    return $instance ? $instance->{sanction_file} : $sanction_file;
}

sub is_sanctioned {        ## no critic (RequireArgUnpacking)
    return (get_sanctioned_info(@_))->{matched};
}

sub get_sanctioned_info {    ## no critic (RequireArgUnpacking)
    my $self = blessed($_[0]) ? shift : $instance;
    
    my ($first_name, $last_name, $date_of_birth) = @_;

    unless ($self) {
        $instance = __PACKAGE__->new(sanction_file => $sanction_file);
        $self = $instance;
    }

    my $data = $self->_load_data();

    # prepare list of possible variants of names: LastnameFirstname and FirstnameLastname
    my @full_name = ($first_name, $last_name);
    
    use Data::Dumper;
    warn Dumper(@full_name);
    
    my @name_variants = map {
        my $name = uc(join('.*', map { my $x = $_; $x =~ s/[[:^alpha:]]//g; $x } @$_));
        $name
    } ([@full_name], @full_name > 1 ? [reverse @full_name] : ());
    
    my @names;
    for my $k (sort keys %$data) {
        
        if($k eq 'HMT-Sanctions') {
            @names = keys %{$data->{'HMT-Sanctions'}->{names_list}};    
        } else {
            @names = @{$data->{$k}{names}};
        }
        
        foreach my $name (@names) {
            
            (my $check_name = $name) =~ s/[[:^alpha:]]//g;
            $check_name = uc($check_name);
            
            for (@name_variants) {
                
                my $checked_dob;
                my $checked_name;
                # First check: See if the regex matches
                # Second check: See if the date of birth matches
                if ($check_name =~ /$_/) {
                    my $client_dob_epoch = Date::Utility->new($date_of_birth)->epoch;
                    $checked_name = 1;
                    $checked_dob = grep { $_ eq $client_dob_epoch } @{$data->{$k}->{names_list}->{$name}->{dob_epoch}};
                }
                
                return +{
                    matched => 1,
                    list    => $k,
                    name    => $name,
                } if (($checked_dob && $k eq 'HMT-Sanctions') || $checked_name) ;
            }
        }
    }

    return {matched => 0};
}

sub _load_data {
    my $self          = shift;
    my $sanction_file = $self->{sanction_file};
    $self->{last_time} //= 0;
    $self->{_data} //= {};

    if (-e $sanction_file) {
        return $self->{_data} if stat($sanction_file)->mtime <= $self->{last_time} && $self->{_data};
        $self->{last_time} = stat($sanction_file)->mtime;
        $self->{_data}     = LoadFile($sanction_file);
    }
    return $self->{_data};
}

sub update_data {
    my $self = shift;

    my $new_data = Data::Validate::Sanctions::Fetcher::run();
    $self->_load_data();
    
    my $updated;
    foreach my $k (keys %$new_data) {
        if (ref($self->{_data}{$k}) ne 'HASH' || $self->{_data}{$k}{updated} < $new_data->{$k}{updated}) {
            $self->{_data}{$k} = $new_data->{$k};
            $updated = 1;
        }
    }

    $self->_save_data if $updated;
    return;
}

sub _save_data {
    my $self = shift;

    my $sanction_file     = $self->{sanction_file};
    my $new_sanction_file = $sanction_file . ".tmp";

    DumpFile($new_sanction_file, $self->{_data});

    rename $new_sanction_file, $sanction_file or die "Can't rename $new_sanction_file to $sanction_file, please check it\n";
    $self->{last_time} = stat($sanction_file)->mtime;
    return;
}

sub _default_sanction_file {
    return $ENV{SANCTION_FILE} // File::ShareDir::dist_file('Data-Validate-Sanctions', 'sanctions.yml');
}

sub last_updated {
    my $self = shift;
    my $list = shift;
    return $list ? $self->{_data}->{$list}->{updated} : $self->{last_time};
}

1;
__END__

=encoding utf-8

=head1 NAME

Data::Validate::Sanctions - Validate a name against sanctions lists

=head1 SYNOPSIS

    # as exported function
    use Data::Validate::Sanctions qw/is_sanctioned get_sanction_file set_sanction_file/;
    set_sanction_file('/var/storage/sanction.csv');

    my ($first_name, $last_name) = ("First", "Last Name");
    print 'BAD' if is_sanctioned($first_name, $last_name);

    # as OO
    use Data::Validate::Sanctions;

    #You can also set sanction_file in the new method.
    my $validator = Data::Validate::Sanctions->new(sanction_file => '/var/storage/sanction.csv');
    print 'BAD' if $validator->is_sanctioned("$last_name $first_name");

=head1 DESCRIPTION

Data::Validate::Sanctions is a simple validitor to validate a name against sanctions lists.

The list is from L<https://www.treasury.gov/ofac/downloads/sdn.csv>, L<https://www.treasury.gov/ofac/downloads/consolidated/cons_prim.csv>

run F<update_sanctions_csv> to update the bundled csv.

The path of list can be set by function L</set_sanction_file> or by method L</new>. If not set, then environment variable $ENV{SANCTION_FILE} will be checked, at last
the default file in this package will be used.

=head1 METHODS

=head2 is_sanctioned

    is_sanctioned($last_name, $first_name);
    is_sanctioned($first_name, $last_name);
    is_sanctioned("$last_name $first_name");

when one string is passed, please be sure last_name is before first_name.

or you can pass first_name, last_name (last_name, first_name), we'll check both "$last_name $first_name" and "$first_name $last_name".

retrun 1 if match is found and 0 if match is not found.

It will remove all non-alpha chars and compare with the list we have.

=head2 get_sanctioned_info

    my $result =get_sanctioned_info($last_name, $first_name);
    print 'match: ', $result->{name}, ' on list ', $result->{list} if $result->{matched};

return hashref with keys:
    matched      1 or 0, depends if name has matched
    list       name of list matched (present only if matched)
    name        name of sanctioned person matched (present only if matched)

It will remove all non-alpha chars and compare with the list we have.

=head2 update_data

Fetches latest versions of sanction lists, and updates corresponding sections of stored file, if needed

=head2 last_updated

Returns timestamp of stored file updated.
If argument is provided - return timestamp when that list was updated.

=head2 new

Create the object, and set sanction_file

    my $validator = Data::Validate::Sanctions->new(sanction_file => '/var/storage/sanction.csv');

=head2 get_sanction_file

get sanction_file which is used by L</is_sanctioned> (procedure-oriented)

=head2 set_sanction_file

set sanction_file which is used by L</is_sanctioned> (procedure-oriented)

=head1 AUTHOR

Binary.com E<lt>fayland@binary.comE<gt>

=head1 COPYRIGHT

Copyright 2014- Binary.com

=head1 LICENSE

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=head1 SEE ALSO

L<Data::OFAC>

=cut

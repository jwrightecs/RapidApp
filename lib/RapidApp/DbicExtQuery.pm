package RapidApp::DbicExtQuery;
#
# -------------------------------------------------------------- #
#
#   -- Catalyst/Ext-JS connector object for DBIC
#
#
# 2010-06-15:	Version 0.1 (HV)
#	Initial development


use strict;
use Moose;

use Clone;


our $VERSION = '0.1';

use DateTime::Format::Flexible;
use DateTime;


use Term::ANSIColor qw(:constants);

#### --------------------- ####

has 'ResultSource'				=> ( is => 'ro',	required => 1, 	isa => 'DBIx::Class::ResultSource'			);
has 'ExtNamesToDbFields'      => ( is => 'rw',	required => 0, 	isa => 'HashRef', default => sub{ {} } 	);
has 'columns'                 => ( is => 'rw',  required => 0,    isa => 'ArrayRef', default => sub{ [] }   );

# be careful! joins can slow queries considerably
has 'joins'    					=> ( is => 'rw',	required => 0, 	isa => 'ArrayRef', default => sub{ [] } 	);
has 'implied_joins'				=> ( is => 'rw',  required => 0,    isa => 'Bool',     default => 0 );

has 'group_by'    				=> ( is => 'ro',	default => undef	);

###########################################################################################


sub data_fetch {
	my $self = shift;
	my $params = shift or return undef;

	my $Attr		= $params->{Attr_spec};		# <-- Optional custom Attr_spec override
	my $Search	= $params->{Search_spec};	# <-- Optional custom Search_spec override
	
	$Attr 		= $self->Attr_spec($params) unless (defined $Attr);
	$Search 		= $self->Search_spec($params) unless (defined $Search);
	
	#use Data::Dumper;
	#print STDERR BOLD .GREEN . Dumper($Attr) . CLEAR;
	
	my @rows = $self->ResultSource->resultset->search($Search,$Attr)->all;
	
	my $count_Attr = Clone::clone($Attr);
	delete $count_Attr->{page} if (defined $count_Attr->{page}); # <-- ##  need to delete page and rows attrs to prevent the
	delete $count_Attr->{rows} if (defined $count_Attr->{rows}); # <-- ##  totalCount from including only the current page
	
	return {
		totalCount	=> $self->ResultSource->resultset->search($Search,$count_Attr)->count,
		rows			=> \@rows
	};
}

sub Attr_spec {
	my $self = shift;
	my $params = shift;

	my $sort = 'id';
	my $dir = 'asc';
	my $start = 0;
	my $count = 1000000;
	
	if (defined $params->{start} and defined $params->{limit}) {
		$start = $params->{start};
		$count = $params->{limit};
	}
	
	my $page = int($start/$count) + 1;
	
	my $attr = {
		page		=> $page,
		rows		=> $count
	};
	
	if (defined $params->{sort} and defined $params->{dir}) {
		# optionally convert table column name to db field name
		my $dbfName= $self->ExtNamesToDbFields->{$params->{sort}};
		defined $dbfName or $dbfName= $params->{sort};
		
		if (lc($params->{dir}) eq 'desc') {
			$attr->{order_by} = { -desc => $dbfName };
		}
		elsif (lc($params->{dir}) eq 'asc') {
			$attr->{order_by} = { -asc => $dbfName };
		}
	}
	
	# --
	# Join attr support:
	if (scalar(@{$self->joins})) {
		$attr->{join}= $self->joins;
	}
	# implied joins with either use all defined values in the name-hash, or just those associated with desired 'columns'
	elsif ($self->implied_joins) {
		my $dbfNames= ();
		if (scalar(@{$self->columns})) {
			foreach my $colName (@{$self->columns}) {
				my $dbfName= $self->ExtNamesToDbFields->{$colName};
				push @$dbfNames, defined $dbfName? $dbfName : $colName;
			}
		}
		else {
			$dbfNames= values %{$self->ExtNamesToDbFields};
		}
		$attr->{join}= $self->_find_implied_joins($dbfNames);
	}
	
	# optional add to prefetch:
	#$attr->{prefetch} = [];
	#foreach my $rel (@{$attr->{join}}) {		push @{$attr->{prefetch}}, $rel;	}
	if (scalar(@{$self->columns})) {
		$attr->{'select'} = [];
		$attr->{'as'} = [];
		foreach my $extName (@{$self->columns}) {
			my $dbfName= $self->ExtNamesToDbFields->{$extName};
			defined $dbfName or $dbfName= $extName;
			
			push @{$attr->{'select'}}, $dbfName;
			push @{$attr->{'as'}}, $extName;
		}
	}
	else {
		$attr->{'+select'} = [];
		$attr->{'+as'} = [];
		
		foreach my $k (keys %{$self->ExtNamesToDbFields}) {
			#my @trans = reverse split(/\./,$self->ExtNamesToDbFields->{$k});
			#my $t = shift @trans;
			#$t = shift(@trans) . '.' . $t if (scalar @trans > 0);
			
			my $t = $self->ExtNamesToDbFields->{$k};
			
			#if ($self->implied_joins) { 
			#	my $j = $self->hash_to_join($t) or next;
			#	push @{$attr->{join}}, $j;
			#}
			push @{$attr->{'+select'}}, $t;
			push @{$attr->{'+as'}}, $k;
		}
	}
	# --
	
	$attr->{group_by} = $self->group_by if (defined $self->group_by);
	
	return $attr;
}

sub _find_implied_joins {
	my $self= shift;
	my $dbfNames= shift;
	
	my $joinTree= {};
	foreach my $dbfName (@$dbfNames) {
		my @parts = split(/\./, $dbfName);
		my $curHash= $joinTree;
		for (my $i=0; $i<$#parts; $i++) { # skip the last part
			defined $curHash->{$parts[$i]} or $curHash->{$parts[$i]}= {};
			$curHash= $curHash->{$parts[$i]};
		}
	}
	
	return $self->_build_join_for_hash($joinTree);
}

sub _build_join_for_hash {
	my $self= shift;
	my $joinTree= shift;
	my @result= ();
	while (my ($reln,$subjoin) = each %$joinTree) {
		my $subCnt= scalar(keys(%$subjoin));
		if ($subCnt == 0) {
			push @result, $reln;
		}
		else {
			push @result, { $reln => $self->_build_join_for_hash($subjoin) };
		}
	}
	return $result[0] if scalar(@result) == 1;
	return \@result;
}

sub Search_spec {
	my $self = shift;
	my $params = shift;

	my $filter_search = [];
	#my $set_filters = {};
	if (defined $params->{filter}) {
		my $filters = $params->{filter};
		$filters = JSON::decode_json($params->{filter}) unless (ref($filters) eq 'ARRAY');
		if (defined $filters and ref($filters) eq 'ARRAY') {
			foreach my $filter (@$filters) {
				my $field = $filter->{field};
				# optionally convert table column name to db field name
				my $dbfName= $self->ExtNamesToDbFields->{$filter->{field}};
				$field = 'me.' . $field; # <-- http://www.mail-archive.com/dbix-class@lists.scsys.co.uk/msg02386.html
				defined $dbfName or $dbfName= $field;
				
				##
				## String type filter:
				##
				if ($filter->{type} eq 'string') {
					push @$filter_search, { $dbfName => { like =>  '%' . $filter->{value} . '%' } };
				}
				##
				## Date type filter:
				##
				elsif ($filter->{type} eq 'date') {
					my $dt = DateTime::Format::Flexible->parse_datetime($filter->{value}) or next;
					my $new_dt = DateTime->new(
						year		=> $dt->year,
						month		=> $dt->month,
						day		=> $dt->day,
						hour		=> 00,
						minute	=> 00,
						second	=> 00
					);
					if ($filter->{comparison} eq 'eq') {
						my $start_str = $new_dt->ymd . ' ' . $new_dt->hms;
						$new_dt->add({ days => 1 });
						my $end_str = $new_dt->ymd . ' ' . $new_dt->hms;
						push @$filter_search, {$dbfName => { '>' =>  $start_str, '<' => $end_str } };
					}
					elsif ($filter->{comparison} eq 'gt') {
						my $str = $new_dt->ymd . ' ' . $new_dt->hms;
						push @$filter_search, {$dbfName => { '>' =>  $str } };
					}
					elsif ($filter->{comparison} eq 'lt') {
						$new_dt->add({ days => 1 });
						my $str = $new_dt->ymd . ' ' . $new_dt->hms;
						push @$filter_search, {$dbfName => { '<' =>  $str } };
					}
				}
				##
				## Numeric type filter
				##
				elsif ($filter->{type} eq 'numeric') {
					if ($filter->{comparison} eq 'eq') {
						push @$filter_search, {$dbfName => { '=' =>  $filter->{value} } };
					}
					elsif ($filter->{comparison} eq 'gt') {
						push @$filter_search, {$dbfName => { '>' =>  $filter->{value} } };
					}
					elsif ($filter->{comparison} eq 'lt') {
						push @$filter_search, {$dbfName => { '<' =>  $filter->{value} } };
					}
				}
				##
				## List type filter (aka 'enum')
				##
				elsif ($filter->{type} eq 'list') {
					my @enum_or = ();
					foreach my $val (@{$filter->{value}}) {
						push @enum_or, {$dbfName => { '=' =>  $val } };
					}
					push @$filter_search, { -or => \@enum_or };
				}
				##
				##
				##
			}
		}
	}
	
	my $search = [];
	if (defined $params->{fields} and defined $params->{query} and $params->{query} ne '') {
		my $fields = JSON::decode_json($params->{fields});
		if (defined $fields and ref($fields) eq 'ARRAY') {
			foreach my $field (@$fields) {
				# optionally convert table column name to db field name
				my $dbfName= $self->ExtNamesToDbFields->{$field};
				$field = 'me.' . $field; # <-- http://www.mail-archive.com/dbix-class@lists.scsys.co.uk/msg02386.html
				defined $dbfName or $dbfName= $field;
				
				#next if ($set_filters->{$field});
				push @$search, { $dbfName => { like =>  '%' . $params->{query} . '%' } };
			}
		}
	}

	my $Search;
	if (scalar @$filter_search > 0) {
		#unshift @$search, { -and => $filter_search };
		$Search = { -and => [{ -or => $search },{ -and => $filter_search }] };
	}
	else {
		$Search = $search;
	}
	
	return $Search;
}



sub safe_create_row {
	my $self = shift;
	my $params = shift;
 
	my $safe_params = {};
	foreach my $col ($self->ResultSource->columns) {
		$safe_params->{$col} = $params->{$col} if (defined $params->{$col});
	}
 
	return $self->ResultSource->resultset->create($safe_params);
}





no Moose;
__PACKAGE__->meta->make_immutable;
1;
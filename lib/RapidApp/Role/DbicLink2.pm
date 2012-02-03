package RapidApp::Role::DbicLink2;
use strict;
use Moose::Role;

use RapidApp::Include qw(sugar perlutil);
use RapidApp::TableSpec::DbicTableSpec;
use Clone qw(clone);
use Text::Glob qw( match_glob );
use Hash::Diff qw( diff );
use Text::TabularDisplay;

# This allows supplying custom BUILD code via a constructor:
has 'onBUILD', is => 'ro', isa => 'Maybe[CodeRef]', default => undef;

has 'get_record_display' => ( is => 'ro', isa => 'CodeRef', lazy => 1, default => sub { 
	my $self = shift;
	return $self->TableSpec->get_Cnf('row_display');
});

# Useful for pages that display only the content of a single database record at a time.
# When set to true, rows are limited to "1" in the ResultSet in read_records and the
# pager is not used to perform the second query to get the total count
has 'single_record_fetch', is => 'ro', isa => 'Bool', default => 0;


# Colspec attrs can be specified as simple arrayrefs
has 'include_colspec' => ( is => 'ro', isa => 'ArrayRef[Str]', default => sub {[]} );
has 'relation_sep' => ( is => 'ro', isa => 'Str', default => '__' );

has 'updatable_colspec' => ( is => 'ro', isa => 'Maybe[ArrayRef[Str]]', default => undef );
has 'creatable_colspec' => ( is => 'ro', isa => 'Maybe[ArrayRef[Str]]', default => undef );

# Specify a list of relspecs to enable record destroy anmd specify which related rows
# should also be destroyed. For the base rel only, '*', specify other rels by name
# NOTE: This is simular in principle, but NOT the same as the colspecs. There is currently
# no real logic in this, no wildcard support, etc. It is just a list of relationship names
# that will be followed and be deleted along with the base. BE CAREFUL! This will delete whole
# sets of related rows. Most of the time you'll only want to put '*' in here
has 'destroyable_relspec' => ( is => 'ro', isa => 'Maybe[ArrayRef[Str]]', default => undef );

# These columns will always be fetched regardless of whether or not they were requested
# by the client:
has 'always_fetch_colspec' => ( is => 'ro', isa => 'Maybe[ArrayRef[Str]]', default => undef );

has 'ResultSource' => (
	is => 'ro',
	isa => 'DBIx::Class::ResultSource',
	required => 1
);

has 'get_ResultSet' => ( is => 'ro', isa => 'CodeRef', lazy => 1, default => sub {
	my $self = shift;
	return sub { $self->ResultSource->resultset };
});

sub baseResultSet {
	my $self = shift;
	return $self->get_ResultSet->(@_);
}

sub _ResultSet {
	my $self = shift;
	my $Rs = $self->baseResultSet(@_);
	$Rs = $self->ResultSet($Rs) if ($self->can('ResultSet'));
	return $Rs;
}

has 'get_CreateData' => ( is => 'ro', isa => 'CodeRef', lazy => 1, default => sub {
	my $self = shift;
	return sub { {} };
});

sub baseCreateData {
	my $self = shift;
	return $self->get_CreateData->(@_);
}

sub _CreateData {
	my $self = shift;
	my $data = $self->baseCreateData(@_);
	$data = $self->CreateData($data) if ($self->can('CreateData'));
	return $data;
}

#sub _ResultSet {
#	my $self = shift;
#	my $Rs = $self->ResultSource->resultset;
#	$Rs = $self->ResultSet($Rs) if ($self->can('ResultSet'));
#	return $Rs;
#}

has 'ResultClass' => ( is => 'ro', lazy_build => 1 );
sub _build_ResultClass {
	my $self = shift;
	my $source_name = $self->ResultSource->source_name;
	return $self->ResultSource->schema->class($source_name);
}


has 'TableSpec' => ( is => 'ro', isa => 'TableSpec', lazy_build => 1 );
sub _build_TableSpec {
	my $self = shift;
	
	my %opt = (
		name => $self->ResultSource->from,
		relation_sep => $self->relation_sep,
		ResultSource => $self->ResultSource,
		include_colspec => $self->include_colspec
	);
	
	$opt{updatable_colspec} = $self->updatable_colspec if (defined $self->updatable_colspec);
	$opt{creatable_colspec} = $self->creatable_colspec if (defined $self->creatable_colspec);
	$opt{always_fetch_colspec} = $self->always_fetch_colspec if (defined $self->always_fetch_colspec);
	
	return RapidApp::TableSpec::DbicTableSpec->new(%opt);
	#return RapidApp::TableSpec->with_traits('RapidApp::TableSpec::Role::DBIC')->new(%opt);
}


has 'record_pk' => ( is => 'ro', isa => 'Str', default => '___record_pk' );
has 'primary_columns_sep' => ( is => 'ro', isa => 'Str', default => '~$~' );
has 'primary_columns' => ( is => 'ro', isa => 'ArrayRef[Str]', lazy => 1, default => sub {
	my $self = shift;
	
	# If the db has no primary columns, then we have to use ALL the columns:
	unless ($self->ResultSource->primary_columns > 0) {
		my $class = $self->ResultSource->schema->class($self->ResultSource->source_name);
		$class->set_primary_key( $self->ResultSource->columns );
		$self->ResultSource->set_primary_key( $self->ResultSource->columns );
	}
	
	my @cols = $self->ResultSource->primary_columns;
	
	$self->apply_extconfig( primary_columns => [ $self->record_pk, @cols ] );

	return \@cols;
});


sub generate_record_pk_value {
	my $self = shift;
	my $data = shift;
	die "generate_record_pk_value(): expected hashref arg" unless (ref($data) eq 'HASH');
	return join(
		$self->primary_columns_sep, 
		map { defined $data->{$_} ? "'" . $data->{$_} . "'" : 'undef' } @{$self->primary_columns}
	);
}

# reverse generate_record_pk_value:
sub record_pk_cond {
	my $self = shift;
	my $value = shift;
	
	my $sep = quotemeta $self->primary_columns_sep;
	my @parts = split(/${sep}/,$value);
	
	my %cond = ();
	foreach my $col (@{$self->primary_columns}) {
		my $val = shift @parts;
		if ($val eq 'undef') {
			$val = undef;
		}
		else {
			$val =~ s/^\'//;
			$val =~ s/\'$//;
		}
		$cond{'me.' . $col} = $val;
	}

	return \%cond;
}




sub BUILD {}
around 'BUILD' => sub { &DbicLink_around_BUILD(@_) };
sub DbicLink_around_BUILD {
	my $orig = shift;
	my $self = shift;
	
	die "FATAL: DbicLink and DbicLink2 cannot both be loaded" if ($self->does('RapidApp::Role::DbicLink'));
	
	# Disable editing on columns that aren't updatable:
	#$self->apply_except_colspec_columns($self->TableSpec->updatable_colspec => {
	#	editor => ''
	#});
	
	$self->apply_columns( $self->record_pk => { 
		no_column => \1, 
		no_multifilter => \1, 
		no_quick_search => \1 
	});
	
	# Hide any extra colspec columns that were only added for relationship
	# columns:
	#$self->apply_colspec_columns($self->TableSpec->added_relationship_column_relspecs,
	#	no_column => \1, 
	#	no_multifilter => \1, 
	#	no_quick_search => \1 
	#);
	
	$self->$orig(@_);
	
	# init primary columns:
	$self->primary_columns;
	
	# TODO: find out why this option doesn't work when applied via other, newer config mechanisms:
	$self->apply_store_config(
		remoteSort => \1
	);
	
	$self->apply_extconfig(
		remote_columns		=> \1,
		loadMask				=> \1
	);
	
	
	# This allows supplying custom BUILD code via a constructor:
	$self->onBUILD->($self) if ($self->onBUILD);
}

sub apply_colspec_columns {
	my $self = shift;
	my $colspec = shift;
	my %opt = (ref($_[0]) eq 'HASH') ? %{ $_[0] } : @_; # <-- arg as hash or hashref
	
	my @colspecs = ( $colspec );
	@colspecs = @$colspec if (ref($colspec) eq 'ARRAY');

	my @columns = $self->TableSpec->get_colspec_column_names(@colspecs);
	my %apply = map { $_ => { %opt } } @columns;
	$self->apply_columns(%apply);
}

# Apply to all columns except those matching colspec:
sub apply_except_colspec_columns {
	my $self = shift;
	my $colspec = shift;
	my %opt = (ref($_[0]) eq 'HASH') ? %{ $_[0] } : @_; # <-- arg as hash or hashref

	my @colspecs = ( $colspec );
	@colspecs = @$colspec if (ref($colspec) eq 'ARRAY');
	
	my @columns = $self->TableSpec->get_except_colspec_column_names(@colspecs);
	my %apply = map { $_ => { %opt } } @columns;
	$self->apply_columns(%apply);
}

sub delete_colspec_columns {
	my $self = shift;
	my @colspecs = (ref($_[0]) eq 'ARRAY') ? @{$_[0]} : @_;
	
	my @columns = $self->TableSpec->get_colspec_column_names(@colspecs);
	return $self->delete_columns(@columns);
}

# Delete all columns except those matching colspec:
sub delete_except_colspec_columns {
	my $self = shift;
	my @colspecs = (ref($_[0]) eq 'ARRAY') ? @{$_[0]} : @_;
	
	die "delete_except_colspec_columns: no colspecs supplied" unless (@colspecs > 0);
	
	my @columns = $self->TableSpec->get_except_colspec_column_names(@colspecs);
	return $self->delete_columns(@columns);
}

sub apply_except_colspec_columns_ordered {
	my $self = shift;
	my $indx = shift;
	my $colspec = shift;
	my %opt = (ref($_[0]) eq 'HASH') ? %{ $_[0] } : @_; # <-- arg as hash or hashref

	my @colspecs = ( $colspec );
	@colspecs = @$colspec if (ref($colspec) eq 'ARRAY');
	
	my @columns = $self->TableSpec->get_except_colspec_column_names(@colspecs);
	my %apply = map { $_ => { %opt } } grep { exists $self->columns->{$_} } @columns;
	$self->apply_columns_ordered($indx,%apply);
}


sub read_records {
	my $self = shift;
	my $params = shift || $self->c->req->params;
	
	my $Rs = $self->_ResultSet;
	
	# Apply base Attrs:
	$Rs = $self->chain_Rs_req_base_Attr($Rs,$params);
	
	# Apply id_in search:
	$Rs = $self->chain_Rs_req_id_in($Rs,$params);
	
	# Apply explicit resultset:
	$Rs = $self->chain_Rs_req_explicit_resultset($Rs,$params);
	
	# Apply quicksearch:
	$Rs = $self->chain_Rs_req_quicksearch($Rs,$params);
	
	# Apply multifilter:
	$Rs = $self->chain_Rs_req_multifilter($Rs,$params);
	
	#scream_color(BOLD.RED,$Rs->{attrs});
	
	$Rs = $Rs->search_rs({},{rows => 1}) if ($self->single_record_fetch);
	
	# don't use Row objects
	$Rs = $Rs->search_rs(undef, { result_class => 'DBIx::Class::ResultClass::HashRefInflator' });
	
	# pull in our rows
	my $rows = [ $self->rs_all($Rs) ];
		
	#Hard coded munger for record_pk:
	foreach my $row (@$rows) {
		$row->{$self->record_pk} = $self->generate_record_pk_value($row);
	}
	
	# Now calculate a total, for the grid to display the number of available pages
	my $total = $self->single_record_fetch ? 1 : $Rs->pager->total_entries;

	return {
		rows    => $rows,
		results => $total,
	};
}

sub rs_all {
	my $self = shift;
	return (shift)->all;
}



# Applies base request attrs to ResultSet:
sub chain_Rs_req_base_Attr {
	my $self = shift;
	my $Rs = shift || $self->_ResultSet;
	my $params = shift || $self->c->req->params;
	
	$params = {
		start => 0,
		limit => 100000,
		dir => 'asc',
		%$params
	};
	
	my $attr = {
		'select' => [],
		'as' => [],
		join => {},
		page => int($params->{start}/$params->{limit}) + 1,
		rows => $params->{limit}
	};
	
	my $columns = $self->get_req_columns;
	
	my $used_aliases = {};
	my $dbic_name_map = {};
	
	for my $col (@$columns) {
		my $dbic_name = $self->TableSpec->resolve_dbic_colname($col,$attr->{join});
		
		unless (ref $dbic_name) {
			my ($alias,$field) = split(/\./,$dbic_name);
			my $prefix = $col;
			
			$prefix =~ s/${field}$//;
			$used_aliases->{$alias} = {} unless ($used_aliases->{$alias});
			$used_aliases->{$alias}->{$prefix}++ unless($alias eq 'me');
			my $count = scalar(keys %{$used_aliases->{$alias}});
			# automatically set alias for duplicate joins:
			$dbic_name = $alias . '_' . $count . '.' . $field if($count > 1);
		}
		
		$dbic_name_map->{$col} = $dbic_name;
		
		push @{$attr->{'select'}}, $dbic_name;
		push @{$attr->{'as'}}, $col;
	}
	
	if (defined $params->{sort} and defined $params->{dir}) {
		my $sort = lc($params->{sort});
		my $get_render_col = 1;
		my $sort_name = $dbic_name_map->{$sort} || $self->TableSpec->resolve_dbic_colname($sort,$attr->{join},$get_render_col);
		if (ref $sort_name eq 'HASH') {
			die "Can't sort by column if it doesn't have an SQL alias"
				unless exists $sort_name->{-as};
			$sort_name= $sort_name->{-as};
		}
		$attr->{order_by} = { '-' . $params->{dir} => $sort_name } ;
	}

	return $Rs->search_rs({},$attr);
}


hasarray 'always_fetch_columns', is => 'ro', lazy => 1, default => sub {
	my $self = shift;
	return [] unless ($self->always_fetch_colspec);
	return [ $self->TableSpec->get_colspec_column_names(
		$self->TableSpec->always_fetch_colspec->colspecs
	)];
};

sub get_req_columns {
	my $self = shift;
	my $params = shift || $self->c->req->params;
	my $param_name = shift || 'columns';
	
	my $columns = $params;
	$columns = $self->param_decodeIf($params->{$param_name},[]) if (ref($params) eq 'HASH');
	
	die "get_req_columns(): bad options" unless(ref($columns) eq 'ARRAY');
	
	# ---
	# If no columns were supplied by the client, add all the columns from
	# include_relspec
	# TODO: move column request logic that's currently only in AppGrid2 to a 
	# plugin/store where it can be used by other js modules like dataview
	unless(@$columns > 0) {
		push @$columns, $self->TableSpec->get_colspec_column_names(
			$self->TableSpec->include_colspec->colspecs
		);
		# Limit to current real/valid columns according to DataStore2:
		my %cols_indx = map {$_=>1} $self->column_name_list;
		@$columns = grep { $cols_indx{$_} } @$columns;
	}
	# ---
	
	
	push @$columns, $self->all_always_fetch_columns;
	
	my @exclude = ( $self->record_pk, 'loadContentCnf' );
	
	push @$columns, @{$self->primary_columns};
	
	my @req_fetch = ();
	foreach my $col (grep {defined $self->columns->{$_}} @$columns) {
		my $req = $self->columns->{$col}->required_fetch_columns or next;
		push @req_fetch, grep { defined $self->columns->{$_} } @$req;
	}
	push @$columns, @req_fetch;
	
	foreach my $col (@$columns) {
		my $column = $self->columns->{$col};
		push @exclude, $col if ($column->{no_fetch});
	}
	
	uniq($columns);
	my %excl = map { $_ => 1 } @exclude;
	@$columns = grep { !$excl{$_} } @$columns;
	
	return $columns;
}


# Applies id_in filter to ResultSet:
sub chain_Rs_req_id_in {
	my $self = shift;
	my $Rs = shift || $self->_ResultSet;
	my $params = shift || $self->c->req->params;
	
	my $id_in = $self->param_decodeIf($params->{id_in}) or return $Rs;
	
	return $Rs if (ref $id_in and ! ref($id_in) eq 'ARRAY');
	$id_in = [ $id_in ] unless (ref $id_in);
	
	# TODO: second form below doesn't work, find out why...
	return $Rs->search_rs({ '-or' => [ map { $self->record_pk_cond($_) } @$id_in ] });
	
	## If there is more than one primary column, we have to construct the condition completely 
	## different:
	#return $Rs->search_rs({ '-or' => [ map { $self->record_pk_cond($_) } @$id_in ] })
	#	if (@{$self->primary_columns} > 1);
	#	
	## If there is really only one primary column we can use '-in' :
	#my $col = $self->TableSpec->resolve_dbic_colname($self->primary_columns->[0]);
	#return $Rs->search_rs({ $col => { '-in' => $id_in } });
}


# Applies additional explicit resultset cond/attr to ResultSet:
sub chain_Rs_req_explicit_resultset {
	my $self = shift;
	my $Rs = shift || $self->_ResultSet;
	my $params = shift || $self->c->req->params;
	
	my $cond = $self->param_decodeIf($params->{resultset_condition},{});
	my $attr = $self->param_decodeIf($params->{resultset_attr},{});
	
	
	##
	## TODO: make this code handle more cases
	## This code converts [[ 'foo' ]] into \[ 'foo' ] and is needed because the later cannot
	## be expressed in JSON. This allows the client to send a literal col name
	if(ref($attr->{select}) eq 'ARRAY') {
		my @new;
		foreach my $sel (@{$attr->{select}}) {
			if(ref($sel) eq 'ARRAY' and scalar @$sel == 1 and ref($sel->[0]) eq 'ARRAY') {
				push @new, \[ $sel->[0]->[0] ];
			}
			else {
				push @new,$sel;
			}
		}
		@{$attr->{select}} = @new;
	}
	##
	##
	
	return $Rs->search_rs($cond,$attr);
}


# Applies multifilter search to ResultSet:
sub chain_Rs_req_quicksearch {
	my $self = shift;
	my $Rs = shift || $self->_ResultSet;
	my $params = shift || $self->c->req->params;
	
	delete $params->{query} if (defined $params->{query} and $params->{query} eq '');
	my $query = $params->{query} or return $Rs;
	
	my $fields = $self->param_decodeIf($params->{fields},[]);
	return $Rs unless (@$fields > 0);
	
	my $attr = { join => {} };
	
	my @search = ();
	push @search, { 
		$self->TableSpec->resolve_dbic_colname($_,$attr->{join}) => 
		{ like =>  '%' . $query . '%' } 
	} for (@$fields);
	
	return $Rs->search_rs({ '-or' => \@search },$attr);
}


# Applies multifilter search to ResultSet:
sub chain_Rs_req_multifilter {
	my $self = shift;
	my $Rs = shift || $self->_ResultSet;
	my $params = shift || $self->c->req->params;
	
	my $multifilter = $self->param_decodeIf($params->{multifilter}) or return $Rs;
	
	my $attr = { join => {} };
	my $cond = $self->multifilter_to_dbf($multifilter,$attr->{join});

	return $Rs->search_rs($cond,$attr);
}

sub multifilter_to_dbf {
	my $self = shift;
	my $multi = clone(shift);
	my $join = shift || {};
	
	return $self->multifilter_to_dbf({ '-and' => $multi },$join) if (ref($multi) eq 'ARRAY');
	
	die 'Invalid multifilter' unless (ref($multi) eq 'HASH');
	
	foreach my $f (keys %$multi) {
		if($f eq '-and' or $f eq '-or') {
			die "-and/-or must reference an ARRAY/LIST" unless (ref($multi->{$f}) eq 'ARRAY');
			my $new = [];
			push @$new, $self->multifilter_to_dbf($_,$join) for (@{$multi->{$f}});
			$multi->{$f} = $new;
			next;
		}
		
		my $dbfName = $self->TableSpec->resolve_dbic_colname($f,$join);
			
		if (!defined $dbfName) {
			$self->c->log->error("Client supplied Unknown multifilter-field '$f' in Ext Query!");
			next;
		}
		
		$multi->{$dbfName} = $multi->{$f};
		delete $multi->{$f};
		
		# --- translate special content conditions to "LIKE" conditions
		if (defined $multi->{$dbfName}->{contains}) {
			$multi->{$dbfName}->{like} = '%' . $multi->{$dbfName}->{contains} . '%';
			delete $multi->{$dbfName}->{contains};
		}
		
		if (defined $multi->{$dbfName}->{starts_with}) {
			$multi->{$dbfName}->{like} = $multi->{$dbfName}->{starts_with} . '%';
			delete $multi->{$dbfName}->{starts_with};
		}
		
		if (defined $multi->{$dbfName}->{ends_with}) {
			$multi->{$dbfName}->{like} = '%' . $multi->{$dbfName}->{ends_with};
			delete $multi->{$dbfName}->{ends_with};
		}
		
		if (defined $multi->{$dbfName}->{not_contain}) {
			$multi->{$dbfName}->{'not like'} = '%' . $multi->{$dbfName}->{not_contain} . '%';
			delete $multi->{$dbfName}->{not_contain};
		}
	}
	
	return $multi;
}



sub param_decodeIf {
	my $self = shift;
	my $param = shift;
	my $default = shift || undef;
	
	return $default unless (defined $param);
	
	return $param if (ref $param);
	return $self->json->decode($param);
}

has 'DataStore_build_params' => ( is => 'ro', isa => 'HashRef', default => sub {{}} );
before DataStore2_BUILD => sub {
	my $self = shift;
	
	my @store_fields = map {{ name => $_ }} uniq(
		$self->TableSpec->updated_column_order,
		'loadContentCnf', #<-- specific to AppGrid2
		$self->record_pk
	);
	
	my $store_params = {
		store_autoLoad => 1,
		reload_on_save => 0,
		remoteSort => \1,
		store_fields => \@store_fields
	};
	
	$store_params->{create_handler}	= RapidApp::Handler->new( scope => $self, method => '_dbiclink_create_records' ) if (
		defined $self->creatable_colspec and 
		not $self->can('create_records')
	);
	
	$store_params->{update_handler}	= RapidApp::Handler->new( scope => $self, method => '_dbiclink_update_records' ) if (
		defined $self->updatable_colspec and 
		not $self->can('update_records')
	);
	
	$store_params->{destroy_handler}	= RapidApp::Handler->new( scope => $self, method => '_dbiclink_destroy_records' ) if (
		defined $self->destroyable_relspec and 
		not $self->can('destroy_records')
	);
	
	# merge this way to make sure the opts get set, but yet still allow
	# the opts to be specifically overridden DataStore_build_params attr
	# is defined but with different params
	%{$self->DataStore_build_params} = ( %$store_params, %{$self->DataStore_build_params} );
};



# convenience method: prints the primary keys of a Row object
# just used to print info to the screen during CRUD ops below
sub get_Row_Rs_label {
	my $self = shift;
	my $Row = shift;
	my $verbose = shift;
	
	if($Row->isa('DBIx::Class::ResultSet')) {
		my $Rs = $Row;
		my $str = ref($Rs) . ' [' . $Rs->count . ' rows]';
		return $str unless ($verbose);
		$str .= ':';
		$str .= "\n " . $self->get_Row_Rs_label($_) for ($Rs->all);
		return $str;
	}

	my $Source = $Row->result_source;
	my @keys = $Source->primary_columns;
	my $data = { $Row->get_columns };
	
	my $str = ref($Row) . ' [ ';
	$str .= $_ . ': ' . $data->{$_} . ' ' for (@keys);
	$str .= ']';
	
	return $str;
}

# Gets programatically added as a method named 'update_records' (see BUILD modifier method above)
# 
# This first runs updates on each supplied (and allowed) relation.
# It then re-runs a read_records to tell the client what the new values are.
#
sub _dbiclink_update_records {
	my $self = shift;
	my $params = shift;
	
	my $limit_columns;
	my $declared_columns = $self->param_decodeIf($self->c->req->params->{columns});
	$limit_columns = { map {$_=>1} @$declared_columns } if ($declared_columns);
	
	# -- current real/valid columns according to DataStore2:
	my %cols_indx = map {$_=>1} $self->column_name_list;
	# --
	
	my $arr = $params;
	$arr = [ $params ] if (ref($params) eq 'HASH');
	
	#my $Rs = $self->ResultSource->resultset;
	my $Rs = $self->baseResultSet;
	
	my @updated_keyvals = ();
	
	# FIXME!!
	# There is a logic problem with update. The comparisons are done iteratively, and so when
	# update is called on one row, and then the backend logic changes another row that is
	# encountered later on in the update process, it can appear that rows were changed, when in fact they
	# were the original values, and it can change the data in an inconsistent/non-atomic way.
	# would be good to find a way to do this just like in create. What really needs to happen is
	# at least the column_data_alias remapping needs to be atomic (like create).
	# this currently only breaks in edge-cases (and where an incorrect/non-sensible set of colspecs
	# was supplied to begin with, but still needs to be FIXED). Needs to be thought about...
	# -- ^^^ --- UPDATE: I believe that I have solved this problem by now pushing rows into
	#                    a queue and then running updates at the end. Need to spend a bit more
	#                    time thinking about it though, so I am not removing the above comment yet
	
	try {
		$self->ResultSource->schema->txn_do(sub {
			foreach my $data (@$arr) {
				my $pkVal= $data->{$self->record_pk};
				defined $pkVal or die ref($self)."->update_records: Record is missing primary key '".$self->record_pk."'";
				my $BaseRow = $Rs->search($self->record_pk_cond($pkVal))->next or die usererr "Failed to find row by record_pk: $pkVal";
				
				# -- Filter out the supplied data packet according to the supplied 'columns' parameter
				# if the client has supplied a column list, filter out fieldnames that aren't in it.
				# The Ext store currently sends all of its configured store fields, including ones it never 
				# loaded from the database. If we don't do this filtering, those fields will appear to have
				# changed.
				#
				# FIXME: handle this on the client/js side so these fields aren't submitted at all
				if($limit_columns) {
					%$data = map { $_ => $data->{$_} } grep { $limit_columns->{$_} } keys %$data;
				}
				# --
				
				my @columns = grep { $_ ne $self->record_pk && $_ ne 'loadContentCnf' } keys %$data;
				
				@columns = $self->TableSpec->filter_updatable_columns(@columns);
				
				# -- Limit to current real/valid columns according to DataStore2:
				@columns = grep { $cols_indx{$_} } @columns;
				# --
				
				my @update_queue = ();
			
				$self->TableSpec->walk_columns_deep(sub {
					my $TableSpec = shift;
					my @columns = @_;
					
					my $Row = $_{return} || $BaseRow;
					return ' ' if ($Row eq ' ');
					
					#my $Row = exists $_{return} ? $_{return} : $BaseRow;
					#return undef unless (defined $Row);
					
					my $rel = $_{rel};
					my $UpdRow = $rel ? $Row->$rel : $Row;
					
					unless (defined $UpdRow) {
						scream('NOTICE: Relationship/row "' . $rel . '" is not defined'); 
						return ' ';
					}
					
					if ($UpdRow->isa('DBIx::Class::ResultSet')) {
						scream('NOTICE: Skipping multi relationship "' . $rel . '"'); 
						return ' ';
					}

					my %current = $UpdRow->get_columns;
					my %update = map { $_ => $data->{ $_{name_map}->{$_} } } keys %{$_{name_map}};
					
					# -- Need to do a map and a grep here; map to remap the values, and grep to prevent
					# the new values from being clobbered by identical key names from the original data:
					my $alias = $TableSpec->column_data_alias;
					my %revalias = map {$_=>1} values %$alias;
					%update = map { $alias->{$_} ? $alias->{$_} : $_ => $update{$_} } grep { !$revalias{$_} } keys %update;
					# --
					
					my $change = {};
					foreach my $col (keys %update) {
						next unless (exists $current{$col});
						next if (! defined $update{$col} and ! defined $current{$col});
						next if ($update{$col} eq $current{$col});
						$change->{$col} = $update{$col};
					}
					
					#my $change = diff(\%current, \%update);
					## why do I need to do this?:
					#foreach my $k (keys %$change) {
					#	my $v1 = $current{$k};
					#	my $v2 = $change->{$k};
					#	delete $change->{$k} if (! defined $v1 and ! defined $v2);
					#	next unless (defined $v1 and defined $v2);
					#	delete $change->{$k} if ($v1 eq $v2);
					#}
					
					my $msg = 'Will UPDATE -> ' . $self->get_Row_Rs_label($UpdRow) . "\n";
					if (keys %$change > 0){ 
						my $t = Text::TabularDisplay->new(qw(column old new));
						$t->add($_,disp($current{$_}),disp($change->{$_})) for (keys %$change);
						$msg .= $t->render;
					}
					else {
						$msg .= 'No Changes';
					}
					scream_color(WHITE.ON_BLUE.BOLD,$msg);
					push @update_queue,{ row => $UpdRow, change => $change };
					#$UpdRow->update($change) if (keys %$change > 0);
					
					return $UpdRow;
				},@columns);
				
				# Update all the rows at the end:
				$_->{row}->update($_->{change}) for (@update_queue);
				
				# Get the new record_pk for the row (it probably hasn't changed, but it could have):
				push @updated_keyvals, $self->generate_record_pk_value({ $BaseRow->get_columns });
			}
		});
	}
	catch {
		my $err = shift;
		$self->handle_dbic_exception($err);
		#die usererr rawhtml $self->make_dbic_exception_friendly($err), title => 'Database Error';
	};
	
	# Perform a fresh lookup of all the records we just updated and send them back to the client:
	my $newdata = $self->DataStore->read({ columns => [ keys %{ $arr->[0] } ], id_in => \@updated_keyvals });
	
	return {
		%$newdata,
		success => \1,
		msg => 'Update Succeeded'
	};
}

# Works with the hashtree supplied to create_records to recursively 
# remap columns according to supplied TableSpec column_data_aliases
sub hashtree_col_alias_map_deep {
	my $self = shift;
	my $hash = shift;
	my $TableSpec = shift;
	
	# Recursive:
	foreach my $rel (grep { ref($hash->{$_}) eq 'HASH' } keys %$hash) {
		my $rel_TableSpec = $TableSpec->related_TableSpec->{$rel} or next;
		$hash->{$rel} = $self->hashtree_col_alias_map_deep($hash->{$rel},$rel_TableSpec);
	}
	
	# -- Need to do a map and a grep here; map to remap the values, and grep to prevent
	# the new values from being clobbered by identical key names from the original data:
	my $alias = $TableSpec->column_data_alias;
	my %revalias = map {$_=>1} grep {!exists $hash->{$_}} values %$alias;
	%$hash = map { $alias->{$_} ? $alias->{$_} : $_ => $hash->{$_} } grep { !$revalias{$_} } keys %$hash;
	# --
	
	return $hash;
}


# Gets programatically added as a method named 'create_records' (see BUILD modifier method above)
sub _dbiclink_create_records {
	my $self = shift;
	my $params = shift;
	
	my $arr = $params;
	$arr = [ $params ] if (ref($params) eq 'HASH');
	
	#my $Rs = $self->ResultSource->resultset;
	my $Rs = $self->baseResultSet;
	
	my @req_columns = $self->get_req_columns(undef,'create_columns');
	
	# -- current real/valid columns according to DataStore2:
	my %cols_indx = map {$_=>1} $self->column_name_list;
	# --
	
	my @updated_keyvals = ();

	try {
		$self->ResultSource->schema->txn_do(sub {
			foreach my $data (@$arr) {
				
				# Apply optional base/hard coded data:
				%$data = ( %$data, %{$self->_CreateData} );
				my @columns = uniq(keys %$data,@req_columns);
				@columns = grep { $_ ne $self->record_pk && $_ ne 'loadContentCnf' } @columns;
				@columns = $self->TableSpec->filter_creatable_columns(@columns);
				
				# -- Limit to current real/valid columns according to DataStore2:
				@columns = grep { $cols_indx{$_} } @columns;
				# --
				
				my $relspecs = $self->TableSpec->columns_to_relspec_map(@columns);
			
				my $create_hash = {};
				
				foreach my $rel (keys %$relspecs) {
					$create_hash->{$rel} = {} unless (defined $create_hash->{$rel}); 
					$data->{$_->{orig_colname}} and $create_hash->{$rel}->{$_->{local_colname}} = $data->{$_->{orig_colname}} 
						for (@{$relspecs->{$rel}});
				}
				
				my $create = delete $create_hash->{''} || {};
				$create = { %$create_hash, %$create };
				
				# -- Recursively remap column_data_alias:
				$create = $self->hashtree_col_alias_map_deep($create,$self->TableSpec);
				# --
				
				my $msg = 'CREATE -> ' . ref($Rs) . "\n";
				if (keys %$create > 0){ 
					my $t = Text::TabularDisplay->new(qw(column value));
					#$t->add($_,ref $create->{$_} ? Dumper($create->{$_}) : $create->{$_} ) for (keys %$create);
					#$t->add($_,disp(sub{ ref $_ ? Dumper($_) : undef },$create->{$_}) ) for (keys %$create);
					$t->add($_,disp($create->{$_})) for (keys %$create);
					$msg .= $t->render;
				}
				else {
					$msg .= 'Empty Record';
				}
				scream_color(WHITE.ON_GREEN.BOLD,$msg);
				my $Row = $Rs->create($create);
				
				push @updated_keyvals, $self->generate_record_pk_value({ $Row->get_columns });
			}
		});
	}
	catch {
		my $err = shift;
		$self->handle_dbic_exception($err);
		#die usererr rawhtml $self->make_dbic_exception_friendly($err), title => 'Database Error';
	};
	
	# Perform a fresh lookup of all the records we just updated and send them back to the client:
	my $newdata = $self->DataStore->read({ columns => \@req_columns, id_in => \@updated_keyvals });
	
	return {
		%$newdata,
		success => \1,
		msg => 'Create Succeeded',
		use_this => 1
	};
}

# Gets programatically added as a method named 'destroy_records' (see BUILD modifier method above)
sub _dbiclink_destroy_records {
	my $self = shift;
	my $params = shift;
	
	my $arr = $params;
	$arr = [ $params ] if (not ref($params));
	
	#my $Rs = $self->ResultSource->resultset;
	my $Rs = $self->baseResultSet;
	
	try {
		$self->ResultSource->schema->txn_do(sub {
			my @Rows = ();
			foreach my $pk (@$arr) {
				my $Row = $Rs->search($self->record_pk_cond($pk))->next or die usererr "Failed to find row by record_pd: $pk";
				
				foreach my $rel (reverse sort @{$self->destroyable_relspec}) {
					next unless(
						$rel =~ /^[a-zA-Z0-9\-\_]+$/ 
						and $Row->can($rel)
					);
					
					my $relObj = $Row->$rel;
					
					scream_color(WHITE.ON_RED.BOLD,'DbicLink2 DESTROY --> ' . ref($Row) . '->' . $rel . ' --> ' .$self->get_Row_Rs_label($relObj,1) . "\n");
					$relObj->can('delete_all') ? $relObj->delete_all : $relObj->delete;
				}
				scream_color(WHITE.ON_RED.BOLD,'DbicLink2 DESTROY --> ' . $self->get_Row_Rs_label($Row,1) . "\n");
				$Row->delete;
			}
		});
	}
	catch {
		my $err = shift;
		$self->handle_dbic_exception($err);
		#die usererr rawhtml $self->make_dbic_exception_friendly($err), title => 'Database Error';
	};
	
	return 1;
}


sub handle_dbic_exception {
	my $self = shift;
	my $exception = shift;
	
	die $exception if (ref($exception) =~ /^RapidApp\:\:Responder/);
	die usererr rawhtml $self->make_dbic_exception_friendly($exception), title => 'DbicLink2 Database Error';
}


sub make_dbic_exception_friendly {
	my $self = shift;
	my $exception = shift;
	my $msg = "" . $exception . "";
	
	
	#### Fix me!!!! ####
	# Randomly getting this DBIx exception when throwing a customprompt object within CRUD operations
	# no idea silently pass it up for now
	die infostatus msg => "Bizarre copy of HASH in aassign", status => 500 if ($msg =~/Bizarre copy of HASH in aassign/);
	
	
	
	my @parts = split(/DBD\:\:mysql\:\:st execute failed\:\s*/,$msg);
	return $exception unless (scalar @parts > 1);
	
	$msg = $parts[1];
	
	@parts = split(/\s*\[/,$msg);

	return '<center><pre>' . $parts[0] . "</pre></center>";
	return $parts[0];
}


1;
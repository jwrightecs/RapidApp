package RapidApp::DBIC::Component::TableSpec;
use base 'DBIx::Class';

# DBIx::Class Component: ties a RapidApp::TableSpec object to
# a Result class for use in configuring various modules that
# consume/use a DBIC Source

use RapidApp::Include qw(sugar perlutil);

use RapidApp::TableSpec;
use RapidApp::DbicAppCombo2;

__PACKAGE__->mk_classdata( 'TableSpec' );
__PACKAGE__->mk_classdata( 'TableSpec_rel_columns' );

__PACKAGE__->mk_classdata( 'TableSpec_cnf' );

# See default profile definitions in RapidApp::TableSpec::Column
__PACKAGE__->mk_classdata( 'TableSpec_data_type_profiles' );
__PACKAGE__->TableSpec_data_type_profiles({
	text 			=> [ 'bigtext' ],
	blob 			=> [ 'bigtext' ],
	varchar 		=> [ 'text' ],
	char 			=> [ 'text' ],
	float			=> [ 'number' ],
	integer		=> [ 'number', 'int' ],
	tinyint		=> [ 'number', 'int' ],
	mediumint	=> [ 'number', 'int' ],
	bigint		=> [ 'number', 'int' ],
	datetime		=> [ 'datetime' ],
	timestamp	=> [ 'datetime' ],
});

sub apply_TableSpec {
	my $self = shift;
	my %opt = (ref($_[0]) eq 'HASH') ? %{ $_[0] } : @_; # <-- arg as hash or hashref
	
	$self->TableSpec_data_type_profiles(
		%{ $self->TableSpec_data_type_profiles || {} },
		%{ delete $opt{TableSpec_data_type_profiles} }
	) if ($opt{TableSpec_data_type_profiles});
	
	$self->TableSpec($self->create_result_TableSpec($self,%opt));
	
	$self->TableSpec_rel_columns({});
	$self->TableSpec_cnf({});
}

sub create_result_TableSpec {
	my $self = shift;
	my $ResultClass = shift;
	my %opt = (ref($_[0]) eq 'HASH') ? %{ $_[0] } : @_; # <-- arg as hash or hashref
	
	my $TableSpec = RapidApp::TableSpec->new( 
		name => $ResultClass->table,
		%opt
	);
	
	my $data_types = $self->TableSpec_data_type_profiles;
	
	foreach my $col ($ResultClass->columns) {
		my $info = $ResultClass->column_info($col);
		my @profiles = ();
		
		push @profiles, $info->{is_nullable} ? 'nullable' : 'notnull';
		
		my $type_profile = $data_types->{$info->{data_type}} || ['text'];
		$type_profile = [ $type_profile ] unless (ref $type_profile);
		push @profiles, @$type_profile; 
		
		$TableSpec->add_columns( { name => $col, profiles => \@profiles } ); 
	}
	
	return $TableSpec;
}


sub TableSpec_add_columns_from_related {
	my $self = shift;
	my $rels = get_mixed_hash_args(@_);
	
	foreach my $rel (keys %$rels) {
		my $conf = $rels->{$rel};
		$conf = {} unless (ref($conf) eq 'HASH');
		
		$conf = { %{ $self->TableSpec->default_column_properties }, %$conf } if ( $self->TableSpec->default_column_properties );
		
		$conf->{column_property_transforms}->{name} = sub { $rel . '_' . $_ };
		
		# If its a relationship column that will setup a combo:
		$conf->{column_property_transforms} = { %{$conf->{column_property_transforms}},
			key_col => sub { $rel . '_' . $_ },
			render_col => sub { $rel . '_' . $_ },
		};
		
		my $info = $self->relationship_info($rel) or next;
		
		# Make sure the related class is already loaded:
		eval 'use ' . $info->{class};
		die $@ if ($@);
		
		my $TableSpec = $info->{class}->TableSpec->copy($conf) or next;
		
		my @added = $self->TableSpec->add_columns_from_TableSpec($TableSpec);
		foreach my $Column (@added) {
			$self->TableSpec_rel_columns->{$rel} = [] unless ($self->TableSpec_rel_columns->{$rel});
			push @{$self->TableSpec_rel_columns->{$rel}}, $Column->name;
			
			# Add a new global_init_coderef entry if this column has one:
			rapidapp_add_global_init_coderef( sub { $Column->call_rapidapp_init_coderef(@_) } ) 
				if ($Column->rapidapp_init_coderef);
		}
	}
}


sub TableSpec_add_relationship_columns {
	my $self = shift;
	my %opt = (ref($_[0]) eq 'HASH') ? %{ $_[0] } : @_; # <-- arg as hash or hashref
	
	
	# Moved to TableSpec::Role::DBIC
	#return;
	
	
	
	my $rels = \%opt;
	
	foreach my $rel (keys %$rels) {
		my $conf = $rels->{$rel};
		$conf = {} unless (ref($conf) eq 'HASH');
		
		$conf = { %{ $self->TableSpec->default_column_properties }, %$conf } if ( $self->TableSpec->default_column_properties );
		
		die "displayField is required" unless (defined $conf->{displayField});
		
		$conf->{render_col} = $rel . '_' . $conf->{displayField} unless ($conf->{render_col});
		
		my $info = $self->relationship_info($rel) or die "Relationship '$rel' not found.";
		
		$conf->{foreign_col} = $self->get_foreign_column_from_cond($info->{cond});
		$conf->{valueField} = $conf->{foreign_col} unless (defined $conf->{valueField});
		$conf->{key_col} = $rel . '_' . $conf->{valueField};
		
		#Temporary/initial column setup:
		$self->TableSpec->add_columns({ name => $rel, %$conf });
		my $Column = $self->TableSpec->get_column($rel);
		
		#$self->TableSpec_rel_columns->{$rel} = [] unless ($self->TableSpec_rel_columns->{$rel});
		#push @{$self->TableSpec_rel_columns->{$rel}}, $Column->name;
		
		# Temp placeholder:
		$Column->set_properties({ editor => 'relationship_column' });
		
		my $ResultClass = $self;
		
		$Column->rapidapp_init_coderef( sub {
			my $self = shift;
			
			my $rootModule = shift;
			$rootModule->apply_init_modules( tablespec => 'RapidApp::AppBase' ) 
				unless ( $rootModule->has_module('tablespec') );
			
			my $TableSpecModule = $rootModule->Module('tablespec');
			my $c = RapidApp::ScopedGlobals->get('catalystClass');
			my $Source = $c->model('DB')->source($info->{source});
			
			my $valueField = $self->get_property('valueField');
			my $displayField = $self->get_property('displayField');
			my $key_col = $self->get_property('key_col');
			my $render_col = $self->get_property('render_col');
			my $auto_editor_type = $self->get_property('auto_editor_type');
			my $rs_condition = $self->get_property('ResultSet_condition') || {};
			my $rs_attr = $self->get_property('ResultSet_attr') || {};
			
			my $editor = $self->get_property('editor') || {};
			
			my $column_params = {
				required_fetch_columns => [ 
					$key_col,
					$render_col
				],
				
				read_raw_munger => RapidApp::Handler->new( code => sub {
					my $rows = (shift)->{rows};
					$rows = [ $rows ] unless (ref($rows) eq 'ARRAY');
					foreach my $row (@$rows) {
						$row->{$self->name} = $row->{$key_col};
					}
				}),
				update_munger => RapidApp::Handler->new( code => sub {
					my $rows = shift;
					$rows = [ $rows ] unless (ref($rows) eq 'ARRAY');
					foreach my $row (@$rows) {
						if ($row->{$self->name}) {
							$row->{$key_col} = $row->{$self->name};
							delete $row->{$self->name};
						}
					}
				}),
				no_quick_search => \1,
				no_multifilter => \1
			};
			
			$column_params->{renderer} = jsfunc(
				'function(value, metaData, record, rowIndex, colIndex, store) {' .
					'return record.data["' . $render_col . '"];' .
				'}', $self->get_property('renderer')
			);
			
			# If editor is no longer set to the temp value 'relationship_column' previously set,
			# it means something else has set the editor, so we don't overwrite it:
			if ($editor eq 'relationship_column') {
				if ($auto_editor_type eq 'combo') {
				
					my $module_name = $ResultClass->table . '_' . $self->name;
					$TableSpecModule->apply_init_modules(
						$module_name => {
							class	=> 'RapidApp::DbicAppCombo2',
							params	=> {
								valueField		=> $valueField,
								displayField	=> $displayField,
								name				=> $self->name,
								ResultSet		=> $Source->resultset,
								RS_condition	=> $rs_condition,
								RS_attr			=> $rs_attr,
								record_pk		=> $valueField
							}
						}
					);
					my $Module = $TableSpecModule->Module($module_name);
					
					# -- vv -- This is required in order to get all of the params applied
					$Module->call_ONREQUEST_handlers;
					$Module->DataStore->call_ONREQUEST_handlers;
					# -- ^^ --
					
					$column_params->{editor} = { %{ $Module->content }, %$editor };
				}
			}
			
			$self->set_properties({ %$column_params });
		});
		
		# This coderef gets called later, after the RapidApp
		# Root Module has been loaded.
		rapidapp_add_global_init_coderef( sub { $Column->call_rapidapp_init_coderef(@_) } );
	}
}


sub related_TableSpec {
	my $self = shift;
	my $rel = shift;
	my %opt = (ref($_[0]) eq 'HASH') ? %{ $_[0] } : @_; # <-- arg as hash or hashref
	
	my $info = $self->relationship_info($rel) or die "Relationship '$rel' not found.";
	my $class = $info->{class};
	
	# Manually load and initialize the TableSpec component if it's missing from the
	# related result class:
	unless($class->can('TableSpec')) {
		$class->load_components('+RapidApp::DBIC::Component::TableSpec');
		$class->apply_TableSpec(%opt);
	}
	
	return $class->TableSpec;
}



# TODO: Find a better way to handle this. Is there a real API
# in DBIC to find this information?
sub get_foreign_column_from_cond {
	my $self = shift;
	my $cond = shift;
	
	die "currently only single-key hashref conditions are supported" unless (
		ref($cond) eq 'HASH' and
		scalar keys %$cond == 1
	);
	
	foreach my $i (%$cond) {
		my ($side,$col) = split(/\./,$i);
		return $col if (defined $col and $side eq 'foreign');
	}
	
	die "Failed to find forein column from condition: " . Dumper($cond);
}


my %hash_conf_params = map {$_=>1} qw(
column_properties
column_properties_ordered
relationship_columns
related_column_property_transforms
column_order_overrides
);

sub TableSpec_set_conf {
	my $self = shift;
	my $param = shift || return undef;
	my $value = shift || die "TableSpec_set_conf(): missing value for param '$param'";
	
	return $self->TableSpec_set_hash_conf($param,$value,@_) 
		if($hash_conf_params{$param} and @_ > 0);
		
	$self->TableSpec_cnf->{$param} = {
		order => [],
		data => $value
	};
	
	return $self->TableSpec_set_conf(@_);
}



# Stores arbitrary hashes, preserving their order
sub TableSpec_set_hash_conf {
	my $self = shift;
	my $param = shift;
	
	return $self->TableSpec_set_conf($param,@_) if (@_ == 1); 
	
	my %opt = get_mixed_hash_args_ordered(@_);
	
	my $i = 0;
	my $order = [ grep { ++$i & 1 } @_ ]; #<--get odd elements (keys)
	
	my $data = \%opt;
	
	$self->TableSpec_cnf->{$param} = {
		order => $order,
		data => $data
	};
}

sub TableSpec_get_conf {
	my $self = shift;
	my $param = shift;
	
	my $cnf = $self->TableSpec_cnf->{$param} or return undef;
	
	return map { $_ => $cnf->{data}->{$_} } @{$cnf->{order}};
}

sub TableSpec_has_conf {
	my $self = shift;
	my $param = shift;
	return 1 if (exists $self->TableSpec_cnf->{$param});
	return 0;
}




sub TableSpec_set_conf_column_order {
	my $self = shift;
	my $offset = $_[0];
	die "TableSpec_set_column_order(): expected offset/index number in first arg (got '$offset')" unless (
		defined $offset and
		$offset =~ /^\d+$/
	);
	return $self->TableSpec_set_conf_column_order_base(@_);
}

# Like TableSpec_set_conf_column_order but the offset is the name of another column
sub TableSpec_set_conf_column_order_after {
	my $self = shift;
	my $colname = shift;
	return $self->TableSpec_set_conf_column_order_base('+' . $colname,@_);
}

# Like TableSpec_set_conf_column_order but the offset is the name of another column
sub TableSpec_set_conf_column_order_before {
	my $self = shift;
	my $colname = shift;
	return $self->TableSpec_set_conf_column_order_base('-' . $colname,@_);
}

# Can be called over and over again to apply and re-apply
sub TableSpec_set_conf_column_order_base {
	my $self = shift;
	my $offset = shift;
	my @cols = @_;
	@cols = $_[0] if (ref($_[0]));
	die "TableSpec_set_column_order(): no column names supplied" unless (@cols > 0);
	
	$self->TableSpec_cnf->{column_order_overrides}->{data} = [] 
		unless ($self->TableSpec_cnf->{column_order_overrides}->{data});
		
	push @{$self->TableSpec_cnf->{column_order_overrides}->{data}}, [$offset,\@cols];
}

1;

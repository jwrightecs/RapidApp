package RapidApp::Module::Grid::SearchBox::Normal;

use strict;
use warnings;

use Moo;
extends 'RapidApp::Module::Grid::SearchBox';
use Types::Standard ':all';

use RapidApp::Util qw(:all);
use Scalar::Util qw(looks_like_number);


has '+documentation', default => sub { join(" ",
  'This is the default quick search mode which searches substrings of all the selected columns, and is also',
  'case insensitive.',
  "\n\n",
  'As a "substring" search, this means means partial values will match, even if it the search term matches',
  'just a few letters within any of the column values. Since this is an intensive, string comparison search,',
  'this search can be slow depending on the number of rows in the table as well as which columns are included.'
)};

has '+mode_name',       default => sub { 'like' };
has '+label',           default => sub { 'Quick Search' };
has '+menu_text',       default => sub { 'Normal' };
has '+choose_columns', default => sub { 1 };

has 'exact_matches',
  is => 'ro', 
  isa => Bool, 
  default => sub { 0 };
  
has 'like_operator', is => 'ro', lazy => 1, default => sub {
  my $self = shift;
  
  # Special just for Postgres: we want to use "ILIKE" instead of "LIKE" because LIKE
  # is case-sensitive in Postgres. Additionallly, we want to use the special syntax
  # ::text to "cast" the column as text first, otherwise we'll get exceptions when
  # ilike is ran on non text coliumns, like 'date' and other types
  $self->_db_is_Postgres ? '::text ilike' : 'like'
    
}, isa => Str;

has 'exact_operator', is => 'ro', lazy => 1, default => sub {
  my $self = shift;
  
  # Special just for Postgres: also cast all exact matches into text to avoid possible
  # type errors, like out of range numbers for numeric cols, etc
  $self->_db_is_Postgres ? '::text =' : '='
    
}, isa => Str;


has '_db_is_Postgres', is => 'ro', lazy => 1, default => sub {
  my $self = shift;
  $self->grid_module->_dbh_driver eq 'Pg' ? 1 : 0
}, isa => Bool;


=head2 chain_query_search_rs

  $modified_resultset = $searchbox->chain_query_search_rs( $resultset, $params );

This method is called by the Grid to apply the QuickSearch query information in
C<$params> to the C<$resultset>, returning a chained C<$modified_resultset>.

If the C<$params> do not contain a C<'query'> string, this returns the C<$resultset>
un-changed.  If the C<$params> describe a search that does not search any columns,
this method returns a resultset that finds zero rows.

=cut

sub chain_query_search_rs {
  my ($self, $Rs, $opt) = @_;
  
  return $Rs unless (ref($opt)||'' eq 'HASH');
  my $query = $opt->{query};
  return $Rs unless defined $query && length $query;
  
  my $search = $self->_get_query_condition_list($Rs,$opt) || [];
  
  # If no search conditions have been populated at all it means the query
  # failed pre-validation for all active columns. We need to simulate
  # a condition which will return no rows
  unless(scalar(@$search) > 0) {
    # Simple dummy condition that will always be false to force 0 results
    return $Rs->search_rs(\'1 = 2');
  }

  return $self->_call_search_rs($Rs,{ '-or' => $search })
}


sub _get_query_condition_list {
  my ($self, $Rs, $opt, $attr) = @_;
  
  $self->_enforce_valid_opt($opt);
  $attr ||= $self->{__current_attr} || { join => {} };
  
  my @search = ();
  for my $col (@{$opt->{columns}}) {
    my $cond = $self->get_condition_for_column($Rs, { col => $col, %$opt }, $attr);
    push @search, $cond if defined $cond;
  }

  return \@search
}

=head2 get_condition_for_column

  $sql_abstract_clause= $searchbox->get_condition_for_column( $resultset, \%opts, \%attrs )
  # where %opts contains:
  {
    query   => $query_text,
    col     => $rapidapp_column_name, # may be virtual
  }
  # and %attrs is the DBIC attributes to be applied with the search

This method generates a DBIC clause for one column.  In this SearchBox implementation,
the clauses for each column are "OR"ed to create the final DBIC search clause.
Subclasses may use this method to tap into the default per-column behavior, or override
behavior for specific columns.

This method should return C<undef> if this column cannot match the search phrase,
such as if the user searches for alphanumeric text and the column can only hold integers.

=cut

sub get_condition_for_column {
  my ($self, $Rs, $opt, $attr)= @_;
  my $Grid = $self->grid_module;
  my $col  = $opt->{col};
  my $cnf  = $Grid->get_column($col) or die "field/column '$col' not found!";
  my $query = $opt->{query};
  my $exact = $self->exact_matches;
  
  # Force to exact mode via optional TableSpec column cnf override: (LEGACY)
  $exact = 1 if (
    exists $cnf->{quick_search_exact_only}
    && jstrue($cnf->{quick_search_exact_only})
  );

  my $dtype    = $cnf->{broad_data_type} || 'text';
  my $dbicname = $Grid->_extract_hash_inner_AS( $Grid->resolve_dbic_colname($col,$attr->{join}) );

  # For numbers, force to 'exact' mode and discard (return undef) for queries
  # which are not numbers (since we already know they will not match anything).
  # This is also now safe for PostgreSQL which complains when you try to search
  # on a numeric column with a non-numeric value:
  if ($dtype eq 'integer') {
    return undef unless $query =~ /^[+-]*[0-9]+$/;
    $exact = 1;
  }
  elsif ($dtype eq 'number') {
    return undef unless looks_like_number( $query );
    $exact = 1;
  }

  # Special-case: pre-validate enums (Github Issue #56)
  my $enumVh = $cnf->{enum_value_hash};
  if ($enumVh) {
    return undef unless $enumVh->{$query};
    $exact = 1;
  }

  # New for GitHub Issue #97
  my $strf = $cnf->{search_operator_strf};
  my $s = $strf ? sub { sprintf($strf,shift) } : sub { shift };

  # 'text' is the only type which can do a LIKE (i.e. sub-string)
  return $exact
    ? $Grid->_op_fuse($dbicname => { $s->($self->exact_operator) => $query })
    : $Grid->_op_fuse($dbicname => { $s->($self->like_operator) => join('%','',$query,'') });
}

1;

package RapidApp::View::Web1Cfg;

use Moose;
use namespace::autoclean;
BEGIN { extends 'Catalyst::View'; }

use RapidApp::Include 'perlutil', 'sugar';

has '_css_files' => ( is => 'rw', isa => 'HashRef', default => sub {{}} );
has '_js_files'  => ( is => 'rw', isa => 'HashRef', default => sub {{}} );
has '_header_extra' => ( is => 'rw', isa => 'ArrayRef', default => sub {[]} );

sub process {
	my ($self, $c)= @_;
	
	$c->res->header('Cache-Control' => 'no-cache');
	
	# clear css and javascript includes
	%{$self->_css_files}= ();
	%{$self->_js_files}= ();
	
	# generate the html
	my $html= $self->genRoot($c->stash->{web1cfg});
	
	$c->stash->{css_inc_list}= keys(%{$self->_css_files});
	$c->stash->{js_inc_list}= keys(%{$self->_js_files});
	$c->stash->{header}= join('\n', @{$self->_header_extra});
	$c->stash->{content}= $html;
	$c->stash->{template}= 'templates/rapidapp/web1_page.tt';
	return $c->view('RapidApp::TT')->process($c);
}

sub c {
	return RapidApp::ScopedGlobals->c;
}
sub stash {
	return c->stash;
}

sub htmlEsc {
	my $text= shift;
	$text =~ s/</&lt;/g;
	$text =~ s/>/&gt;/g;
	$text =~ s/&/&amp;/g;
	$text =~ s/"/&quot;/g;
	return $text;
}

sub genRoot {
	my ($self, $cfg)= @_;
	return '<pre>'.htmlEsc(Dumper($cfg)).'</pre>';
}

1;
package RapidApp::Controller::DirectCmp;

use strict;
use warnings;

use Moose;
BEGIN { extends 'Catalyst::Controller'; }
use namespace::autoclean;

use RapidApp::Include qw(sugar perlutil);

# This is a special controller designed to render a single RapidApp 
# Module in its own Viewport (i.e. in an iFrame)

sub default :Path {
  my ($self, $c, @args) = @_;
  # Fallback to 'direct'
  return $self->direct($c,@args);
}

sub direct :Local {
  my ($self, $c, @args) = @_;

  $c->req->params->{__no_hashnav_redirect} = 1;
  $c->stash->{render_viewport} = 1;

  return $c->redispatch_public_path(@args);
}

sub navable :Local {
  ...
  
  # TODO: the idea here is that the module will be wrapped in a navable
  # parent, such as an AppTab which can handle hashnav events
  
}


no Moose;
__PACKAGE__->meta->make_immutable;
1;

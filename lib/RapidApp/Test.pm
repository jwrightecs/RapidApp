package RapidApp::Test;
use base 'Catalyst::Test';

use strict;
use warnings;
use Import::Into;

use HTTP::Request::Common;
use JSON qw(decode_json);

my $target;
my $app_class;

sub import {
  $target = caller;
  my ($self, $class, @args) = @_;
  
  # Since apps might take a while to start-up:
  ok($class,"[RapidApp::Test]: loading testapp '$class'...");
  
  ok(
    Catalyst::Test->import::into($target,$class,@args),
    "$class loaded/started"
  );
  
  my @funcs = grep { 
    $_ ne 'import' && $_ ne 'AUTOLOAD'
  } Class::MOP::Class->initialize(__PACKAGE__)->get_method_list;
  
  # Manually export our functions:
  {
    no strict 'refs';
    *{ join('::',$target,$_) } = \*{ $_ } for (@funcs);
  }
  
  $app_class = $class;
};

our $AUTOLOAD;
sub AUTOLOAD {
  my $method = (reverse(split('::',$AUTOLOAD)))[0];
  $target->can($method)->(@_);
}

# These are tests which should pass for all RapidApp applications:
sub run_common_tests {

  action_ok(
    '/assets/rapidapp/misc/static/images/rapidapp_powered_logo_tiny.png',
    "Fetched RapidApp logo from the Misc asset controller"
  );

  action_notfound(
    '/assets/rapidapp/misc/static/some/bad/file.txt',
    "Invalid asset path not found as expected"
  );

}

# Simulate an Ajax POST request as if it was generated by the
# RapidApp/ExtJS JavaScript client/browser to a JSON-encoded
# resource. Decodes and returns the JSON as perl ref
sub ajax_post_decode {
  my ($url, $params, $msg) = @_;
  
  $msg ||= "ajax_post_decode ($url)";
  my $arr_arg = ref($params) eq 'HASH' ? [%$params] : $params;
  
  my $req = POST $url, $arr_arg;
  $req->header(
    'X-RapidApp-RequestContentType' => 'JSON',
    'X-RapidApp-VERSION'            => $RapidApp::VERSION,
    'X-Requested-With'              => 'XMLHttpRequest',
    'Content-Type'                  => 'application/x-www-form-urlencoded; charset=UTF-8'
  );

  ok(
    my $res = request($req),
    $msg
  );
  
  ok(
    my $decoded = decode_json($res->decoded_content),
    "Received valid JSON response from POST ($url)"
  );

  return $decoded;
}


sub ajax_get_raw {
  my ($url, $msg) = @_;
  
  $msg ||= "ajax_get_raw ($url)";
  
  my $req = GET $url;
  $req->header(
    'X-RapidApp-RequestContentType' => 'JSON',
    'X-RapidApp-VERSION'            => $RapidApp::VERSION,
    'X-Requested-With'              => 'XMLHttpRequest',
    'Content-Type'                  => 'application/x-www-form-urlencoded; charset=UTF-8'
  );

  ok(
    my $res = request($req),
    $msg
  );
  
  return $res->decoded_content;
}


sub ajax_get_decode {
  my ($url, $msg) = @_;
  
  my $content = ajax_get_raw(@_);
  
  ok(
    my $decoded = decode_json($content),
    "Received valid JSON response from GET ($url)"
  );

  return $decoded;
}


1;
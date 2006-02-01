#!/usr/bin/perl

use strict;
use warnings;

use POE;
use POE::Wheel::SocketFactory;
use POE::Component::ForkManager;

POE::Session->create(
	package_states => [
		main => [qw(_start child_fork child_shutdown success decrease)],
	],
);

POE::Kernel->run();

sub _start {
	my ($kernel, $session, $heap) = @_[KERNEL, SESSION, HEAP];

	my $listener = $heap->{listener} = POE::Wheel::SocketFactory->new(
		BindPort	=> '3003',
		SuccessEvent	=> 'success',
		FailureEvent	=> 'failure',
		Reuse		=> 1,
	);
	$listener->pause_accept;

	my $forkmanager = $heap->{forkmanager} = POE::Component::ForkManager->new();
 	$forkmanager->callback( child_fork => $session->postback( 'child_fork' ) );
	$forkmanager->callback( child_shutdown => $session->postback( 'child_shutdown' ) );
	$forkmanager->limits( 10, 15 ); # 10 idle minimum, 15 maximum
	$kernel->delay( 'decrease', 10 );
}

sub child_fork {
	my ($kernel, $heap) = @_[KERNEL, HEAP];
	warn "Fork Child!\n";
	$0 = "Waiting for connection";
	$heap->{listener}->resume_accept;
	$kernel->state( 'decrease' );
}

sub child_shutdown {
	my $heap = $_[HEAP];
	warn "Shutdown Child!\n";
	delete( $heap->{listener} );
}

sub success {
	my $handle = $_[ARG0];

	warn "[$$] Blah!\n";
	$0 = "Accepting connection";
	$_[HEAP]->{forkmanager}->busy();
	delete( $_[HEAP]->{listener} );
	delete( $_[HEAP]->{forkmanager} );
	$_[KERNEL]->delay( 'done', 10 );
}

sub decrease {
	my $heap = $_[HEAP];

	$heap->{forkmanager}->limits( 4, 7 );
}

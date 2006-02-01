package POE::Component::ForkManager;

use 5;

use strict;
use warnings;

use vars '$VERSION';

$VERSION = '0.00_01';

use POE;

use POE::Wheel::ReadWrite;
use POE::Filter::Block;
use POE::Driver::SysRW;
use POE::Pipe::TwoWay;

sub DEBUGGING () { 0 }

sub new {
	my $class = shift;
	my ($min, $max) = @_;

	$min ||= 0;
	$max ||= 0;

	my $self = bless {}, (ref $class || $class);

	POE::Session->create(
		package_states => [
			 __PACKAGE__, [qw(
			 	_start
				_stop
				spawn_child
				sigchld
				parent_input
				child_input
				child_flushed
				check_idle
			)],
		],
		heap => {
			pids => {},
			wheels => {},
			min_idle => $min,
			max_idle => $max,
			idle => {},
			callbacks => {},
		},
		args => [
			$self,
		],
	);

	return $self;
}

sub limits {
	my $self = shift;
	my ($min, $max) = @_;

	my $heap = $self->{heap};

	if (defined( $min )) {
		$heap->{min_idle} = $min + 0;
	}
	if (defined( $max )) {
		$heap->{max_idle} = $max + 0;
	}

	$self->{check_idle}->();

	return( $heap->{min_idle}, $heap->{max_idle} );
}

sub callback {
	my $self = shift;
	my ($name, $value) = @_;
	my $callbacks = $self->{heap}->{callbacks};

	if (defined( $value )) {
		$callbacks->{$name} = $value;
	}
	else {
		delete( $callbacks->{$name} );
	}
}

sub busy {
	my $self = shift;
	my $heap = $self->{heap};
	
	my $write = $heap->{amulet} = $heap->{write};
	$write->put( 0 );
}

sub idle {
	my $self = shift;
	my $heap = $self->{heap};

	my $write = $heap->{amulet} = $heap->{write};
	$write->put( 1 );
}

sub DESTROY {
	my $self = shift;
	
	warn "DESTROY\n" if DEBUGGING;
	
	my $heap = delete( $self->{heap} );

	my $write = delete( $heap->{write} );
	
	$heap->{min_idle} = $heap->{max_idle} = 0;
	$self->{check_idle}->();

	delete( $self->{check_idle} );
}

sub _start {
	my ($kernel, $session, $heap, $object) = @_[KERNEL, SESSION, HEAP, ARG0];

	# Set up the first batch of child processes, if any.
	$kernel->yield( 'check_idle' );

	# Detach from the parent session so that we don't hold it alive.
	$kernel->detach_myself();

	$object->{check_idle} = $session->callback( 'check_idle' );
	$object->{heap} = $heap;
}

sub _stop {
	warn "[$$] Stopping\n" if DEBUGGING;
}

sub spawn_child {
	my ($kernel, $heap) = @_[KERNEL, HEAP];
	my $pids = $heap->{pids};
	my $wheels = $heap->{wheels};

	# Our pipe, for IPC
	my ($parent_read, $parent_write, $child_read, $child_write) = POE::Pipe::TwoWay->new();

	# Build Filter and Driver before we fork, saves cycles later and reduces linecount
	my $filter = POE::Filter::Block->new( BlockSize => 1 );
	my $driver = POE::Driver::SysRW->new();

	$_[KERNEL]->sig( 'CHLD', 'sigchld' );
	
	# Where once was one, there are now two.
	my $fork = fork();

	if (!defined( $fork )) {
		warn( "[POE::Component::Forkmanager] Fork Failed: $!\n" );
	}
	elsif( $fork ) {
		# Parent process
		my $wheel = $pids->{$fork} = POE::Wheel::ReadWrite->new(
			InputHandle	=> $parent_read,
			OutputHandle	=> $parent_write,
			Driver		=> $driver,
			Filter		=> $filter,
			InputEvent	=> 'parent_input',
		);
		$wheels->{$wheel->ID} = $fork;

		# A new process is counted as idle, because we don't want to
		# end up forking and flooding the machine.
		$heap->{idle}->{$fork} = 1;

		# TODO make child startup tracking more robust. Push startup pids
		# on an array, add a delay event to forcibly kill them if they haven't
		# signaled that they are ready soon enough. Possibly refactor this into
		# a general 'watchdog' design.
		return 0;
	}
	else {
		# Child process
		$kernel->sig( 'CHLD' );
		$kernel->state( 'sigchld' );
		$kernel->state( 'spawn_child' ); # Prevent children from forking themselves.
		$kernel->state( 'check_idle' );

		my $callbacks = $heap->{callbacks};
		
		%$heap = (
			callbacks => $callbacks,
		);
		
		$heap->{write} = POE::Wheel::ReadWrite->new(
			InputHandle	=> $child_read,
			OutputHandle	=> $child_write,
			Driver		=> $driver,
			Filter		=> $filter,
			InputEvent	=> 'child_input',
			FlushedEvent	=> 'child_flushed',
		);

		if (exists( $callbacks->{child_fork} )) {
			$callbacks->{child_fork}->();
		}
		
		return 1;
	}
}

sub sigchld {
	my ($kernel, $session, $heap, $pid) = @_[KERNEL, SESSION, HEAP, ARG1];
	my $pids = $heap->{pids};
	my $wheels = $heap->{wheels};

	if (exists( $pids->{$pid} )) {
		my $idle = $heap->{idle};
		if (exists( $idle->{$pid} )) {
			delete( $idle->{$pid} );
			$kernel->call( $session, 'check_idle' );
		}
		my $wheel = delete( $pids->{$pid} );
		delete( $wheels->{$wheel->ID} );
		$kernel->sig_handled();
	}
	$kernel->sig( 'CHLD' ) unless (keys( %$pids ));
}

sub parent_input {
	my ($kernel, $session, $heap, $input, $wheel_id) = @_[KERNEL, SESSION, HEAP, ARG0, ARG1];
	my $idle = $heap->{idle};
	
	my $pid = $heap->{wheels}->{$wheel_id};

	my $now_idle = $input; # This line defines true to mean idle, false to mean busy
	my $previously_idle = exists( $idle->{$pid} );
	
	if ($now_idle xor $previously_idle) { # we're changing state
		if ($now_idle) {
			$idle->{$pid} = 1;
		}
		else {
			delete( $idle->{$pid} );
		}
		$kernel->call( $session, 'check_idle' );
	}
}

sub child_input {
	my ($kernel, $heap, $input) = @_[KERNEL, HEAP, ARG0];
	my $callbacks = delete( $heap->{callbacks} );
	delete( $heap->{write} );

	if ($input) {
		if (exists( $callbacks->{child_shutdown} )) {
			$callbacks->{child_shutdown}->();
		}
	}
}

sub child_flushed {
	delete $_[HEAP]->{amulet};
}

sub check_idle {
	my ($kernel, $session, $heap) = @_[KERNEL, SESSION, HEAP];

	my $idle = $heap->{idle};

	my $max_idle = $heap->{max_idle};
	my $min_idle = $heap->{min_idle};

	my $idle_count = keys( %$idle );

	if ($idle_count > $max_idle) {
		my $count = $idle_count - $max_idle;

		while ($count-- > 0) {
			my ($pid, undef) = each %$idle;
			
			$heap->{pids}->{$pid}->put( '1' );
		}
		
		# TODO Remove from idle count because it should be shutting down.
		# TODO Push onto an array, add a delay event to forcibly kill off in a few seconds.
		# TODO cleanup array and delay event in sigchld above
	}
	elsif ( $idle_count < $min_idle) {
		my $count = $min_idle - $idle_count;
		
		foreach (1..$count) {
			return if $kernel->call( $session, 'spawn_child' );
		}
	}
}

1;
__END__

=head1 NAME

POE::Component::ForkManager - Perl extension for managing a preforking server in POE

=head1 SYNOPSIS

  use POE::Component::ForkManager;

  my $forkmanager = POE::Component::ForkManager->new( $minimum, $maximum );
  
  $forkmanager->limits( $minimum, $maximum );

  $forkmanager->callback( "name" => CODEREF );

=head1 DESCRIPTION

This module manages a pool of processes under POE. Processes can mark themselves either
busy or idle and the parent will add or remove processes as necessary to maintain the
limits set forth in either the new() or limits() call.

Callbacks are used to notify the child (and possibly the parent in the future) of
certain events occuring.

=head1 CALLBACKS

=head2 child_fork

Occurs immediately after a new child process is forked off the parent. This new child
is assumed to be idle.

=head2 child_shutdown

Occurs when a signal arrives from the parent indicating that this particular child
process has been chosen to shut down. The process may finish any tasks it has running
before shutting down, but the parent tries to choose a process which is idle (races
can occur.)

=head1 SEE ALSO

POE

=head1 AUTHOR

Jonathan Steinert, E<lt>hachi@cpan.orgE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2006 by Jonathan Steinert

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.8.7 or,
at your option, any later version of Perl 5 you may have available.

=cut

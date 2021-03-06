package Mojo::IOLoop::Delay;
use Mojo::Base 'Mojo::EventEmitter';

use Mojo;
use Mojo::IOLoop;
use Hash::Util::FieldHash 'fieldhash';

has ioloop => sub { Mojo::IOLoop->singleton };

fieldhash my %REMAINING;

sub begin {
  my ($self, $offset, $len) = @_;
  $self->{pending}++;
  my $id = $self->{counter}++;
  return sub { $self->_step($id, $offset // 1, $len, @_) };
}

sub data { shift->Mojo::_dict(data => @_) }

sub pass { $_[0]->begin->(@_) }

sub remaining {
  my $self = shift;
  return $REMAINING{$self} //= [] unless @_;
  $REMAINING{$self} = shift;
  return $self;
}

sub steps {
  my $self = shift->remaining([@_]);
  $self->ioloop->next_tick($self->begin);
  return $self;
}

sub wait {
  my $self = shift;

  my @args;
  $self->once(error => \&_die);
  $self->once(finish => sub { shift->ioloop->stop; @args = @_ });
  $self->ioloop->start;

  return wantarray ? @args : $args[0];
}

sub _die { $_[0]->has_subscribers('error') ? $_[0]->ioloop->stop : die $_[1] }

sub _step {
  my ($self, $id, $offset, $len) = (shift, shift, shift, shift);

  $self->{args}[$id]
    = [defined $len ? splice(@_, $offset, $len) : splice(@_, $offset)];
  return $self if $self->{fail} || --$self->{pending} || $self->{lock};
  local $self->{lock} = 1;
  my @args = map {@$_} @{delete $self->{args}};

  $self->{counter} = 0;
  if (my $cb = shift @{$self->remaining}) {
    eval { $self->$cb(@args); 1 }
      or (++$self->{fail} and return $self->remaining([])->emit(error => $@));
  }

  return $self->remaining([])->emit(finish => @args) unless $self->{counter};
  $self->ioloop->next_tick($self->begin) unless $self->{pending};
  return $self;
}

1;

=encoding utf8

=head1 NAME

Mojo::IOLoop::Delay - Manage callbacks and control the flow of events

=head1 SYNOPSIS

  use Mojo::IOLoop::Delay;

  # Synchronize multiple events
  my $delay = Mojo::IOLoop::Delay->new;
  $delay->steps(sub { say 'BOOM!' });
  for my $i (1 .. 10) {
    my $end = $delay->begin;
    Mojo::IOLoop->timer($i => sub {
      say 10 - $i;
      $end->();
    });
  }
  $delay->wait unless Mojo::IOLoop->is_running;

  # Sequentialize multiple events
  my $delay = Mojo::IOLoop::Delay->new;
  $delay->steps(

    # First step (simple timer)
    sub {
      my $delay = shift;
      Mojo::IOLoop->timer(2 => $delay->begin);
      say 'Second step in 2 seconds.';
    },

    # Second step (concurrent timers)
    sub {
      my ($delay, @args) = @_;
      Mojo::IOLoop->timer(1 => $delay->begin);
      Mojo::IOLoop->timer(3 => $delay->begin);
      say 'Third step in 3 seconds.';
    },

    # Third step (the end)
    sub {
      my ($delay, @args) = @_;
      say 'And done after 5 seconds total.';
    }
  );
  $delay->wait unless Mojo::IOLoop->is_running;

=head1 DESCRIPTION

L<Mojo::IOLoop::Delay> manages callbacks and controls the flow of events for
L<Mojo::IOLoop>, which can help you avoid deep nested closures that often
result from continuation-passing style.

=head1 EVENTS

L<Mojo::IOLoop::Delay> inherits all events from L<Mojo::EventEmitter> and can
emit the following new ones.

=head2 error

  $delay->on(error => sub {
    my ($delay, $err) = @_;
    ...
  });

Emitted if an error occurs in one of the steps, breaking the chain, fatal if
unhandled.

=head2 finish

  $delay->on(finish => sub {
    my ($delay, @args) = @_;
    ...
  });

Emitted once the active event counter reaches zero and there are no more
steps.

=head1 ATTRIBUTES

L<Mojo::IOLoop::Delay> implements the following attributes.

=head2 ioloop

  my $ioloop = $delay->ioloop;
  $delay     = $delay->ioloop(Mojo::IOLoop->new);

Event loop object to control, defaults to the global L<Mojo::IOLoop>
singleton.

=head1 METHODS

L<Mojo::IOLoop::Delay> inherits all methods from L<Mojo::EventEmitter> and
implements the following new ones.

=head2 begin

  my $cb = $delay->begin;
  my $cb = $delay->begin($offset);
  my $cb = $delay->begin($offset, $len);

Increment active event counter, the returned callback can be used to decrement
the active event counter again. Arguments passed to the callback are spliced
and queued in the right order for the next step or L</"finish"> event and
L</"wait"> method, the argument offset defaults to C<1> with no default
length.

  # Capture all arguments except for the first one (invocant)
  my $delay = Mojo::IOLoop->delay;
  Mojo::IOLoop->client({port => 3000} => $delay->begin);
  my ($err, $stream) = $delay->wait;

  # Capture all arguments
  my $delay = Mojo::IOLoop->delay;
  Mojo::IOLoop->client({port => 3000} => $delay->begin(0));
  my ($loop, $err, $stream) = $delay->wait;

  # Capture only the second argument
  my $delay = Mojo::IOLoop->delay;
  Mojo::IOLoop->client({port => 3000} => $delay->begin(1, 1));
  my $err = $delay->wait;

=head2 data

  my $hash = $delay->data;
  my $foo  = $delay->data('foo');
  $delay   = $delay->data({foo => 'bar'});
  $delay   = $delay->data(foo => 'bar');

Data shared between all L</"steps">.

  # Remove value
  my $foo = delete $delay->data->{foo};

=head2 pass

  $delay = $delay->pass;
  $delay = $delay->pass(@args);

Increment active event counter and decrement it again right away to pass
values to the next step.

  # Longer version
  $delay->begin(0)->(@args);

=head2 remaining

  my $remaining = $delay->remaining;
  $delay        = $delay->remaining([]);

Remaining L</"steps"> in chain, stored outside the object to protect from
circular references.

=head2 steps

  $delay = $delay->steps(sub {...}, sub {...});

Sequentialize multiple events, the first callback will run right away, and the
next one once the active event counter reaches zero. This chain will continue
until there are no more callbacks, a callback does not increment the active
event counter or an error occurs in a callback.

=head2 wait

  my $arg  = $delay->wait;
  my @args = $delay->wait;

Start L</"ioloop"> and stop it again once an L</"error"> or L</"finish"> event
gets emitted, only works when L</"ioloop"> is not running already.

  # Use a single step to synchronize portably
  $delay->steps(sub {
    my ($delay, @args) = @_;
    ...
  });
  $delay->wait unless $delay->ioloop->is_running;

=head1 SEE ALSO

L<Mojolicious>, L<Mojolicious::Guides>, L<http://mojolicio.us>.

=cut

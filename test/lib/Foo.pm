package Foo;

=head1 Tricksy
__END__
=cut

use Indented;

sub greetings:
    print "Hello " . shift;

no Indented;

sub farewell {
    print "Goodbye " . shift;
}

1;

__END__

=head1 NAME

t::Foo - Hello and Goodbye

=cut

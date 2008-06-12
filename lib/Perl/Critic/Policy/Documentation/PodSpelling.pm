##############################################################################
#      $URL$
#     $Date$
#   $Author$
# $Revision$
##############################################################################

package Perl::Critic::Policy::Documentation::PodSpelling;

use 5.006001;
use strict;
use warnings;

use English qw(-no_match_vars);
use Readonly;

use File::Spec;
use List::MoreUtils qw(uniq);

use Perl::Critic::Utils qw{
    :characters
    :booleans
    :severities
    words_from_string
};
use Perl::Critic::Exception::Fatal::Generic qw{ throw_generic };

use base 'Perl::Critic::Policy';

our $VERSION = '1.086';

#-----------------------------------------------------------------------------

Readonly::Scalar my $POD_RX => qr{\A = (?: for|begin|end ) }mx;
Readonly::Scalar my $DESC => q{Check the spelling in your POD};
Readonly::Scalar my $EXPL => [148];

#-----------------------------------------------------------------------------

sub supported_parameters {
    return (
        {
            name            => 'spell_command',
            description     => 'The command to invoke to check spelling.',
            default_string  => 'aspell list',
            behavior        => 'string',
        },
        {
            name            => 'stop_words',
            description     => 'The words to not consider as misspelled.',
            default_string  => $EMPTY,
            behavior        => 'string list',
        },
    );
}

sub default_severity     { return $SEVERITY_LOWEST        }
sub default_themes       { return qw( core cosmetic pbp ) }
sub applies_to           { return 'PPI::Document'         }

#-----------------------------------------------------------------------------

my $got_sigpipe = 0;
sub got_sigpipe {
    return $got_sigpipe;
}

#-----------------------------------------------------------------------------

sub initialize_if_enabled {
    my ( $self, $config ) = @_;

    # workaround for Test::Without::Module v0.11
    local $EVAL_ERROR = undef;

    eval {
        require File::Which;
        require File::Temp;
        require Text::ParseWords;
        require Pod::Spell;
        require IO::String;
    };
    return $FALSE if $EVAL_ERROR;

    return $FALSE if not $self->_derive_spell_command_line();

    return $FALSE if not $self->_run_spell_command( <<'END_TEST_CODE' );
=pod

=head1 Test The Spell Command

=cut
END_TEST_CODE

    return $TRUE;
}

#-----------------------------------------------------------------------------

sub violates {
    my ( $self, $elem, $doc ) = @_;

    my $code = $doc->serialize();

    my $words = $self->_run_spell_command($code);

    return if not $words;       # error running spell command

    return if not @{$words};    # no problems found

    return $self->violation( "$DESC: @{$words}", $EXPL, $doc );
}

#-----------------------------------------------------------------------------

sub _derive_spell_command_line {
    my ($self) = @_;

    my @words = Text::ParseWords::shellwords($self->_get_spell_command());
    if (!@words) {
        return;
    }
    if (! File::Spec->file_name_is_absolute($words[0])) {
       $words[0] = File::Which::which($words[0]);
    }
    if (! $words[0] || ! -x $words[0]) {
        return;
    }
    $self->_set_spell_command_line(\@words);

    return $self->_get_spell_command_line();
}

#-----------------------------------------------------------------------------

sub _get_spell_command {
    my ( $self ) = @_;

    return $self->{_spell_command};
}

sub _set_spell_command {
    my ( $self, $spell_command ) = @_;

    $self->{_spell_command} = $spell_command;

    return;
}

#-----------------------------------------------------------------------------

sub _get_spell_command_line {
    my ( $self ) = @_;

    return $self->{_spell_command_line};
}

sub _set_spell_command_line {
    my ( $self, $spell_command_line ) = @_;

    $self->{_spell_command_line} = $spell_command_line;

    return;
}

#-----------------------------------------------------------------------------

sub _get_stop_words {
    my ( $self ) = @_;

    return $self->{_stop_words};
}

sub _set_stop_words {
    my ( $self, $stop_words ) = @_;

    $self->{_stop_words} = $stop_words;

    return;
}

#-----------------------------------------------------------------------------

sub _run_spell_command {
    my ($self, $code) = @_;

    my $infh = IO::String->new( $code );

    my $outfh = File::Temp->new()
      or throw_generic "Unable to create tempfile: $OS_ERROR";

    my $outfile = $outfh->filename();
    my @words;

    local $EVAL_ERROR = undef;

    eval {
        # temporarily add our special wordlist to this annoying global
        local %Pod::Wordlist::Wordlist =    ##no critic(ProhibitPackageVars)
            %{ $self->_get_stop_words() };

        Pod::Spell->new()->parse_from_filehandle($infh, $outfh);
        close $outfh or throw_generic "Failed to close pod temp file: $OS_ERROR";
        return if not -s $outfile; # Bail out if no words to spellcheck

        # run spell command and fetch output
        local $SIG{PIPE} = sub { $got_sigpipe = 1; };
        my $command_line = join $SPACE, @{$self->_get_spell_command_line()};
        open my $aspell_out_fh, q{-|}, "$command_line < $outfile"  ## Is this portable??
            or throw_generic "Failed to open handle to spelling program: $OS_ERROR";

        @words = uniq( <$aspell_out_fh> );
        close $aspell_out_fh
            or throw_generic "Failed to close handle to spelling program: $OS_ERROR";

        for (@words) {
            chomp;
        }

        # Why is this extra step needed???
        @words = grep { not exists $Pod::Wordlist::Wordlist{$_} } @words;  ## no critic(ProhibitPackageVars)
    };

    if ($EVAL_ERROR) {
        # Eat anything we did ourselves above, propagate anything else.
        if (not ref Perl::Critic::Exception::Fatal::Generic->caught()) {
            ref $EVAL_ERROR ? $EVAL_ERROR->rethrow() : die $EVAL_ERROR;  ## no critic (ErrorHandling::RequireCarping)
        }

        return;
    }

    return [ @words ];
}

#-----------------------------------------------------------------------------

1;

__END__

#-----------------------------------------------------------------------------

=pod

=for stopwords Hmm stopwords

=head1 NAME

Perl::Critic::Policy::Documentation::PodSpelling - Check your spelling.

=head1 AFFILIATION

This Policy is part of the core L<Perl::Critic> distribution.


=head1 DESCRIPTION

Did you write the documentation?  Check.

Did you document all of the public methods?  Check.

Is your documentation readable?  Hmm...

Ideally, we'd like Perl::Critic to tell you when your documentation is
inadequate.  That's hard to code, though.  So, inspired by
L<Test::Spelling>, this module checks the spelling of your POD.  It
does this by pulling the prose out of the code and passing it to an
external spell checker.  It skips over words you flagged to ignore.
If the spell checker returns any misspelled words, this policy emits a
violation.

If anything else goes wrong -- you don't have Pod::Spell installed or
we can't locate the spell checking program or (gasp!) your module has
no POD -- then this policy passes.

To add exceptions on a module-by-module basis, add "stopwords" as
described in L<Pod::Spell>.  For example:

   =for stopword gibbles

   =head1 Gibble::Manip -- manipulate your gibbles

   =cut

=head1 CONFIGURATION

This policy can be configured to tell which spell checker to use or to
set a global list of spelling exceptions.  To do this, put entries in
a F<.perlcriticrc> file like this:

  [Documentation::PodSpelling]
  spell_command = aspell list
  stop_words = gibbles foobar

The default spell command is C<aspell list> and it is interpreted as a
shell command.  We parse the individual arguments via
L<Text::ParseWords> so feel free to use quotes around your arguments.
If the executable path is an absolute file name, it is used as-is.  If
it is a relative file name, we employ L<File::Which> to convert it to
an absolute path via the C<PATH> environment variable.  As described
in Pod::Spell and Test::Spelling, the spell checker must accept text
on STDIN and print misspelled words one per line on STDOUT.

=head1 NOTES

L<Pod::Spell> is not included with Perl::Critic, nor is a spell
checking program.

=head1 CREDITS

Initial development of this policy was supported by a grant from the Perl Foundation.

=head1 AUTHOR

Chris Dolan <cdolan@cpan.org>

=head1 COPYRIGHT

Copyright (c) 2007-2008 Chris Dolan.  Many rights reserved.

This program is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.  The full text of this license
can be found in the LICENSE file included with this module

=cut

# Local Variables:
#   mode: cperl
#   cperl-indent-level: 4
#   fill-column: 78
#   indent-tabs-mode: nil
#   c-indentation-style: bsd
# End:
# ex: set ts=8 sts=4 sw=4 tw=78 ft=perl expandtab shiftround :

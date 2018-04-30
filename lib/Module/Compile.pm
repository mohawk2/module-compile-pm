# To Do:
#
# - Make preface part of parsed code, since it might contain `package`
#   statements or other scoping stuff.
# - Build code into an AST.
use strict; use warnings;
package Module::Compile;
our $VERSION = '0.37';

use Digest::SHA1();

# A lexical hash to keep track of which files have already been filtered
my $filtered = {};

# A map of digests to code blocks
my $digest_map = {};

# All subroutines are prefixed with pmc_ so subclasses don't
# accidentally override things they didn't intend to.

# Determine which stack frame points to the code we are filtering.
# This is a method in case it needs to be overridden.
sub pmc_caller_stack_frame { 0 };

# This is called while parsing source code to determine if the
# module/class in a use/no line is part of the Module::Compile game.
#
# Return true if this class supports PMC compilation.
#
# The hope is that this will allow interoperability with modules that
# do not inherit from Module::Compile but still want to do this sort
# of thing.
sub pmc_is_compiler_module { 1 };

sub new {
    return bless {}, shift;
}

# This is called to determine whether the meaning of use/no is reversed.
sub pmc_use_means_no { 0 }

# This is called to determine whether the use line means a one line section.
sub pmc_use_means_now { 0 }

# All Module::Compile based modules inherit this import routine.
sub import {
    my ($class) = @_;
    return if $class->pmc_use_means_no;
    goto &{$class->can('pmc_import')};
}

# Treat unimport like import if use means no
sub unimport {
    my ($class) = @_;
    return unless $class->pmc_use_means_no;
    goto &{$class->can('pmc_import')};
}

sub pmc_import {
    my ($class, @args) = @_;

    # Handler modules can do `use Module::Compile -base;`. Make them ISA
    # Module::Compile and get the hell out of Dodge.
    $class->pmc_set_base(@args) and return;

    my ($module, $line) = (caller($class->pmc_caller_stack_frame))[1, 2];

    return if $filtered->{$module}++;

    my $callback = sub {
        my ($class, $content, $data) = @_;
        my $output = $class->pmc_template($module, $content, $data);
        $class->pmc_output($module, $output);
    };

    $class->pmc_check_compiled_file($module);

    $class->pmc_filter($module, $line, $callback);

    # Is there a meaningful return value here?
    return;
}

# File might not be a module (.pm) and might be compiled already.
# If so, run the compiled file.
sub pmc_check_compiled_file {
    my ($class, $file) = @_;

    if (defined $file and $file !~ /\.pm$/i) {
        # Do the freshness check ourselves
        my $pmc = $file.'c';
        $class->pmc_run_compiled_file($pmc), die
          if -s $pmc and (-M $pmc <= -M $file);
    }
}

sub pmc_run_compiled_file {
    my ($class, $pmc) = @_;
    my ($package) = caller($class->pmc_file_caller_frame());
    eval "package $package; do \$pmc";
    die $@ if $@;
    exit 0;
}

sub pmc_file_caller_frame { 2 }

# Set up inheritance
sub pmc_set_base {
    my ($class, $flag) = @_;

    # Handle the `use Module::Compile -base;` command.
    if ($class->isa(__PACKAGE__) and defined $flag and $flag eq '-base') {
        my $descendant = (caller 1)[0];;
        no strict 'refs';
        push @{$descendant . '::ISA'}, $class;
        return 1;
    }

    return 0;
}

# Generate the actual code that will go into the .pmc file.
sub pmc_template {
    my ($class, $module, $content, $data) = @_;
    my $base = __PACKAGE__;
    my $check = $class->freshness_check($module);
    my $version = $class->VERSION || '0';
    return join "\n",
        "# Generated by $class $version ($base $VERSION) - do not edit!",
        "$check$content$data";
}

# This returns a piece of Perl code to do a runtime check to see if the
# .pmc file is fresh.  By default we use a 32-bit running checksum.
sub freshness_check {
    my ($class, $module) = @_;
    my $sum = sprintf('%08X', do {
        local $/;
        open my $fh, "<", $module
          or die "Cannot open $module: $!";
        binmode($fh, ':crlf'); # normalize CRLF for consistent checksum
        unpack('%32N*', <$fh>);
    });
    return << "...";
################((( 32-bit Checksum Validator III )))################
#line 1
BEGIN { use 5.006; local (*F, \$/); (\$F = __FILE__) =~ s!c\$!!; open(F)
or die "Cannot open \$F: \$!"; binmode(F, ':crlf'); if (unpack('%32N*',
\$F=readline(*F)) != 0x$sum) { use Filter::Util::Call; my \$f = \$F;
filter_add(sub { filter_del(); 1 while &filter_read; \$_ = \$f; 1; })}}
#line 1
...
}

# Write the output to the .pmc file
sub pmc_output {
    my ($class, $module, $output) = @_;
    $class->pmc_can_output($module)
      or return 0;
    my $pmc = $module . 'c';

    # If we can't open the file, just return. The filtering will not be cached,
    # but that might be ok.
    open my $fh, ">", $pmc
      or return 0;

    # Protect against disk full or whatever else.
    local $@;
    eval {
        print $fh $output
           or die;
        close $fh
           or die;
    };
    if ( my $e = $@ ) {
        # close $fh? die if unlink?
        if ( -e $pmc ) {
            unlink $pmc
                or die "Can't delete errant $pmc: $!";
        }
        return 0;
    }

    return 1;
}

# Check whether output can be written.
sub pmc_can_output {
    my ($class, $file_path) = @_;
    return 1;
#     return $file_path =~ /\.pm$/;
}

# We use a source filter to get all the code for compiling.
sub pmc_filter {
    my ($class, $module, $line_number, $post_process) = @_;

    # Read original module source code instead of taking from filter,
    # because we need all the lines including the ones before the `use`
    # statement, so we can parse Perl into packages and such.
    open my $fh, $module
        or die "Can't open $module for input:\n$!";
    my $module_content = do { local $/; <$fh> };
    close $fh;

    # Find the real __DATA__ or __END__ line. (Not one hidden in a Pod
    # section or heredoc).
    my $folded_content = $class->pmc_fold_blocks($module_content);
    my $folded_data = '';
    if ($folded_content =~ s/^((?:__(?:DATA|END)__$).*)//ms) {
        $folded_data = $1;
    }
    my $real_content = $class->pmc_unfold_blocks($folded_content);
    my $real_data = $class->pmc_unfold_blocks($folded_data);

    # Calculate the number of lines to skip in the source filter, since
    # we already have them in $real_content.
    my @lines = ($real_content =~ /(.*\n)/g);
    my $lines_to_skip = @lines;
    $lines_to_skip -= $line_number;

    # Use filter to skip past that many lines
    # Leave __DATA__ section intact
    my $done = 0;
    require Filter::Util::Call;
    Filter::Util::Call::filter_add(sub {
        return 0 if $done;
        my $data_line = '';
        while (1) {
            my $status = Filter::Util::Call::filter_read();
            last unless $status;
            return $status if $status < 0;
            # Skip lines up to the DATA section.
            next if $lines_to_skip-- > 0;
            if (/^__(?:END|DATA)__$/) {
                # Don't filter the DATA section, or else the DATA file
                # handle becomes invalid.

                # XXX - Maybe there is a way to simply recreate the DATA
                # file handle, or at least seek back to the start of it.
                # Needs investigation.

                # For now this means that we only allow compilation on
                # the module content; not the DATA section. Because we
                # want to make sure that the program runs the same way
                # as both a .pm and a .pmc.

                $data_line = $_;
                last;
            }
        }
        continue {
            $_ = '';
        }

        $real_content =~ s/\r//g;
        my $filtered_content = $class->pmc_process($real_content);
        $class->$post_process($filtered_content, $real_data);

        $filtered_content =~ s/(.*\n){$line_number}//;

        $_ = $filtered_content . $data_line;

        $done = 1;
    });
}

use constant TEXT => 0;
use constant CONTEXT => 1;
use constant CLASSES => 2;
# Break the code into blocks. Compile the blocks.
# Fold out heredocs etc
# Parse the code into packages, blocks and subs
# Parse the code by `use/no *::Compiler`
# Build an AST
# Reduce the AST until fully reduced
# Return the result
sub pmc_process {
    my $class = shift;
    my $data = shift;
    my @blocks = $class->pmc_parse_blocks($data);
    while (@blocks = $class->pmc_reduce(@blocks)) {
        if (@blocks == 1 and @{$blocks[0][CLASSES]} == 0) {
            my $content = $blocks[0][TEXT];
            $content .= "\n" unless $content =~ /\n\z/;
            return $content;
        }
    }
    die "How did I get here?!?";
}

# Analyze the remaining blocks and determine which compilers to call to reduce
# the problem.
#
# XXX This routine must do some kind of reduction each pass, or infinite loop
# will ensue. It is not yet certain if this is the case.
sub pmc_reduce {
    my $class = shift;
    my @blocks;
    my $prev;
    while (@_) {
        my $block = shift;
        my $next = $_[TEXT];
        if ($next and "@{$block->[CLASSES]}" eq "@{$next->[CLASSES]}") {
            shift;
            $block->[TEXT] .= $next->[TEXT];
        }
        elsif (
            (not $prev or @{$prev->[CLASSES]} < @{$block->[CLASSES]}) and
            (not $next or @{$next->[CLASSES]} < @{$block->[CLASSES]})
        ) {
            my $prev_len = $prev ? @{$prev->[CLASSES]} : 0;
            my $next_len = $next ? @{$next->[CLASSES]} : 0;
            my $offset = ($prev_len > $next_len) ? $prev_len : $next_len;
            my $length = @{$block->[CLASSES]} - $offset;
            $class->pmc_call($block, $offset, $length);
        }
        push @blocks, $block;
        $prev = $block;
    }
    return @blocks;
}

# Call a set of compilers on a piece of source code.
sub pmc_call {
    my $class = shift;
    my $block = shift;
    my $offset = shift;
    my $length = shift;

    my $text = $block->[TEXT];
    my $context = $block->[CONTEXT];
    my @classes = splice(@{$block->[CLASSES]}, $offset, $length);
    for my $klass (@classes) {
        local $_ = $text;
        my $return = $klass->pmc_compile($text, ($context->{$klass} || {}));
        $text = (defined $return and $return !~ /^\d+\z/)
            ? $return
            : $_;
    }
    $block->[TEXT] = $text;
}

# Divide a Perl module into blocks. This code divides a module based on
# lines that use/no a Module::Compile subclass.
sub pmc_parse_blocks {
    my $class = shift;
    my $data = shift;
    my @blocks = ();
    my @classes = ();
    my $context = {};
    my $text = '';
    my @parts = split /^([^\S\n]*(?:use|no)[^\S\n]+[\w\:\']+[^\n]*\n)/m, $data;
    for my $part (@parts) {
        if ($part =~ /^[^\S\n]*(use|no)[^\S\n]+([\w\:\']+)[^\n]*\n/) {
            my ($use, $klass, $file) = ($1, $2, $2);
            $file =~ s{(?:::|')}{/}g;
            if ($klass =~ /^\d+$/) {
                $text .= $part;
                next;
            }
            {
                local $@;
                eval { require "$file.pm" };
                die $@ if $@ and "$@" !~ /^Can't locate /;
            }
            if ($klass->can('pmc_is_compiler_module') and
                $klass->pmc_is_compiler_module) {
                push @blocks, [$text, {%$context}, [@classes]];
                $text = '';
                @classes = grep {$_ ne $klass} @classes;
                if (($use eq 'use') xor $klass->pmc_use_means_no) {
                    push @classes, $klass;
                    $context->{$klass} = {%{$context->{$klass} || {}}};
                    $context->{$klass}{use} = $part;
                    if ($klass->pmc_use_means_now) {
                        push @blocks, ['', {%$context}, [@classes]];
                        @classes = grep {$_ ne $klass} @classes;
                        delete $context->{$klass};
                    }
                }
                else {
                    delete $context->{$klass};
                }
            }
            else {
                $text .= $part;
            }
        }
        else {
            $text .= $part;
        }
    }
    push @blocks, [$text, {%$context}, [@classes]]
        if length $text;
    return @blocks;
}

# Compile/Filter some source code into something else. This is almost
# always overridden in a subclass.
sub pmc_compile {
    my ($class, $source_code_string, $context_hashref) = @_;
    return $source_code_string;
}

# Regexp fragments for matching heredoc, pod section, comment block and
# data section.
my $re_here = qr/
(?:                     # Heredoc starting line
    ^                   # Start of some line
    ((?-s:.*?))         # $2 - text before heredoc marker
    <<(?!=)             # heredoc marker
    [\t\x20]*           # whitespace between marker and quote
    ((?>['"]?))         # $3 - possible left quote
    ([\w\-\.]*)         # $4 - heredoc terminator
    (\3                 # $5 - possible right quote
     (?-s:.*\n))        #      and rest of the line
    (.*?\n)             # $6 - Heredoc content
    (?<!\n[0-9a-fA-F]{40}\n)  # Not another digest
    (\4\n)              # $7 - Heredoc terminating line
)
/xsm;

my $re_pod = qr/
(?:
    (?-s:^=(?!cut\b)\w+.*\n)        # Pod starter line
    .*?                             # Pod lines
    (?:(?-s:^=cut\b.*\n)|\z)        # Pod terminator
)
/xsm;

my $re_comment = qr/
(?:
    (?m-s:^[^\S\n]*\#.*\n)+           # one or more comment lines
)
/xsm;

my $re_data = qr/
(?:
    ^(?:__END__|__DATA__)\n   # DATA starter line
    .*                              # Rest of lines
)
/xsm;

# Fold each heredoc, pod section, comment block and data section, each
# into a single line containing a digest of the original content.
#
# This makes further dividing of Perl code less troublesome.
sub pmc_fold_blocks {
    my ($class, $source) = @_;

    $source =~ s/(~{3,})/$1~/g;
    $source =~ s/(^'{3,})/$1'/gm;
    $source =~ s/(^`{3,})/$1`/gm;
    $source =~ s/(^={3,})/$1=/gm;

    while (1) {
        no warnings;
        $source =~ s/
            (
                $re_pod |
                $re_comment |
                $re_here |
                $re_data
            )
        /
            my $result = $1;
            $result =~ m{\A($re_data)}    ? $class->pmc_fold_data()    :
            $result =~ m{\A($re_pod)}     ? $class->pmc_fold_pod()     :
            $result =~ m{\A($re_comment)} ? $class->pmc_fold_comment() :
            $result =~ m{\A($re_here)}    ? $class->pmc_fold_here()    :
                die "'$result' didn't match '$re_comment'";
        /ex or last;
    }

    $source =~ s/(?<!~)~~~(?!~)/<</g;
    $source =~ s/^'''(?!') /__DATA__\n/gm;
    $source =~ s/^```(?!`)/#/gm;
    $source =~ s/^===(?!=)/=/gm;

    $source =~ s/^(={3,})=/$1/gm;
    $source =~ s/^('{3,})'/$1/gm;
    $source =~ s/^(`{3,})`/$1/gm;
    $source =~ s/(~{3,})~/$1/g;

    return $source;
}

sub pmc_unfold_blocks {
    my ($class, $source) = @_;

    $source =~ s/
        (
            ^__DATA__\n[0-9a-fA-F]{40}\n
        |
            ^=pod\s[0-9a-fA-F]{40}\n=cut\n
        )
    /
        my $match = $1;
        $match =~ s!.*?([0-9a-fA-F]{40}).*!$1!s or die;
        $digest_map->{$match}
    /xmeg;

    return $source;
}

# Fold a heredoc's content but don't fold other heredocs from the
# same line.
sub pmc_fold_here {
    my $class = shift;
    my $result = "$2~~~$3$4$5";
    my $preface = '';
    my $text = $6;
    my $stop = $7;
    while (1) {
        if ($text =~ s!^(([0-9a-fA-F]{40})\n.*\n)!!) {
            if (defined $digest_map->{$2}) {
                $preface .= $1;
                next;
            }
            else {
                $text = $1 . $text;
                last;
            }
        }
        last;
    }
    my $digest = $class->pmc_fold($text);
    $result = "$result$preface$digest\n$stop";
    $result;
}

sub pmc_fold_pod {
    my $class = shift;
    my $text = $1;
    my $digest = $class->pmc_fold($text);
    return qq{===pod $digest\n===cut\n};
}

sub pmc_fold_comment {
    my $class = shift;
    my $text = $1;
    my $digest = $class->pmc_fold($text);
    return qq{``` $digest\n};
}

sub pmc_fold_data {
    my $class = shift;
    my $text = $1;
    my $digest = $class->pmc_fold($text);
    return qq{''' $digest\n};
}

# Fold a piece of code into a unique string.
sub pmc_fold {
    require Digest::SHA1;
    my ($class, $text) = @_;
    my $digest = Digest::SHA1::sha1_hex($text);
    $digest_map->{$digest} = $text;
    return $digest;
}

# Expand folded code into original content.
sub pmc_unfold {
    my ($class, $digest) = @_;
    return $digest_map->{$digest};
}

1;

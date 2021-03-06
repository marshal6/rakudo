our $?TABSTOP = 8;

augment class Str does Stringy {

    multi method Bool { ?(pir::istrue__IP(self)); }

    method Str() { self }

    my @KNOWN_ENCODINGS = <utf-8 iso-8859-1 ascii>;

    # XXX: We have no $?ENC or $?NF compile-time constants yet.
    multi method encode($encoding is copy = 'utf-8', $nf = '') {
        if $encoding eq 'latin-1' {
            $encoding = 'iso-8859-1';
        }
        die "Unknown encoding $encoding"
            unless $encoding.lc eq any @KNOWN_ENCODINGS;
        $encoding .= lc;
        my @bytes = Q:PIR {
            .local int byte
            .local pmc bytebuffer, it, result
            $P0 = find_lex 'self'
            $S0 = $P0
            $P1 = find_lex '$encoding'
            $S1 = $P1
            if $S1 == 'ascii'      goto transcode_ascii
            if $S1 == 'iso-8859-1' goto transcode_iso_8859_1
            # NOTE: There's an assumption here, that all strings coming in
            #       from the rest of Rakudo are always in UTF-8 form. Don't
            #       know if this assumption always holds; to be on the safe
            #       side, we might transcode even to UTF-8.
            goto finished_transcoding
          transcode_ascii:
            $I0 = find_encoding 'ascii'
            $S0 = trans_encoding $S0, $I0
            goto finished_transcoding
          transcode_iso_8859_1:
            $I0 = find_encoding 'iso-8859-1'
            $S0 = trans_encoding $S0, $I0
          finished_transcoding:
            bytebuffer = new ['ByteBuffer']
            bytebuffer = $S0

            result = new ['Parcel']
            it = iter bytebuffer
          bytes_loop:
            unless it goto done
            byte = shift it
            push result, byte
            goto bytes_loop
          done:
            %r = result
        };
        return Buf.new(@bytes);
    }

    # Zero indent does nothing
    multi method indent($steps as Int where { $_ == 0 }) {
        self;
    }

    # Positive indent does indent
    multi method indent($steps as Int where { $_ > 0 }) {
    # We want to keep trailing \n so we have to .comb explicitly instead of .lines
        return self.comb(/:r ^^ \N* \n?/).map({
            given $_ {
                # Use the existing space character if they're all the same
                # (but tabs are done slightly differently)
                when /^(\t+) ([ \S .* | $ ])/ {
                    $0 ~ "\t" x ($steps div $?TABSTOP) ~
                         ' '  x ($steps mod $?TABSTOP) ~ $1
                }
                when /^(\h) $0* [ \S | $ ]/ {
                    $0 x $steps ~ $_
                }

                # Otherwise we just insert spaces after the existing leading space
                default {
                    ($_ ~~ /^(\h*) (.*)$/).join(' ' x $steps)
                }
            }
        }).join;
    }

    # Negative values and Whatever-* do outdent
    multi method indent($steps) {
        # Loop through all lines to get as much info out of them as possible
        my @lines = self.comb(/:r ^^ \N* \n?/).map({
            # Split the line into indent and content
            my ($indent, $rest) = @($_ ~~ /^(\h*) (.*)$/);

            # Split the indent into characters and annotate them
            # with their visual size
            my $indent-size = 0;
            my @indent-chars = $indent.comb.map(-> $char {
                my $width = $char eq "\t"
                    ?? $?TABSTOP - ($indent-size mod $?TABSTOP)
                    !! 1;
                $indent-size += $width;
                $char => $width;
            });

            { :$indent-size, :@indent-chars, :$rest };
        });

        # Figure out the amount * should outdent by, we also use this for warnings
        my $common-prefix = [min] @lines.map({ $_<indent-size> });

        # Set the actual outdent amount here
        my Int $outdent = $steps ~~ Whatever ?? $common-prefix
                                             !! -$steps;

        warn sprintf('Asked to remove %d spaces, ' ~
                     'but the shortest indent is %d spaces',
                     $outdent, $common-prefix) if $outdent > $common-prefix;

        # Work backwards from the right end of the indent whitespace, removing
        # array elements up to # (or over, in the case of tab-explosion)
        # the specified outdent amount.
        @lines.map({
            my $pos = 0;
            while $_<indent-chars> and $pos < $outdent {
                $pos += $_<indent-chars>.pop.value;
            }
            $_<indent-chars>».key.join ~ ' ' x ($pos - $outdent) ~ $_<rest>;
        }).join;
    }

    our sub str2num-int($src) {
        Q:PIR {
            .local pmc src
            .local string src_s
            src = find_lex '$src'
            src_s = src
            .local int pos, eos
            .local num result
            pos = 0
            eos = length src_s
            result = 0
          str_loop:
            unless pos < eos goto str_done
            .local string char
            char = substr src_s, pos, 1
            if char == '_' goto str_next
            .local int digitval
            digitval = index "0123456789", char
            if digitval < 0 goto err_base
            if digitval >= 10 goto err_base
            result *= 10
            result += digitval
          str_next:
            inc pos
            goto str_loop
          err_base:
        src.'panic'('Invalid radix conversion of "', char, '"')
          str_done:
            %r = box result
        };
    }

    our sub str2num-base($src) {
        Q:PIR {
            .local pmc src
            .local string src_s
            src = find_lex '$src'
            src_s = src
            .local int pos, eos
            .local num result
            pos = 0
            eos = length src_s
            result = 1
          str_loop:
            unless pos < eos goto str_done
            .local string char
            char = substr src_s, pos, 1
            if char == '_' goto str_next
            result *= 10
          str_next:
            inc pos
            goto str_loop
          err_base:
        src.'panic'('Invalid radix conversion of "', char, '"')
          str_done:
            %r = box result
        };
    }

    sub chop-trailing-zeros($i) {
        Q:PIR {
            .local int idx
            $P0 = find_lex '$i'
            $S0 = $P0
            idx = length $S0
        repl_loop:
            if idx == 0 goto done
            dec idx
            $S1 = substr $S0, idx, 1
            if $S1 == '0' goto repl_loop
        done:
            inc idx
            $S0 = substr $S0, 0, idx
            $P0 = $S0
            %r = $P0
        }
    }

    our sub str2num-rat($negate, $int-part, $frac-part is copy) is export {
        $frac-part = chop-trailing-zeros($frac-part);
        my $result = upgrade_to_num_if_needed(str2num-int($int-part))
                     + upgrade_to_num_if_needed(str2num-int($frac-part))
                       / upgrade_to_num_if_needed(str2num-base($frac-part));
        $result = -$result if $negate;
        $result;
    }

    our sub str2num-num($negate, $int-part, $frac-part, $exp-part-negate, $exp-part) is export {
        my $exp = str2num-int($exp-part);
        $exp = -$exp if $exp-part-negate;
        my $result = (str2num-int($int-part) + str2num-int($frac-part) / str2num-base($frac-part))
                     * 10 ** $exp;
        $result = -$result if $negate;
        $result;
    }
}

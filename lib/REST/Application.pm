# vi:ai:sm:et:sw=4:ts=4:tw=0
#   
# REST::Application - A framework for building RESTful web-applications.
#
# Copyright 2005 Matthew O'Connor <matthew@canonical.org>
package REST::Application;
use strict;
use warnings;
use Carp;
use Tie::IxHash;
use UNIVERSAL;

our $VERSION = '0.91';

####################
# Class Methods 
####################

sub new {
    my ($proto, %args) = @_;
    my $class = ref($proto) ? ref($proto) : $proto;
    my $self = bless({}, $class);
    $self->setup(%args);
    return $self;
}

##################################
# Instance Methods - Object State
##################################

sub query {
    my $self = shift;

    # Set default value if this method hasn't been called yet.
    if (not exists $self->{__query}) {
        $self->{__query} = $self->defaultQueryObject();
    }

    # Set the field if we got any arguments.
    $self->{__query} = shift if @_;

    return $self->{__query};
}

sub defaultQueryObject {
    my $self = shift;

    # Set the default value if this method hasn't been called before.
    if (not exists $self->{__query}) {
        require CGI;
        $self->{__defaultQuery} = CGI->new();
    }

    # Set the field if we got any arguments.
    if (@_) {
        $self->{__defaultQuery} = shift;
    }

    return $self->{__defaultQuery};
}

sub resourceHooks {
    my $self = shift;

    # Set default value if this method hasn't been called yet.
    if (not exists $self->{__resourceHooks}) {
        my %hooks;
        tie(%hooks, "Tie::IxHash");  # For keeping hash key order preserved.
        $self->{__resourceHooks} = \%hooks;
    }

    # If we got arguments then they should be an even sized list, otherwise a
    # hash reference.
    if (@_ and @_%2 == 0) {
        %{ $self->{__resourceHooks} } = @_;
    } elsif (@_ == 1) {
        my $value = shift;
        if (ref($value) ne 'HASH') {
            croak "Expected hash reference or even-sized list.";
        }
        %{ $self->{__resourceHooks} } = %$value;
    }

    return $self->{__resourceHooks};
}

sub extraHandlerArgs {
    my $self = shift;

    # Set default value for method if it hasn't been called yet.
    if (not exists $self->{__extraHandlerArgs}) {
        $self->{__extraHandlerArgs} = [];
    }

    # If got arguments then process them.  We expect either a single array
    # reference or a list
    if (@_) {
        if (@_ == 1 and ref($_[0]) eq 'ARRAY') {
            $self->{__extraHandlerArgs} = shift;
        } else {
            $self->{__extraHandlerArgs} = [ @_ ];
        } 
    }

    return @{ $self->{__extraHandlerArgs} };
}

##################################
# Instance Methods - Proxies
##################################

sub getPathInfo {
    my $self = shift;
    return $self->query->path_info();
}

sub getRequestMethod {
    my $self = shift;
    return uc($self->query->request_method());
}

#############################
# Instance Methods - Public
#############################

sub loadResource {
    my ($self, $path, @extraArgs) = @_;
    $path ||= $self->getMatchText();
    my $handler = sub { $self->defaultResourceHandler(@_) };
    my $matches = [];

    # Loop through the keys of the hash returned by resourceHooks().  Each of
    # the keys is a regular expression, see if the current path info matches
    # that regular expression.  Save the parent matches for passing into the
    # handler.
    for my $pathRegex (keys %{ $self->resourceHooks() }) {
        if ($self->checkMatch($path, $pathRegex)) {
            $handler = $self->_getHandlerFromHook($pathRegex);
            last;
        }
    }

    return $self->callHandler($handler, @extraArgs);
}

sub getHandlerArgs {
    my ($self, @extraArgs) = @_;
    my @args = ($self,
                $self->_getLastRegexMatches(),
                $self->extraHandlerArgs(),
                @extraArgs);

    # Don't make $self the first argument if the handler is a method on $self,
    # because in that case it'd be redundant.  Also see _getHandlerFromHook().
    shift @args if $self->{__handlerIsOurMethod};

    return @args;
}

sub callHandler {
    my ($self, $handler, @extraArgs) = @_;
    my @args = $self->getHandlerArgs(@extraArgs);

    # Call the handler, carp if something goes wrong.
    my $result;
    eval {
        $self->preHandler(\@args);  # no-op by default.
        $result = $handler->(@args);
        $self->postHandler(\$result, \@args); # no-op by default.
    };
    carp "Handler failed: $@\n" if $@;

    # Convert the result to a scalar result if it isn't already.
    my $ref = (ref($result) eq 'scalar') ? $result : \$result;

    return $ref;
}

sub getMatchText {
    my $self = shift;
    return $self->getPathInfo();
}

sub checkMatch {
    my ($self, $a, $b) = @_;
    my $match = 0;

    if ($a =~ /$b/) {
        $self->_setLastRegexMatches();
        $match = 1;
    }

    return $match;
}

sub run {
    my $self = shift;

    # Get resource.
    $self->preRun(); # A no-op by default.
    my $repr = $self->loadResource(@_);
    $self->postRun($repr); # A no-op by default.

    # Get the headers and then add the representation to to the output stream.
    my $output = $self->getHeaders();
    $self->addRepresentation($repr, \$output);

    # Send the output unless we're told not to by the environment.
    print $output if not $ENV{REST_APP_RETURN_ONLY};

    return $output;
}

sub getHeaders {
    my $self = shift;
    my $type = $self->headerType() || "";
    my $header = "";

    if ($type eq 'header') {
        $header = $self->query->header($self->header());
    } elsif ($type eq 'redirect') {
        $header = $self->query->redirect($self->header());
    } elsif ($type ne 'none') {
        croak "Unexpected header type: \"$type\".";
    }

    return $header;
}

sub addRepresentation {
    my ($self, $repr, $outputRef) = @_;

    # Make sure $outputRef is a scalar ref and the scalar it references is
    # defined.
    return if ref($outputRef) ne 'SCALAR';
    return if not defined $$outputRef;

    # If we're given a scalar reference then dereference it first, otherwise
    # just treat what we got as though it's a string.
    if (ref($repr) eq 'SCALAR') {
        $$outputRef .= $$repr if defined $$repr;
    } else {
        $$outputRef .= $repr if defined $repr;
    }
}

sub headerType {
    my $self = shift;

    # Set the default value if this method has not been called yet.
    if (not exists $self->{__headerType}) {
        $self->{__headerType} = "header";
    }

    # If an argument was passed in then use them to set the header type.
    if (@_) {
        my $type = lc(shift || "");
        if ($type =~ /^(redirect|header|none)$/) {
            $self->{__headerType} = $type;
        } else {
            croak "Invalid header type specified: \"$type\"";
        }
    }

    return $self->{__headerType};
}

sub header {
    my $self = shift;

    # Set the default value if this method has not been called yet.
    if (not exists $self->{__header}) {
        $self->{__header} = {};
    }

    # If arguments were passed in then use them to set the header type.
    # Arguments can be passed in as a hash-ref or as an even sized list.
    if (@_) {
        if (@_%2 == 0) { # even-sized list, must be hash
            %{ $self->{__header} } = @_;
        } elsif (ref($_[0]) eq 'HASH') {  # First item must be a hash reference
            $self->{__header} = shift;
        } else {
            croak "Expected even-sized list or hash reference.";
        }
    }
    
    return %{$self->{__header}};
}

sub resetHeader {
    my $self = shift;
    my %old = $self->header();
    $self->headerType('header');
    $self->{__header} = {};
    return %old;
}

sub setRedirect {
    my ($self, $url) = @_;
    $self->headerType('redirect');
    $self->header(-url => $url || "");
}

##############################################
# Instance Methods - Intended for Overloading
##############################################

sub setup { return }
sub preRun { return }
sub postRun{ return }
sub preHandler { return }
sub postHandler { return }
sub defaultResourceHandler { return }

#############################
# Instance Methods - Private
#############################

# CodeRef _getHandlerFromHook(String $pathRegex)
#
# This method retrieves a code reference which will yield the resource of the
# given $pathRegex, where $pathRegex is a key into the resource hooks hash (it
# isn't used as a regex in this method, just a hash key).
sub _getHandlerFromHook {
    my ($self, $pathRegex) = @_;
    my $ref = $self->resourceHooks()->{$pathRegex};
    my $refType = ref($ref);
    my $handler = sub { $self->defaultResourceHandler(@_) };

    # If we get a hash, then use the request method to narrow down the choice.
    # We do this first because we allow the same range of handler types for a
    # particular HTTP method that we do for a more generic handler.
    while ($refType eq 'HASH') {
        %$ref = map { uc($_) => $ref->{$_} } keys %$ref;  # Uppercase the keys
        $ref = $ref->{$self->getRequestMethod()};
        $refType = ref($ref);
    }

    # Based on the the reference's type construct the handler.
    if ($refType eq "CODE") {
        # A code reference
        $handler = $ref;
    } elsif ($refType eq "ARRAY") {
        # Array reference which holds a $object and "method name" pair.
        my ($object, $method) = @$ref;
        $handler = sub { $object->$method(@_) };
    } elsif ($refType) {
        # Object with getResource method.
        $handler = sub { $ref->getResource(@_) };
    } elsif ($ref) {
        # A bare string signifying a method name
        $handler = sub { $self->$ref(@_) };
        $self->{__handlerIsOurMethod} = 1;  # See callHandler().
    }

    return $handler;
}

# List _getLastRegexMatches(void)
#
# Returns a list of all the paren matches in the last regular expression who's
# matches were saved with _saveLastRegexMatches().  
sub _getLastRegexMatches {
    my $self = shift;
    my $matches = $self->{__lastRegexMatches} || [];
    return @$matches;
}

# ArrayRef _setLastRegexMatches(void)
#
# Grabs the values of $1, $2, etc. as set by the last regular expression to run
# in the current dyanamic scope.  This of course exploits that $1, $2, etc. and
# @+ are dynamically scoped.  A reference to an array is returned where the
# array values are $1, $2, $3, etc.  _getLastRegexMatches() can also be used to
# retrieve the values saved by this method.
sub _setLastRegexMatches {
    my $self = shift;
    no strict 'refs'; # For the $$_ symbolic reference below.
    my @matches = map $$_, (1 ..  scalar(@+)-1);  # See "perlvar" for @+.
    $self->{__lastRegexMatches} = \@matches;
}

1;
__END__
=pod

=head1 NAME

L<REST::Application> - A framework for building RESTful web-applications.

=head1 SYNOPSIS

    # MyRESTApp L<REST::Application> instance / mod_perl handler
    package MyRESTApp;
    use Apache;
    use Apache::Constants qw(:common);

    sub handler {
        __PACKAGE__->new(request => $r)->run();
        return OK;
    }
    
    sub getMatchText { return Apache->uri }

    sub setup {
        my $self = shift;
        $self->resourceHooks(
            qr{/rest/parts/(\d+)} => 'get_part',
            # ... other handlers here ...
        );
    }

    sub get_part {
        my ($self, $part_num) = @_;
        # Business logic to retrieve part num
    }

    # Apache conf
    <Location /rest>
        perl-script .cgi
        PerlHandler MyRESTApp
    </Location>

=head1 DESCRIPTION

This module acts as a base class for applications which implement a RESTful
interface.   When an HTTP request is received some dispatching logic in
L<L<REST::Application>> is invoked, calling different handlers based on what the
kind of HTTP request it was (i.e. GET, PUT, etc) and what resource it was
trying to access.  This module won't ensure that your API is RESTful but
hopefully it will aid in developing a REST API.

=head1 OVERVIEW

The following list describes the basic way this module is intended to be used.
It does not capture everything the module can do.

=over

=item 1. Subclass

Subclass L<REST::Application>, i.e. C<use base 'REST::Application'>.

=item 2. Overload C<setup()>

Overload the C<setup()> method and set up some resource hooks with the
C<resourceHooks()> method.  Hooks are mappings of the form: 
       
            REGEX => handler

where handler is either a method name, a code reference, an object which
supports the C<getResource()> method, or a reference to an array of the form:
C<[$objectRef, "methodName"]> (C<$objectRef> can be a class name instead).

The regular expressions are applied, by default, to the path info of the HTTP
request.  Anything captured by parens in the regex will be passed into the
handler as arguments.

For example:

    qr{/parts/(\d+)$} => "getPartByNumber",

The above hook will call a method named C<getPartByNumber> on the current
object (i.e. $self, an instance of L<REST::Application>) if the path info of
the requested URI matches the above regular expression.  The first argument to
the method will be the part number, since that's the first element captured in
the regular expression.

=item 3. Write code.

Write the code for the handler specified above.  So here we'd define the
C<getPartByNumber> method.

=item 4. Create a handler/loader.

Create an Apache handler, for example: 

    use MyRESTApp;
    sub handler {
        my $r = shift;
        my $app = MyRESTApp->new(request => $r);
        $app->run();
    }

or a small CGI script with the following code:

    #!/usr/bin/perl
    use MyRESTApp;
    MyRESTApp->new()->run();

In the second case, for a CGI script, you'll probably need to do something
special to get Apache to load up your script unless you give it a .cgi
extension.  It would be unRESTful to allow your script to have a .cgi
extension, so you should go the extra mile and configure Apache to run your
script without it.  For example, it'd be bad to have your users go to:

    http://www.foo.tld/parts.cgi/12345.html
    
=item 5. Call the C<run()> method.

When the C<run()> method is called the path info is extracted from the HTTP
request.  The regexes specified in step 2 are processed, in order, and if one
matches then the handler is called.  If the regex had paren. matching then the
matched elements are passed into the handler.  A handler is also passed a copy
of the L<REST::Application> object instance (except for the case when the
handler is a method on the L<REST::Application> object, in that case it'd be
redundant).  So, when writing a subroutine handler you'd do:

            sub rest_handler {
                my ($rest, @capturedArgs) = @_;
                ...
            }

=item 6. Return a representation of the resource.

The handler is processed and should return a string or a scalar reference to a
string.  Optionally the handler should set any header information via the
C<header()> method on instance object pased in.

=head1 CALLING ORDER

The L<REST::Application> base class provides a good number of methods, each of
which can be overloaded.  By default you only need to overload the C<setup()>
method but you may wish to overload others.  To help with this the following
outline is the calling order of the various methods in the base class.  You can
find detailed descriptions of each method in the METHODS section of this
document.

If a method is followed by the string NOOP then that means it does nothing by
default and it exists only to be overloaded.

    new()
        setup() - NOOP
    run()
        preRun() - NOOP
        loadResource()
            getMatchText()
                getPathInfo()
                    query()
                        defaultQueryObject()
            defaultResourceHandler() - NOOP
            resourceHooks()
            checkMatch()
                _setLastRegexMatches()
            _getHandlerFromHook()
                resourceHooks()
                defaultResourceHandler() - NOOP
                getRequestMethod()
                    query()
                        defaultQueryObject()
            callHandler()
                _getLastRegexMatches()
                extraHandlerArgs()
                preHandler() - NOOP
                ... your handler called here ...
                postHandler() - NOOP
        postRun() - NOOP
        getHeaders()
            headerType()
            query()
                defaultQueryObject()
            header()
        addRepresentation()

The only methods not called as part of the new() or run() methods are the
helper methods C<resetHeader()> and C<setRedirect()>, both of which call the
C<header()> and C<headerType()> methods.

For example, if you wanted to have your code branch on the entire URI of the
HTTP request rather than just the path info you'd merely overload
C<getMatchText()> to return the URI rather than the path info.

=back

=head1 METHODS

=head2 new(%args)

This method creates a new L<REST::Application> object and returns it.  The
arguments passed in via C<%args>, if any, are passed untouched to the
C<setup()> method.

=head2 query([$newCGI])

This accessor/mutator retrieves the current CGI query object or sets it if one
is passed in.

=head2 defaultQueryObject([$newCGI])

This method retrieves/sets the default query object.  This method is called if
C<query()> is called for the first time and no query object has been set yet.

=head2 resourceHooks([%hash])

This method is used to set the resource hooks.  A L<REST::Application> hook is
a regex to handler mapping.  The hooks are passed in as a hash (or a reference
to one) and the keys are treated as regular expressions while the values are
treated as handlers should B<PATH_INFO> match the regex that maps to that
handler.  

Handlers can be code references, methods on the current object, methods on
other objects, or class methods.  Also, handlers can be differ based on what
the B<REQUEST_METHOD> was (e.g. GET, PUT, POST, DELETE, etc).

The handler's types are as follows:

=over 8

=item string 

The handler is considered to be a method on the current L<REST::Application>
instance.

=item code ref

The code ref is considered to be the handler.

=item object ref

The object is considered to have a C<getResource()> method, which will be used.

=item array ref 

The array is expected to be two elements long, the first element is a class
name or object instance.  The 2nd element is a method name on that
class/instance.

=item hash ref

The current B<REQUEST_METHOD> is used as a key to the hash, the value should be
one the four above handler types.  In this way you can specify different
handles for each of the request types.

The return value of a reference is expected to be a string, which
L<REST::Application> will then send to the browser with the
C<sendRepresentation()> method.

If no argument is supplied to C<resourceHooks()> then the current set of hooks
is returned.  The returned hash referces is a tied IxHash, so the keys are kept
sorted.

=head2 loadResource([$path])

This method will take the value of B<PATH_INFO>, iterate through the path
regex's set in C<resourceHooks()> and if it finds a match call the associated
handler and return the handler's value, which should be a scalar.  If $path is
passed in then that is used instead of B<PATH_INFO>.

=head2 run()

This method calls C<loadResource()> with no arguments and then takes that
output and sends it to the remote client.  Headers are sent with
C<sendHeaders()> and the representation is sent with C<sendRepresentation()>.

If the environment variable B<REST_APP_RETURN_ONLY> is set then output isn't
sent to the client.  The return value of this method is the text output it
sends (or would've sent).

=head2 sendHeaders()

This method returns the headers as a string.

=head2 sendRepresentation($representation)

This method just returns C<$representation>.  It is provided soely for
overloading purposes.

=head2 headerType([$type])

This accessor/mutator controls the type of header to be returned.  This method
returns one of "header, redirect, or none."  If C<$type> is passed in then that
is used to set the header type. 

=head2 header([%args])

This accessor/mutator controls the header values sent.  If called without
arguments then it simply returns the current header values as a hash, where the
keys are the header fields and the values are the header field values.

If this method is called multiple times then the values of %args are additive.
So calling C<$self->header(-type => "text/html")> and C<$self->header(-foo =>
"bar")> results in both the content-type header being set and the "foo" header
being set.

=head2 resetHeader()

This header causes the current header values to be reset.  The previous values
are returned.

=head2 defaultResourceHandler()

This method is called by C<loadResource()> if no regex in C<resourceHooks()>
matches the current B<PATH_INFO>.  It returns undef by default, it exists for
overloading.

=head1 AUTHORS

Matthew O'Connor E<lt>matthew@canonical.org<gt>

=head1 LICENSE

This program is free software. It is subject to the same license as Perl itself.

=head1 SEE ALSO

L<CGI>, L<CGI::Application>, L<Tie::IxHash>, L<CGI::Application::Dispatch>

=cut

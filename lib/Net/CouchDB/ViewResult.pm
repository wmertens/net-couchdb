package Net::CouchDB::ViewResult;
use warnings;
use strict;

use Net::CouchDB;
use Net::CouchDB::Request;
use Net::CouchDB::ViewResultRow;
use URI;

sub new {
    my $class = shift;
    my $db    = shift || die "Need database";
    my $uri   = shift || die "Need URI";
    my $args  = shift || {};
    my $json = Net::CouchDB->json;

    my %params = %$args;

    foreach ( qw| key startkey endkey |){
        if ( exists $params{$_}  ){
            if ( ref $params{$_} eq 'SCALAR' ) {
                $params{$_} = ${ $params{$_} };
            }
            else {
                $params{$_} = $json->encode($params{$_}) ;
            }
        }
    }

    my $self = bless {
		db     => $db,
		uri    => $uri,
        params => \%params,
        _pointer => 0,
    }, $class;

    # Note that this doesn't actually fetch the result; it only 
    # sets up the container for the result.
    # Fetching the data is done on demand ... (for better or worse)

    return $self;
}

sub db     { shift->{db}   }
sub uri    { shift->{uri} }
sub params { shift->{params} }

sub count {
    my ($self) = @_;
    my $rows = $self->response->content->{rows};
    return scalar @$rows;
}

sub total_rows {
    my ($self) = @_;
    return $self->response->content->{total_rows};
}

sub first {
	# TODO should this reset the _pointer?
    my ($self) = @_;
    return if $self->count < 1;
    return Net::CouchDB::ViewResultRow->new(
		$self,
        $self->response->content->{rows}[0]
    );
}

sub next {
    my ($self) = @_;

    # if the iterator has returned all results, reset it (similar to each())
    if ( $self->{_pointer} >= $self->count ) {
        $self->{_pointer} = 0;
        return;
    }

    return Net::CouchDB::ViewResultRow->new(
        $self,
        $self->response->content->{rows}[ $self->{_pointer}++ ]
    );
}

sub all_rows_hash {
	my $self = shift;
	my %result;
	for my $row (@{$self->response->content->{rows}}) {
		$result{$row->{key}} = $row->{value};
	}
	return wantarray ? %result : \%result;
}

sub all_keys {
	my $self = shift;
	my @keys = map { ${$_}{key} } @{$self->response->content->{rows}};
	return wantarray ? @keys : \@keys;
}

sub all_values {
	my $self = shift;
	my @values = map { $_->{value} } @{$self->response->content->{rows}};
	return wantarray ? @values : \@values;
}

sub all_docs {
	my ($self, $keys, $values) = @_;

	my @documents;
	# test if there is an id, in case this is a reduce view
	if ($self->first && $self->first->id) {
		while (my $row = $self->next) {
			push @documents, $row->document;
		}
	}

	return wantarray ? @documents : \@documents;
}

sub response {
    my ($self) = @_;
    return $self->{response} if exists $self->{response};
    my $res = $self->request( 'GET', {
        description => 'retrieve the view',
        200         => 'ok',
        params      => $self->params,
    });
    $self->{_pointer} = 0;
    return $self->{response} = $res;
}

# use the db's ua
sub ua { shift->db->ua }

1;

__END__

=head1 NAME

Net::CouchDB::ViewResult - the result of searching a view

=head1 SYNOPSIS

    my $rs = $view->search({ key => 'foo' });
    printf "There are %d rows\n", $rs->count;

    my $rs = $view->search({ limit => 20, startkey_docid => 'abc' });
    my $doc = $rs->first;

=head1 DESCRIPTION

A L<Net::CouchDB::ViewResult> object represents the results of searching a
specific view.  Those results may be all rows from the view or it may be a
subset of those rows.  In general, a newly created ViewResult object lazily
represents the search results and does not actually query the CouchDB instance
until absolutely necessary.  The query usually happens the first time a
method is called on the ViewResult object.

=head1 METHODS

=head2 new

This method is only intended to be used internally.  The correct way to create
a new ViewResult object is to call L<Net::CouchDB::View/search>,
L<Net::CouchDB::DB/view> or L<Net::CouchDB::DB/all_documents>. All these calls
take optional view arguments to further refine the result received from
CouchDB.

The view arguments can be any arguments accepted by CouchDB's view API.  For
a complete list, see L<http://wiki.apache.org/couchdb/HttpViewApi>.  Arguments
of particular interest are document below.

=head3 key, startkey, endkey

Restricts the results to only those rows where the key matches the one given,
or is in the range indicated by startkey and endkey.

Searching ViewResults by key is very fast because of the way that CouchDB
handles indexes.

=head3 group

If the search is for a map+reduce view, setting group to "true" will return
reduce values for each of the keys in the map. Otherwise, a globally reduced
value will be returned.

=head3 include_docs

If this argument has the value 'true', both the search results and the
corresponding documents are retrieved with a single HTTP request.  Calling
L<Net::CouchDB::ViewResultRow/document> on rows from such a search requires no
additional HTTP requests.

=head2 count

Returns the number of rows in the result.  This number will be less than
or equal to the number returned by L</total_rows>.

=head2 first

Returns a L<Net::CouchDB::ViewResultRow> object representing the first
row in the result.  If there are no rows in the result, it returns
C<undef>.

=head2 next

Returns the next L<Net::CouchDB::ViewResultRow> until there are no
more rows where it returns C<undef>.

=head2 total_rows

Similar to L</count> but it returns the total number of rows that are
available in the View regardless whether those rows are available in
this result or not.

=head2 all_keys

Returns an array or arrayref containing all keys in the view, in view order.

=head2 all_values

Returns an array or arrayref containing all values in the view, in view order.

=head2 all_rows_hash

Returns a hash or a hashref loaded with the key/value pairs of the view. No
attempt is made to combine rows with the same key, the last row wins.

This function only makes sense for views with unique and scalar keys, like a
map+reduce view with a string or number as the key.

=head2 all_docs

Returns an array or arrayref containing all documents that were matched by the
view. No attempt is made to make the list unique.

This function only makes sense for map-only views which output one key/value
pair per document that matches the view.

A good use case for this is a view like this which selects all documents with a
key called "foo", stored in a design "bar":

 "all_foo":{"map":"function(doc) { doc.foo && emit(null, null); }"}

You can then get all matching documents in one request, like this:

 $db->view('bar','all_foo',{include_docs=>'true'})->all_docs

=head1 INTERNAL METHODS

These methods are intended for internal use.  They are documented here for
completeness.

=head2 db

Returns a L<Net::CouchDB::DB> object representing the database from which this
result is derived.

=head2 params

Returns a hashref of CGI query parameters that will be used when querying
CouchDB to retrieve the view results.

=head2 response

Returns a L<Net::CouchDB::Response> object representing CouchDB's response to
our view query.  Calling this method will query the database if it hasn't been
queried yet.

=head2 ua

Returns the L<LWP::UserAgent> object used for making HTTP requests to the
database.

=head2 uri

Returns a L<URI> object indicating the URI of the view.

=head1 AUTHOR

Michael Hendricks  <michael@ndrix.org>

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2008 Michael Hendricks (<michael@ndrix.org>). All rights
reserved.

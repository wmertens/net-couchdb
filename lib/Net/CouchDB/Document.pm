package Net::CouchDB::Document;
use strict;
use warnings;

use Net::CouchDB::Request;
use Net::CouchDB::Attachment;
use Storable qw( dclone );
use URI;
use URI::Escape qw(); # don't polute the namespace
use overload '%{}' => 'data', fallback => 1;

# a Document object is a blessed arrayref to avoid hash
# dereferencing problems
use constant _db     => 0;
use constant _id     => 1;  # document ID
use constant _rev    => 2;  # revision on which this document is based
use constant _data   => 3;  # the original data from the server
							# this is kept in order to do delayed copy
use constant _public => 4;  # public copy of 'data'
use constant _deleted => 5; # is this document deleted in the database?
sub new {
    my ($class, $db, $args) = @_;
	die "Didn't get an argument hash" unless defined $args;

    my $self = bless [], $class;
    $self->[_db]     = $db;
    if ($self->[_id] = $args->{id}) {
		$self->[_rev] = $args->{rev};
	} elsif ($self->[_data] = $args->{data}) {
		$self->[_id]  = $args->{data}{_id};
		$self->[_rev] = $args->{data}{_rev};
	} elsif ($self->[_public] = $args->{keep_data}) {
		$self->[_id]  = delete $args->{keep_data}{_id};
		$self->[_rev] = delete $args->{keep_data}{_rev};
	}
    $self->[_deleted] = 0;
    return $self;
}

sub db  { shift->[_db]  }
sub id  { shift->[_id]  }
sub rev { shift->[_rev] }
sub is_deleted { shift->[_deleted] }

sub delete {
    my ($self) = @_;
    my @deleted = $self->db->bulk({ delete => [$self] });
    return;
}

sub ua { shift->db->ua }  # use the db's UserAgent

sub uri {
    my ($self) = @_;
    return URI->new_abs(URI::Escape::uri_escape($self->id) . '/' , $self->db->uri );
}

sub update {
    my ($self) = @_;
    $self->db->bulk({ update => [ $self ] });
    return;
}

sub exists {
    my ($self) = @_;
    return if not $self->id;
    my $res = $self->request( 'HEAD', {
       description => 'test a document',
       404         => 'ok',
       200         => 'ok',
    });

    return $res->code != 404;
}

sub get {
    my ($self) = @_;
	die "get() called on a document without id!" unless $self->id;
	my $res = $self->request( 'GET', {
			description => 'get a document',
			404         => 'ok', # Should we die?
			200         => 'ok',
		});
    if ($res->code == 404) {
		$self->[_data] = undef;
		$self->[_public] = undef;
		return;
	} else {
		# We created this ourself so we can keep the data, no need to copy
		$self->[_data] = undef;
		$self->[_public] = $res->content;
		delete $self->[_public]->{_id};
		$self->[_rev] = delete $self->[_public]->{_rev};
		return $self;
	}
}

# this method lets us pretend that we're really a hashref
sub data {
    my ($self) = @_;

    if ( not defined $self->[_public] ) {
        if ( not defined $self->[_data] ) {
            if ($self->get) {
				return $self->[_public];
			} else {
				return $self->[_public]={};
			}
        }
        $self->[_public] = dclone $self->[_data];
        delete $self->[_public]->{_id};
        delete $self->[_public]->{_rev};
    }

    # return the copy so that users can modify it at will
    return $self->[_public];
}

# create an attachment for this document
sub attach {
    my $self = shift;
    my $args = shift || {};
    $args = { filename => $args } if ref($args) ne 'HASH';

    my $fh;
    my $name         = $args->{name};
    my $content_type = $args->{content_type};

    if ( my $filename = $args->{filename} ) {
        die "The attachment file $filename is not readable or does not exist\n"
          if not -r $filename;
        open $fh, '<', $filename or die "Could not open '$filename': $!";
        if ( not $name ) {  # name the attachment after the file
            ($name) = $filename =~ m{ ( [^\\/]+ ) \z }xms;
        }
    }

    my $content;
    if ( $fh = $fh || $args->{fh} ) {
        $content_type ||= -T $fh ? 'text/plain' : 'application/octet-stream';
        $content = do { local $/; <$fh> };
    }

    $content ||= $args->{content};

    # create the attachment
    my $res = $self->request( 'PUT', $name, {
        description => 'create an attachment',
        params      => { rev => $self->rev },
        headers     => { 'Content-Type' => $content_type },
        content     => $content,
        200         => 'ok',
    });
    $self->_you_are_now({  # update the revision number
        rev           => $res->content->{rev},
        preserve_data => 1,
    });

    return Net::CouchDB::Attachment->new({
        document => $self,
        name     => $name,
    });
}

# retrieve an attachment from this document
sub attachment {
    my ($self, $name) = @_;
    return Net::CouchDB::Attachment->new({
        document => $self,
        name     => $name,
    });
}

# after we've been updated or deleted, someone calls this to let
# us know about our new standing in the database
sub _you_are_now {
    my ( $self, $args ) = @_;
    my $rev = $args->{rev} or die "I am now what? Give me a rev dangit!\n";
    $self->[_rev]     = $rev;
    $self->[_deleted] = $args->{deleted};
    if ( not $args->{preserve_data} ) {
        $self->[_data]    = undef;  # our old data is no good
        $self->[_public]  = undef;  # same with our public data
    }
    return;
}

1;

__END__

=head1 NAME

Net::CouchDB::Document - a single CouchDB document

=head1 SYNOPSIS

    use Net::CouchDB;
    # do some stuff to connect to a database
    my $document = $db->insert({ key => 'value' })

    # access the values individually
    print "* $document->{key}\n";

    # or iterate over them
    while ( my ($k, $v) = each %$document ) {
        print "$k --> $v\n";
    }

    # $document is not really a hash, but it acts like one
    $document->{actor} = 'James Dean';
    $document->update;

=head1 DESCRIPTION

A Net::CouchDB::Document object represents a single document in the CouchDB
database.  It also represents a document which is no longer physically
available from the database but which was once available.

=head1 METHODS

=head2 new

 new( $db, {})
 new( $db, {id=>"id", rev=>"rev"})
 new( $db, {data=>$hashrev})
 new( $db, {keep_data=>$hashrev})

Generally speaking, users should not call this method directly.  Document
objects should be created by calling appropriate methods on a
L<Net::CouchDB::DB> object such as "insert".

Use the C<data> form for decoded JSON data that needs to be copied. The
C<keep_data> form means the data can be modified.

=head2 exists

Tests if the document exists on the server. Returns true or false.

=head2 get

Fetches the document from the server, overwriting any data you stored.

Returns self or undef if the document does not exist.

=head2 attach

If a single scalar argument is given, it's interpreted as a C<$filename>.
Attach the contents of C<$filename> to the current document as an attachment.
If the file looks like it's text, the content type is C<text/plain>;
otherwise, the content type is C<application/octet-stream>.

If the argument is a hashref, the hashref gives named arguments which specify
the attachment to be created.  Acceptable arguments are:

=head3 content

The actual content to use for the body of the attachment.

=head3 content_type

A MIME type for specifying the type of the attachment's content.  CouchDB uses
this as the "Content-Type" HTTP header when the attachment is requested
directly.

=head3 fh

A filehandle which should be used for reading the content of the attachment.

=head3 filename

Create an attachment based on a given filename.  This is the same as calling
L</attach> with a single, scalar argument.

=head3 name

The name of the attachment.

=head2 attachment($name)

Retrieves the attachment named C<$name> and returns a
L<Net::CouchDB::Attachment> object.

=head2 data

Returns the document's contents.

=head2 db

Returns a L<Net::CouchDB::DB> object indicating the database in which
this document is stored.

=head2 delete

Deletes the document from the database.  Throws an exception if there is an
error while deleting.

=head2 id

Returns the document ID for this document.  This is the unique identifier for
this document within the database.

=head2 is_deleted

Returns a true value if this document has been deleted from the database.
Otherwise, it returns false.

=head2 rev

Returns the revision name on which this document is based.  It's possible that
the document has been modified since it was retrieved from the database.  In
such a case, the data in the document may not represent what is currently
stored in the database.

=head2 update

Stores any changes to the document into the database.  If the changes
cause a conflict, an exception is thrown.  One may treat a Document
object like a hashref and make changes to it however those changes are not
stored in the database until C<update> is called.

=head2 uri

Returns a L<URI> object representing the URI for this document.

=head1 INTERNAL METHODS

These methods are primarily intended for internal use but documented here
for completeness.

=head2 ua

Returns the L<LWP::UserAgent> object used for making HTTP requests.

=head1 AUTHOR

Michael Hendricks  <michael@ndrix.org>

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2008 Michael Hendricks (<michael@ndrix.org>). All rights
reserved.

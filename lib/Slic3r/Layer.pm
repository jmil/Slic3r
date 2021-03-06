package Slic3r::Layer;
use Moo;

use Math::Clipper ':all';
use Math::Geometry::Planar;
use XXX;

# a sequential number of layer, starting at 0
has 'id' => (
    is          => 'ro',
    #isa         => 'Int',
    required    => 1,
);

# collection of spare segments generated by slicing the original geometry;
# these need to be merged in continuos (closed) polylines
has 'lines' => (
    is      => 'rw',
    #isa     => 'ArrayRef[Slic3r::Line]',
    default => sub { [] },
);

# collection of surfaces generated by slicing the original geometry
has 'surfaces' => (
    is      => 'rw',
    #isa     => 'ArrayRef[Slic3r::Surface]',
    default => sub { [] },
);

# ordered collection of extrusion paths to build all perimeters
has 'perimeters' => (
    is      => 'rw',
    #isa     => 'ArrayRef[Slic3r::ExtrusionPath]',
    default => sub { [] },
);

# ordered collection of extrusion paths to build skirt loops
has 'skirts' => (
    is      => 'rw',
    #isa     => 'ArrayRef[Slic3r::ExtrusionPath]',
    default => sub { [] },
);

# collection of surfaces generated by offsetting the innermost perimeter(s)
# they represent boundaries of areas to fill
has 'fill_surfaces' => (
    is      => 'rw',
    #isa     => 'ArrayRef[Slic3r::Surface]',
    default => sub { [] },
);

# ordered collection of extrusion paths to fill surfaces
has 'fills' => (
    is      => 'rw',
    #isa     => 'ArrayRef[Slic3r::ExtrusionPath]',
    default => sub { [] },
);

sub z {
    my $self = shift;
    return $self->id * $Slic3r::layer_height / $Slic3r::resolution;
}

sub add_surface {
    my $self = shift;
    my (@vertices) = @_;
    
    # convert arrayref points to Point objects
    @vertices = map Slic3r::Point->cast($_), @vertices;
    
    my $surface = Slic3r::Surface->new(
        contour => Slic3r::Polyline::Closed->new(points => \@vertices),
    );
    push @{ $self->surfaces }, $surface;
    
    # make sure our contour has its points in counter-clockwise order
    $surface->contour->make_counter_clockwise;
    
    return $surface;
}

sub add_line {
    my $self = shift;
    my ($line) = @_;
    
    $line = Slic3r::Line->cast($line);
    
    push @{ $self->lines }, $line;
    return $line;
}

sub remove_line {
    my $self = shift;
    my ($line) = @_;
    @{ $self->lines } = grep $_ ne $line, @{ $self->lines };
}

sub remove_surface {
    my $self = shift;
    my ($surface) = @_;
    @{ $self->surfaces } = grep $_ ne $surface, @{ $self->surfaces };
}

# build polylines of lines which do not already belong to a surface
sub make_polylines {
    my $self = shift;
    
    # remove line duplicates
    {
        my %lines_map = map { join(',', sort map $_->id, @{$_->points} ) => "$_" } @{ $self->lines };
        %lines_map = reverse %lines_map;
        @{ $self->lines } = grep $lines_map{"$_"}, @{ $self->lines };
    }
    
    # now remove lines that are already part of a surface
    {
        my @lines = @{ $self->lines };
        @{ $self->lines } = ();
        LINE: foreach my $line (@lines) {
            if (!$line->isa('Slic3r::Line::FacetEdge')) {
                push @{ $self->lines }, $line;
                next LINE;
            }
            foreach my $surface (@{$self->surfaces}) {
                if ($surface->surface_type eq $line->edge_type && $surface->contour->has_segment($line)) {
                    next LINE;
                }
            }
            push @{ $self->lines }, $line;
        }
    }
    
    # make a cache of line endpoints
    my %pointmap = ();
    foreach my $line (@{ $self->lines }) {
        for my $point (@{ $line->points }) {
            $pointmap{$point->id} ||= [];
            push @{ $pointmap{$point->id} }, $line;
        }
    }
    
    # defensive programming
    #die "No point should be endpoint of less or more than 2 lines!"
    #    if grep @$_ != 2, values %pointmap;
    
    if (0) {
        # defensive programming
        for (keys %pointmap) {
            next if @{$pointmap{$_}} == 2;
            
            #use Slic3r::SVG;
            #Slic3r::SVG::output_points($main::print, "points.svg", [ map [split /,/], keys %pointmap ], [ [split /,/, $_ ] ]);
            #Slic3r::SVG::output_lines($main::print, "lines.svg", [ map $_->p, @{$self->lines} ]);
            
            YYY $pointmap{$_};
            
            die sprintf "No point should be endpoint of less or more than 2 lines ($_ => %d)!", scalar(@{$pointmap{$_}});
        }
        
        while (my @single_line_points = grep @{$pointmap{$_}} == 1, keys %pointmap) {
            for my $point_id (@single_line_points) {
                foreach my $lines (values %pointmap) {
                    next unless $pointmap{$point_id}->[0];
                    @$lines = grep $_ ne $pointmap{$point_id}->[0], @$lines;
                }
                delete $pointmap{$point_id};
            }
        }
    }
    
    # make a subroutine to remove lines from pointmap
    my $remove_line = sub {
        my $line = shift;
        foreach my $lines ($pointmap{$line->a->id}, $pointmap{$line->b->id}) {
            @$lines = grep $_ ne $line, @$lines;
        }
    };
    
    my $polylines = [];
    
    # loop while we have spare lines
    while (my ($first_line) = map @$_, values %pointmap) {
        # add first line to a new polyline
        my $points = [ $first_line->a, $first_line->b ];
        $remove_line->($first_line);
        my $last_point = $first_line->b;
        
        # loop through connected lines until we return to the first point
        while (my $next_line = $pointmap{$last_point->id}->[0]) {
            
            # get next point
            ($last_point) = grep $_->id ne $last_point->id, @{$next_line->points};
            
            # add point to polyline
            push @$points, $last_point;
            $remove_line->($next_line);
        }
        
        # remove last point as it coincides with first one
        pop @$points;
        
        die sprintf "Invalid polyline with only %d points\n", scalar(@$points) if @$points < 3;
        
        Slic3r::debugf "Discovered polyline of %d points (%s)\n", scalar @$points,
            join ' - ', map $_->id, @$points;
        push @$polylines, Slic3r::Polyline::Closed->new(points => $points);
        
        # actually this is not needed, as Math::Clipper used in make_surfaces() also cleans contours
        $polylines->[-1]->merge_continuous_lines;
        #$polylines->[-1]->cleanup;  # not proven to be actually useful
    }
    
    return $polylines;
}

sub make_surfaces {
    my $self = shift;
    my ($polylines) = @_;
    
    #use Slic3r::SVG;
    #Slic3r::SVG::output_polygons($main::print, "polylines.svg", [ map $_->p, @$polylines ]);
    
    # count how many other polylines enclose each polyline
    # even = contour; odd = hole
    my %enclosing_polylines = ();
    my %enclosing_polylines_count = ();
    my $max_depth = 0;
    foreach my $polyline (@$polylines) {
        # a polyline encloses another one if any point of it is enclosed
        # in the other
        my $point = $polyline->points->[0];
        my $ordered_id = $polyline->id;
        
        # find polylines contaning $point, and thus $polyline
        $enclosing_polylines{$polyline} = 
            [ grep $_->id ne $ordered_id && $_->encloses_point($point), @$polylines ];
        $enclosing_polylines_count{$polyline} = scalar @{ $enclosing_polylines{$polyline} };
        
        $max_depth = $enclosing_polylines_count{$polyline}
            if $enclosing_polylines_count{$polyline} > $max_depth;
    }
    
    # make a cache for contours and surfaces
    my %surfaces = ();   # contour => surface
    
    # start looking at most inner polylines
    for (; $max_depth > -1; $max_depth--) {
        foreach my $polyline (@$polylines) {
            next unless $enclosing_polylines_count{$polyline} == $max_depth;
            
            my $surface;
            if ($enclosing_polylines_count{$polyline} % 2 == 0) {
                # this is a contour
                $polyline->make_counter_clockwise;
                $surface = Slic3r::Surface->new(contour => $polyline);
            } else {
                # this is a hole
                $polyline->make_clockwise;
                
                # find the enclosing polyline having immediately close depth
                my ($contour) = grep $enclosing_polylines_count{$_} == ($max_depth-1), 
                    @{ $enclosing_polylines{$polyline} };
                
                if ($surfaces{$contour}) {
                    $surface = $surfaces{$contour};
                    $surface->add_hole($polyline);
                } else {
                    $surface = Slic3r::Surface->new(
                        contour => $contour,
                        holes   => [$polyline],
                    );
                    $surfaces{$contour} = $surface;
                }
            }
            
            # check whether we already have this surface
            next if grep $_->id eq $surface->id, @{ $self->surfaces };
            
            $surface->surface_type('internal');
            push @{ $self->surfaces }, $surface;
            
            Slic3r::debugf "New surface: %s (%d holes: %s)\n", 
                $surface->id, scalar @{$surface->holes},
                join(', ', map $_->id, @{$surface->holes}) || 'none'
                if $Slic3r::debug;
        }
    }
}

sub merge_contiguous_surfaces {
    my $self = shift;
    
    if ($Slic3r::debug) {
        Slic3r::debugf "Initial surfaces (%d):\n", scalar @{ $self->surfaces };
        Slic3r::debugf "  [%s] %s (%s with %d holes)\n", $_->surface_type, $_->id, 
            ($_->contour->is_counter_clockwise ? 'ccw' : 'cw'), scalar @{$_->holes} for @{ $self->surfaces };
        #Slic3r::SVG::output_polygons($main::print, "polygons-before.svg", [ map $_->contour->p, @{$self->surfaces} ]);
    }
    
    my %resulting_surfaces = ();
    
    # only merge surfaces with same type
    foreach my $type (qw(bottom top internal)) {
        my $clipper = Math::Clipper->new;
        my @surfaces = grep $_->surface_type eq $type, @{$self->surfaces}
            or next;
        
        #Slic3r::SVG::output_polygons($main::print, "polygons-$type-before.svg", [ map $_->contour->p, @surfaces ]);
        $clipper->add_subject_polygons([ map $_->contour->p, @surfaces ]);
        
        my $result = $clipper->ex_execute(CT_UNION, PFT_NONZERO, PFT_NONZERO);
        $clipper->clear;
        
        my @extra_holes = map @{$_->{holes}}, @$result;
        $result = [ map $_->{outer}, @$result ];
        #Slic3r::SVG::output_polygons($main::print, "polygons-$type-union.svg", $result);
        
        # subtract bottom or top surfaces from internal
        if ($type eq 'internal') {
            $clipper->add_subject_polygons($result);
            $clipper->add_clip_polygons([ map $_->{outer}, @{$resulting_surfaces{$_}} ])
                for qw(bottom top);
            $result = $clipper->execute(CT_DIFFERENCE, PFT_NONZERO, PFT_NONZERO);
            $clipper->clear;
        }
        
        # apply holes
        $clipper->add_subject_polygons($result);
        $result = $clipper->execute(CT_DIFFERENCE, PFT_NONZERO, PFT_NONZERO);
        $clipper->clear;
        
        $clipper->add_subject_polygons($result);
        $clipper->add_clip_polygons([ @extra_holes ]) if @extra_holes;
        $clipper->add_clip_polygons([ map $_->p, map @{$_->holes}, @surfaces ]);
        my $result2 = $clipper->ex_execute(CT_DIFFERENCE, PFT_NONZERO, PFT_NONZERO);
        
        $resulting_surfaces{$type} = $result2;
    }
    
    # save surfaces
    @{ $self->surfaces } = ();
    foreach my $type (keys %resulting_surfaces) {
        foreach my $p (@{ $resulting_surfaces{$type} }) {
            push @{ $self->surfaces }, Slic3r::Surface->new(
                surface_type => $type,
                contour => Slic3r::Polyline::Closed->cast($p->{outer}),
                holes   => [
                    map Slic3r::Polyline::Closed->cast($_), @{$p->{holes}}
                ],
            );
        }
    }
    
    if ($Slic3r::debug) {
        Slic3r::debugf "Final surfaces (%d):\n", scalar @{ $self->surfaces };
        Slic3r::debugf "  [%s] %s (%s with %d holes)\n", $_->surface_type, $_->id, 
            ($_->contour->is_counter_clockwise ? 'ccw' : 'cw'), scalar @{$_->holes} for @{ $self->surfaces };
    }
}

sub remove_small_features {
    my $self = shift;
    
    # for each perimeter, try to get an inwards offset
    # for a distance equal to half of the extrusion width;
    # if no offset is possible, then feature is not printable
    my @good_perimeters = ();
    foreach my $loop (@{$self->perimeters}) {
        my $p = $loop->p;
        @$p = reverse @$p if !is_counter_clockwise($p);
        my $offsets = offset([$p], -($Slic3r::flow_width / 2 / $Slic3r::resolution), $Slic3r::resolution * 100000, JT_MITER, 2);
        push @good_perimeters, $loop if @$offsets;
    }
    Slic3r::debugf "removed %d unprintable perimeters\n", (@{$self->perimeters} - @good_perimeters) 
        if @good_perimeters != @{$self->perimeters};
    
    @{$self->perimeters} = @good_perimeters;
}

1;

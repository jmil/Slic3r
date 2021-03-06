package Slic3r::Extruder;
use Moo;

has 'shift_x'            => (is => 'ro', default => sub {0} );
has 'shift_y'            => (is => 'ro', default => sub {0} );
has 'z'                  => (is => 'rw', default => sub {0} );

has 'extrusion_distance' => (is => 'rw', default => sub {0} );
has 'retracted'          => (is => 'rw', default => sub {1} );  # this spits out some plastic at start
has 'last_pos'           => (is => 'rw', default => sub { [0,0] } );
has 'dec'                => (is => 'ro', default => sub { 3 } );

# calculate speeds
has 'travel_feed_rate' => (
    is      => 'ro',
    default => sub { $Slic3r::travel_feed_rate * 60 },  # mm/min
);
has 'print_feed_rate' => (
    is      => 'ro',
    default => sub { $Slic3r::print_feed_rate * 60 },  # mm/min
);
has 'perimeter_feed_rate' => (
    is      => 'ro',
    default => sub { $Slic3r::perimeter_feed_rate * 60 },  # mm/min
);
has 'retract_speed' => (
    is      => 'ro',
    default => sub { $Slic3r::retract_speed * 60 },  # mm/min
);

use XXX;

use constant PI => 4 * atan2(1, 1);
use constant X => 0;
use constant Y => 1;

sub move_z {
    my $self = shift;
    my ($z) = @_;
    
    my $gcode = "";
    
    $gcode .= $self->retract;
    $gcode .= $self->G1(undef, $z, 0, 'move to next layer');
    
    return $gcode;
}

sub extrude_loop {
    my $self = shift;
    my ($loop, $description) = @_;
        
    # find the point of the loop that is closest to the current extruder position
    my $start_at = $loop->nearest_point_to($self->last_pos);
    
    # split the loop at the starting point and make a path
    my $extrusion_path = $loop->split_at($start_at);
    
    # clip the path to avoid the extruder to get exactly on the first point of the loop
    $extrusion_path->clip_end($Slic3r::flow_width / $Slic3r::resolution);
    
    # extrude along the path
    return $self->extrude($extrusion_path, $description);
}

sub extrude {
    my $self = shift;
    my ($path, $description) = @_;
    
    my $gcode = "";
    
    # reset extrusion distance counter
    if (!$Slic3r::use_relative_e_distances) {
        $self->extrusion_distance(0);
        $gcode .= "G92 E0 ; reset extrusion distance\n";
    }
    
    # retract
    if (Slic3r::Geometry::distance_between_points($self->last_pos, $path->points->[0]->p) * $Slic3r::resolution
        >= $Slic3r::retract_before_travel) {
        $gcode .= $self->retract;
    }
    
    # go to first point of extrusion path
    $gcode .= $self->G1($path->points->[0], undef, 0, "move to first $description point");
    
    # compensate retraction
    $gcode .= $self->unretract if $self->retracted;
    
    # extrude while going to next points
    foreach my $line ($path->lines) {
        # calculate how much filament to drive into the extruder
        # to get the desired amount of extruded plastic
        my $e = $line->a->distance_to($line->b) * $Slic3r::resolution
            * (($Slic3r::nozzle_diameter**2) / ($Slic3r::filament_diameter ** 2))
            * $Slic3r::thickness_ratio 
            * $Slic3r::filament_packing_density;
        
        $gcode .= $self->G1($line->b, undef, $e, $description);
    }
    
    return $gcode;
}

sub retract {
    my $self = shift;
    return "" unless $Slic3r::retract_length > 0 
        && !$self->retracted;
    
    $self->retracted(1);
    return $self->G1(undef, undef, -$Slic3r::retract_length, "retract");
}

sub unretract {
    my $self = shift;
    $self->retracted(0);
    return $self->G1(undef, undef, ($Slic3r::retract_length + $Slic3r::retract_restart_extra), 
        "compensate retraction");
}

sub G1 {
    my $self = shift;
    my ($point, $z, $e, $comment) = @_;
    my $dec = $self->dec;
    
    my $gcode = "G1";
    
    if ($point) {
        $gcode .= sprintf " X%.${dec}f Y%.${dec}f", 
            ($point->x * $Slic3r::resolution) + $self->shift_x, 
            ($point->y * $Slic3r::resolution) + $self->shift_y; #**
        $self->last_pos($point->p);
    }
    if (defined $z && $z != $self->z) {
        $self->z($z);
        $gcode .= sprintf " Z%.${dec}f", $z;
    }
    
    # apply the speed reduction for print moves on bottom layer
    my $speed_multiplier = $e && $self->z == $Slic3r::z_offset
        ? $Slic3r::bottom_layer_speed_ratio 
        : 1;

    if ($e) {
        $self->extrusion_distance(0) if $Slic3r::use_relative_e_distances;
        $self->extrusion_distance($self->extrusion_distance + $e);
        my $speed = $self->print_feed_rate * $speed_multiplier;
        $speed = $self->retract_speed if $comment =~ /retract/;
        $speed = $self->perimeter_feed_rate * $speed_multiplier if $comment =~ /perimeter/;
        
        $gcode .= sprintf " F%.${dec}f E%.5f", $speed, $self->extrusion_distance;
        
    } else {
        $gcode .= sprintf " F%.${dec}f", ($self->travel_feed_rate * $speed_multiplier);
    }
    $gcode .= sprintf " ; %s", $comment if $comment;
    
    return "$gcode\n";
}

1;

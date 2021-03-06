use Module::Build;

my $build = Module::Build->new(
    module_name     => 'Slic3r',
    dist_abstract   => 'STL-to-GCODE translator',
    dist_author     => 'Alessandro Ranellucci <aar@cpan.org>',
    dist_version    => '0.1',
    license         => 'perl',
    requires        => {
        'CAD::Format::STL'          => '0',
        'File::Basename'            => '0',
        'Getopt::Long'              => '0',
        'Math::Clipper'             => '1.01',
        'Math::Geometry::Planar'    => '0',
        'Math::Geometry::Planar::Offset' => '0',
        'Moo'                       => '0',
        'Time::HiRes'               => '0',
        'XXX'                       => '0',
    },
    build_requires => {
        'Test::More' => '0.10',
    },
    script_files    => ['slic3r.pl'],
);
$build->dispatch('installdeps');
$build->dispatch('test', verbose => 0);

$build->create_build_script;

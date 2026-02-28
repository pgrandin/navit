project('navit', 'c', 'cpp', default_options: ['warning_level=3'])

# Enable some sanity
add_project_arguments(
	'-fno-strict-aliasing',
	'-fwrapv',
	'-DHAVE_UNISTD_H=1',
	language: ['c', 'cpp'])

# Enable large files
add_project_arguments(
	'-D_LARGEFILE_SOURCE=1',
	'-D_FILE_OFFSET_BITS=64',
	language: ['c', 'cpp'])

# Set directories for data
sharedir = get_option('datadir') + '/navit'
add_project_arguments(
	'-DPREFIX="' + get_option('prefix') + '"',
	'-DLIBDIR="' + get_option('libdir') + '"',
	'-DLIB_DIR="' + get_option('libdir') + '"',
	'-DSHARE_DIR="' + sharedir + '"',
	'-DLOCALE_DIR="' + get_option('localedir') + '"',
	language: ['c', 'cpp'])

# Required dependencies
cc = meson.get_compiler('cpp')
glib = dependency('glib-2.0')
libm = cc.find_library('m')
libpthread = cc.find_library('pthread')
zlib = dependency('zlib')

# Common source code
depends = [glib, libm, libpthread, zlib]
includedirs = [include_directories('navit')]
sources = [
	'navit/atom.c',
	'navit/attr.c',
	'navit/cache.c',
	'navit/callback.c',
	'navit/config_.c',
	'navit/coord.c',
	'navit/country.c',
	'navit/debug.c',
	'navit/event.c',
	'navit/event_glib.c',
	'navit/file.c',
	'navit/geom.c',
	'navit/item.c',
	'navit/linguistics.c',
	'navit/main.c',
	'navit/map/binfile/binfile.c',
	'navit/map.c',
	'navit/maps.c',
	'navit/mapset.c',
	'navit/navit.c',
	'navit/navit_nls.c',
	'navit/param.c',
	'navit/plugin.c',
	'navit/projection.c',
	'navit/start_real.c',
	'navit/track.c',
	'navit/transform.c',
	'navit/util.c',
	'navit/vehicle.c',
	'navit/xmlconfig.c',
]

# Navit
libgps = dependency('libgps', required: false)
arduipi = cc.find_library('ArduiPi_OLED', required: false)
if arduipi.found()
	navitdepends = depends + [arduipi]
	navitincludedirs = includedirs
	navitsources = sources + [
		'navit/graphics/ssd1306/graphics_init_animation.cpp',
		'navit/graphics/ssd1306/graphics_ssd1306.cpp',
		'navit/start.c',
		'navit/vehicle/file/vehicle_file.c',
	]
	if libgps.found()
		navitdepends += [libgps]
		navitsources += ['navit/vehicle/gpsd/vehicle_gpsd.c']
	endif
	executable('navit',
		navitsources,
		dependencies: navitdepends,
		include_directories: navitincludedirs,
		install: true)
	configure_file(input: 'navit/navit.service.in',
		output: 'navit.service',
		configuration: { 'bindir': get_option('prefix') / get_option('bindir') },
		install: true,
		install_dir: '/usr/lib/systemd/system/')
	install_data('navit/navit_shipped.xml', rename: 'navit.xml', install_dir: sharedir)
	install_data('navit/graphics/ssd1306/tone7.wav', install_dir: sharedir)
else
	message('Unable to find a Navit dependency, skipping build')
endif

# MapTool apparently only supports 64-bit architectures
# I assume it's only been tested on x86_64
if target_machine.cpu_family() == 'x86_64'
	mapdepends = depends
	mapincludedirs = includedirs + [include_directories('navit/maptool')]
	mapsources = sources + [
		'navit/maptool/boundaries.c',
		'navit/maptool/buffer.c',
		'navit/maptool/coastline.c',
		'navit/maptool/itembin_buffer.c',
		'navit/maptool/itembin.c',
		'navit/maptool/maptool.c',
		'navit/maptool/misc.c',
		'navit/maptool/osm.c',
		'navit/maptool/osm_relations.c',
		'navit/maptool/osm_xml.c',
		'navit/maptool/sourcesink.c',
		'navit/maptool/tempfile.c',
		'navit/maptool/tile.c',
		'navit/maptool/zip.c',
	]
	executable('maptool',
		mapsources,
		dependencies: mapdepends,
		include_directories: mapincludedirs)
else
	message('MapTool build only supported on x86_64')
endif

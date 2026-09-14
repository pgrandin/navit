/* End-to-end routing check using the production, unmodified binfile reader. */
#include "attr.h"
#include "config.h"
#include "file.h"
#include "item.h"
#include "linguistics.h"
#include "main.h"
#include "map.h"
#include "mapset.h"
#include "plugin.h"
#include "roadprofile.h"
#include "route.h"
#include "transform.h"
#include "vehicleprofile.h"
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv) {
  if (argc != 7)
    return 2;
  main_init(argv[0]);
  file_init();
  linguistics_init();
  route_init();
  struct plugins *plugins = plugins_new(NULL, NULL);
  struct attr parent = {.type = attr_plugins, .u.plugins = plugins};
  struct attr path = {.type = attr_path, .u.str = argv[1]};
  struct attr *plugin_attrs[] = {&path, NULL};
  plugin_new(&parent, plugin_attrs);
  plugins_init(plugins);
  struct attr type = {.type = attr_type, .u.str = "binfile"};
  struct attr data = {.type = attr_data, .u.str = argv[2]};
  struct attr *attrs[] = {&type, &data, NULL};
  struct map *map = map_new(NULL, attrs);
  if (!map)
    return 3;
  struct attr *empty[] = {NULL};
  struct mapset *maps = mapset_new(NULL, empty);
  struct attr map_attr = {.type = attr_map, .u.map = map};
  mapset_add_attr(maps, &map_attr);
  struct attr flags = {.type = attr_flags, .u.num = 0x4000000};
  struct attr forward = {.type = attr_flags_forward_mask, .u.num = 0x4000002};
  struct attr reverse = {.type = attr_flags_reverse_mask, .u.num = 0x4000001};
  struct attr depth = {.type = attr_route_depth, .u.str = "18:100000"};
  struct attr mode = {.type = attr_route_mode, .u.num = 1};
  struct attr name = {.type = attr_name, .u.str = "car"};
  struct attr *profile_attrs[] = {&name,  &flags, &forward, &reverse,
                                  &depth, &mode,  NULL};
  struct vehicleprofile *profile = vehicleprofile_new(NULL, profile_attrs);
  if (!profile)
    return 4;
  enum item_type road_types[] = {
      type_street_0,       type_street_1_city,       type_street_2_city,
      type_street_3_city,  type_street_4_city,       type_highway_city,
      type_street_1_land,  type_street_2_land,       type_street_3_land,
      type_street_4_land,  type_street_n_lanes,      type_highway_land,
      type_ramp,           type_roundabout,          type_ferry,
      type_track_paved,    type_track_gravelled,     type_track_unpaved,
      type_track_ground,   type_track_grass,         type_living_street,
      type_street_service, type_street_parking_lane, type_none};
  struct attr types = {.type = attr_item_types, .u.item_types = road_types};
  struct attr speed = {.type = attr_speed, .u.num = 50};
  struct attr maxspeed = {.type = attr_maxspeed, .u.num = 50};
  struct attr *road_attrs[] = {&types, &speed, &maxspeed, NULL};
  struct attr road = {.type = attr_roadprofile,
                      .u.roadprofile = roadprofile_new(NULL, road_attrs)};
  vehicleprofile_add_attr(profile, &road);
  struct route *route = route_new(NULL, empty);
  route_set_mapset(route, maps);
  route_set_profile(route, profile);
  struct pcoord start = {.pro = projection_mg}, end = {.pro = projection_mg};
  struct coord c;
  struct coord_geo geo = {.lng = atof(argv[3]), .lat = atof(argv[4])};
  transform_from_geo(projection_mg, &geo, &c);
  start.x = c.x;
  start.y = c.y;
  geo.lng = atof(argv[5]);
  geo.lat = atof(argv[6]);
  transform_from_geo(projection_mg, &geo, &c);
  end.x = c.x;
  end.y = c.y;
  route_set_position(route, &start);
  route_set_destination(route, &end, 0);
  struct attr length, status;
  int found = route_get_attr(route, attr_destination_length, &length, NULL);
  route_get_attr(route, attr_route_status, &status, NULL);
  printf("{\"found\":%d,\"length\":%ld,\"status\":%ld,\"coordinates\":[", found,
         found ? length.u.num : -1L, status.u.num);
  struct map_rect *rect = map_rect_new(route_get_map(route), NULL);
  struct item *it;
  int first = 1;
  while (rect && (it = map_rect_get_item(rect))) {
    if (it->type != type_street_route)
      continue;
    while (item_coord_get(it, &c, 1)) {
      printf("%s[%d,%d]", first ? "" : ",", c.x, c.y);
      first = 0;
    }
  }
  if (rect)
    map_rect_destroy(rect);
  printf("]}\n");
  route_destroy(route);
  return 0;
}

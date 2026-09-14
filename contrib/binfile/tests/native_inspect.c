/* Feature reachability and country/town/street/house search through Navit. */
#include "attr.h"
#include "config.h"
#include "coord.h"
#include "file.h"
#include "item.h"
#include "linguistics.h"
#include "main.h"
#include "map.h"
#include "plugin.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void hex_string(const char *s) {
  if (!s)
    return;
  while (*s)
    printf("%02x", (unsigned char)*s++);
}

static char *name_of(struct item *it, enum attr_type type) {
  struct attr a;
  return item_attr_get(it, type, &a) ? g_strdup(a.u.str) : g_strdup("");
}

static void search(struct map *map, int country_id, int include_houses) {
  struct item country = {.type = type_country_label, .id_lo = country_id};
  struct attr query = {.type = attr_town_name, .u.str = ""};
  struct map_search *towns = map_search_new(map, &country, &query, 1);
  struct item *town;
  while (towns && (town = map_search_get_item(towns))) {
    struct item town_copy = *town;
    char *town_name = name_of(town, attr_town_name);
    printf("town %d ", country_id);
    hex_string(town_name);
    printf("\n");
    query.type = attr_street_name;
    struct map_search *streets = map_search_new(map, &town_copy, &query, 1);
    struct item *street;
    while (streets && (street = map_search_get_item(streets))) {
      struct item street_copy = *street;
      char *street_name = name_of(street, attr_label);
      printf("street %d ", country_id);
      hex_string(town_name);
      printf(" ");
      hex_string(street_name);
      printf("\n");
      if (!include_houses) {
        g_free(street_name);
        continue;
      }
      query.type = attr_house_number;
      struct map_search *houses = map_search_new(map, &street_copy, &query, 1);
      struct item *house;
      while (houses && (house = map_search_get_item(houses))) {
        char *number = name_of(house, attr_house_number);
        struct coord c = {0};
        item_coord_get(house, &c, 1);
        printf("house %d ", country_id);
        hex_string(town_name);
        printf(" ");
        hex_string(street_name);
        printf(" ");
        hex_string(number);
        printf(" %d %d\n", c.x, c.y);
        g_free(number);
      }
      if (houses)
        map_search_destroy(houses);
      g_free(street_name);
    }
    if (streets)
      map_search_destroy(streets);
    g_free(town_name);
  }
  if (towns)
    map_search_destroy(towns);
}

int main(int argc, char **argv) {
  if (argc < 3)
    return 2;
  main_init(argv[0]);
  file_init();
  linguistics_init();
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
  struct map_rect *rect = map_rect_new(map, NULL);
  if (!rect)
    return 4;
  struct item *it;
  while ((it = map_rect_get_item(rect))) {
    if (it->type == type_none || it->type == type_submap ||
        it->type == type_countryindex || it->type == type_map_information)
      continue;
    struct coord c;
    printf("feature %d", it->type);
    while (item_coord_get(it, &c, 1))
      printf(" %d,%d", c.x, c.y);
    printf("\n");
  }
  map_rect_destroy(rect);
  int first_country = 3;
  int include_houses = 1;
  if (argc > 3 && !strcmp(argv[3], "--skip-houses")) {
    first_country = 4;
    include_houses = 0;
  }
  for (int i = first_country; i < argc; ++i)
    search(map, atoi(argv[i]), include_houses);
  map_destroy(map);
  return 0;
}

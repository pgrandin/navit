#include <glib.h>
#include <navit/main.h>
#include <navit/debug.h>
#include <navit/point.h>
#include <navit/navit.h>
#include <navit/callback.h>
#include <navit/color.h>
#include <navit/event.h>
#include <navit/command.h>
#include <navit/config_.h>

#include "gui_internal.h"
#include "coord.h"
#include "math.h"
#include "gui_internal_menu.h"
#include "gui_internal_widget.h"
#include "gui_internal_priv.h"
#include "gui_internal_foursquare.h"
#include "network.h"

#include "jansson.h"

char *api_version = "20131016";
char *api_url = "https://api.foursquare.com/v2/checkins/add";
char *client_id = "";
char *client_secret = "";
char *oauth_token = "";

static void
foursquare_set_destination (struct gui_priv *this, struct widget *wm,
			    void *data)
{
  char *name = wm->name;
  dbg (0, "%s c=%d:0x%x,0x%x\n", name, wm->c.pro, wm->c.x, wm->c.y);
  navit_set_destination (this->nav, &wm->c, name, 1);
  gui_internal_prune_menu (this, NULL);
}

void
foursquare_checkin (struct gui_priv *this, struct widget *wm, void *data)
{
  struct widget *wb, *w, *wtable, *wc, *row;
  char lat_s[50], lng_s[50];
  dbg (0, "About to check-in at %s\n", wm->prefix);

  struct coord_geo g;

  struct transformation *trans;
  trans = navit_get_trans (this->nav);
  struct coord c;
  c.x = wm->c.x;
  c.y = wm->c.y;

  transform_to_geo (transform_get_projection (trans), &c, &g);

  snprintf (lat_s, 50, "%f", g.lat);
  snprintf (lng_s, 50, "%f", g.lng);

  char *url = NULL;
  url = malloc (256);
  char *broadcast = "public";
  sprintf (url, "venueId=%s&ll=%s,%s&oauth_token=%s&v=%s&broadcast=%s",
	   wm->prefix, lat_s, lng_s, oauth_token, api_version, broadcast);
  dbg (0, "Url is [%s]\n", url);
  dbg (0, "Try with [ wget --post-data='%s' '%s' ]\n", url, api_url);

  char * js=post_to_string(api_url);
  printf ("%s\n", js);
  // FIXME : actually parse the resultcode
  int resultcode = 200;
  dbg (0, "Meta code is %i\n", resultcode);

  wb = gui_internal_menu (this, "Check-in result");

  w = gui_internal_box_new (this,
			  gravity_top_center | orientation_vertical |
			  flags_expand | flags_fill);
  gui_internal_widget_append (wb, w);
  gui_internal_widget_append (w, gui_internal_label_new (this, "coord"));
  wtable =
    gui_internal_widget_table_new (this,
				   gravity_left_top | flags_fill |
				   flags_expand | orientation_vertical, 1);
  gui_internal_widget_append (w, wtable);

  gui_internal_widget_append (wtable, row =
			      gui_internal_widget_table_row_new (this,
	 gravity_left | orientation_horizontal | flags_fill));
  gui_internal_widget_append (row, wc =
			      gui_internal_button_new_with_callback (this,
	     resultcode == 200 ?  "Check-in successful" : "Check-in failed",
	     image_new_xs (this, resultcode == 200 ?  "gui_active" : "gui_inactive"),
	     gravity_left_center | orientation_horizontal | flags_fill, NULL, wm)
  );
  wc->item = wm->item;
  wc->selection_id = wm->selection_id;
  wc->prefix = g_strdup (wm->prefix);

  gui_internal_menu_render (this);
}

void
foursquare_show_item (struct gui_priv *this, struct widget *wm, void *data)
{
  struct widget *wb, *w, *wtable, *wc, *row;
  dbg (0, "Item is at nvt:%d %d\n", wm->c.x, wm->c.y);
  wb = gui_internal_menu (this, wm->name);
  w =
    gui_internal_box_new (this,
			  gravity_top_center | orientation_vertical |
			  flags_expand | flags_fill);
  gui_internal_widget_append (wb, w);
  gui_internal_widget_append (w, gui_internal_label_new (this, wm->name));
  wtable =
    gui_internal_widget_table_new (this,
				   gravity_left_top | flags_fill |
				   flags_expand | orientation_vertical, 1);
  gui_internal_widget_append (w, wtable);

  gui_internal_widget_append (wtable, row =
			      gui_internal_widget_table_row_new (this,
								 gravity_left
								 |
								 orientation_horizontal
								 |
								 flags_fill));
  gui_internal_widget_append (row, wc =
			      gui_internal_button_new_with_callback (this,
								     "Set as destination",
								     image_new_xs
								     (this,
								      "gui_active"),
								     gravity_left_center
								     |
								     orientation_horizontal
								     |
								     flags_fill,
								     foursquare_set_destination,
								     wm));
  wc->item = wm->item;
  wc->selection_id = wm->selection_id;
  wc->name = g_strdup (wm->name);
  wc->c.x = wm->c.x;
  wc->c.y = wm->c.y;
  wc->c.pro = projection_mg;
  wc->prefix = g_strdup (wm->prefix);


  gui_internal_widget_append (wtable, row =
			      gui_internal_widget_table_row_new (this,
								 gravity_left
								 |
								 orientation_horizontal
								 |
								 flags_fill));
  gui_internal_widget_append (row, wc =
			      gui_internal_button_new_with_callback (this,
								     "Check-in there",
								     image_new_xs
								     (this,
								      "gui_active"),
								     gravity_left_center
								     |
								     orientation_horizontal
								     |
								     flags_fill,
								     foursquare_checkin,
								     wm));
  wc->item = wm->item;
  wc->selection_id = wm->selection_id;
  wc->c.x = wm->c.x;
  wc->c.y = wm->c.y;
  wc->prefix = g_strdup (wm->prefix);

  gui_internal_menu_render (this);
}

static void
gui_internal_cmd_pois_filter_do(struct gui_priv *this, struct widget *wm, void *data)
{
        struct widget *w=data;
        struct poi_param *param;

        if(!w->text)
                return;
	dbg(0,"Searching for %s\n", w->text);


  char *prefix = 0;
  char track_icon[64];
  struct widget *wb, *wbm;
  struct widget *tbl, *row;

  struct coord_geo g;

  struct transformation *trans;
  trans = navit_get_trans (this->nav);
  struct coord c;
  c.x = wm->c.x;
  c.y = wm->c.y;

  transform_to_geo (transform_get_projection (trans), &c, &g);

  dbg (0, "4sq called for %d x %d, converted to %4.16f x %4.16f\n", wm->c.x,
       wm->c.y, g.lat, g.lng);
  int radius = 20000;
  char radius_string[32];
  sprintf (radius_string, "%d", radius);

  char *baseurl = "https://api.foursquare.com/v2/venues/search?limit=50&ll=";
  char url[256];

  char lat_string[50];
  snprintf (lat_string, 50, "%f", g.lat);
  char lng_string[50];
  snprintf (lng_string, 50, "%f", g.lng);

  strcpy (url, g_strdup_printf ("%s%s,%s&radius=%s&client_id=%s&client_secret=%s&v=%s&query=%s",  baseurl, lat_string, lng_string, radius_string, client_id, client_secret, api_version, w->text));

  char * js=fetch_url_to_string(url);
  dbg (0, "url %s gave %s\n", url, js);

  json_t *root;
  json_error_t error;

  root = json_loads (js, 0, &error);

  json_t *response, *venues;
  response = json_object_get (root, "response");

  // gui_internal_prune_menu_count (this, 1, 0);
  wb = gui_internal_menu (this, "Foursquare");
  wb->background = this->background;
  w = gui_internal_box_new (this,
			  gravity_top_center | orientation_vertical |
			  flags_expand | flags_fill);
  gui_internal_widget_append (wb, w);

  wbm = gui_internal_button_new_with_callback (this, "Search results",
					       image_new_xs (this,
							     "foursquare"),
					       gravity_left_center |
					       orientation_horizontal,
					       NULL,
					       NULL);
  gui_internal_widget_append (w, wbm);

  tbl = gui_internal_widget_table_new (this,
				   gravity_left_top | flags_fill |
				   flags_expand | orientation_vertical, 1);
  gui_internal_widget_append (w, tbl);

  venues = json_object_get (response, "venues");

  int i = 0;
  for (i = 0; i < json_array_size (venues); i++)
    {
      json_t *venue, *name, *location, *id;
      venue = json_array_get (venues, i);
      name = json_object_get (venue, "name");
      id = json_object_get (venue, "id");
      location = json_object_get (venue, "location");

      dbg (0, "Found [%i] %s with id %s\n", i, json_string_value (name),
	   json_string_value (id));

      json_t *categories = json_object_get (venue, "categories");
      strcpy (track_icon, "default");
      if (json_array_size (categories) > 0)
	{
	  json_t *categorie = json_array_get (categories, 0);
	  json_t *icon = json_object_get (categorie, "icon");
	  json_t *prefix = json_object_get (icon, "prefix");
	  json_t *suffix = json_object_get (icon, "suffix");
	  dbg (0, "Icon found at %s32%s\n", json_string_value (prefix),
	       json_string_value (suffix));
	  char prefix_str[512], suffix_str[12];
	  strcpy (prefix_str, json_string_value (prefix));
	  strcpy (suffix_str, json_string_value (suffix));

	  download_icon (prefix_str, "32", suffix_str);

	  strcpy (track_icon, strrchr (prefix_str, '/') + 1);
	  char *end = track_icon + strlen (track_icon) - 4;
	  *(end + 1) = 0;
	}

      row = gui_internal_widget_table_row_new (this,
					   gravity_left | flags_fill |
					   orientation_horizontal);
      gui_internal_widget_append (tbl, row);
      wbm = gui_internal_button_new_with_callback (this, 
      		g_strdup_printf("%s (%s, %s) %i meters", json_string_value(name),
			json_string_value(json_object_get(location,"address")),
			json_string_value(json_object_get(location,"city")),
			json_integer_value(json_object_get(location,"distance"))
		),
					       image_new_xs (this,
							     track_icon),
					       gravity_left_center |
					       orientation_horizontal |
					       flags_fill,
					       foursquare_show_item, NULL);

      gui_internal_widget_append (row, wbm);

      struct coord c;
      struct coord_geo g;

      g.lat = json_real_value (json_object_get (location, "lat"));
      g.lng = json_real_value (json_object_get (location, "lng"));

      transform_from_geo (projection_mg, &g, &c);
      dbg (0, "Item as at : %4.16f x %4.16f [ %d x %d ]\n", g.lat, g.lng, c.x, c.y);

      wbm->c.x = c.x;
      wbm->c.y = c.y;
      wbm->c.pro = projection_mg;
      wbm->img = image_new_xs (this, track_icon);
      // FIXME : we should convert the results into navit item struct
      wbm->name = g_strdup (json_string_value (name));
      wbm->prefix = g_strdup (json_string_value (id));
    }

  g_free (prefix);
  json_decref (root);

  gui_internal_menu_render (this);
}

void
gui_internal_foursquare_search(struct gui_priv *this, struct widget *wm, void *data)
{
        struct widget *wb, *w, *wr, *wk, *we;
        int keyboard_mode;
        keyboard_mode=2+gui_internal_keyboard_init_mode(getenv("LANG"));
        wb=gui_internal_menu(this,"Search");
        w=gui_internal_box_new(this, gravity_center|orientation_vertical|flags_expand|flags_fill);
        gui_internal_widget_append(wb, w);
        wr=gui_internal_box_new(this, gravity_top_center|orientation_vertical|flags_expand|flags_fill);
        gui_internal_widget_append(w, wr);
        we=gui_internal_box_new(this, gravity_left_center|orientation_horizontal|flags_fill);
        gui_internal_widget_append(wr, we);

        gui_internal_widget_append(we, wk=gui_internal_label_new(this, NULL));
        wk->state |= STATE_EDIT|STATE_EDITABLE;
        // wk->func=gui_internal_cmd_pois_filter_changed;
        wk->background=this->background;
        wk->flags |= flags_expand|flags_fill;
        wk->name=g_strdup("POIsFilter");
        wk->c=wm->c;
        dbg (0, "4sq  filter called for %d x %d\n", wm->c.x, wm->c.y);
        gui_internal_widget_append(we, wb=gui_internal_image_new(this, image_new_xs(this, "gui_active")));
        wb->state |= STATE_SENSITIVE;
        wb->func = gui_internal_cmd_pois_filter_do;
        wb->name=g_strdup("NameFilter");
        wb->c=wm->c;
        wb->data=wk;

        if (this->keyboard)
                gui_internal_widget_append(w, gui_internal_keyboard(this,keyboard_mode));
        gui_internal_menu_render(this);


}


void
gui_internal_foursquare_show_pois (struct gui_priv *this, struct widget *wm,
				   void *data)
{

  char *prefix = 0;
  char track_icon[64];
  struct widget *wb, *w, *wbm;
  struct widget *tbl, *row;

  struct coord_geo g;

  struct transformation *trans;
  trans = navit_get_trans (this->nav);
  struct coord c;
  c.x = wm->c.x;
  c.y = wm->c.y;

  transform_to_geo (transform_get_projection (trans), &c, &g);

  dbg (0, "4sq called for %d x %d, converted to %4.16f x %4.16f\n", wm->c.x,
       wm->c.y, g.lat, g.lng);
  int radius = 20000;
  char radius_string[32];
  sprintf (radius_string, "%d", radius);

  char *baseurl = "https://api.foursquare.com/v2/venues/search?limit=50&ll=";
  char url[256];

  char lat_string[50];
  snprintf (lat_string, 50, "%f", g.lat);
  char lng_string[50];
  snprintf (lng_string, 50, "%f", g.lng);

  strcpy (url, g_strdup_printf ("%s%s,%s&radius=%s&client_id=%s&client_secret=%s&v=%s",  baseurl, lat_string, lng_string, radius_string, client_id, client_secret, api_version));
  char *js=fetch_url_to_string(url);

  dbg (0, "url %s gave %s\n", url, js);

  json_t *root;
  json_error_t error;

  root = json_loads (js, 0, &error);

  json_t *response, *venues;
  response = json_object_get (root, "response");

  // gui_internal_prune_menu_count (this, 1, 0);
  wb = gui_internal_menu (this, "Foursquare");
  wb->background = this->background;
  w = gui_internal_box_new (this,
			  gravity_top_center | orientation_vertical |
			  flags_expand | flags_fill);
  gui_internal_widget_append (wb, w);

  wbm = gui_internal_button_new_with_callback (this, "Search",
					       image_new_xs (this,
							     "foursquare"),
					       gravity_left_center |
					       orientation_horizontal,
					       gui_internal_foursquare_search,
					       NULL);
  gui_internal_widget_append (w, wbm);
  wbm->c=wm->c;

  tbl = gui_internal_widget_table_new (this,
				   gravity_left_top | flags_fill |
				   flags_expand | orientation_vertical, 1);
  gui_internal_widget_append (w, tbl);

  venues = json_object_get (response, "venues");

  int i = 0;
  for (i = 0; i < json_array_size (venues); i++)
    {
      json_t *venue, *name, *location, *id;
      venue = json_array_get (venues, i);
      name = json_object_get (venue, "name");
      id = json_object_get (venue, "id");
      location = json_object_get (venue, "location");

      dbg (0, "Found [%i] %s with id %s\n", i, json_string_value (name),
	   json_string_value (id));

      json_t *categories = json_object_get (venue, "categories");
      strcpy (track_icon, "default");
      if (json_array_size (categories) > 0)
	{
	  json_t *categorie = json_array_get (categories, 0);
	  json_t *icon = json_object_get (categorie, "icon");
	  json_t *prefix = json_object_get (icon, "prefix");
	  json_t *suffix = json_object_get (icon, "suffix");
	  dbg (0, "Icon found at %s32%s\n", json_string_value (prefix),
	       json_string_value (suffix));
	  char prefix_str[512], suffix_str[12];
	  strcpy (prefix_str, json_string_value (prefix));
	  strcpy (suffix_str, json_string_value (suffix));

	  download_icon (prefix_str, "32", suffix_str);

	  strcpy (track_icon, strrchr (prefix_str, '/') + 1);
	  char *end = track_icon + strlen (track_icon) - 4;
	  *(end + 1) = 0;
	}

      row = gui_internal_widget_table_row_new (this,
					   gravity_left | flags_fill |
					   orientation_horizontal);
      gui_internal_widget_append (tbl, row);
      wbm = gui_internal_button_new_with_callback (this, json_string_value (name),
					       image_new_xs (this,
							     track_icon),
					       gravity_left_center |
					       orientation_horizontal |
					       flags_fill,
					       foursquare_show_item, NULL);

      gui_internal_widget_append (row, wbm);

      struct coord c;
      struct coord_geo g;

      g.lat = json_real_value (json_object_get (location, "lat"));
      g.lng = json_real_value (json_object_get (location, "lng"));

      transform_from_geo (projection_mg, &g, &c);
      dbg (0, "Item as at : %4.16f x %4.16f [ %d x %d ]\n", g.lat, g.lng, c.x, c.y);

      wbm->c.x = c.x;
      wbm->c.y = c.y;
      wbm->c.pro = projection_mg;
      wbm->img = image_new_xs (this, track_icon);
      // FIXME : we should convert the results into navit item struct
      wbm->name = g_strdup (json_string_value (name));
      wbm->prefix = g_strdup (json_string_value (id));
    }

  g_free (prefix);
  json_decref (root);

  gui_internal_menu_render (this);
}

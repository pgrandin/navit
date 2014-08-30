/* vim: set tabstop=4 expandtab: */
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
#include "gui_internal_googlesearch.h"
#include "network.h"
#include <time.h> // Benchmarking the multithreading code, to be removed
#include <pthread.h>

#include "jansson.h"

// Insert the googleplace API key
char *key = "";

struct googleplace {
    char * id;
    char * description;
    struct coord c;
    struct coord_geo g;
    struct gui_priv *gui_priv;
    struct widget *wm;
};

static void
googlesearch_set_destination (struct gui_priv *this, struct widget *wm,
			    void *data)
{
  char *name = wm->name;
  dbg (1, "%s c=%d:0x%x,0x%x\n", name, wm->c.pro, wm->c.x, wm->c.y);
  navit_set_destination (this->nav, &wm->c, name, 1);
  gui_internal_prune_menu (this, NULL);
}


void *
fetch_googleplace_details(void * arg)
{
      char url[256];
      struct googleplace *gp;
      gp = (struct googleplace*)arg;
      strcpy (url, g_strdup_printf ("https://maps.googleapis.com/maps/api/place/details/json?key=%s&placeid=%s",key,gp->id));
      dbg(1,"Url %s\n", url);

      json_t *root;
      json_error_t error;
      json_t *result, *geometry, *location;
      char * item_js= fetch_url_to_string(url);
      dbg(1,"%s\n",item_js);
      root = json_loads (item_js, 0, &error);
      free(item_js);
      if(!root)
      {
          dbg(0,"Invalid json for url %s, giving up for place id %s\n",url,gp->id);
          json_decref (root);
          return 0;
      }
      // result->geometry->location->lat
      result = json_object_get (root, "result");
      geometry = json_object_get (result, "geometry");
      location = json_object_get (geometry, "location");
      gp->g.lat = json_real_value (json_object_get (location, "lat"));
      gp->g.lng = json_real_value (json_object_get (location, "lng"));
      transform_from_geo (projection_mg, &gp->g, &gp->c);
      dbg (1, "Item as at : %4.16f x %4.16f [ %d x %d ]\n", gp->g.lat, gp->g.lng, gp->c.x, gp->c.y);
      json_decref (root);
  
      struct widget *wtable=gui_internal_menu_data(gp->gui_priv)->search_list;
      struct widget *wc;
      struct widget *row;
      gui_internal_widget_append (wtable, row =
                      gui_internal_widget_table_row_new (gp->gui_priv,
                           gravity_left | orientation_horizontal | flags_fill));
      gui_internal_widget_append (row, wc =
                      gui_internal_button_new_with_callback (gp->gui_priv,
                                         gp->description,
                                         image_new_xs (gp->gui_priv, "gui_active"),
                                         gravity_left_center | orientation_horizontal | flags_fill,
                                         googlesearch_set_destination,
                                         gp->wm));
    
      wc->item = gp->wm->item;
      wc->selection_id = gp->wm->selection_id;
      wc->name = g_strdup (gp->description);
      wc->c.x = gp->c.x;
      wc->c.y = gp->c.y;
      wc->c.pro = projection_mg;
      wc->prefix = g_strdup (gp->wm->prefix);
      return 0;
}

static void
gui_internal_cmd_googlesearch_filter_do(struct gui_priv *this, struct widget *wm, void *data)
{
        struct widget *w=data;

        if(!w->text)
                return;

  char *prefix = 0;
  char track_icon[64];
  struct coord_geo g;

  struct transformation *trans;
  trans = navit_get_trans (this->nav);
  struct coord c;
  c.x = wm->c.x;
  c.y = wm->c.y;

  transform_to_geo (transform_get_projection (trans), &c, &g);

  dbg (1, "googlesearch called for %d x %d, converted to %4.16f x %4.16f\n", wm->c.x, wm->c.y, g.lat, g.lng);

  char *baseurl = "https://maps.googleapis.com/maps/api/place/autocomplete/json?";
  char url[256];

  char lat_string[50];
  snprintf (lat_string, 50, "%f", g.lat);
  char lng_string[50];
  snprintf (lng_string, 50, "%f", g.lng);

  strcpy (url, g_strdup_printf ("%slocation=%s,%s&key=%s&input=%s",  baseurl, lat_string, lng_string, key, w->text));

  char * js=fetch_url_to_string(url);

  json_t *root;
  json_error_t error;
  root = json_loads (js, 0, &error);

  json_t *response, *venues;
  response = json_object_get (root, "response");
  venues = json_object_get (root, "predictions");

  struct timespec now, tmstart;
  clock_gettime(CLOCK_REALTIME, &tmstart);

  int i = 0;

  // The autocomplete API returns max 5 results
  pthread_t thread_id[5];
  struct googleplace gp[5];

  for (i = 0; i < json_array_size (venues); i++)
    {
      json_t *venue, *description, *id;
      venue = json_array_get (venues, i);
      description = json_object_get (venue, "description");
      id = json_object_get (venue, "place_id");

      dbg (1, "Found [%i] %s with id %s\n", i, json_string_value (description), json_string_value (id));
      strcpy (track_icon, "default");
      gp[i].id=g_strdup(json_string_value (id));
      gp[i].description=g_strdup(json_string_value (description));
      gp[i].gui_priv=this;
      gp[i].wm=wm;
      pthread_create( &thread_id[i], NULL, &fetch_googleplace_details, &gp[i] );
    }
   int j;
   for(j=0; j < json_array_size (venues); j++)
   {
      dbg(1,"Checking thread #%i with p:%p\n",j,thread_id[j]);
      pthread_join( thread_id[j], NULL);
   }

    clock_gettime(CLOCK_REALTIME, &now);

    double seconds = (double)((now.tv_sec+now.tv_nsec*1e-9) - (double)(tmstart.tv_sec+tmstart.tv_nsec*1e-9));
    dbg(1,"wall time %fs\n", seconds);
    gui_internal_menu_render(this);
  g_free (prefix);
  json_decref (root);

}

static void
gui_internal_cmd_google_filter_changed(struct gui_priv *this, struct widget *wm, void *data)
{
//        if (wm->text && wm->reason==gui_internal_reason_keypress_finish) {
//                gui_internal_cmd_googlesearch_filter_do(this, wm, wm);
//        }
        if (wm->text) {
                gui_internal_widget_table_clear(this, gui_internal_menu_data(this)->search_list);
                gui_internal_cmd_googlesearch_filter_do(this, wm, wm);
        }
}

void
gui_internal_googlesearch_search(struct gui_priv *this, struct widget *wm, void *data)
{
        struct widget *wb, *w, *wr, *wk, *we, *wl;
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
        wk->func=gui_internal_cmd_google_filter_changed;
        wk->background=this->background;
        wk->flags |= flags_expand|flags_fill;
        wk->name=g_strdup("POIsFilter");
        wk->c=wm->c;
        dbg (1, "googlesearch filter called for %d x %d\n", wm->c.x, wm->c.y);
        gui_internal_widget_append(we, wb=gui_internal_image_new(this, image_new_xs(this, "gui_active")));
        wb->state |= STATE_SENSITIVE;
        wb->func = gui_internal_cmd_googlesearch_filter_do;
        wb->name=g_strdup("NameFilter");
        wb->c=wm->c;
        wb->data=wk;
        wl=gui_internal_widget_table_new(this,gravity_left_top | flags_fill | flags_expand |orientation_vertical,1);
        gui_internal_widget_append(wr, wl);
        gui_internal_menu_data(this)->search_list=wl;

        if (this->keyboard)
                gui_internal_widget_append(w, gui_internal_keyboard(this,keyboard_mode));
        gui_internal_menu_render(this);
}

static struct command_table navit_commands[] = {
  {"googlesearch_search", command_cast (gui_internal_googlesearch_search)},
};

void
googlesearch_navit_command_init (struct gui_priv *this, struct attr **attrs)
{
  struct attr *attr;
  if ((attr = attr_search (attrs, NULL, attr_callback_list)))
    {
      command_add_table (attr->u.callback_list, navit_commands,
			 sizeof (navit_commands) /
			 sizeof (struct command_table), this);
    }

}

/* vim: set tabstop=4 expandtab: */
/**
 * Navit, a modular navigation system.
 * Copyright (C) 2005-2017 Navit Team
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * version 2 as published by the Free Software Foundation.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the
 * Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
 * Boston, MA  02110-1301, USA.
 */

/* 
   This plugin is able to drive a ssd1306 OLED i2c screen
   */

#include <math.h>
#include <stdio.h>
#include <glib.h>
#include <time.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <termios.h>
#include <errno.h>
#include <sys/ioctl.h>
#include "config.h"
#include <navit/item.h>
#include <navit/xmlconfig.h>
#include <navit/main.h>
#include <navit/debug.h>
#include <navit/map.h>
#include <navit/navit.h>
#include <navit/callback.h>
#include <navit/file.h>
#include <navit/plugin.h>
#include <navit/event.h>
#include <navit/command.h>
#include <navit/config_.h>
#include "graphics.h"
#include "color.h"
#include "vehicle.h"
#include "transform.h"
#include "track.h"
#include "vehicleprofile.h"
#include "roadprofile.h"

#include <linux/unistd.h>	/* for _syscallX macros/related stuff */
#include <linux/kernel.h>	/* for struct sysinfo */
#include <sys/sysinfo.h>

#include "ArduiPi_SSD1306.h"
#include "Adafruit_GFX.h"
#include "Adafruit_SSD1306.h"

extern char *version;

Adafruit_SSD1306 display;

struct ssd1306
{
  struct navit *nav;
  struct callback *callback;
  struct event_idle *idle;
  int frames;
  long tick;
  int fps;
};


long
get_uptime ()
{
  struct sysinfo s_info;
  int error = sysinfo (&s_info);
  if (error != 0)
    {
      printf ("code error = %d\n", error);
    }
  return s_info.uptime;
}

static gboolean
ssd1306_idle (gpointer data)	// (struct ssd1306 *ssd1306)
{
  struct ssd1306 *ssd1306 = (struct ssd1306 *) data;

  display.clearDisplay ();
  display.setTextSize (1);
  display.setTextColor (WHITE);
  display.setCursor (0, 0);

  char snum[32];

  struct attr attr, attr2, vattr;
  struct attr position_attr, position_fix_attr;
  struct attr_iter *iter;
  struct attr active_vehicle;
  enum projection pro;
  struct coord c1;
  long current_tick = get_uptime ();

  int ret_attr = 0;
  struct attr speed_attr;
  double speed = -1;
  int strength = -1;

  iter = navit_attr_iter_new ();
  if (navit_get_attr (ssd1306->nav, attr_vehicle, &attr, iter)
      && !navit_get_attr (ssd1306->nav, attr_vehicle, &attr2, iter))
    {
      vehicle_get_attr (attr.u.vehicle, attr_name, &vattr, NULL);
      navit_attr_iter_destroy (iter);


      if (vehicle_get_attr
	  (attr.u.vehicle, attr_position_fix_type, &position_fix_attr, NULL))
	{
	  switch (position_fix_attr.u.num)
	    {
	    case 1:
	    case 2:
	      strength = 2;
	      if (vehicle_get_attr
		  (attr.u.vehicle, attr_position_sats_used,
		   &position_fix_attr, NULL))
		{
		  if (position_fix_attr.u.num >= 3)
		    strength = position_fix_attr.u.num - 1;
		  if (strength > 5)
		    strength = 5;
		  if (strength > 3)
		    {
		      if (vehicle_get_attr
			  (attr.u.vehicle, attr_position_hdop,
			   &position_fix_attr, NULL))
			{
			  if (*position_fix_attr.u.numd > 2.0 && strength > 4)
			    strength = 4;
			  if (*position_fix_attr.u.numd > 4.0 && strength > 3)
			    strength = 3;
			}
		    }
		}
	      break;
	    default:
	      strength = 1;
	    }
	}
        display.drawLine( 0, display.height()-1, strength * 5, display.height()-1, WHITE);

      if (strength > 2)
	{
	  if (vehicle_get_attr
	      (attr.u.vehicle, attr_position_coord_geo, &position_attr, NULL))
	    {
	      pro = position_attr.u.pcoord->pro;
	      transform_from_geo (pro, position_attr.u.coord_geo, &c1);
	      dbg (lvl_error, "%f %f\n", position_attr.u.coord_geo->lat,
		   position_attr.u.coord_geo->lng);
	      sprintf (snum, "%f %f\n", position_attr.u.coord_geo->lat,
		       position_attr.u.coord_geo->lng);
	      display.printf (snum);

	      ret_attr =
		vehicle_get_attr (attr.u.vehicle, attr_position_speed,
				  &speed_attr, NULL);
	      speed = *speed_attr.u.numd;
	      display.setTextSize (2);
	      dbg (lvl_error, "speed : %0.0f (%f)\n", speed, speed);
	    }
	  else
	    {
	      dbg (lvl_error, "nope\n");
	      navit_attr_iter_destroy (iter);
	    }

	  struct tracking *tracking = NULL;
	  double routespeed = -1;
	  int *flags;
	  struct attr maxspeed_attr;
	  int osm_data = 0;
	  tracking = navit_get_tracking (ssd1306->nav);

	  if (tracking)
	    {
	      struct item *item;

	      flags = tracking_get_current_flags (tracking);
	      if (flags && (*flags & AF_SPEED_LIMIT)
		  && tracking_get_attr (tracking, attr_maxspeed,
					&maxspeed_attr, NULL))
		{
		  routespeed = maxspeed_attr.u.num;
		  osm_data = 1;
		}
	      item = tracking_get_current_item (tracking);
	      if (routespeed == -1 and item)
		{

		  struct vehicleprofile *prof =
		    navit_get_vehicleprofile (ssd1306->nav);
		  struct roadprofile *rprof = NULL;
		  if (prof)
		    rprof = vehicleprofile_get_roadprofile (prof, item->type);
		  if (rprof)
		    {
		      if (rprof->maxspeed != 0)
			routespeed = rprof->maxspeed;
		    }
		}
 	      
	      sprintf (snum, "%0.0f", speed);
	      display.setCursor(10,12);
	      if (routespeed == -1)
		{
		  display.printf (snum);
		  display.setTextColor (BLACK, WHITE);
                  display.setCursor(64,8);
		  display.printf (" ?? ");
		  display.setTextColor (WHITE, BLACK);

		}
	      else
		{
		  dbg (lvl_error, "route speed : %0.0f\n", routespeed);
		  if (speed > routespeed)
		    {
		      display.setTextColor (BLACK, WHITE);	// 'inverted' text
		      display.printf (snum);
		      display.setTextColor (WHITE, BLACK);	// 'inverted' text
		    }
		  else
		    {
		      display.printf (snum);
		    }
                  display.setCursor(64,12);
		  sprintf (snum, " %0.0f", routespeed);
		  display.printf (snum);
		}
	    }

          display.drawLine( display.width() - 1 - ssd1306->fps , display.height()-1, display.width() - 1, display.height()-1, WHITE);

	  if (current_tick == ssd1306->tick)
	    {
	      ssd1306->frames++;
	    }
	  else
	    {
	      ssd1306->fps = ssd1306->frames;
	      ssd1306->frames = 0;
	      ssd1306->tick = current_tick;
	    }
	}
      else
	{
	  if (current_tick % 2)
	    {
	      display.printf ("Waiting for GPS...");
	    }
	  else
	    {
	      display.printf ("Waiting for GPS.");
	    }

          if ( strength > 0 )
	  	display.fillRect(36, display.height()-9, 6, 8, WHITE);
	  else 
	  	display.drawRect(36, display.height()-9, 6, 8, WHITE);
          if ( strength > 1 )
	  	display.fillRect(44, display.height()-13, 6, 12, WHITE);
	  else 
	  	display.fillRect(44, display.height()-13, 6, 12, WHITE);
          if ( strength > 2 )
	  	display.drawRect(52, display.height()-17, 6, 16, WHITE);
	  else 
	  	display.fillRect(52, display.height()-17, 6, 16, WHITE);
          if ( strength > 3 )
	  	display.fillRect(60, display.height()-21, 6, 20, WHITE);
	  else 
	  	display.drawRect(60, display.height()-21, 6, 20, WHITE);
	}
      display.display ();
      g_timeout_add (10, ssd1306_idle, ssd1306);
    }
}

static void
ssd1306_init (struct ssd1306 *ssd1306, struct navit *nav)
{
  dbg (lvl_error, "here\n");
  // ssd1306->callback=callback_new_1(callback_cast(ssd1306_idle), ssd1306);
  // ssd1306->idle=event_add_timeout(100, 1, ssd1306->callback);
  // ssd1306->idle=event_add_idle(125, ssd1306->callback);
  ssd1306_idle (ssd1306);
  // g_timeout_add (10, ssd1306_idle, ssd1306);
}

/**
 * @brief	Creates the ssd1306 and set some default properties
 * @param[in]	nav	- the navit object
 *              meth    - the osd_methods
 * 		attrs	- pointer to the attributes
 *
 * @return	nothing
 *
 * Creates the ssd1306 OSD and set some default properties
 *
 */
static struct osd_priv *
ssd1306_new (struct navit *nav, struct osd_methods *meth, struct attr **attrs)
{
  dbg (lvl_error, "here\n");
  if (!display.init (OLED_I2C_RESET, 2))
    exit (-1);

  display.begin ();
  display.clearDisplay ();

  display.setTextSize (1);
  display.setTextColor (WHITE);
  display.setCursor (0, 0);
  display.print ("Navit\n");
  // display.setTextColor(BLACK, WHITE); // 'inverted' text
  display.printf (version);
  display.setTextSize (2);
  display.setTextColor (WHITE);
  display.display ();
  struct ssd1306 *ssd1306 = g_new0 (struct ssd1306, 1);
  ssd1306->nav = nav;
  ssd1306->frames = 0;
  ssd1306->fps = 0;
  ssd1306->tick = get_uptime ();
  navit_add_callback (nav,
		      callback_new_attr_1 (callback_cast (ssd1306_init),
					   attr_graphics_ready, ssd1306));
}

/**
 * @brief	The plugin entry point
 *
 * @return	nothing
 *
 * The plugin entry point
 *
 */
void
plugin_init (void)
{
  struct attr callback, navit;
  struct attr_iter *iter;
  dbg (lvl_error, "here\n");

  plugin_register_category_osd ("ssd1306", ssd1306_new);
}

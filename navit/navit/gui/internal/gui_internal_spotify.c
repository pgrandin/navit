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
// #include <navit/api_keys.h>

#include "time.h"
#include <libspotify/api.h>
#include "spotify/audio.h"
#include "spotify/queue.h"
#include "gui_internal.h"
#include "gui_internal_menu.h"
#include "coord.h"
#include "gui_internal_widget.h"
#include "gui_internal_priv.h"
#include "gui_internal_spotify.h"

extern const uint8_t spotify_apikey[];
extern const size_t spotify_apikey_size;
const bool autostart=0;

/// Handle to the playlist currently being played
static sp_playlist *g_jukeboxlist;
/// Handle to the current track 
static sp_track *g_currenttrack;
/// Index to the next track
static int g_track_index;
/// The global session handle

static sp_session *g_sess;
int g_logged_in;
static audio_fifo_t g_audiofifo;

int next_timeout = 0;

struct attr initial_layout, main_layout;

struct spotify
{
  struct navit *navit;
  struct callback *callback;
  struct event_idle *idle;
  struct attr **attrs;
  char *login;
  char *password;
  char *playlist;
  sp_playlistcontainer *pc;
  gboolean playing;
} *spotify;

/**
 * Called on various events to start playback if it hasn't been started already.
 *
 * The function simply starts playing the first track of the playlist.
 */
static void
try_jukebox_start (void)
{
  dbg (0, "Starting the jukebox\n");
  sp_track *t;
  spotify->playing = 0;

  if (!g_jukeboxlist)
    {
      dbg (0, "jukebox: No playlist. Waiting\n");
      return;
    }

  if (!sp_playlist_num_tracks (g_jukeboxlist))
    {
      dbg (0, "jukebox: No tracks in playlist. Waiting\n");
      return;
    }

  if (sp_playlist_num_tracks (g_jukeboxlist) < g_track_index)
    {
      dbg (0, "jukebox: No more tracks in playlist. Waiting\n");
      return;
    }

  t = sp_playlist_track (g_jukeboxlist, g_track_index);

  if (g_currenttrack && t != g_currenttrack)
    {
      /* Someone changed the current track */
      audio_fifo_flush (&g_audiofifo);
      sp_session_player_unload (g_sess);
      g_currenttrack = NULL;
    }

  if (!t)
    return;

  if (sp_track_error (t) != SP_ERROR_OK)
    return;

  if (g_currenttrack == t)
    return;

  g_currenttrack = t;

  dbg (0, "jukebox: Now playing \"%s\"...\n", sp_track_name (t));

  sp_session_player_load (g_sess, t);
  spotify->playing = 1;
  sp_session_player_play (g_sess, 1);
}

/* --------------------------  PLAYLIST CALLBACKS  ------------------------- */
/**
 * Callback from libspotify, saying that a track has been added to a playlist.
 *
 * @param  pl          The playlist handle
 * @param  tracks      An array of track handles
 * @param  num_tracks  The number of tracks in the \c tracks array
 * @param  position    Where the tracks were inserted
 * @param  userdata    The opaque pointer
 */
static void
tracks_added (sp_playlist * pl, sp_track * const *tracks,
	      int num_tracks, int position, void *userdata)
{
  dbg (0, "jukebox: %d tracks were added to %s\n", num_tracks,
       sp_playlist_name (pl));

  if (!strcasecmp (sp_playlist_name (pl), spotify->playlist))
    {
      g_jukeboxlist = pl;
      if (autostart)
      	try_jukebox_start ();
    }
}


/**
 * The callbacks we are interested in for individual playlists.
 */
static sp_playlist_callbacks pl_callbacks = {
  .tracks_added = &tracks_added,
//        .tracks_removed = &tracks_removed,
//        .tracks_moved = &tracks_moved,
//        .playlist_renamed = &playlist_renamed,
};


/* --------------------  PLAYLIST CONTAINER CALLBACKS  --------------------- */
/**
 * Callback from libspotify, telling us a playlist was added to the playlist container.
 *
 * We add our playlist callbacks to the newly added playlist.
 *
 * @param  pc            The playlist container handle
 * @param  pl            The playlist handle
 * @param  position      Index of the added playlist
 * @param  userdata      The opaque pointer
 */
static void
playlist_added (sp_playlistcontainer * pc, sp_playlist * pl,
		int position, void *userdata)
{
  sp_playlist_add_callbacks (pl, &pl_callbacks, NULL);
  dbg (0, "List name: %s\n", sp_playlist_name (pl));

  if (!strcasecmp (sp_playlist_name (pl), spotify->playlist))
    {
      g_jukeboxlist = pl;
      if (autostart)
        try_jukebox_start ();
    }
}


/**
 * Callback from libspotify, telling us the rootlist is fully synchronized
 * We can resume playback
 *
 * @param  pc            The playlist container handle
 * @param  userdata      The opaque pointer
 */
static void
container_loaded (sp_playlistcontainer * pc, void *userdata)
{
  dbg (0, "jukebox: Rootlist synchronized (%d playlists)\n",
       sp_playlistcontainer_num_playlists (pc));
  if (autostart)
     try_jukebox_start ();
}

/**
 * The playlist container callbacks
 */
static sp_playlistcontainer_callbacks pc_callbacks = {
  .playlist_added = &playlist_added,
//        .playlist_removed = &playlist_removed,
  .container_loaded = &container_loaded,
};

static void
on_login (sp_session * session, sp_error error)
{
  dbg (0, "spotify login\n");
  if (error != SP_ERROR_OK)
    {
      dbg (0, "Error: unable to log in: %s\n", sp_error_message (error));
      return;
    }

  g_logged_in = 1;
  spotify->pc = sp_session_playlistcontainer (session);
  int i;

  sp_playlistcontainer_add_callbacks (spotify->pc, &pc_callbacks, NULL);
  dbg (0, "Got %d playlists\n",
       sp_playlistcontainer_num_playlists (spotify->pc)) for (i = 0;
							      i <
							      sp_playlistcontainer_num_playlists
							      (spotify->pc);
							      ++i)
    {
      sp_playlist *pl = sp_playlistcontainer_playlist (spotify->pc, i);

      sp_playlist_add_callbacks (pl, &pl_callbacks, NULL);

      if (!strcasecmp (sp_playlist_name (pl), spotify->playlist))
	{
	  dbg (0, "Found the playlist %s\n", spotify->playlist);
	  switch (sp_playlist_get_offline_status (session, pl))
	    {
	    case SP_PLAYLIST_OFFLINE_STATUS_NO:
	      dbg (0, "Playlist is not offline enabled.\n");
	      sp_playlist_set_offline_mode (session, pl, 1);
	      dbg (0, "  %d tracks to sync\n",
		   sp_offline_tracks_to_sync (session));
	      break;

	    case SP_PLAYLIST_OFFLINE_STATUS_YES:
	      dbg (0, "Playlist is synchronized to local storage.\n");
	      break;

	    case SP_PLAYLIST_OFFLINE_STATUS_DOWNLOADING:
	      dbg
		(0,
		 "This playlist is currently downloading. Only one playlist can be in this state any given time.\n");
	      break;

	    case SP_PLAYLIST_OFFLINE_STATUS_WAITING:
	      dbg (0, "Playlist is queued for download.\n");
	      break;

	    default:
	      dbg (0, "unknow state\n");
	      break;
	    }
	  g_jukeboxlist = pl;
	  // try_jukebox_start ();
	}
    }
  if (!g_jukeboxlist)
    {
      dbg (0, "jukebox: No such playlist. Waiting for one to pop up...\n");
    }
  // try_jukebox_start ();


}

static int
on_music_delivered (sp_session * session, const sp_audioformat * format,
		    const void *frames, int num_frames)
{
  audio_fifo_t *af = &g_audiofifo;
  audio_fifo_data_t *afd;
  size_t s;

  if (num_frames == 0)
    return 0;			// Audio discontinuity, do nothing

  pthread_mutex_lock (&af->mutex);

  /* Buffer one second of audio */
  if (af->qlen > format->sample_rate)
    {
      pthread_mutex_unlock (&af->mutex);

      return 0;
    }

  s = num_frames * sizeof (int16_t) * format->channels;

  afd = malloc (sizeof (*afd) + s);
  memcpy (afd->samples, frames, s);

  afd->nsamples = num_frames;

  afd->rate = format->sample_rate;
  afd->channels = format->channels;

  TAILQ_INSERT_TAIL (&af->q, afd, link);
  af->qlen += num_frames;

  pthread_cond_signal (&af->cond);
  pthread_mutex_unlock (&af->mutex);

  return num_frames;
}

static void
on_end_of_track (sp_session * session)
{

  ++g_track_index;
  try_jukebox_start ();
}

static sp_session_callbacks session_callbacks = {
  .logged_in = &on_login,
//  .notify_main_thread = &on_main_thread_notified,
  .music_delivery = &on_music_delivered,
//  .log_message = &on_log,
  .end_of_track = &on_end_of_track,
//  .offline_status_updated = &offline_status_updated,
//  .play_token_lost = &play_token_lost,
};

static sp_session_config spconfig = {
  .api_version = SPOTIFY_API_VERSION,
  .cache_location = "/var/tmp/spotify",
  .settings_location = "/var/tmp/spotify",
  .application_key = spotify_apikey,
  .application_key_size = 0,	// set in main()
  .user_agent = "navit",
  .callbacks = &session_callbacks,
  NULL
};

static void
spotify_spotify_idle (struct spotify *spotify)
{
  sp_session_process_events (g_sess, &next_timeout);
}

void
gui_internal_spotify_previous_track (struct gui_priv *this, struct widget *wm, void *data)
{
  if (g_track_index > 0)
    {
      --g_track_index;
    }
  dbg (0, "rewinding to previous track\n");
  try_jukebox_start ();
}

void
gui_internal_spotify_next_track (struct gui_priv *this, struct widget *wm, void *data)
{
  ++g_track_index;
  dbg (0, "skipping to next track\n");
  try_jukebox_start ();
}

void
gui_internal_spotify_toggle (struct gui_priv *this, struct widget *wm, void *data)
{
  if (spotify->playing)
    {
      dbg (0, "pausing playback\n");
      sp_session_player_play (g_sess, 0);
    }
  else
    {
      dbg (0, "resuming playback\n");
      sp_session_player_play (g_sess, 1);
      try_jukebox_start ();
    }
  spotify->playing = !spotify->playing;
}

static void
gui_internal_spotify_play_random_track (struct spotify *spotify)
{
  int tracks = sp_playlist_num_tracks (g_jukeboxlist);
  srand (time (NULL));
  g_track_index = rand () % tracks;
  dbg (0, "New track index is %i (out of %i)\n", g_track_index, tracks);
  try_jukebox_start ();

}

void
spotify_navit_init (struct navit *nav)
{
  dbg (0, "spotify_navit_init\n");
  sp_error error;
  sp_session *session;

  spconfig.application_key_size = spotify_apikey_size;
  error = sp_session_create (&spconfig, &session);
  if (error != SP_ERROR_OK)
    {
      dbg (0, "Can't create spotify session :(\n");
      return;
    }
  dbg (0, "Session created successfully :)\n");
  g_sess = session;
  g_logged_in = 0;
  sp_session_login (session, spotify->login, spotify->password, 0, NULL);
  audio_init (&g_audiofifo);
  spotify->navit = nav;
  spotify->callback =
    callback_new_1 (callback_cast (spotify_spotify_idle), spotify);
  event_add_idle (500, spotify->callback);
  dbg (0, "Callback created successfully\n");
  struct attr attr;
  spotify->navit = nav;
}

void
spotify_navit (struct navit *nav, int add)
{
  struct attr callback;
  if (add)
    {
      dbg (0, "adding callback\n");
      callback.type = attr_callback;
      callback.u.callback =
	callback_new_attr_0 (callback_cast (spotify_navit_init), attr_navit);
      navit_add_attr (nav, &callback);
    }
}

struct marker
{
  struct cursor *cursor;
};

void
spotify_set_attr (struct attr **attrs)
{
  spotify = g_new0 (struct spotify, 1);
  struct attr *attr;
  if ((attr = attr_search (attrs, NULL, attr_spotify_login)))
    {
      dbg (0, "found spotify_login attr %s\n", attr->u.str);
      spotify->login = attr->u.str;
    }
  if ((attr = attr_search (attrs, NULL, attr_spotify_password)))
    {
      dbg (0, "found spotify_password attr %s\n", attr->u.str);
      spotify->password = attr->u.str;
    }
  else
    {
      dbg (0, "SPOTIFY PASSWORD NOT FOUND!\n");
    }
  if ((attr = attr_search (attrs, NULL, attr_spotify_playlist)))
    {
      dbg (0, "found spotify_playlist attr %s\n", attr->u.str);
      spotify->playlist = attr->u.str;
    }

char **hints;
/* Enumerate sound devices */
int err = snd_device_name_hint(-1, "pcm", (void***)&hints);
if (err != 0)
   return;//Error! Just return

char** n = hints;
while (*n != NULL) {

    char *name = snd_device_name_get_hint(*n, "NAME");
	dbg(0,"Found audio device %s\n",name);

    if (name != NULL && 0 != strcmp("null", name)) {
        //Copy name to another buffer and then free it
        free(name);
    }
    n++;
}//End of while

//Free hint buffer too
snd_device_name_free_hint((void**)hints);
}

void
spotify_play_track (struct gui_priv *this, struct widget *wm, void *data)
{
  dbg (0, "Got a request to play a specific track : %i\n", wm->c.x);
  g_track_index = wm->c.x;
  try_jukebox_start ();
  gui_internal_spotify_show_playlist (this, NULL, NULL);
}

void
spotify_play_playlist (struct gui_priv *this, struct widget *wm, void *data)
{
  sp_playlist *pl = sp_playlistcontainer_playlist (spotify->pc, wm->c.x);
  dbg (0, "Got a request to play a specific playlist : #%i : %s\n", wm->c.x,
       sp_playlist_name (pl));
  g_jukeboxlist = pl;
  //g_track_index=0;
  spotify->playlist = sp_playlist_name (pl);
  gui_internal_spotify_show_playlist (this, NULL, NULL);
}

void
spotify_play_toggle_offline_mode (struct gui_priv *this, struct widget *wm, void *data)
{
            sp_playlist_set_offline_mode (g_sess, g_jukeboxlist,  sp_playlist_get_offline_status (g_sess, g_jukeboxlist) != 1);
	    gui_internal_spotify_show_playlist(this,wm,data);
}

static struct widget *
gui_internal_spotify_playlist_toolbar(struct gui_priv *this)
{
        struct widget *wl,*wb;
        int nitems,nrows;
        int i;
	char *icon;
        wl=gui_internal_box_new(this, gravity_left_center|orientation_horizontal_vertical|flags_fill);
        wl->background=this->background;
        wl->w=this->root.w;
        wl->cols=this->root.w/this->icon_s;
        nitems=2;
        nrows=nitems/wl->cols + (nitems%wl->cols>0);
        wl->h=this->icon_l*nrows;
	
        switch (sp_playlist_get_offline_status (g_sess, g_jukeboxlist))
          {
          case SP_PLAYLIST_OFFLINE_STATUS_NO:
            icon="switch-off";
            break;

          case SP_PLAYLIST_OFFLINE_STATUS_YES:
            icon="switch-on";
            break;

          case SP_PLAYLIST_OFFLINE_STATUS_DOWNLOADING:
            icon="switch-on-pending";
            break;

          case SP_PLAYLIST_OFFLINE_STATUS_WAITING:
            icon="switch-on-pending";
            break;

          default:
            icon="music-red";
            break;
          }

      wb = gui_internal_button_new_with_callback (this, "Playlists",
					       image_new_s (this,
							     "spotify_playlists"),
					       gravity_left_center |
					       orientation_horizontal,
					       gui_internal_spotify_show_rootlist,
					       NULL);
      gui_internal_widget_append (wl, wb);


        gui_internal_widget_append(wl, wb=gui_internal_button_new_with_callback(this, "Offline",
                image_new_s(this, icon), gravity_left_center|orientation_horizontal,
                spotify_play_toggle_offline_mode, NULL));

        gui_internal_widget_pack(this,wl);
        return wl;
}

void
gui_internal_spotify_show_rootlist (struct gui_priv *this, struct widget *wm,
				    void *data)
{
  struct attr attr, mattr;
  struct item *item;
  char *label_full, *prefix = 0, *icon;
  int plen = 0, is_playing, found = 0;
  struct widget *wb, *w, *wbm;
  struct widget *tbl, *row;
  dbg (0, "Showing rootlist\n");

  gui_internal_prune_menu_count (this, 1, 0);
  wb = gui_internal_menu (this, "Spotify > Playlists");
  wb->background = this->background;
  w =
    gui_internal_box_new (this,
			  gravity_top_center | orientation_vertical |
			  flags_expand | flags_fill);
  gui_internal_widget_append (wb, w);


  tbl =
    gui_internal_widget_table_new (this,
				   gravity_left_top | flags_fill |
				   flags_expand | orientation_vertical, 1);
  gui_internal_widget_append (w, tbl);
  int i = 0;
  for (i = 0; i < sp_playlistcontainer_num_playlists (spotify->pc); i++)
    {
      sp_playlist *pl = sp_playlistcontainer_playlist (spotify->pc, i);
	
        switch (sp_playlist_get_offline_status (g_sess, pl))
          {
          case SP_PLAYLIST_OFFLINE_STATUS_NO:
            icon="sp_playlist_offline_unset";
            break;

          case SP_PLAYLIST_OFFLINE_STATUS_YES:
            icon="sp_playlist_offline";
            break;

          case SP_PLAYLIST_OFFLINE_STATUS_DOWNLOADING:
            icon="sp_playlist_offline_downloading";
            break;

          case SP_PLAYLIST_OFFLINE_STATUS_WAITING:
            icon="sp_playlist_offline_queued";
            break;

          default:
            icon="sp_playlist_offline_unset";
            break;
          }


      row =
	gui_internal_widget_table_row_new (this,
					   gravity_left | flags_fill |
					   orientation_horizontal);
      gui_internal_widget_append (tbl, row);
      wbm =
	gui_internal_button_new_with_callback (this, sp_playlist_name (pl),
					       image_new_s (this,icon),
					       gravity_left_center |
					       orientation_horizontal |
					       flags_fill,
					       spotify_play_playlist, NULL);

      gui_internal_widget_append (row, wbm);
      wbm->c.x = i;
    }

  g_free (prefix);

  gui_internal_menu_render (this);

}

void
gui_internal_spotify_show_playlist (struct gui_priv *this, struct widget *wm,
				    void *data)
{
  struct attr attr, mattr;
  struct item *item;
  char *label_full, *prefix = 0;
  char track_icon[64];
  int plen = 0, is_playing, found = 0;
  struct widget *wb, *w, *wbm;
  struct widget *tbl, *row;

  gui_internal_prune_menu_count (this, 1, 0);
  wb = gui_internal_menu (this,  g_strdup_printf ("Spotify > %s", spotify->playlist ) );
  wb->background = this->background;
  w =
    gui_internal_box_new (this,
			  gravity_top_center | orientation_vertical |
			  flags_expand | flags_fill);
  gui_internal_widget_append (wb, w);
  gui_internal_widget_append(w, gui_internal_spotify_playlist_toolbar(this));
  tbl =
    gui_internal_widget_table_new (this,
				   gravity_left_top | flags_fill |
				   flags_expand | orientation_vertical, 1);
  gui_internal_widget_append (w, tbl);
  int i = 0;
  int tracks = sp_playlist_num_tracks (g_jukeboxlist);
  for (i = 0; i < tracks; i++)
    {
      sp_track *t = sp_playlist_track (g_jukeboxlist, i);
      is_playing = (i == g_track_index);
      switch (sp_track_offline_get_status (t))
	{
	case SP_TRACK_OFFLINE_DONE:
	  strcpy (track_icon, "music-green");
	  break;
	case SP_TRACK_OFFLINE_DOWNLOADING:
	  strcpy (track_icon, "music-orange");
	  break;
	case SP_TRACK_OFFLINE_NO:
	  strcpy (track_icon, "music-blue");
	  break;
	default:
	  strcpy (track_icon, "music-red");
	}

      row =
	gui_internal_widget_table_row_new (this,
					   gravity_left | flags_fill |
					   orientation_horizontal);
      gui_internal_widget_append (tbl, row);
      wbm = gui_internal_button_new_with_callback (this, sp_track_name (t),
						   image_new_xs (this,
								 is_playing ?
								 "play" :
								 track_icon),
						   gravity_left_center |
						   orientation_horizontal |
						   flags_fill,
						   spotify_play_track, NULL);

      gui_internal_widget_append (row, wbm);
      wbm->c.x = i;
    }

  g_free (prefix);

  gui_internal_menu_render (this);
}

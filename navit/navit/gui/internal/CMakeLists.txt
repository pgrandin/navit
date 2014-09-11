if(LIBSPOTIFY_FOUND)
	set(spotify_LIBS "-lspotify -lasound -lpthread")
	set(spotify_sources gui_internal_spotify.c spotify/audio.c
	spotify/alsa-audio.c api_keys.c)
endif(LIBSPOTIFY_FOUND)
if(JANSSON_FOUND)
	set(foursquare_LIBS "-ljansson -lpthread -lcurl")
	set(fourquare_sources gui_internal_foursquare.c
		gui_internal_googlesearch.c network.c api_keys.c)
endif(JANSSON_FOUND)
set(gui_internal_LIBS ${spotify_LIBS} ${foursquare_LIBS})
module_add_library(gui_internal gui_internal.c gui_internal_bookmark.c
	gui_internal_command.c gui_internal_gesture.c gui_internal_html.c
	gui_internal_menu.c gui_internal_poi.c gui_internal_search.c
	gui_internal_widget.c gui_internal_keyboard.c
	${spotify_sources} ${fourquare_sources})

/**
 * Navit, a modular navigation system.
 * Copyright (C) 2005-2008 Navit Team
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

struct j1850 {
	int status;
	int device;
	int index;
	char message[255];
	struct event_idle *idle;
	struct callback *callback;
};

static void
j1850_idle(struct j1850 *j1850)
{
	time_t current_time;
	int res;
	int n;
	int value;
	char buf = '\0';
   	n = read( j1850->device, &buf, 1 );
   if(n == -1) {
        printf("x");
   } else if (n==0) {
        printf(".");
   } else {
        if( buf == 13 ) {
                //append(response,255,'\0');
		current_time = time(NULL);
                j1850->message[j1850->index]='\0';
                // printf("%i : %s\n", current_time, j1850->message);
		FILE *fp;
		char str[] = "test";     
	
		fp = fopen("/home/navit/.navit/obd/obd.log","a");
		fprintf(fp, "%i,%s\n", current_time, j1850->message);
		fclose(fp); 
                char header[3];
                strncpy(header, j1850->message, 2);
                header[2]='\0';
                if( strncmp(header,"10",2)==0 ) {
			char * w1 =strndup(j1850->message+2, 4);
			int rpm = ((int)strtol(w1, NULL, 16) ) / 4 ;
                } else if( strncmp(header,"3D",2)==0 ) {
                        if (strcmp(j1850->message, "3D110000EE") == 0) {
                                // noise
                        } else if (strcmp(j1850->message, "3D1120009B") == 0) {
                                printf("L1\n");
                        } else if (strcmp(j1850->message, "3D110080C8") == 0) {
                                printf("L2\n");
                        } else if (strcmp(j1850->message, "3D1110005A") == 0) {
                                printf("L3\n");
                        } else if (strcmp(j1850->message, "3D110400C3") == 0) {
                                printf("R1\n");
                        } else if (strcmp(j1850->message, "3D110002D4") == 0) {
                                printf("R2\n");
                        } else if (strcmp(j1850->message, "3D11020076") == 0) {
                                printf("R3\n");
                        } else {
                                printf("Got button from %s\n", j1850->message);
                        }
                } else if( strncmp(header,"72",2)==0 ) {
			char * data=strndup(j1850->message+2, 8);
			int odo=((int)strtol(data, NULL, 16) )/8000;
                        printf("%i : Got odo %i from %s\n", current_time, odo, j1850->message);
                } else if( strncmp(header,"90",2)==0 ) {
                        printf("%i : Got metric from %s\n", current_time, j1850->message);
                } else {
                        // printf(" ascii: %i [%s] with header [%s]\n",buf, response, header);
                }

                j1850->message[0]='\0';
                j1850->index=0;
        } else {
                value=buf-48;
                if(value==-16 || buf == 10 ){
                        //space and newline, discard
                        return;
                } else if (value>16) {
                        // chars, need to shift down
                        value-=7;
                        j1850->message[j1850->index]=buf;
                        j1850->index++;
                } else if (buf == '<' ) {
                        // We have a data error. Let's truncate the message
                        j1850->message[j1850->index]='\0';
                        j1850->index++;
                } else {
                        j1850->message[j1850->index]=buf;
                        j1850->index++;
                }
                // printf("{%c:%i}", buf,value);
        }
   }
   fflush(stdout);
}

void send_and_read(unsigned char *cmd, int USB)
{
// Write
// unsigned char cmd[] = "ATZ\r";
int n_written = 0;

do {
    n_written += write( USB, &cmd[n_written], 1 );
}
while (cmd[n_written-1] != '\r' && n_written > 0);

fflush(stdout);
int n = 0;
char buf = '\0';

/* Whole response*/
char response[255];

do
{
   n = read( USB, &buf, 1 );
   if(n == -1) {
        printf("x");
        fflush(stdout);
   } else if (n==0) {
        printf(".");
        fflush(stdout);
   } else {
        printf("[%s]", &buf);
        //append(response,255,buf);
        fflush(stdout);
   }
}
while( buf != '\r' && n > 0);
// append(response,255,'\0');

if (n < 0)
{
        printf("Read error\n");
   // cout << "Error reading: " << strerror(errno) << endl;
}
   else if (n == 0)
{
        printf("Nothing to read?\n");
    // cout << "Read nothing!" << endl;
}
else
{
        printf("Response : \n");
}

  sleep(1);
}

static void
j1850_navit_init(struct navit *nav)
{
	int USB = open( "/dev/ttyUSB0", O_RDWR| O_NOCTTY );
	if ( USB < 0 ) 
	{
		dbg(0,"Can't open port\n");
		return;
	}

	struct termios tty;
	struct termios tty_old;
	memset (&tty, 0, sizeof tty);
	
	/* Error Handling */
	if ( tcgetattr ( USB, &tty ) != 0 )
	{
	        dbg(0,"Error\n");
		return;
	}
	
	/* Save old tty parameters */
	tty_old = tty;
	
	/* Set Baud Rate */
	cfsetospeed (&tty, (speed_t)B115200);
	cfsetispeed (&tty, (speed_t)B115200);
	
	/* Setting other Port Stuff */
	tty.c_cflag     &=  ~PARENB;        // Make 8n1
	tty.c_cflag     &=  ~CSTOPB;
	tty.c_cflag     &=  ~CSIZE;
	tty.c_cflag     |=  CS8;
	
	tty.c_cflag     &=  ~CRTSCTS;       // no flow control
	tty.c_cc[VMIN]      =   1;                  // read doesn't block
	tty.c_cc[VTIME]     =   10;                  // 0.5 seconds read timeout
	tty.c_cflag     |=  CREAD | CLOCAL;     // turn on READ & ignore ctrl lines
	
	/* Make raw */
	cfmakeraw(&tty);
	
	/* Flush Port, then applies attributes */
	tcflush( USB, TCIFLUSH );
	if ( tcsetattr ( USB, TCSANOW, &tty ) != 0)
	{
	        dbg(0,"Flush error\n");
		return;
	}

	send_and_read("ATZ\r\n", USB);
	send_and_read("ATI\r\n", USB);
	send_and_read("ATL1\r\n", USB);
	send_and_read("ATH1\r\n", USB);
	send_and_read("ATS1\r\n", USB);
	send_and_read("ATAL\r\n", USB);
	send_and_read("ATMA\r\n", USB);
	struct j1850 *j1850=g_new0(struct j1850, 1);
	j1850->device=USB;
	j1850->callback=callback_new_1(callback_cast(j1850_idle), j1850);
	j1850->idle=event_add_idle(50, j1850->callback);
	dbg(0,"Init ok\n");
}

static void
j1850_navit(struct navit *nav, int add)
{
	dbg(0,"enter\n");
	struct attr callback;
	if (add) {
		callback.type=attr_callback;
		callback.u.callback=callback_new_attr_0(callback_cast(j1850_navit_init), attr_navit);
		navit_add_attr(nav, &callback);
	}
}

void
plugin_init(void)
{
	struct attr callback,navit;
	struct attr_iter *iter;

	callback.type=attr_callback;
	callback.u.callback=callback_new_attr_0(callback_cast(j1850_navit), attr_navit);
	config_add_attr(config, &callback);
	iter=config_attr_iter_new();
	while (config_get_attr(config, attr_navit, &navit, iter)) 
		j1850_navit_init(navit.u.navit);
	config_attr_iter_destroy(iter);	
}

FROM ubuntu
RUN ls
RUN curl -k -L -o california-latest.osm.bz2 http://download.geofabrik.de/north-america/us/california-latest.osm.bz2
RUN apt-get update && apt-get install -y curl
RUN apt-get install -y cmake zlib1g-dev libpng12-dev libgtk2.0-dev librsvg2-bin g++

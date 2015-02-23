FROM ubuntu
RUN apt-get update && apt-get install -y curl
RUN ls
RUN pwd
RUN apt-get install -y cmake zlib1g-dev libpng12-dev libgtk2.0-dev librsvg2-bin g++

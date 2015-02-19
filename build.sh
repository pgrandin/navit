cd navit
tar xfz ~/assets/cov-analysis-linux64-7.6.0.tar.gz
export PATH=~/navit/navit/cov-analysis-linux64-7.6.0/bin:$PATH

mkdir bin && cd bin
cov-build --dir cov-int cmake ../ -Dgraphics/qt_qpainter:BOOL=FALSE -Dgui/qml:BOOL=FALSE
cov-build --dir cov-int make -j32 || exit -1
tar czvf navit.tgz cov-int

curl --form token=$COVERITY_TOKEN \
  --form email=$COVERITY_EMAIL \
  --form file=@navit.tgz \
  --form version="$CIRCLE_SHA1" \
  --form description="$CIRCLE_SHA1" \
  https://scan.coverity.com/builds?project=navit-gps

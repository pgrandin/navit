lat="37.620072"
lng="-122.399168"
dlat="37.839374"
dlng="-122.289420"

dbus-send  --print-reply --session --dest=org.navit_project.navit /org/navit_project/navit/default_navit org.navit_project.navit.navit.set_center_by_string string:"geo: $lng $lat"
dbus-send  --print-reply --session --dest=org.navit_project.navit /org/navit_project/navit/default_navit org.navit_project.navit.navit.set_position string:"geo: $lng $lat"
dbus-send  --print-reply --session --dest=org.navit_project.navit /org/navit_project/navit/default_navit org.navit_project.navit.navit.set_destination string:"geo: $dlng $dlat" string:"dbus"
sleep 1
import -window root $1/route.png
dbus-send --session --type=method_call --print-reply --dest=org.navit_project.navit /org/navit_project/navit/default_navit org.navit_project.navit.navit.export_as_geojson string:$1/h5_001.geojson

lat="37.839753"
lng="-122.297752"
dlat="37.829220"
dlng="-122.294190"
dbus-send  --print-reply --session --dest=org.navit_project.navit /org/navit_project/navit/default_navit org.navit_project.navit.navit.set_center_by_string string:"geo: $lng $lat"
dbus-send  --print-reply --session --dest=org.navit_project.navit /org/navit_project/navit/default_navit org.navit_project.navit.navit.set_position string:"geo: $lng $lat"
dbus-send  --print-reply --session --dest=org.navit_project.navit /org/navit_project/navit/default_navit org.navit_project.navit.navit.set_destination string:"geo: $dlng $dlat" string:"dbus"
sleep 1
import -window root $1/h5.png
dbus-send --session --type=method_call --print-reply --dest=org.navit_project.navit /org/navit_project/navit/default_navit org.navit_project.navit.navit.export_as_geojson string:$1/h5_002.geojson

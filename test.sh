tmux new-session -s "navit-tests" -n "navit-tests" -d
for i in 1 2; do
  tmux new-window -t "navit-tests:$i" -n "cpt-$i"
done

tmux select-window -t "navit-tests:1"


i=1
tmux send-keys -t :cpt-$i "cd ~/navit/navit/bin/navit/ && ./navit; exit" Enter
tmux select-layout tiled

i=2
tmux send-keys -t :cpt-$i "sleep 5; import -window root ~/assets/default.png; pkill navit; tmux kill-session" Enter
tmux join-pane -s :cpt-$i
tmux select-layout tiled

#tmux set-window-option synchronize-panes
tmux -2 attach-session -t "navit-tests"

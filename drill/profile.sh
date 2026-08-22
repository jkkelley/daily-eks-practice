# Installed as /etc/profile.d/drill.sh in both drill images.
#
# Alpine's own /etc/profile sets PS1='\h:\w\$ ', which shows the host and the
# directory but not who you are. Every real machine's prompt leads with the user, and
# now that the user has a name worth showing - see `callsign` - the prompt is where
# it belongs.
PS1='\u@\h:\w\$ '

# `callsign` and anything else the drill ships live here in the image. In the Vite
# preview the same directory is mounted from the repo; dev.sh puts it on PATH there.
case ":$PATH:" in
*":/usr/local/bin:"*) ;;
*) PATH="/usr/local/bin:$PATH" ;;
esac
export PATH

# $USER is not set for a shell started by a PTY rather than by login(1), and plenty
# of tooling reads it - git's default author, for one, before it falls back to the
# passwd entry. Derive it rather than leave it empty.
USER="$(id -un 2>/dev/null || echo drill)"
LOGNAME="$USER"
export USER LOGNAME

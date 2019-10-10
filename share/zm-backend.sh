#!/bin/bash
#
### BEGIN INIT INFO
# Provides:          zm-backend
# Required-Start:    $network $local_fs
# Required-Stop:     $network $local_fs
# Should-Start:      mysql postgresql
# Should-Stop:       mysql postgresql
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: Start and stop the Zonemaster Backend (RPC API daemon and Test Agent daemon)
# Description:       Control script for the two demon processes that
#                    make up the Zonemaster Backend.
### END INIT INFO

BASEDIR=${ZM_BACKEND_BASEDIR:-/usr/local}
LOGDIR=${ZM_BACKEND_LOGDIR:-/var/log/zonemaster}
PIDDIR=${ZM_BACKEND_PIDDIR:-/var/run/zonemaster}
LISTENIP=${ZM_BACKEND_LISTENIP:-127.0.0.1}
USER=${ZM_BACKEND_USER:-zonemaster}
GROUP=${ZM_BACKEND_GROUP:-zonemaster}

STARMAN=`PATH="$PATH:/usr/local/bin" /usr/bin/which starman`

testagent_args="--logfile=$LOGDIR/zonemaster_backend_testagent.log --user=$USER --group=$GROUP --pidfile=$PIDDIR/zonemaster_backend_testagent.pid"

start() {
    $STARMAN --user=$USER --group=$GROUP --error-log=$LOGDIR/zm-starman-error.log --pid=$PIDDIR/zm-starman.pid --listen=$LISTENIP:5000 --preload-app --daemonize $BASEDIR/bin/zonemaster_backend_rpcapi.psgi
    $BASEDIR/bin/zonemaster_backend_testagent $testagent_args start
}

stop() {
    if [ -f $PIDDIR/zonemaster_backend_testagent.pid ]
    then
        $BASEDIR/bin/zonemaster_backend_testagent $testagent_args stop
    fi

    if [ -f $PIDDIR/zm-starman.pid ]
    then
        kill `cat $PIDDIR/zm-starman.pid`
    fi
}

case "$1" in
    start)
        start
        ;;
    stop)
        stop
        ;;
    restart|force-reload)
        stop
        start
        ;;
    status)
        ;;
    *)
        echo "usage: $0 [start|stop|restart]"
        exit 1
esac
exit 0

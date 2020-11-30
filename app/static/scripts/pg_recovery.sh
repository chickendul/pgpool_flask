#!/bin/bash

export LANG="ko_KR.UTF-8"
export LC_ALL="ko_KR.UTF-8"


LOG_FILE="/somansa/common/log/pgpool.log"

DEBUG_MODE=0

SSH_PGPOOL_CHECK=$(ps -ef | grep pgpool | grep check | grep ssh | grep -v grep | wc -l)

PG11_EXIST=$(rpm -qa | grep postgresql11 | wc -l)

PEER_IP="10.103.31.154"

POSTGRES_PASSWORD='sms980502!'

PGPOOL_REVIVER="/somansa/common/script/pgpool_check.sh"
PGPOOL_START="/root/pgpool_start.sh"
PGPOOL_STOP="/root/pgpool_stop.sh"

CHECK_ERROR=1

SSH_PORT="22"
REP_USER="replicationuser"
MANUAL_MODE=0

export PGPORT=$(cat /var/lib/pgsql/11/data/postgresql.conf | grep port | grep -v \# | awk -F\= '{print $2}' | awk '{print $1}')

PG_ALIVE=$(sudo -i -u postgres psql -h /tmp -p $PGPORT -c "\l" | grep postgres | grep UTF8 | grep -v somansa | grep -v template | awk -F\| '{print $4}' | sed 's/^ *//')

if [ -z $PGPORT ]
then
  ERROR_LOG "Can't find the postgresql port. Will run as 5432 in 15 seconds. If there is something wrong stop by Ctrl + C."
  sleep 15
  PGPORT='5432'
fi

function DEBUG_LOG(){
    echo "[$(date +%Y)-$(date +%m)-$(date +%d) $(date +%H):$(date +%M):$(date +%S)] [DEBG] $1"
    if [ $DEBUG_MODE -eq 1 ];then
        echo "[$(date +%Y)-$(date +%m)-$(date +%d) $(date +%H):$(date +%M):$(date +%S)] [DEBG] $1" >> $LOG_FILE
    fi
}

function INFO_LOG(){
    #$1=information to log
    echo "[$(date +%Y)-$(date +%m)-$(date +%d) $(date +%H):$(date +%M):$(date +%S)] [INFO] $1"
    echo "[$(date +%Y)-$(date +%m)-$(date +%d) $(date +%H):$(date +%M):$(date +%S)] [INFO] $1" >> $LOG_FILE
}

function WARN_LOG(){
    #$1=information to log
    echo "[$(date +%Y)-$(date +%m)-$(date +%d) $(date +%H):$(date +%M):$(date +%S)] [WARN] $1"
    echo "[$(date +%Y)-$(date +%m)-$(date +%d) $(date +%H):$(date +%M):$(date +%S)] [WARN] $1" >> $LOG_FILE
}

function ERROR_LOG(){
    #$1=information to log
    echo "[$(date +%Y)-$(date +%m)-$(date +%d) $(date +%H):$(date +%M):$(date +%S)] [ERROR] $1"
    echo "[$(date +%Y)-$(date +%m)-$(date +%d) $(date +%H):$(date +%M):$(date +%S)] [ERROR] $1" >> $LOG_FILE
}

function SSH_TO_SLAVE(){
	/usr/bin/ssh -tt $PEER_IP -p $SSH_PORT "/somansa/common/script/pg_recovery.sh SLAVE"
}

function SLAVE_TO_MASTER(){
        mkdir -p /somansa/pg_backup

        BACKEND_MASTER=$(cat /etc/pgpool-II/pgpool.conf | grep backend_hostname0 | grep -v \# | awk -F\= '{print $2}' | awk '{print $1}')

        if [ $(echo $BACKEND_MASTER | grep \' | wc -l) -gt 0 ]
        then
            BACKEND_MASTER=$(echo $BACKEND_MASTER | sed "s/'//g")
        fi

        if [ $(echo $BACKEND_MASTER | grep \" | wc -l) -gt 0 ]
        then
            BACKEND_MASTER=$(echo $BACKEND_MASTER | sed "s/\"//g")
        fi

        if [ $(/usr/sbin/ifconfig | grep $BACKEND_MASTER | wc -l) -gt 0 ]
        then
            ERROR_LOG "Already configured to Master. Will end the recovery. Recover slave by manual."

            exit 0
        fi

        \cp -f /var/lib/pgsql/$PG_VER/data/postgresql.conf /somansa/pg_backup/postgresql.conf_`date +%y%m%d`

        sed -i 's/wal_level/\#wal_level/g' /var/lib/pgsql/$PG_VER/data/postgresql.conf
        sed -i 's/hot_standby/\#hot_standby/g' /var/lib/pgsql/$PG_VER/data/postgresql.conf

        echo "wal_level = hot_standby
      	max_wal_senders = 2
      	wal_keep_segments = 32" >> /var/lib/pgsql/$PG_VER/data/postgresql.conf

        /usr/bin/pgpool -m fast stop >> /somansa/pgpool.log 2>&1

        sleep 3

        if [ -e /var/run/pgpool/pgpool_status ]; then
  	       sed -i 's/down/up/g' /var/run/pgpool/pgpool_status
        else
  	       ERROR_LOG "/var/run/pgpool/pgpool_status doesn't exist."
        fi

        if [ -e /etc/pgpool-II/pgpool.conf ]; then
  	       sed -i 's/backend_hostname0/backend_hostname2/g' /etc/pgpool-II/pgpool.conf
  	       sed -i 's/backend_hostname1/backend_hostname0/g' /etc/pgpool-II/pgpool.conf
  	       sed -i 's/backend_hostname2/backend_hostname1/g' /etc/pgpool-II/pgpool.conf
        else
  	       ERROR_LOG "/etc/pgpool-II/pgpool.conf doesn't exist."
        fi

        cd /var/lib/pgsql/$PG_VER/data
        mkdir -p /somansa/pg_backup

        if [ -e recovery.done ]; then
   	        mv /var/lib/pgsql/$PG_VER/data/recovery.done /somansa/pg_backup/recovery.done.bak_`date +%y%m%d`
        else
	         WARN_LOG "/var/lib/pgsql/$PG_VER/data/recovery.done doesn't exist."
        fi

        if [ -e recovery.conf ]; then
         \cp -Rf recovery.conf recovery.slave
	       mv /var/lib/pgsql/$PG_VER/data/recovery.conf /somansa/pg_backup/recovery.bak_`date +%y%m%d`
        else
	       WARN_LOG "/var/lib/pgsql/$PG_VER/data/recovery.conf doesn't exist. Makes /var/lib/pgsql/$PG_VER/data/recovery.slave for next time recovery."
         echo "standby_mode = on
primary_conninfo = 'host=$PEER_IP port=$PGPORT user=$REP_USER password=$POSTGRES_PASSWORD'
trigger_file = '/tmp/trigger_file0'" > /var/lib/pgsql/$PG_VER/data/recovery.slave
        fi

        service postgresql-$PG_VER restart

	      sleep 10

	      WALWRITER=$(ps -ef | grep walwriter | grep -v grep | wc -l)

	      if [ $WALWRITER -eq 1 ]
	      then
		        INFO_LOG "Change to master success."
	      fi
}

function MASTER_TO_SLAVE(){
      cd /var/lib/pgsql/$PG_VER/data

			mkdir -p /somansa/pg_backup

      BACKEND_SLAVE=$(cat /etc/pgpool-II/pgpool.conf | grep backend_hostname1 | grep -v \# | awk -F\= '{print $2}' | awk '{print $1}')

      if [ $(echo $BACKEND_SLAVE | grep \' | wc -l) -gt 0 ]
      then
          BACKEND_SLAVE=$(echo $BACKEND_SLAVE | sed "s/'//g")
      fi

      if [ $(echo $BACKEND_SLAVE | grep \" | wc -l) -gt 0 ]
      then
          BACKEND_SLAVE=$(echo $BACKEND_SLAVE | sed "s/\"//g")
      fi

      if [ $(/usr/sbin/ifconfig | grep $BACKEND_SLAVE | wc -l) -gt 0 ]
      then
          if [ $MANUAL_MODE -eq 0 ]
          then
              ERROR_LOG "Already configured to slave. Will end the recovery. Recovery to slave by manual."
              exit 0
          fi
          WARN_LOG "Will pass as backend_hostname1 is correctly configured."
      else
          INFO_LOG "Change /etc/pgpool-II/pgpool.conf backend_hostname."
          sed -i 's/backend_hostname0/backend_hostname2/g' /etc/pgpool-II/pgpool.conf
          sed -i 's/backend_hostname1/backend_hostname0/g' /etc/pgpool-II/pgpool.conf
          sed -i 's/backend_hostname2/backend_hostname1/g' /etc/pgpool-II/pgpool.conf
      fi

      INFO_LOG "Backup postgres.conf, recovery.slave."
			\cp -f /var/lib/pgsql/$PG_VER/data/postgresql.conf /somansa/pg_backup/postgresql.conf_`date +%y%m%d`
			\cp -f /var/lib/pgsql/$PG_VER/data/recovery.slave /somansa/pg_backup/recovery.slave_`date +%y%m%d`
			\cp -f /var/lib/pgsql/$PG_VER/data/recovery.slave /somansa/pg_backup/recovery.slave


			mkdir -p /somansa/data/log
			mkdir -p /somansa/data/productdata
			mkdir -p /somansa/data/worm
			mkdir -p /somansa/data/log/common
			mkdir -p /somansa/data/log/maili
			mkdir -p /somansa/data/log/dbi
			mkdir -p /somansa/data/log/webkeeper
			mkdir -p /somansa/data/log/privacyi
			mkdir -p /somansa/data/log/worm
			chown -R postgres:postgres /somansa/data/log
			chown -R postgres:postgres /somansa/data/productdata
			chown -R postgres:postgres /somansa/data/worm

			service postgresql-$PG_VER stop

			sleep 10

      POSTGRES_PROC=$(ps -ef | awk '{print $1,$2}' | grep postgres)

      if [ $POSTGRES_PROC -ne 0 ]
      then
          sleep 10
          if [ $POSTGRES_PROC -ne 0 ]
          then
              ERROR_LOG "Postgresql is running. Can't do any more."

              exit 0
          fi
      fi

      rm -rf /somansa/data/log/common/*
      rm -rf /somansa/data/log/maili/*
      rm -rf /somansa/data/log/dbi/*
      rm -rf /somansa/data/log/privacyi/*
      rm -rf /somansa/data/log/webkeeper/*
      rm -rf /somansa/data/productdata/*
      rm -rf /var/lib/pgsql/$PG_VER/data/*

			sleep 10

			sudo -u postgres /usr/pgsql-$PG_VER/bin/pg_basebackup -h $PEER_IP -p $PGPORT -D /var/lib/pgsql/$PG_VER/data -U $REP_USER -v -P -X stream

			\cp -f /somansa/pg_backup/postgresql.conf_`date +%y%m%d` /var/lib/pgsql/$PG_VER/data/postgresql.conf
			\cp -f /somansa/pg_backup/recovery.slave /var/lib/pgsql/$PG_VER/data/recovery.slave

      sed -i 's/wal_level/\#wal_level/g' /var/lib/pgsql/$PG_VER/data/postgresql.conf
      sed -i 's/max_wal_senders/\#max_wal_senders/g' /var/lib/pgsql/$PG_VER/data/postgresql.conf
      sed -i 's/wal_keep_segments/\#wal_keep_segments/g' /var/lib/pgsql/$PG_VER/data/postgresql.conf
      sed -i 's/hot_standby/\#hot_standby/g' /var/lib/pgsql/$PG_VER/data/postgresql.conf

      echo "hot_standby = on" >> /var/lib/pgsql/$PG_VER/data/postgresql.conf

      chown postgres:postgres /var/lib/pgsql/$PG_VER/data/postgresql.conf
      chown postgres:postgres /var/lib/pgsql/$PG_VER/data/recovery.slave

			/usr/bin/pgpool -m fast stop >> /somansa/pgpool.log 2>&1

			sleep 3

			if [ -e /var/run/pgpool/pgpool_status ]; then
        INFO_LOG "Change pgpool status"
				sed -i 's/down/up/g' /var/run/pgpool/pgpool_status
			else
				ERROR_LOG "/var/run/pgpool/pgpool_status doesn't exist."
			fi

			if [ -e recovery.done ]; then
        INFO_LOG "Move recovery.done to pg_backup"
				mv recovery.done /somansa/pg_backup/recovery.done.bak_`date +%y%m%d`
			else
				WARN_LOG "/var/lib/pgsql/$PG_VER/data/recovery.done doesn't exist."
			fi

      INFO_LOG "Create new /var/lib/pgsql/$PG_VER/data/recovery.conf and copy recovery.slave"
      echo "standby_mode = on
primary_conninfo = 'host=$PEER_IP port=$PGPORT user=$REP_USER password=$POSTGRES_PASSWORD'
trigger_file = '/tmp/trigger_file0'" > /var/lib/pgsql/$PG_VER/data/recovery.conf
      \cp -Rf /var/lib/pgsql/$PG_VER/data/recovery.conf /var/lib/pgsql/$PG_VER/data/recovery.slave

			chown postgres:postgres /var/lib/pgsql/$PG_VER/data/recovery.conf

      INFO_LOG "Postgresql Restart"

      sleep 5

			sudo /bin/systemctl restart postgresql-11

      echo "service postgresql-$PG_VER restart"

      sleep 10
}

function CHECK_STATUS(){
	CHECK_UP=$(cat /var/run/pgpool/pgpool_status | wc -l)

	if [ $CHECK_UP -eq 2 ]
	then
		  INFO_LOG "Update finished."
	else
		  ERROR_LOG "After update there is service that is not running right. Check pgpool."
	fi

}

function CHECK_MASTER_SUCCESS(){
	MASTER_SUCCESS=$(/usr/bin/ssh $PEER_IP -p $SSH_PORT "cat /somansa/common/log/pgpool.log | tail -1 | grep \"Change to master success.\" | wc -l")

	if [ $MASTER_SUCCESS -eq 1 ]
	then
		  INFO_LOG "Slave changed to master."
	else
		  ERROR_LOG "Failed slave to change to master."

		  exit 0
	fi
}

function PGPOOL_RESTART(){
  INFO_LOG "pgpool stop"
  $PGPOOL_STOP

  /usr/bin/ssh $PEER_IP -p $SSH_PORT $PGPOOL_STOP

	sleep 10
  INFO_LOG "pgpool start"

  /usr/bin/ssh $PEER_IP -p $SSH_PORT "$PGPOOL_REVIVER"
}

function CHECK_PRESETUP(){
  INFO_LOG "/usr/bin/ssh connection by root to peer check."
  ROOT_SSH_CONNECT=$(/usr/bin/ssh root@$PEER_IP -p $SSH_PORT ls)
  WARN_LOG "If password need to be inserted, the /usr/bin/ssh-copy-id to peer root wasn't setup. Try to setup /usr/bin/ssh connection to peer as root."

  INFO_LOG "/usr/bin/ssh connection by postgres to peer check."
  POSTGRES_SSH_CONNECT=$(sudo -i -u postgres /usr/bin/ssh postgres@$PEER_IP -p $SSH_PORT ls)
  WARN_LOG "If password need to be inserted, the /usr/bin/ssh-copy-id to peer postgres wasn't setup. Try to setup /usr/bin/ssh connection to peer as postgres."

  MY_PGPASS=$(cat /var/lib/pgsql/.pgpass | wc -l)
  MY_PGPASS_PERMITION=$(stat /var/lib/pgsql/.pgpass | grep Access | grep Uid | awk '{print $2}' | awk -F\/ '{print $1}' | awk -F\( '{print $2}')
  MY_PGPASS_OWNER=$(ls -al /var/lib/pgsql/ | grep pgpass | awk '{print $3}' | grep postgres | wc -l)
  MY_PGPASS_GROUP=$(ls -al /var/lib/pgsql/ | grep pgpass | awk '{print $4}' | grep postgres | wc -l)

  DEBUG_LOG "MY PGPASS"
  DEBUG_LOG "PERMITION : $MY_PGPASS_PERMITION , OWNER/GROUP : $MY_PGPASS_OWNER / $MY_PGPASS_GROUP "

  PEER_PGPASS=$(/usr/bin/ssh $PEER_IP -p $SSH_PORT "cat /var/lib/pgsql/.pgpass | wc -l")
  PEER_PGPASS_PERMITION=$(/usr/bin/ssh $PEER_IP -p $SSH_PORT "stat /var/lib/pgsql/.pgpass | grep Access | grep Uid")
  PEER_PGPASS_PERMITION=$(echo $PEER_PGPASS_PERMITION | awk '{print $2}' | awk -F\/ '{print $1}' | awk -F\( '{print $2}')
  PEER_PGPASS_OWNER=$(/usr/bin/ssh $PEER_IP -p $SSH_PORT "ls -al /var/lib/pgsql/ | grep pgpass | awk '{print $3}' | grep postgres | wc -l")
  PEER_PGPASS_OWNER=$(/usr/bin/ssh $PEER_IP -p $SSH_PORT "ls -al /var/lib/pgsql/ | grep pgpass | awk '{print $4}' | grep postgres | wc -l")

  DEBUG_LOG "PEER PGPASS"
  DEBUG_LOG "PERMITION : $PEER_PGPASS_PERMITION , OWNER/GROUP : $PEER_PGPASS_OWNER / $PEER_PGPASS_GROUP "

  if [ $MY_PGPASS -gt 0 ] && [ $MY_PGPASS_PERMITION == "0600" ] && [ $MY_PGPASS_OWNER -eq 1 ] && [ $MY_PGPASS_GROUP -eq 1 ]
  then
      INFO_LOG "Local pgpass was setup."
      CHECK_ERROR=0
  elif [ $MY_PGPASS -eq 0 ]
  then
      ERROR_LOG "Local pgpass wasn't setup. Setup pgpass in local."
  elif [ $MY_PGPASS_PERMITION != "0600" ]
  then
      ERROR_LOG "Local pgpass permission isn't 0600. Change pgpass permission in local."
  elif [ $MY_PGPASS_OWNER -ne 1 ] || [ $MY_PGPASS_GROUP -ne 1 ]
  then
      ERROR_LOG "Local pgpass owner isn't postgres. Check both user and group in local."
  fi

  if [ $PEER_PGPASS -gt 0 ] && [ $MY_PGPASS_PERMITION == "0600" ] && [ $MY_PGPASS_OWNER -eq 1 ] && [ $MY_PGPASS_GROUP -eq 1 ]
  then
      CHECK_ERROR=0
      INFO_LOG "Peer pgpass was setup."
  elif [ $PEER_PGPASS -eq 0 ]
  then
      ERROR_LOG "Peer pgpass wasn't setup. Setup pgpass in peer."
  elif [ $PEER_PGPASS_PERMITION != "0600" ]
  then
      ERROR_LOG "Peer pgpass permission isn't 0600. Change pgpass permission in local."
  elif [ $PEER_PGPASS_OWNER -ne 1 ] || [ $PEER_PGPASS_GROUP -ne 1 ]
  then
      ERROR_LOG "Peer pgpass owner isn't postgres. Check both user and group in local."
  fi
}

function CHECK_PGVER(){
  if [ $PG11_EXIST -gt 0 ]
  then
      PG_VER=11
  else
      ERROR_LOG "Postgresql version isn't 11. Will exit progress."

      exit 0
  fi
}

function CHECK_SSH_PGPOOL_START(){
#SSH PGPOOL CHECK DOESN'T END THE CONNECTION SO KILL THE CONNECTION
  if [ $SSH_PGPOOL_CHECK -gt 0 ]
  then
      export PGPASSWORD=$POSTGRES_PASSWORD
      SSH_PGPOOL_RUNNING=$(/usr/bin/ssh $PEER_IP -p $SSH_PORT "ps -ef | grep pgpool | grep -v grep | grep -v cat | grep -v vim | grep -v tail | wc -l")
      if [ $SSH_PGPOOL_RUNNING -gt 1 ]
      then
          INFO_LOG "Killed /usr/bin/ssh pgpool check as is doesn't ends. It's not a problem only for check."
    	    kill -9 $(ps -ef | grep pgpool | grep check | grep ssh | grep -v grep | grep -v cat | grep -v vim | grep -v tail | awk '{print $2}')

          PGPOOL_RUNNING=$(ps -ef | grep pgpool | grep -v grep | grep -v cat | grep -v vim | grep -v tail | wc -l)

          if [ $PGPOOL_RUNNING -gt 1 ]
          then
              INFO_LOG "PGPool is running in local."
          else
              INFO_LOG "PGPool is not running. Start's to run local."
              $PGPOOL_REVIVER
          fi
      fi
  fi
}

function CHECK_PGPOOL_CHECK()){
  if [ ! -e $PGPOOL_REVIVER ]
  then
      echo "#!/bin/bash

      PG_POOL_RUN=$(ps -ef | grep pgpool | grep -v grep | wc -l)

      if [ $PG_POOL_RUN -gt 1 ]
      then
      	$PGPOOL_START &
      fi" > $PGPOOL_REVIVER

      chmod 755 $PGPOOL_REVIVER
  fi
}
#Only works in Postgresql-11
CHECK_PGVER

CHECK_SSH_PGPOOL_START

if [ ! -z $1 ]
then
  if [ $1 == "CHECK" ]
  then
      INFO_LOG "Check presetup"
      CHECK_PRESETUP

      exit 0
  fi

  if [ $1 == "SLAVE" ] && [ ! -z $PG_ALIVE ]
  then
      INFO_LOG "SLAVE to Master works."
    	SLAVE_TO_MASTER

    	exit 0
  elif [ -z $PG_ALIVE ]
  then
      ERROR_LOG "Postgresql service isn't running. Check postgresql."

      exit 0
  else
      MY_WALWRITER=$(ps -ef | grep walwriter | grep -v grep | wc -l)
      PEER_WALWRITER=$(/usr/bin/ssh $PEER_IP -p $SSH_PORT "ps -ef | grep walwriter | grep postgres | grep -v grep | wc -l")
      PGPOOL_UP=$(cat /var/run/pgpool/pgpool_status | grep up | grep -v grep | wc -l)
  fi

  export PGPASSWORD=$POSTGRES_PASSWORD

  PGPOOL_IP=$(cat /etc/pgpool-II/pgpool.conf | grep delegate_IP | tail -1 | awk -F\' '{print $2}')
  PGPOOL_PORT=$(cat /etc/pgpool-II/pgpool.conf | grep port\ = | grep -v pcp | grep -v wd | grep -v mem | awk '{print $3}')

  DEBUG_LOG "BEFORE PSQL TO PGPOOL"

  PGPOOL_PRIMARY_STATUS=$(psql -h $PGPOOL_IP -p $PGPOOL_PORT -U postgres -c "show pool_nodes" | grep primary | awk '{print $7}')
  PGPOOL_STANDBY_STATUS=$(psql -h $PGPOOL_IP -p $PGPOOL_PORT -U postgres -c "show pool_nodes" | grep standby | awk '{print $7}')
  PGPOOL_PRIMARY_IP=$(psql -h $PGPOOL_IP -p $PGPOOL_PORT -U postgres -c "show pool_nodes" | grep primary | awk '{print $3}')
  PGPOOL_STANDBY_IP=$(psql -h $PGPOOL_IP -p $PGPOOL_PORT -U postgres -c "show pool_nodes" | grep standby | awk '{print $3}')
  PGPOOL_STANDBY_COUNT=$(psql -h $PGPOOL_IP -p $PGPOOL_PORT -U postgres -c "show pool_nodes" | grep standby | wc -l)
  PGPOOL_STANDBY_COUNT=$(psql -h $PGPOOL_IP -p $PGPOOL_PORT -U postgres -c "show pool_nodes" | grep standby  | grep up | wc -l)

  PGPOOL_ROLE_PRIMARY_CHECK=$(/sbin/ifconfig | grep $PGPOOL_PRIMARY_IP | wc -l)
  PGPOOL_ROLE_STANDBY_CHECK=$(/sbin/ifconfig | grep $PGPOOL_STANDBY_IP | wc -l)

  DEBUG_LOG "START AUTO MODE"

  DEBUG_LOG "PGPOOL IP : $PGPOOL_IP PORT : $PGPOOL_PORT"
  DEBUG_LOG "IP P : $PGPOOL_PRIMARY_IP S : $PGPOOL_STANDBY_IP"
  DEBUG_LOG "ROLE P : $PGPOOL_ROLE_PRIMARY_CHECK S : $PGPOOL_ROLE_STANDBY_CHECK"

  if [ $PGPOOL_ROLE_PRIMARY_CHECK -eq 1 ]
  then
    	ROLE=PRIMARY
  elif [ $PGPOOL_ROLE_STANDBY_CHECK -eq 1 ]
  then
    	ROLE=STANDBY
  else
    	ERROR_LOG "Nether primary or standby ip matches. Check the setup."
  fi

  if [ $PGPOOL_PRIMARY_STATUS == "up" ] && [ $PGPOOL_STANDBY_STATUS == "down" ] && [ $1 == "AUTO" ] && [ ! -z $PG_ALIVE ] && [ $ROLE == "STANDBY" ] && [ $MY_WALWRITER -eq 1 ] && [ $PEER_WALWRITER -eq 1 ]
  then
      CHECK_PRESETUP

      if [ $CHECK_ERROR -eq 1 ]
      then
          ERROR_LOG "Error was found in presetup. Auto mode exits."
          exit 0
      fi

  	  INFO_LOG "START RECOVER"

    	SSH_TO_SLAVE

    	CHECK_MASTER_SUCCESS

    	sleep 10

    	MASTER_TO_SLAVE

    	sleep 10

    	PGPOOL_RESTART

    	sleep 10

  #  	CHECK_STATUS

    	exit 0
  elif [ $1 == "AUTO" ]
  then
    	DEBUG_LOG "Nothing to do."

    	exit 0
  fi
fi

INFO_LOG "Manual Mode"
MANUAL_MODE=1

#ORIGINAL BY HONGSIMAN
#CHANGE $PG_VER BY JYCHO

while :
do
	echo "==============================================="
        echo "1. MASTER NODE Setting(from SLAVE to MASTER)"
        echo "2. SLAVE NODE Setting(from MASTER to SLAVE)"
        echo "==============================================="
        echo "Chnage to MASTER NODE Must be done first. Postgresql will be restarted in progress."
        echo -n "Select Option > "

	read NODE
	case $NODE in
	"1")
  INFO_LOG "Slave to Master selected."

  SLAVE_TO_MASTER

  INFO_LOG "PostgreSQL MASTER NODE Setting Complete. You must to restart PG-POOL Service"
	exit 0
	;;

	"2")
  INFO_LOG "Master to slave selected."

            echo "======================="
            echo "SLAVE NODE Setting"
            echo "======================="

    cd /var/lib/pgsql/$PG_VER/data

    echo "Please, Insert the Postgresql Password"
    read dbpwd
    export PGPASSWORD=$dbpwd

    pgsqlconnect=`psql -h 127.0.0.1 -p $PGPORT -U postgres -d somansa -c "select count(*) from sms_info.sms_options"`
    dbconnect=`echo $?`

    if [ $dbconnect -ne 0 ];
    then
        ERROR_LOG "Fail to connect database. Try update again."
        exit 0
    else
        INFO_LOG "Succeed connect to database."
    fi


    MASTER_TO_SLAVE

    INFO_LOG "PostgreSQL SLAVE NODE Setting Complete. You must to Restart PG-POOL Service"

    exit 0
    ;;

	esac
done

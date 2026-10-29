#!/bin/sh
case "$*" in
    *inspect*)
        echo "/www/cloud_waf/nginx/logs/error.log"
        exit 0
        ;;
    *-t*)
        echo "nginx: the configuration file /usr/local/openresty/nginx/conf/nginx.conf syntax is ok"
        echo "nginx: configuration file /usr/local/openresty/nginx/conf/nginx.conf test is successful"
        exit 0
        ;;
    *reload*|*restart*)
        /www/cloud_waf/btw.init reload
        exit 0
        ;;
esac
exit 0

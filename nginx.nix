cfg@{ pkgs, package, user, group, ffmpeg, stateDir, errorLog, accessLog, ... }:

let
  # where does logs/error.log come from??
  writeNginxConfig = text: pkgs.runCommand "nginx.conf" { inherit text; } ''
    echo "$text" >> "$out"
    ${package}/bin/nginx -c "$out" -p $PWD -t > check.log 2>&1 || true
    grep -q 'syntax is ok' check.log
  '';
in cfg // rec {
  CORS_HTTP_ORIGIN = ".*"; # (https?://[^/]*\.awakeningchurch\.com(:[0-9]+)?)
  PUBLISH_SECRET = "secret";

  configFile = writeNginxConfig ''
    user ${cfg.user} ${cfg.group};
    daemon off;
    worker_processes auto;
    error_log ${errorLog};

    events {
      worker_connections  1024;
    }

    http {
      include ${cfg.package}/conf/mime.types;
      include ${cfg.package}/conf/fastcgi.conf;

      default_type  application/octet-stream;

      log_format  main  '$remote_addr - $remote_user [$time_local] "$request" '
                '$status $body_bytes_sent "$http_referer" '
                '"$http_user_agent" "$http_x_forwarded_for"';

      access_log ${accessLog} main;
      error_log ${errorLog};

      sendfile on;
      tcp_nopush on;
      tcp_nodelay on;
      keepalive_timeout 65;
      types_hash_max_size 2048;

      server {
        listen 80;
        error_log ${errorLog};

        location / {
          root /www;
          access_log ${accessLog} main;
        }

        location /hls {
          types {
            application/vnd.apple.mpegurl m3u8;
          }

          root /tmp;
          access_log ${accessLog} main;
          error_log ${errorLog};
          add_header Cache-Control no-cache;

          # CORS
          # based on: https://gist.github.com/algal/5480916
          # based on: https://gist.github.com/alexjs/4165271

          # if the request included an Origin: header with an origin on the whitelist,
          # then it is some kind of CORS request.

          if ($http_origin ~* ${CORS_HTTP_ORIGIN}) {
            set $cors "true";
          }

          # Nginx doesn't support nested If statements, so we use string
          # concatenation to create a flag for compound conditions

          # OPTIONS indicates a CORS pre-flight request
          if ($request_method = 'OPTIONS') {
            set $cors "''${cors}options";
          }

          # non-OPTIONS indicates a normal CORS request
          if ($request_method = 'GET') {
            set $cors "''${cors}get";
          }
          if ($request_method = 'POST') {
            set $cors "''${cors}post";
          }

          # if it's a GET or POST, set the standard CORS responses header
          if ($cors = "trueget") {
            # Tells the browser this origin may make cross-origin requests
            # (Here, we echo the requesting origin, which matched the whitelist.)
            add_header 'Access-Control-Allow-Origin' "$http_origin";
            # Tells the browser it may show the response, when XmlHttpRequest.withCredentials=true.
            add_header 'Access-Control-Allow-Credentials' 'true';
          }

          if ($cors = "truepost") {
            # Tells the browser this origin may make cross-origin requests
            # (Here, we echo the requesting origin, which matched the whitelist.)
            add_header 'Access-Control-Allow-Origin' "$http_origin";
            # Tells the browser it may show the response, when XmlHttpRequest.withCredentials=true.
            add_header 'Access-Control-Allow-Credentials' 'true';
          }

          # if it's OPTIONS, then it's a CORS preflight request so respond immediately with no response body
          if ($cors = "trueoptions") {
            # Tells the browser this origin may make cross-origin requests
            # (Here, we echo the requesting origin, which matched the whitelist.)
            add_header 'Access-Control-Allow-Origin' "$http_origin";
            # in a preflight response, tells browser the subsequent actual request can include user credentials (e.g., cookies)
            add_header 'Access-Control-Allow-Credentials' 'true';

            # Tell browser to cache this pre-flight info for 20 days
            add_header 'Access-Control-Max-Age' 1728000;

            add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS';

            add_header 'Access-Control-Allow-Headers' 'Authorization,Content-Type,Accept,Origin,User-Agent,DNT,Cache-Control,X-Mx-ReqToken,Keep-Alive,X-Requested-With,If-Modified-Since';

            # no body in this response
            add_header 'Content-Length' 0;
            # (should not be necessary, but included for non-conforming browsers)
            add_header 'Content-Type' 'text/plain charset=UTF-8';
            # indicate successful return with no content
            return 204;
          }
        }

        location /p/ {
          access_log ${accessLog} main;

          secure_link_secret "${PUBLISH_SECRET}";

          if ($secure_link = "") {
            return 403;
          }

          rewrite ^ /secure/$secure_link;
        }

        location /secure/stat {
          internal;
          access_log ${accessLog} main;
          rtmp_stat all;
        }

        location /secure/info {
          internal;
          access_log ${accessLog} main;
          rtmp_stat all;
          rtmp_stat_stylesheet /info.xsl;
        }

        location /info.xsl {
          root /www;
          access_log ${accessLog} main;
        }

      }

    }

    rtmp_auto_push on;

    rtmp {
      server {
        listen 1935;
        notify_method get;

        chunk_size 131072;
        max_message 12M;
        buflen 2s;

        access_log ${accessLog} combined;

        application pub_${PUBLISH_SECRET} {
          live on;
          drop_idle_publisher 5s;
          allow play 127.0.0.1;
          deny play all;

          exec_push ${ffmpeg}/bin/ffmpeg -i rtmp://localhost/pub_${PUBLISH_SECRET}/$name
            -filter:v scale=-1:460
            -c:a libfdk_aac -b:a 32k  -c:v libx264 -b:v 128k  -f flv rtmp://localhost/hls/$name_128
            -c:a libfdk_aac -b:a 128k -c:v libx264 -b:v 512k  -f flv rtmp://localhost/hls/$name_512;
        }

        application player {
          live on;

          allow publish 127.0.0.1;
          deny publish all;

          pull rtmp://localhost/pub_${PUBLISH_SECRET} live=1;

          wait_key on;
          wait_video on;
        }

        application hls {
          live on;
          allow publish 127.0.0.1;
          deny publish all;

          hls on;
          hls_path /tmp/hls;
          hls_fragment 15s;
          hls_nested on;

          hls_variant _128   BANDWIDTH=160000;
          hls_variant _512   BANDWIDTH=640000;
        }

      }
    }
  '';
  serviceConfig.ExecStart = "${cfg.package}/bin/nginx -c ${configFile} -p ${cfg.stateDir}";
}

FROM alpine:latest
RUN apk add --no-cache rsync sqlite
COPY sync.sh /usr/local/bin/sync.sh
RUN chmod +x /usr/local/bin/sync.sh
ENTRYPOINT ["/usr/local/bin/sync.sh"]

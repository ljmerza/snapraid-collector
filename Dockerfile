FROM alpine:3.20

RUN apk add --no-cache bash coreutils

COPY snapraid_metrics_collector.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/snapraid_metrics_collector.sh

ENTRYPOINT ["/usr/local/bin/snapraid_metrics_collector.sh"]
CMD ["--help"]

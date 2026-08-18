FROM alpine:3.20
RUN apk add --no-cache bash curl jq
COPY monitor.sh /monitor.sh
RUN sed -i 's/\r$//' /monitor.sh && chmod +x /monitor.sh
ENTRYPOINT ["/monitor.sh"]

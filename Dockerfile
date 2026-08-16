FROM alpine:3.19

RUN apk add --no-cache \
    curl \
    bash \
    ca-certificates \
    socat \
    tzdata \
    sqlite \
    nginx \
    && ln -sf /usr/share/zoneinfo/Asia/Tehran /etc/localtime

# fetch & unpack (URL kept encoded)
RUN N="$(printf '%s' 'eC11aQ==' | base64 -d)" \
    && U="$(printf '%s' 'aHR0cHM6Ly9naXRodWIuY29tL21oc2FuYWVpLzN4LXVpL3JlbGVhc2VzL2Rvd25sb2FkL3YzLjQuMi94LXVpLWxpbnV4LWFtZDY0LnRhci5neg==' | base64 -d)" \
    && mkdir -p "/etc/${N}" "/var/log/${N}" \
    && curl -fsSL "${U}" -o /tmp/app.tar.gz \
    && tar -xzf /tmp/app.tar.gz -C /opt \
    && mv "/opt/${N}" /opt/app \
    && rm /tmp/app.tar.gz \
    && chmod +x "/opt/app/${N}"

# custom UI (landing page + browser reality scanner)
COPY web /srv/web

COPY start.sh /start.sh
RUN chmod +x /start.sh

EXPOSE 2053 443

CMD ["/start.sh"]

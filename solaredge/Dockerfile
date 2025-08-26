ARG BUILD_FROM
# Val terug op Alpine base als BUILD_FROM niet gezet is (Supervisor zet dit normaal)
ARG BUILD_FROM=${BUILD_FROM:-ghcr.io/home-assistant/amd64-base:3.19}
FROM ${BUILD_FROM}

# Benodigdheden
RUN apk add --no-cache bash curl jq python3 py3-pip

WORKDIR /app
COPY run.sh /run.sh
COPY se-agent-bms.sh /app/se-agent-bms.sh

RUN chmod +x /run.sh /app/se-agent-bms.sh

ENV PYTHONUNBUFFERED=1

CMD ["/run.sh"]

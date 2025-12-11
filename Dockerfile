ARG BUILD_FROM
FROM ${BUILD_FROM}

# Python + requests + jq + CA certs voor HTTPS
RUN apk add --no-cache \
      bash \
      python3 \
      py3-pip \
      py3-virtualenv \
      py3-requests \
      jq \
      ca-certificates \
    && update-ca-certificates

WORKDIR /app
COPY run.sh /app/run.sh
COPY enphase_agent.py /app/enphase_agent.py

RUN chmod +x /app/run.sh

CMD [ "/app/run.sh" ]


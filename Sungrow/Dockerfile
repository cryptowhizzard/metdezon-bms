ARG BUILD_FROM
FROM ${BUILD_FROM}

# Minimal runtime: Python + requests + jq + CA certs for HTTPS
RUN apk add --no-cache bash python3 py3-requests jq ca-certificates && update-ca-certificates

WORKDIR /app
COPY run.sh /app/run.sh
COPY sungrow_agent.py /app/sungrow_agent.py
RUN chmod +x /app/run.sh

CMD [ "/app/run.sh" ]


FROM artifactory.algol60.net/docker.io/library/golang:1.18-alpine AS builder

RUN set -ex \
    && apk -U upgrade \
    && apk add build-base

COPY . /work

RUN set -ex \
    && cd /work \
    && go build .

### Final Stage ###
FROM artifactory.algol60.net/docker.io/alpine:3.15
LABEL maintainer="Hewlett Packard Enterprise"
STOPSIGNAL SIGTERM

# Setup environment variables.
ENV VAULT_ADDR="http://cray-vault.vault:8200"
ENV VAULT_SKIP_VERIFY="true"

# Include curl in the final image.
RUN set -ex \
    && apk -U upgrade \
    && apk add --no-cache curl

# Copy built binaries from above build step.
COPY --from=builder /work/health /usr/local/bin

# Set up the command to start the service, the run the init script.
CMD health

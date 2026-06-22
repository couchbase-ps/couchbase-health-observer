# Build the observer and run it inside the compose network so the SDK reaches
# every node by its internal address.
#
# NOTE on the runtime image: the Couchbase SDK fails to maintain KV node
# connections (ping reports all nodes unreachable) on distroless/static AND on
# debian:12-slim, even though the identical binary works on the full golang image
# and on full debian:12. Use full debian:12 for the runtime; slim/distroless drop
# something the SDK's connection management needs in this network.
FROM golang:1.26 AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN go build -o /svchealthcheck ./cmd/svchealthcheck

FROM debian:12
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /svchealthcheck /svchealthcheck
EXPOSE 8080
ENTRYPOINT ["/svchealthcheck"]

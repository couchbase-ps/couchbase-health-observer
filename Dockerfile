# Build the observer and run it as a small static image inside the compose network,
# so the SDK can reach every node by its internal address.
FROM golang:1.26 AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -o /svchealthcheck ./cmd/svchealthcheck

FROM gcr.io/distroless/static-debian12
COPY --from=build /svchealthcheck /svchealthcheck
EXPOSE 8080
ENTRYPOINT ["/svchealthcheck"]

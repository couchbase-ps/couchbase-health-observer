# Multi-arch build. Compile on the build platform but cross-compile the Go binary for the
# target platform (TARGETARCH), so buildx produces amd64 + arm64 images without emulation.
FROM --platform=$BUILDPLATFORM golang:1.26 AS build
ARG TARGETOS TARGETARCH
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} go build -o /svchealthcheck ./cmd/svchealthcheck

FROM gcr.io/distroless/static-debian12
COPY --from=build /svchealthcheck /svchealthcheck
EXPOSE 8080
ENTRYPOINT ["/svchealthcheck"]

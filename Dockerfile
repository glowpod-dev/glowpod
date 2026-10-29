# syntax=docker/dockerfile:1
# Glowpod in one small, non-root image, for amd64 and arm64.
#   docker build -t glowpod .
#   docker buildx build --platform linux/amd64,linux/arm64 -t REGISTRY/glowpod:TAG --push .
# The UI and Go stages run on the build machine's platform and cross-compile,
# so multi-arch builds don't emulate anything.

ARG VERSION=dev

FROM --platform=$BUILDPLATFORM node:26-alpine AS ui
WORKDIR /src/frontend
RUN npm install -g pnpm@12.3.4
COPY frontend/package.json frontend/pnpm-lock.yaml ./
RUN pnpm install --frozen-lockfile
COPY frontend/ ./
RUN pnpm build

FROM --platform=$BUILDPLATFORM golang:1.27-alpine AS api
ARG TARGETOS TARGETARCH VERSION
WORKDIR /src/backend
COPY backend/go.mod backend/go.sum ./
RUN go mod download
COPY backend/ ./
COPY --from=ui /src/frontend/dist ./internal/web/dist
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH \
    go build -trimpath -ldflags="-s -w -X main.version=${VERSION}" -o /glowpod ./cmd/glowpod

# Glowpod Hub in one container, like Rancher's Docker install: K3s inside,
# and the Hub on it. It needs docker run --privileged. Build it with
#   docker build --target hub -t glowpod-hub .
FROM rancher/k3s:v1.37.1-k3s1 AS hub
ARG VERSION
LABEL org.opencontainers.image.title="Glowpod Hub" \
      org.opencontainers.image.description="Glowpod Hub with K3s inside: many Kubernetes clusters, one sign-in" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.source="https://github.com/glowpod-dev/glowpod"
COPY --from=api /glowpod /bin/glowpod
# K3s, the Hub's CA and its state; keep it on a volume.
VOLUME /var/lib/glowpod
EXPOSE 80 443
ENTRYPOINT ["/bin/glowpod", "hub", "run"]

# kubectl and helm for the Hub's browser shell, checked against their
# published checksums. Fetched on the build machine for the target arch.
FROM --platform=$BUILDPLATFORM alpine:3.24.3 AS shell-tools
ARG TARGETARCH
ARG KUBECTL_VERSION=v1.37.1
ARG HELM_VERSION=v4.3.1
RUN apk add --no-cache curl
WORKDIR /tools
RUN curl -fsSLo kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl" \
 && echo "$(curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl.sha256")  kubectl" | sha256sum -c - \
 && curl -fsSLo helm.tgz "https://get.helm.sh/helm-${HELM_VERSION}-linux-${TARGETARCH}.tar.gz" \
 && echo "$(curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-${TARGETARCH}.tar.gz.sha256sum" | cut -d' ' -f1)  helm.tgz" | sha256sum -c - \
 && tar -xzf helm.tgz --strip-components=1 "linux-${TARGETARCH}/helm" \
 && chmod 0755 kubectl helm && rm helm.tgz

# The Hub's browser shell: a short-lived pod per person and cluster, with
# kubectl, helm, jq, yq and glowpod set up to act as them. Runs as non-root
# with a read-only root filesystem. Build it with --target shell.
FROM alpine:3.24.3 AS shell
ARG VERSION
LABEL org.opencontainers.image.title="Glowpod shell" \
      org.opencontainers.image.description="kubectl, helm and friends for Glowpod Hub's browser shell" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.source="https://github.com/glowpod-dev/glowpod"
RUN apk add --no-cache bash bash-completion ca-certificates jq yq less ncurses \
 && adduser -D -u 1000 -h /home/shell shell
COPY --from=shell-tools /tools/kubectl /tools/helm /usr/local/bin/
COPY --from=api /glowpod /usr/local/bin/glowpod
COPY deploy/shell/glowpod.sh /etc/bash/glowpod.sh
ENV HOME=/home/shell KUBECONFIG=/etc/glowpod/kubeconfig KUBE_EDITOR=vi
USER 1000:1000
WORKDIR /home/shell
# The pod only waits; the Hub opens bash in it with exec.
CMD ["sleep", "infinity"]

# The default image. No shell, no package manager: the binary and CA
# certificates only.
FROM gcr.io/distroless/static-debian12:nonroot
ARG VERSION
LABEL org.opencontainers.image.title="Glowpod" \
      org.opencontainers.image.description="Kubernetes dashboard: people sign in and act as themselves" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.source="https://github.com/glowpod-dev/glowpod"
COPY --from=api /glowpod /glowpod
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/glowpod", "-mode=server"]

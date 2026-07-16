# Self-contained Linux smoke-test harness for the clique-cancun fork.
#
# Bakes in BOTH the stock v1.13.15 geth and the patched geth (built for
# linux/amd64) plus the whole smoke-test suite, then runs run-all.sh.
#
# Build the two static binaries first (from the repo root):
#   CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o build/bin/geth-linux-amd64 ./cmd/geth
#   # stock v1.13.15 from the base commit c5ba367eb -> build/bin/geth-original-linux-amd64
#
# Then, from the repo root:
#   docker build -f smoke-test/Dockerfile -t clique-cancun-smoke .
#   docker run --rm clique-cancun-smoke
#
# node/npm are included so ethers-compat.sh runs (it skips gracefully otherwise).
FROM node:20-bookworm-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends curl ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# Binaries (built for linux/amd64, statically linked with CGO_ENABLED=0).
COPY build/bin/geth-original-linux-amd64 /usr/local/bin/geth-original
COPY build/bin/geth-linux-amd64          /usr/local/bin/geth-patched

# Test suite.
COPY smoke-test/ /smoke-test/

# Normalise line endings (defensive if checked out with CRLF) and make executable.
RUN sed -i 's/\r$//' /smoke-test/*.sh \
 && chmod +x /usr/local/bin/geth-original /usr/local/bin/geth-patched /smoke-test/*.sh

WORKDIR /smoke-test
ENTRYPOINT ["bash", "/smoke-test/run-all.sh", "/usr/local/bin/geth-original", "/usr/local/bin/geth-patched"]

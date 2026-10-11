# =============================================================================
# Dockerfile — a disposable sandbox to run main.sh against a clean Ubuntu
# =============================================================================
# This builds only the sandbox, not the repository: a bare Ubuntu, a non-root
# `tester` with passwordless sudo, and a policy-rc.d so apt maintainer scripts
# cannot try to start services in a container that has no init. The repository
# is NOT copied in — scripts/docker-test.sh mounts it read-only at /work, so the
# same image always runs the current working tree and every `docker run --rm`
# starts from a pristine filesystem.
#
# There is deliberately NO `# syntax=docker/dockerfile:1` line here. Such a
# directive makes every build resolve the BuildKit frontend image through
# https://auth.docker.io/token before a single instruction is parsed; the
# frontend is not cached locally, so a 504 from that endpoint (seen in the
# wild) fails the whole test run before it starts. The daemon's built-in
# frontend handles everything below — there are no heredocs or RUN --mount
# mounts that would need a newer one. Do not re-add the directive.
#
#   docker build --build-arg UBUNTU_VERSION=26.04 -t linux-utils-test:26.04 .
#   docker run --rm -v "$PWD:/work:ro" linux-utils-test:26.04
#
# or, for a whole release at once:
#
#   scripts/docker-test.sh 26.04

# The release under test. 26.04 is the current LTS and the primary target; older
# LTSes (22.04, 24.04) build from the same file and are exercised by
# scripts/docker-test.sh.
ARG UBUNTU_VERSION=26.04
FROM ubuntu:${UBUNTU_VERSION}

# Unattended: preflight auto-approves without a TTY, and sudo never prompts
# (there is no TTY to prompt on). SETUP_DESKTOP pins the desktop: a container
# has no session to detect, so step 1 would otherwise resolve `unknown` and
# install only the desktop-neutral set — leaving the GNOME path of the package
# split untested. Override at run time (scripts/docker-test.sh forwards it) to
# exercise another desktop.
ENV DEBIAN_FRONTEND=noninteractive \
    SETUP_ASSUME_YES=1 \
    SETUP_DESKTOP=gnome

# Deliberately minimal. curl and software-properties-common are NOT installed,
# so the run exercises base_packages.sh's own bootstrap instead of being handed
# them. Only sudo — needed to host the tester user — is pre-seeded.
# hadolint ignore=DL3008
RUN apt update \
    && apt install -y --no-install-recommends sudo \
    && rm -rf /var/lib/apt/lists/*

# A container has no init. Without this, a maintainer script that calls
# invoke-rc.d (docker-ce's postinst, for one) fails and takes the apt run with
# it. exit 101 tells invoke-rc.d "do not start anything".
RUN printf '#!/bin/sh\nexit 101\n' > /etc/policy-rc.d \
    && chmod +x /etc/policy-rc.d

# A normal user with passwordless sudo, closer to a real desktop than root.
RUN useradd -m -s /bin/bash tester \
    && printf 'tester ALL=(ALL) NOPASSWD:ALL\n' > /etc/sudoers.d/tester \
    && chmod 0440 /etc/sudoers.d/tester

USER tester
WORKDIR /work

# The repository is bind-mounted here by scripts/docker-test.sh. Invoked through
# `bash` so a mount that lost the executable bit still runs.
CMD ["bash", "./main.sh"]

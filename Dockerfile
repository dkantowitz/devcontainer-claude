FROM node:20

ARG TZ
ENV TZ="$TZ"

ARG CLAUDE_CODE_VERSION=latest

# Install software

## Prevent services from starting during package installation
RUN printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d && chmod +x /usr/sbin/policy-rc.d

## Set non-interactive mode for apt-get to avoid warnings during installation
ENV DEBIAN_FRONTEND=noninteractive

## ── Locale ──────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends locales \
    && sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen \
    && locale-gen \
    && apt-get clean && rm -rf /var/lib/apt/lists/*


## ── Networking Tools ─────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
      aggregate \
      dnsutils \
      iproute2 \
      ipset \
      iptables \
      netcat-openbsd \
      procps \
      traceroute \
  && apt-get clean && rm -rf /var/lib/apt/lists/*


## ── Python ───────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
      python3 \
      python3-pip \
      python3-venv \
    && apt-get clean && rm -rf /var/lib/apt/lists/*


## ── C/C++ Toolchain ──────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
      gcc g++ \
      clang clangd clang-format clang-tidy \
      bear \
      gcc-mingw-w64 g++-mingw-w64 \
      make \
      gdb \
      valgrind \
      lcov \
      cppcheck \
    && pip3 install --break-system-packages lizard \
    && apt-get clean && rm -rf /var/lib/apt/lists/*


## ── Shell Tools ─────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
      curl \
      fd-find fzf \
      git \
      jq \
      less \
      man-db \
      nano \
      inetutils-ping \
      ripgrep \
      sqlite3 sudo \
      tree \
      unzip \
      vim \
      xxd \
      wget \
      zsh \
    && ln -s /usr/bin/fdfind /usr/local/bin/fd \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# End of apt-get installs. Remove policy-rc.d to allow services to start if needed.
RUN rm /usr/sbin/policy-rc.d

## ── DuckDB ───────────────────────────────────────────────────────
ARG DUCKDB_VERSION=1.2.1
RUN curl -fsSL "https://github.com/duckdb/duckdb/releases/download/v${DUCKDB_VERSION}/duckdb_cli-linux-amd64.zip" \
        -o /tmp/duckdb.zip \
    && unzip /tmp/duckdb.zip -d /usr/local/bin/ \
    && chmod +x /usr/local/bin/duckdb \
    && rm /tmp/duckdb.zip \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

## ── git-delta ─────────────────────────────────────────────────────
ARG GIT_DELTA_VERSION=0.18.2
RUN ARCH=$(dpkg --print-architecture) && \
    wget "https://github.com/dandavison/delta/releases/download/${GIT_DELTA_VERSION}/git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb" && \
    dpkg -i "git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb" && \
    rm "git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb"


# Ensure default node user has access to /usr/local/share
RUN mkdir -p /usr/local/share/npm-global && \
    chown -R node:node /usr/local/share

ARG USERNAME=node

# Persist bash history.
RUN SNIPPET="export PROMPT_COMMAND='history -a' && export HISTFILE=/commandhistory/.bash_history" \
    && mkdir /commandhistory \
    && touch /commandhistory/.bash_history \
    && chown -R $USERNAME /commandhistory

# Set `DEVCONTAINER` environment variable to help with orientation
ENV DEVCONTAINER=true

# Create workspace and config directories and set permissions
RUN mkdir -p /workspace /home/node/.claude && \
    chown -R node:node /workspace /home/node/.claude

WORKDIR /workspace

# Set up non-root user
USER node

# Install global packages
ENV NPM_CONFIG_PREFIX=/usr/local/share/npm-global
ENV PATH=$PATH:/usr/local/share/npm-global/bin

# Set the default shell to zsh rather than sh
ENV SHELL=/bin/zsh

# Set the default editor and visual
ENV EDITOR=nano
ENV VISUAL=nano

# Default powerline10k theme
ARG ZSH_IN_DOCKER_VERSION=1.2.0
RUN sh -c "$(wget -O- https://github.com/deluan/zsh-in-docker/releases/download/v${ZSH_IN_DOCKER_VERSION}/zsh-in-docker.sh)" -- \
  -p git \
  -p fzf \
  -a "source /usr/share/doc/fzf/examples/key-bindings.zsh" \
  -a "source /usr/share/doc/fzf/examples/completion.zsh" \
  -a "export PROMPT_COMMAND='history -a' && export HISTFILE=/commandhistory/.bash_history" \
  -x

# Install Claude, then install wrapper to /usr/local/bin/claude (ahead of npm
# global bin in PATH) so that npm install -g cannot overwrite it.
RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}
COPY --chmod=755 claude-wrapper.sh /usr/local/bin/claude

# These directories get used in .devcontainer mountings to persist claude data.
RUN mkdir -p /home/node/.claude/projects \
             /home/node/.claude/commands \
             /home/node/.claude/plugins \
             /home/node/.claude/skills \
    && chown -R node:node /home/node/.claude

# Copy firewall script and set up sudoers
COPY --chmod=755 init-firewall.sh /usr/local/bin/
USER root
RUN echo "node ALL=(root) NOPASSWD: /bin/chown -R node\\:node /workspace" > /etc/sudoers.d/workspace && \
    echo "node ALL=(root) NOPASSWD: /usr/local/bin/init-firewall.sh" > /etc/sudoers.d/firewall && \
    chmod 0440 /etc/sudoers.d/firewall /etc/sudoers.d/workspace
USER node

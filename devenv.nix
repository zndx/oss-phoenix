{ pkgs, config, ... }:

let
  # Product UI lattice: signals :9889, gaius :9890, phoenix :9891, optagent :9892.
  # gRPC stays on the OTLP default so exporters can use :4317.
  uiPort = 9891;
  grpcPort = 4317;
  advertise = "tinybox.dev.vista.zndx.org";
  root = config.devenv.root;
  uiManifest = "${root}/src/phoenix/server/static/.vite/manifest.json";
in
{
  packages = with pkgs; [
    curl
    git
    gnumake
  ];

  env = {
    PHOENIX_HOST = "0.0.0.0";
    PHOENIX_PORT = toString uiPort;
    PHOENIX_GRPC_PORT = toString grpcPort;
    PHOENIX_WORKING_DIR = "${config.devenv.state}/phoenix";
    PHOENIX_TELEMETRY_ENABLED = "false";
    PHOENIX_ENABLE_AUTH = "false";
  };

  # Server and workspace packages come from pyproject.toml / uv.lock.
  # --frozen keeps a newer uv from rewriting the lock the repo pins.
  languages.python = {
    enable = true;
    package = pkgs.python312;
    venv.enable = true;
    lsp.enable = false;
    uv.enable = true;
    uv.sync.enable = true;
    uv.sync.arguments = [ "--frozen" ];
  };

  # js/package.json engines require Node >= 24.20. pnpm is the workspace manager.
  languages.javascript = {
    enable = true;
    package = pkgs.nodejs_24;
    directory = "js";
    pnpm.enable = true;
    # The nixpkgs typescript-language-server build is not needed to serve the UI.
    lsp.enable = false;
  };

  # Production bundle the Python server mounts at /. Skipped once the Vite
  # manifest is newer than the UI sources.
  # Build during the task phase, before the process daemon's 120s startup
  # budget. `devenv up -d` gives up if the daemon has not written its pid by then,
  # and a cold pnpm + Vite build does not fit in that window.
  tasks."phoenix:ui" = {
    exec = ''
      set -euo pipefail
      cd ${root}/js
      pnpm install --frozen-lockfile
      pnpm --filter 'phoenix-ui...' run build
    '';
    status = ''
      set -euo pipefail
      test -f ${uiManifest}
      newer="$(find ${root}/js/app/src ${root}/js/app/static ${root}/js/app/package.json ${root}/js/app/vite.config.mts ${root}/js/pnpm-lock.yaml ${root}/js/packages \
        -path '*/node_modules/*' -prune -o -type f -newer ${uiManifest} -print -quit || true)"
      test -z "$newer"
    '';
    before = [ "devenv:enterShell" ];
  };

  # SQLite lives under PHOENIX_WORKING_DIR. Bind every interface so WARP can
  # open http://${advertise}:${toString uiPort}.
  processes.phoenix = {
    exec = ''
      mkdir -p "$PHOENIX_WORKING_DIR"
      export PYTHONPATH=""
      exec ${config.devenv.state}/venv/bin/python -m phoenix.server.main serve \
        --host 0.0.0.0 \
        --port ${toString uiPort} \
        --grpc-port ${toString grpcPort}
    '';
    after = [ "phoenix:ui" ];
    ready.http.get = {
      host = "127.0.0.1";
      port = uiPort;
      path = "/readyz";
    };
    ready.initial_delay = 2;
    ready.period = 2;
    ready.probe_timeout = 3;
    ready.failure_threshold = 90;
    ready.timeout = 240;
  };

  enterShell = ''
    echo "phoenix: $(python --version) — devenv up -d"
    echo "  UI   http://${advertise}:${toString uiPort}"
    echo "  gRPC ${advertise}:${toString grpcPort}"
  '';
}
